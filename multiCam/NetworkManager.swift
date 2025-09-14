import Foundation
import Network
import Combine
import UIKit

enum RecordingCommand: String, Codable {
    case startRecording = "START_RECORDING"
    case stopRecording = "STOP_RECORDING"
    case deviceStatus = "DEVICE_STATUS"
    case heartbeat = "HEARTBEAT"
    case getVideo = "GET_VIDEO"
    case listFiles = "LIST_FILES"
}

struct CommandMessage: Codable {
    let command: RecordingCommand
    let timestamp: TimeInterval?
    let deviceId: String?
    let fileId: String?
    
    init(command: RecordingCommand, timestamp: TimeInterval? = nil, deviceId: String? = nil, fileId: String? = nil) {
        self.command = command
        self.timestamp = timestamp
        self.deviceId = deviceId
        self.fileId = fileId
    }
}

struct StatusResponse: Codable {
    let deviceId: String
    let status: String
    let timestamp: TimeInterval
    let isRecording: Bool
    let fileId: String?
    let fileSize: Int64?
}

struct FileResponse: Codable {
    let deviceId: String
    let fileId: String
    let fileName: String
    let fileSize: Int64
    let status: String
}

struct FileMetadata: Codable {
    let fileId: String
    let fileName: String
    let fileSize: Int64
    let creationDate: TimeInterval
    let modificationDate: TimeInterval
}

struct ListFilesResponse: Codable {
    let deviceId: String
    let status: String
    let timestamp: TimeInterval
    let files: [FileMetadata]
}

@MainActor
class NetworkManager: NSObject, ObservableObject {
    @Published var isConnected = false
    @Published var connectionStatus = "Disconnected"
    @Published var connectedDevices: [String] = []
    
    private var listener: NWListener?
    private var connection: NWConnection?
    private var netService: NetService?
    private let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    private let port: NWEndpoint.Port = 8080
    
    private var onRecordingCommand: ((RecordingCommand, TimeInterval?) -> Void)?
    private var onScheduledStartCommand: ((TimeInterval) -> Void)?
    private var onGetVideoCommand: ((String) -> URL?)?
    private var onStopRecordingCommand: ((NWConnection) -> Void)?
    private var onListFilesCommand: (() -> [FileMetadata])?
    private var onSyncStatusCheck: (() -> Bool)?
    private var lastRecordedFileId: String?
    
    override init() {
        super.init()
        setupNetworkListener()
        startBonjourService()
    }
    
    deinit {
        Task { @MainActor in
            stopListener()
            stopBonjourService()
        }
    }
    
    func setRecordingCommandHandler(_ handler: @escaping (RecordingCommand, TimeInterval?) -> Void) {
        self.onRecordingCommand = handler
    }
    
    func setGetVideoHandler(_ handler: @escaping (String) -> URL?) {
        self.onGetVideoCommand = handler
    }
    
    func setStopRecordingHandler(_ handler: @escaping (NWConnection) -> Void) {
        self.onStopRecordingCommand = handler
    }
    
    func setScheduledStartHandler(_ handler: @escaping (TimeInterval) -> Void) {
        self.onScheduledStartCommand = handler
    }
    
    func setListFilesHandler(_ handler: @escaping () -> [FileMetadata]) {
        self.onListFilesCommand = handler
    }

    func setSyncStatusHandler(_ handler: @escaping () -> Bool) {
        self.onSyncStatusCheck = handler
    }
    
    func setLastRecordedFileId(_ fileId: String) {
        self.lastRecordedFileId = fileId
    }
    
    func sendStopRecordingResponse(to connection: NWConnection) {
        let response = StatusResponse(
            deviceId: deviceId,
            status: "Recording stopped",
            timestamp: Date().timeIntervalSince1970,
            isRecording: false,
            fileId: lastRecordedFileId,
            fileSize: nil
        )
        
        sendResponse(response, to: connection)
    }
    
