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
    
    func makeUIView(context: Context) -> UIView {
        print("Creating camera preview view")
        let view = UIView()
        view.backgroundColor = .black
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        
        // Ensure the layer updates properly on orientation changes
        view.layer.masksToBounds = true
        
        // Set preview layer orientation to landscape
        if let connection = previewLayer.connection {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .landscapeRight
                print("Preview layer orientation set to landscape right")
            }
        }
        
        view.layer.addSublayer(previewLayer)
        print("Preview layer added to view with bounds: \(view.bounds)")
        
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
                
                // Ensure correct orientation
                if let connection = previewLayer.connection {
                    if connection.isVideoOrientationSupported {
                        connection.videoOrientation = .landscapeRight
                    }
                }
                
                CATransaction.commit()
                print("Updated preview layer frame to: \(uiView.bounds)")
            }
        }
    }
}