//
//  CameraManager.swift
//  multiCam
//
//  Created by Claude Code on 8/24/25.
//

import AVFoundation
import UIKit

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

        let timestamp = timeSync.getSynchronizedTime()
        let fileId = "video_\(timestamp)"
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let videoURL = documentsPath.appendingPathComponent("\(fileId).mov")

        currentVideoURL = videoURL
        currentFileId = fileId

        if let scheduledTime = scheduledTime {
            // Check if time is synchronized for scheduled recordings
            guard timeSync.isSynchronized else {
                print("Cannot accept scheduled recording: Time not synchronized")
                return
            }

            let currentSyncTime = timeSync.getSynchronizedTime()
            let delay = scheduledTime - currentSyncTime

            print("Scheduled recording: target=\(scheduledTime), current=\(currentSyncTime), delay=\(delay)s")

            if delay <= 2.0 { // 2 second immediate window to match Android
                print("Scheduled time within immediate window (\(delay)s), starting immediately")
                executeRecordingStart(to: videoURL)
            } else if delay > 0 {
                print("Scheduling recording start in \(delay) seconds using synchronized time")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    let actualStartTime = self?.timeSync.getSynchronizedTime() ?? 0
                    print("Actually starting recording at synchronized timestamp \(actualStartTime)")
                    self?.executeRecordingStart(to: videoURL)
                }
                return
            } else {
                print("Scheduled time \(scheduledTime) has already passed (current sync: \(currentSyncTime)), starting immediately")
                executeRecordingStart(to: videoURL)
            }
        } else {
            // Immediate recording
            executeRecordingStart(to: videoURL)
        }
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
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            print("Started recording to: \(fileURL)")
        }
    }
    
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            
            if let error = error {
                self.errorMessage = "Recording failed: \(error.localizedDescription)"
            } else {
                print("Recording saved to: \(outputFileURL)")
                if let fileId = self.currentFileId {
                    self.recordedFiles[fileId] = outputFileURL
                    print("Stored file mapping: \(fileId) -> \(outputFileURL.lastPathComponent)")
                    
                    // Notify callback of recording completion
                    self.onRecordingStopped?(fileId)
                }
            }
        }
    }
    
}