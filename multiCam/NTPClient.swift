//
//  NTPClient.swift
//  multiCam
//
//  NTP (Network Time Protocol) client for precise time synchronization
//

import Foundation
import Network

class NTPClient {
    private let ntpServer: String
    private let timeout: TimeInterval = 5.0
    private let ntpPort: UInt16 = 123

    init(server: String = "pool.ntp.org") {
        self.ntpServer = server
    }

    func getNTPTime() async throws -> (ntpTime: TimeInterval, roundTripTime: TimeInterval) {
        return try await withCheckedThrowingContinuation { continuation in
            getNTPTime { result in
                continuation.resume(with: result)
            }
        }
    }

    private func getNTPTime(completion: @escaping (Result<(TimeInterval, TimeInterval), Error>) -> Void) {
        // Record request time
        let t1 = Date().timeIntervalSince1970
        var hasCompleted = false

        // Create UDP connection
        let host = NWEndpoint.Host(ntpServer)

        let connection = NWConnection(
            host: host,
            port: NWEndpoint.Port(rawValue: ntpPort)!,
            using: .udp
        )

        // Helper to ensure completion is only called once
        func completeOnce(_ result: Result<(TimeInterval, TimeInterval), Error>) {
            guard !hasCompleted else { return }
            hasCompleted = true
            connection.cancel()
            completion(result)
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Send NTP request packet
                let packet = self.createNTPPacket()
                connection.send(content: packet, completion: .contentProcessed { error in
                    if let error = error {
                        completeOnce(.failure(error))
                        return
                    }

                    // Receive NTP response
                    connection.receive(minimumIncompleteLength: 48, maximumLength: 48) { data, _, isComplete, error in
                        let t4 = Date().timeIntervalSince1970 // Record receive time

                        if let error = error {
                            completeOnce(.failure(error))
                            return
                        }

                        guard let data = data, data.count == 48 else {
                            completeOnce(.failure(NTPError.invalidResponse))
                            return
                        }

                        do {
                            let ntpTime = try self.parseNTPResponse(data)
                            let roundTripTime = t4 - t1
                            completeOnce(.success((ntpTime, roundTripTime)))
                        } catch {
                            completeOnce(.failure(error))
                        }
                    }
                })

            case .failed(let error):
                completeOnce(.failure(error))

            case .cancelled:
                completeOnce(.failure(NTPError.connectionCancelled))

            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))

        // Timeout handling
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            completeOnce(.failure(NTPError.timeout))
        }
    }

    private func createNTPPacket() -> Data {
        var packet = Data(count: 48)
        // NTP version 3, client mode
        packet[0] = 0x1B // 00_011_011 (LI=0, VN=3, Mode=3)
        return packet
    }

    private func parseNTPResponse(_ data: Data) throws -> TimeInterval {
        // Extract transmit timestamp (bytes 40-47)
        guard data.count >= 48 else {
            throw NTPError.invalidResponse
        }

        // Read 32-bit seconds (big-endian)
        let secondsData = data.subdata(in: 40..<44)
        let seconds = secondsData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        // Read 32-bit fraction (big-endian)
        let fractionData = data.subdata(in: 44..<48)
        let fraction = fractionData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        // Convert NTP timestamp to Unix timestamp
        // NTP epoch: Jan 1, 1900; Unix epoch: Jan 1, 1970
        // Difference: 2208988800 seconds
        let ntpEpochOffset: UInt32 = 2208988800

        guard seconds > ntpEpochOffset else {
            throw NTPError.invalidTimestamp
        }

        let unixSeconds = seconds - ntpEpochOffset
        let fractionalSeconds = Double(fraction) / Double(UInt32.max)

        return TimeInterval(unixSeconds) + fractionalSeconds
    }
}

enum NTPError: Error, LocalizedError {
    case invalidServer
    case invalidResponse
    case invalidTimestamp
    case connectionCancelled
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidServer:
            return "Invalid NTP server"
        case .invalidResponse:
            return "Invalid NTP response"
        case .invalidTimestamp:
            return "Invalid NTP timestamp"
        case .connectionCancelled:
            return "NTP connection cancelled"
        case .timeout:
            return "NTP request timeout"
        }
    }
}