    private func setupNetworkListener() {
        do {
            listener = try NWListener(using: .tcp, on: port)
            
            listener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewConnection(connection)
                }
            }
            
            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.connectionStatus = "Listening for connections"
                        print("NetworkManager: Listener ready on port \(self?.port.rawValue ?? 0)")
                    case .failed(let error):
                        self?.connectionStatus = "Failed: \(error.localizedDescription)"
                        print("NetworkManager: Listener failed with error: \(error)")
                    case .cancelled:
                        self?.connectionStatus = "Cancelled"
                        print("NetworkManager: Listener cancelled")
                    default:
                        break
                    }
                }
            }
            
            listener?.start(queue: .global(qos: .userInitiated))
        } catch {
            connectionStatus = "Failed to create listener: \(error.localizedDescription)"
            print("NetworkManager: Failed to create listener: \(error)")
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        self.connection = connection
        self.isConnected = true
        self.connectionStatus = "Connected to controller"
        
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    print("NetworkManager: Connection ready")
                    self?.receiveMessage(connection: connection)
                case .failed(let error):
                    print("NetworkManager: Connection failed: \(error)")
                    self?.isConnected = false
                    self?.connectionStatus = "Connection failed"
                case .cancelled:
                    print("NetworkManager: Connection cancelled")
                    self?.isConnected = false
                    self?.connectionStatus = "Connection cancelled"
                default:
                    break
                }
            }
        }
        
        connection.start(queue: .global(qos: .userInitiated))
    }
    
    private func receiveMessage(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            if let error = error {
                print("NetworkManager: Receive error: \(error)")
                return
            }
            
            if let data = data, !data.isEmpty {
                self?.processReceivedData(data, connection: connection)
            }
            
            if !isComplete {
                self?.receiveMessage(connection: connection)
            }
        }
    }
    
    private func processReceivedData(_ data: Data, connection: NWConnection) {
        do {
            let message = try JSONDecoder().decode(CommandMessage.self, from: data)
            print("NetworkManager: Received command: \(message.command.rawValue)")
            
            Task { @MainActor in
                if message.command == .getVideo {
                    self.handleGetVideoRequest(message, connection: connection)
                } else if message.command == .listFiles {
                    self.handleListFilesRequest(connection: connection)
                } else if message.command == .stopRecording {
                    // Handle stop recording specially - don't send response immediately
                    self.onRecordingCommand?(message.command, message.timestamp)
                    self.onStopRecordingCommand?(connection)
                } else if message.command == .startRecording && message.timestamp != nil {
                    // Handle scheduled start recording - check sync status first
                    print("NetworkManager: Received scheduled start recording for timestamp \(message.timestamp!)")

                    // Get sync status from camera manager (via callback)
                    // For now, we'll add a sync check callback
                    if let syncCheck = self.onSyncStatusCheck?(), !syncCheck {
                        let response = StatusResponse(
                            deviceId: self.deviceId,
                            status: "Time not synchronized",
                            timestamp: Date().timeIntervalSince1970,
                            isRecording: false,
                            fileId: nil,
                            fileSize: nil
                        )
                        self.sendResponse(response, to: connection)
                        return
                    }

                    self.onScheduledStartCommand?(message.timestamp!)

                    let response = StatusResponse(
                        deviceId: self.deviceId,
                        status: "Scheduled recording accepted",
                        timestamp: Date().timeIntervalSince1970,
                        isRecording: false,
                        fileId: nil,
                        fileSize: nil
                    )

                    self.sendResponse(response, to: connection)
                } else {
                    self.onRecordingCommand?(message.command, message.timestamp)
                    
                    let response = StatusResponse(
                        deviceId: self.deviceId,
                        status: "Command received",
                        timestamp: Date().timeIntervalSince1970,
                        isRecording: message.command == .startRecording,
                        fileId: nil,
                        fileSize: nil
                    )
                    
                    self.sendResponse(response, to: connection)
                }
            }
        } catch {
            print("NetworkManager: Failed to decode message: \(error)")
        }
    }
    
    private func sendResponse(_ response: StatusResponse, to connection: NWConnection) {
        do {
            let data = try JSONEncoder().encode(response)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    print("NetworkManager: Failed to send response: \(error)")
                } else {
                    print("NetworkManager: Response sent successfully")
                }
            })
        } catch {
            print("NetworkManager: Failed to encode response: \(error)")
        }
    }
    
    private func startBonjourService() {
        netService = NetService(domain: "", type: "_multicam._tcp.", name: "multiCam-\(deviceId)", port: Int32(port.rawValue))
        netService?.delegate = self
        netService?.publish()
        print("NetworkManager: Started Bonjour service: multiCam-\(deviceId)")
    }
    
    private func stopBonjourService() {
        netService?.stop()
        netService = nil
    }
    
    private func stopListener() {
        listener?.cancel()
        connection?.cancel()
        listener = nil
        connection = nil
        isConnected = false
        connectionStatus = "Disconnected"
    }
    
    func sendHeartbeat() {
        guard let connection = connection, isConnected else { return }
        
        let heartbeat = CommandMessage(command: .heartbeat, deviceId: deviceId)
        do {
            let data = try JSONEncoder().encode(heartbeat)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    print("NetworkManager: Failed to send heartbeat: \(error)")
                }
            })
        } catch {
            print("NetworkManager: Failed to encode heartbeat: \(error)")
        }
    }
    
    private func handleGetVideoRequest(_ message: CommandMessage, connection: NWConnection) {
        guard let fileId = message.fileId,
              let fileURL = onGetVideoCommand?(fileId) else {
            sendErrorResponse("File not found", to: connection)
            return
        }
        
        do {
            let fileData = try Data(contentsOf: fileURL)
            let fileName = fileURL.lastPathComponent
            
            let fileResponse = FileResponse(
                deviceId: deviceId,
                fileId: fileId,
                fileName: fileName,
                fileSize: Int64(fileData.count),
                status: "ready"
            )
            
            let headerData = try JSONEncoder().encode(fileResponse)
            var headerSize = UInt32(headerData.count).bigEndian
            
            var combinedData = Data()
            combinedData.append(withUnsafeBytes(of: &headerSize) { Data($0) })
            combinedData.append(headerData)
            combinedData.append(fileData)
            
            print("NetworkManager: Sending file \(fileName) (\(fileData.count) bytes)")
            
            connection.send(content: combinedData, completion: .contentProcessed { error in
                if let error = error {
                    print("NetworkManager: Failed to send file: \(error)")
                } else {
                    print("NetworkManager: File sent successfully")
                }
            })
            
        } catch {
            print("NetworkManager: Error reading file: \(error)")
            sendErrorResponse("Error reading file: \(error.localizedDescription)", to: connection)
        }
    }
    
    private func handleListFilesRequest(connection: NWConnection) {
        let files = onListFilesCommand?() ?? []
        
        let response = ListFilesResponse(
            deviceId: deviceId,
            status: "Files listed successfully",
            timestamp: Date().timeIntervalSince1970,
            files: files
        )
        
        do {
            let data = try JSONEncoder().encode(response)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    print("NetworkManager: Failed to send list files response: \(error)")
                } else {
                    print("NetworkManager: List files response sent successfully (\(files.count) files)")
                }
            })
        } catch {
            print("NetworkManager: Failed to encode list files response: \(error)")
            sendErrorResponse("Error listing files: \(error.localizedDescription)", to: connection)
        }
    }
    
    private func sendErrorResponse(_ errorMessage: String, to connection: NWConnection) {
        let response = StatusResponse(
            deviceId: deviceId,
            status: errorMessage,
            timestamp: Date().timeIntervalSince1970,
            isRecording: false,
            fileId: nil,
            fileSize: nil
        )
        
        do {
            let data = try JSONEncoder().encode(response)
            connection.send(content: data, completion: .contentProcessed { _ in })
        } catch {
            print("NetworkManager: Failed to send error response: \(error)")
        }
    }
}

extension NetworkManager: NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        print("NetworkManager: Bonjour service published successfully")
        connectionStatus = "Advertising on network"
    }
    
    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        print("NetworkManager: Failed to publish Bonjour service: \(errorDict)")
        connectionStatus = "Failed to advertise on network"
    }
    
    func netServiceDidStop(_ sender: NetService) {
        print("NetworkManager: Bonjour service stopped")
    }
}