//
//  CameraPreviewView.swift
//  multiCam
//
//  Created by Claude Code on 8/24/25.
//

import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeUIView(context: Context) -> UIView {
        print("Creating camera preview view")
        let view = UIView()
        view.backgroundColor = .black
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        
        // Ensure the layer updates properly on orientation changes
        view.layer.masksToBounds = true
        
        // Set initial preview layer orientation based on current device orientation
        if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
            if let videoOrientation = Self.currentVideoOrientation {
                connection.videoOrientation = videoOrientation
                print("Preview layer orientation set to \(videoOrientation)")
            }
        }
        
        view.layer.addSublayer(previewLayer)

        // Store the previewLayer reference inside coordinator for orientation updates
        context.coordinator.previewLayer = previewLayer

        // Observe orientation changes
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.orientationDidChange),
                                               name: UIDevice.orientationDidChangeNotification,
                                               object: nil)
        
        #if targetEnvironment(simulator)
        print("Running in simulator - camera preview may not work")
        let label = UILabel()
        label.text = "Camera Preview\n(Landscape Mode)"
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = UIFont.systemFont(ofSize: 16)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        #endif
        
        print("Preview view setup complete")
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        print("Updating preview view with bounds: \(uiView.bounds)")
        if let previewLayer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            DispatchQueue.main.async {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                previewLayer.frame = uiView.bounds
                
                // Ensure correct orientation matches current device orientation
                if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
                    if let videoOrientation = Self.currentVideoOrientation {
                        connection.videoOrientation = videoOrientation
                    }
                }
                
                CATransaction.commit()
                print("Updated preview layer frame to: \(uiView.bounds)")
            }
        }
    }
}

private extension CameraPreviewView {
    /// Translate the current `UIDeviceOrientation` to an `AVCaptureVideoOrientation` limited to landscape cases.
    static var currentVideoOrientation: AVCaptureVideoOrientation? {
        // Prefer interface orientation (stable) over device orientation due to some edge cases
        if let interfaceOrientation = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.interfaceOrientation {
            if interfaceOrientation.isLandscape {
                return interfaceOrientation == .landscapeLeft ? .landscapeLeft : .landscapeRight
            }
        }
        // Fallback to device orientation
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        default:
            return nil
        }
    }
}

// MARK: - Coordinator

extension CameraPreviewView {
    class Coordinator: NSObject {
        weak var previewLayer: AVCaptureVideoPreviewLayer?

        @objc func orientationDidChange() {
            guard let previewLayer, let connection = previewLayer.connection, connection.isVideoOrientationSupported else { return }
            if let newOrientation = CameraPreviewView.currentVideoOrientation, connection.videoOrientation != newOrientation {
                connection.videoOrientation = newOrientation
                // Ensure the layer redraws correctly
                previewLayer.frame = previewLayer.superlayer?.bounds ?? .zero
            }
        }
    }
}