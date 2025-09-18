//
//  CameraManager.swift
//  multiCam
//
//  Created by Claude Code on 8/24/25.
//

import AVFoundation
import UIKit
import CoreMedia

@MainActor
class CameraManager: NSObject, ObservableObject {
    @Published var isRecording = false {
        didSet {
            print("isRecording changed to: \(isRecording)")
        }
    }

    @Published var isSetupComplete = false {
        didSet {
            print("isSetupComplete changed to: \(isSetupComplete)")
        }
    }

    @Published var errorMessage: String? {
        didSet {
            print("errorMessage changed to: \(errorMessage ?? "nil")")
        }
    }

    @Published var session: AVCaptureSession? {
        didSet {
            print("session changed to: \(session != nil ? "non-nil" : "nil")")
        }
    }

    // Time synchronization
    let timeSync = TimeSync()
    
    private var videoOutput: AVCaptureMovieFileOutput?
    private var currentVideoURL: URL?
    private var currentFileId: String?
    private var recordedFiles: [String: URL] = [:]
    private var onRecordingStopped: ((String) -> Void)?

    // Immediate recording + trimming properties
    private var commandReceivedTime: TimeInterval = 0
    private var targetStartTime: TimeInterval = 0
    private var actualRecordingStartTime: TimeInterval = 0
    private var firstFramePresentationTime: CMTime = CMTime.zero
    private var captureStartTime: CMTime = CMTime.zero

    // Recording state for immediate mode
    private var isImmediateRecording = false
    private var tempRecordingURL: URL?
    private var finalRecordingURL: URL?
    private var scheduledDuration: TimeInterval = 0

