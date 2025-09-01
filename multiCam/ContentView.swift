//
//  ContentView.swift
//  multiCam
//
//  Created by Angus Emmett on 8/23/25.
//

import SwiftUI
import Network
import UIKit

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var networkManager = NetworkManager()
    
    var body: some View {
        ZStack {
            Group {
                if let session = cameraManager.session, cameraManager.isSetupComplete {
                    CameraPreviewView(session: session)
                        .ignoresSafeArea(.all)
                        .clipped()
                        .onAppear {
                            print("Camera preview appeared")
                        }
                } else {
                    Color.black
                        .ignoresSafeArea(.all)
                        .onAppear {
                            print("Showing black screen - setupComplete: \(cameraManager.isSetupComplete), session: \(cameraManager.session != nil)")
                            if let error = cameraManager.errorMessage {
                                print("Error: \(error)")
                            }
                        }
                }
            }
            .onChange(of: cameraManager.isSetupComplete) { setupComplete in
                print("UI detected isSetupComplete change: \(setupComplete)")
            }
            .onChange(of: cameraManager.session) { session in
                print("UI detected session change: \(session != nil)")
            }
            
            HStack {
                // Left side - Recording status
                VStack(alignment: .leading, spacing: 8) {
                    Text(cameraManager.isRecording ? "RECORDING" : "NOT RECORDING")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(cameraManager.isRecording ? .red : .white)
                    
                    Text(networkManager.connectionStatus)
                        .font(.caption)
                        .foregroundColor(networkManager.isConnected ? .green : .yellow)
                    
                    Spacer()
                }
                .padding(.leading, 20)
                .padding(.top, 20)
                
                Spacer()
                
                // Right side - Debug info
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Setup: \(cameraManager.isSetupComplete ? "✅" : "❌")")
                        .foregroundColor(.white)
                        .font(.caption)
                    Text("Session: \(cameraManager.session != nil ? "✅" : "❌")")
                        .foregroundColor(.white)
                        .font(.caption)
                    if let error = cameraManager.errorMessage {
                        Text("Error: \(error)")
                            .foregroundColor(.red)
                            .font(.caption2)
                    }
                    
                    Spacer()
                }
                .padding(.trailing, 20)
                .padding(.top, 20)
            }
        }
        .onAppear {
            // Force landscape orientation
            UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
            UINavigationController.attemptRotationToDeviceOrientation()
            
            // Store network connections that are waiting for stop recording response
            var pendingStopConnections: [NWConnection] = []
            
            networkManager.setRecordingCommandHandler { command, timestamp in
                switch command {
                case .startRecording:
                    cameraManager.startRecording()
                case .stopRecording:
                    cameraManager.stopRecording()
                case .deviceStatus, .heartbeat, .getVideo, .listFiles:
                    break
                }
            }
            
            networkManager.setScheduledStartHandler { scheduledTime in
                cameraManager.startRecording(at: scheduledTime)
            }
            
            networkManager.setStopRecordingHandler { connection in
                pendingStopConnections.append(connection)
            }
            
            cameraManager.setRecordingStoppedHandler { fileId in
                networkManager.setLastRecordedFileId(fileId)
                
                // Send responses to all pending connections
                for connection in pendingStopConnections {
                    networkManager.sendStopRecordingResponse(to: connection)
                }
                pendingStopConnections.removeAll()
            }
            
            networkManager.setGetVideoHandler { fileId in
                return cameraManager.getVideoURL(for: fileId)
            }
            
            networkManager.setListFilesHandler {
                return cameraManager.getAllVideoFiles()
            }
        }
    }
}

#Preview {
    ContentView()
}