    // iOS version detection for startPTS support
    private var supportsStartPTS: Bool {
        if #available(iOS 18.2, *) {
            return true
        }
        return false
    }
    
    override init() {
        super.init()
        setupCamera()

        // Start NTP synchronization immediately
        Task {
            await timeSync.synchronizeTime()
        }
    }
    
    private func setupCamera() {
        Task { @MainActor in
            do {
                print("Starting camera setup")
                await requestCameraPermission()
                await configureSession()
                print("Camera setup completed")
            } catch {
                print("Camera setup error: \(error.localizedDescription)")
                self.errorMessage = error.localizedDescription
            }
        }
    }
    
    private func requestCameraPermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        print("Camera permission status: \(status.rawValue)")
        
        if status == .notDetermined {
            print("Requesting camera permission...")
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            print("Camera permission granted: \(granted)")
            if !granted {
                self.errorMessage = "Camera permission denied"
                return
            }
        } else if status != .authorized {
            print("Camera permission not authorized")
            self.errorMessage = "Camera permission not granted"
            return
        }
    }
    
    private func configureSession() async {
        print("Configuring capture session...")
        let session = AVCaptureSession()
        session.beginConfiguration()
        
        session.sessionPreset = .hd1920x1080
        print("Session preset set to 1080p")
        
        guard let camera = selectBackCameraPreferUltraWide() else {
            print("Could not access camera device")
            self.errorMessage = "Could not access camera"
            return
        }
        print("Camera device found: \(camera.localizedName)")
        
        do {
            let videoInput = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            } else {
                self.errorMessage = "Could not add video input"
                return
            }
            // Additional configuration: lock device and set frame-rate / zoom preferences
            do {
                try camera.lockForConfiguration()
                // Force 1080p/30 if supported
                let ranges = camera.activeFormat.videoSupportedFrameRateRanges
                if ranges.contains(where: { $0.minFrameRate <= 30 && 30 <= $0.maxFrameRate }) {
                    camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                    camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                }
                // If virtual multi-camera, bias to ultra-wide by zooming to minimum factor
                if camera.deviceType == .builtInDualWideCamera || camera.deviceType == .builtInTripleCamera {
                    let target = camera.minAvailableVideoZoomFactor
                    camera.videoZoomFactor = max(target, 1.0)
                }
                camera.unlockForConfiguration()
            } catch {
                self.errorMessage = "Could not configure camera: \(error.localizedDescription)"
                return
            }
        } catch {
            self.errorMessage = "Could not create video input: \(error.localizedDescription)"
            return
        }
        
        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            self.errorMessage = "Could not access microphone"
            return
        }
        
        do {
            let audioInput = try AVCaptureDeviceInput(device: microphone)
            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
            }
        } catch {
            self.errorMessage = "Could not create audio input: \(error.localizedDescription)"
            return
        }
        
        let movieOutput = AVCaptureMovieFileOutput()
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            
            if let connection = movieOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
                
                // Set video orientation to landscape
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .landscapeRight
                    print("Video orientation set to landscape right")
                }
            }
        } else {
            self.errorMessage = "Could not add movie output"
            return
        }
        
        session.commitConfiguration()
        
        self.session = session
        self.videoOutput = movieOutput
        print("Session configured, setting isSetupComplete = true")
        
        // Explicitly ensure UI update happens on main thread
        await MainActor.run {
            self.isSetupComplete = true
            print("isSetupComplete set to true on main thread")
        }
        
        Task.detached { [weak session] in
            print("Starting session on background thread...")
            session?.startRunning()
            print("Session started!")
        }
    }
    
    private func selectBackCameraPreferUltraWide() -> AVCaptureDevice? {
        // Prefer the 0.5× ultra-wide camera when available, otherwise fall back to other back cameras.
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera,     // 0.5× if available
            .builtInDualWideCamera,      // virtual device: ultra-wide + wide
            .builtInTripleCamera,        // virtual device: ultra-wide + wide + tele
            .builtInWideAngleCamera      // fallback (iPhone 8, etc.)
        ]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                         mediaType: .video,
                                                         position: .back)
        let devices = discovery.devices
        if let uw = devices.first(where: { $0.deviceType == .builtInUltraWideCamera }) { return uw }
        if let virt = devices.first(where: { $0.deviceType == .builtInDualWideCamera || $0.deviceType == .builtInTripleCamera }) { return virt }
        return devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
    }
    
    func startRecording(at scheduledTime: TimeInterval? = nil) {
        guard let videoOutput = videoOutput,
              !videoOutput.isRecording else { return }

        if let scheduledTime = scheduledTime {
            // Check if time is synchronized for scheduled recordings
            guard timeSync.isSynchronized else {
                print("Cannot accept scheduled recording: Time not synchronized")
                return
            }

            // Use immediate recording with trimming for scheduled recordings
            // Duration will be calculated when STOP command is received
            startImmediateRecording(targetTime: scheduledTime)
        } else {
            // Legacy immediate recording (no trimming)
            let timestamp = timeSync.getSynchronizedTime()
            let fileId = "video_\(timestamp)"
            let documentsPath = getDocumentsDirectory()
            let videoURL = documentsPath.appendingPathComponent("\(fileId).mov")

            currentVideoURL = videoURL
            currentFileId = fileId
            executeRecordingStart(to: videoURL)
        }
    }

    func startImmediateRecording(targetTime: TimeInterval) {
        guard let videoOutput = videoOutput,
              !videoOutput.isRecording else { return }

        // Store timing information
        commandReceivedTime = timeSync.getSynchronizedTime()
        targetStartTime = targetTime
        scheduledDuration = 0 // Will be calculated when recording stops
        isImmediateRecording = true

        // Create temporary file URL
        let timestamp = Date().timeIntervalSince1970
        let tempFileName = "temp_recording_\(timestamp).mov" 
        tempRecordingURL = getDocumentsDirectory().appendingPathComponent(tempFileName)

        // Create final file URL
        let finalFileName = "video_\(targetTime).mov"
        finalRecordingURL = getDocumentsDirectory().appendingPathComponent(finalFileName)
        currentFileId = "video_\(targetTime)"

        print("🚀 Starting immediate recording for target time: \(targetTime)")
        print("📂 Temp file: \(tempRecordingURL?.lastPathComponent ?? "nil")")
        print("📁 Final file: \(finalRecordingURL?.lastPathComponent ?? "nil")")
        print("⏱️ Command received at: \(commandReceivedTime)")

        // Start recording immediately to temp file
        videoOutput.startRecording(to: tempRecordingURL!, recordingDelegate: self)
        isRecording = true
    }
    
    private func executeRecordingStart(to videoURL: URL) {
        guard let videoOutput = videoOutput else { return }
        
        let actualStartTime = Date().timeIntervalSince1970
        print("Actually starting recording at timestamp \(actualStartTime)")
        
        videoOutput.startRecording(to: videoURL, recordingDelegate: self)
        isRecording = true
    }
    
    func stopRecording() {
        guard let videoOutput = videoOutput,
              videoOutput.isRecording else { return }

        print("🛑 Stopping recording...")
        videoOutput.stopRecording()
    }
    
    func getDocumentsDirectory() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    func listSavedVideos() -> [URL] {
        let documentsPath = getDocumentsDirectory()
        
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: nil)
            return fileURLs.filter { $0.pathExtension.lowercased() == "mov" }
        } catch {
            print("Error listing videos: \(error)")
            return []
        }
    }
    
    func getVideoURL(for fileId: String) -> URL? {
        // First check if it's a file from current session
        if let url = recordedFiles[fileId] {
            return url
        }
        
        // If not found, check the Documents directory for existing files
        let documentsPath = getDocumentsDirectory()
        let potentialURL = documentsPath.appendingPathComponent("\(fileId).mov")
        
        if FileManager.default.fileExists(atPath: potentialURL.path) {
            return potentialURL
        }
        
        return nil
    }
    
    func getCurrentFileId() -> String? {
        return currentFileId
    }
    
    func setRecordingStoppedHandler(_ handler: @escaping (String) -> Void) {
        self.onRecordingStopped = handler
    }
    
    func getAllVideoFiles() -> [FileMetadata] {
        let documentsPath = getDocumentsDirectory()
        var files: [FileMetadata] = []

        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])

            for url in fileURLs {
                guard url.pathExtension.lowercased() == "mov" else { continue }

                let fileName = url.lastPathComponent
                let fileId = String(fileName.dropLast(4)) // Remove .mov extension

                let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])

                let fileSize = Int64(resourceValues.fileSize ?? 0)
                let creationDate = resourceValues.creationDate?.timeIntervalSince1970 ?? 0
                let modificationDate = resourceValues.contentModificationDate?.timeIntervalSince1970 ?? 0

                let metadata = FileMetadata(
                    fileId: fileId,
                    fileName: fileName,
                    fileSize: fileSize,
                    creationDate: creationDate,
                    modificationDate: modificationDate
                )

                files.append(metadata)
            }

            // Sort by creation date, newest first
            files.sort { $0.creationDate > $1.creationDate }

        } catch {
            print("Error getting file metadata: \(error)")
        }

        return files
    }

    // MARK: - Video Trimming Implementation

    private func trimVideoToTarget() {
        guard let tempURL = tempRecordingURL,
              let finalURL = finalRecordingURL else {
            print("❌ Missing URLs for trimming")
            return
        }

        let asset = AVAsset(url: tempURL)

        // Calculate trim offset
        let trimOffsetSeconds = targetStartTime - actualRecordingStartTime
        let trimStartTime = CMTime(seconds: max(0, trimOffsetSeconds), preferredTimescale: 600)

        // Calculate the actual duration to keep (from target start time until recording stop)
        let effectiveRecordingDuration = scheduledDuration - max(0, trimOffsetSeconds)

        // Safety check: if trim offset is larger than total duration, use a minimal duration
        let finalDuration = max(0.1, effectiveRecordingDuration) // Minimum 0.1s
        let recordingDuration = CMTime(seconds: finalDuration, preferredTimescale: 600)

        print("✂️ Trimming video:")
        print("   • Trim offset: \(trimOffsetSeconds)s")
        print("   • Start time: \(trimStartTime)")
        print("   • Total recorded duration: \(scheduledDuration)s")
        print("   • Effective duration: \(effectiveRecordingDuration)s")
        print("   • Final duration: \(finalDuration)s")

        // Create export session
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            print("❌ Failed to create export session")
            fallbackToTempFile()
            return
        }

        // Set trim range
        let trimRange = CMTimeRange(start: trimStartTime, duration: recordingDuration)
        exportSession.timeRange = trimRange
        exportSession.outputURL = finalURL
        exportSession.outputFileType = .mov

        // Export trimmed video
        exportSession.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                self?.handleTrimCompletion(exportSession: exportSession)
            }
        }
    }

    private func handleTrimCompletion(exportSession: AVAssetExportSession) {
        switch exportSession.status {
        case .completed:
            print("✅ Video trimming completed successfully")

            // Store final file reference
            if let finalURL = finalRecordingURL,
               let fileId = currentFileId {
                recordedFiles[fileId] = finalURL
                print("📁 Final video stored: \(finalURL.lastPathComponent)")

                // Notify completion
                onRecordingStopped?(fileId)
            }

            // Cleanup
            cleanupTempFiles()

        case .failed:
            print("❌ Video trimming failed: \(exportSession.error?.localizedDescription ?? "Unknown error")")
            fallbackToTempFile()

        case .cancelled:
            print("⚠️ Video trimming cancelled")
            fallbackToTempFile()

        default:
            print("⚠️ Video trimming status: \(exportSession.status.rawValue)")
            fallbackToTempFile()
        }

        // Reset state
        isImmediateRecording = false
    }

    private func handleNormalRecordingCompletion(_ outputFileURL: URL) {
        print("Recording saved to: \(outputFileURL)")
        if let fileId = currentFileId {
            recordedFiles[fileId] = outputFileURL
            print("Stored file mapping: \(fileId) -> \(outputFileURL.lastPathComponent)")

            // Notify callback of recording completion
            onRecordingStopped?(fileId)
        }
    }

    private func fallbackToTempFile() {
        guard let tempURL = tempRecordingURL,
              let finalURL = finalRecordingURL else { return }

        // If trimming fails, use the original temp file
        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: finalURL)

            if let fileId = currentFileId {
                recordedFiles[fileId] = finalURL
                onRecordingStopped?(fileId)
            }

            print("⚠️ Used fallback temp file due to trimming failure")
        } catch {
            print("❌ Fallback failed: \(error)")
        }

        // Don't call cleanupTempFiles here since we moved the temp file
        tempRecordingURL = nil
    }

    private func cleanupTempFiles() {
        if let tempURL = tempRecordingURL,
           FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }
        tempRecordingURL = nil
    }

    private func logPerformanceMetrics() {
        let commandToRecordLatency = actualRecordingStartTime - commandReceivedTime
        let targetAccuracy = abs(targetStartTime - actualRecordingStartTime)

        print("📊 Performance Metrics:")
        print("   • Command to record latency: \(Int(commandToRecordLatency * 1000))ms")
        print("   • Target timing accuracy: \(Int(targetAccuracy * 1000))ms")
        print("   • Supports startPTS: \(supportsStartPTS)")
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    // iOS 18.2+ with precise startPTS
    @available(iOS 18.2, *)
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                               didStartRecordingTo fileURL: URL,
                               startPTS: CMTime,
                               from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            self.actualRecordingStartTime = self.timeSync.getSynchronizedTime()
            self.firstFramePresentationTime = startPTS

            print("🎬 Recording started with precise startPTS: \(startPTS)")
            print("🕐 Actual start time: \(self.actualRecordingStartTime)")
            print("🎯 Target start time: \(self.targetStartTime)")

            if self.isImmediateRecording {
                let timingOffset = self.targetStartTime - self.actualRecordingStartTime
                print("⏱️ Timing offset: \(timingOffset)s")
                self.logPerformanceMetrics()
            }
        }
    }

    // iOS < 18.2 fallback
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            self.actualRecordingStartTime = self.timeSync.getSynchronizedTime()

            // Capture session synchronization clock time as fallback
            if let session = self.session, let syncClock = session.synchronizationClock {
                self.captureStartTime = syncClock.time
            }

            print("🎬 Recording started (legacy): \(self.actualRecordingStartTime)")

            if self.isImmediateRecording {
                print("🎯 Target start time: \(self.targetStartTime)")
                let timingOffset = self.targetStartTime - self.actualRecordingStartTime
                print("⏱️ Timing offset: \(timingOffset)s")
                self.logPerformanceMetrics()
            }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false

            if let error = error {
                print("❌ Recording error: \(error)")
                self.errorMessage = "Recording failed: \(error.localizedDescription)"
                self.cleanupTempFiles()
                return
            }

            if self.isImmediateRecording {
                print("✅ Immediate recording completed, starting trim process...")

                // Calculate actual recording duration
                let recordingStopTime = self.timeSync.getSynchronizedTime()
                let actualRecordingDuration = recordingStopTime - self.actualRecordingStartTime
                self.scheduledDuration = actualRecordingDuration

                print("🕐 Recording duration: \(actualRecordingDuration)s")
                self.trimVideoToTarget()
            } else {
                // Handle normal recording completion
                self.handleNormalRecordingCompletion(outputFileURL)
            }
        }
    }
}
