//
//  TimeSync.swift
//  multiCam
//
//  Time synchronization manager using NTP for precise multi-device sync
//

import Foundation

@MainActor
class TimeSync: ObservableObject {
    @Published var isSynchronized = false
    @Published var timeOffset: TimeInterval = 0
    @Published var syncStatus: String = "Not synchronized"
    @Published var lastSyncTime: Date?

    private let ntpClient: NTPClient
    private let syncAttempts = 3
    private let maxAcceptableRTT: TimeInterval = 0.5 // 500ms max RTT
    private let resyncInterval: TimeInterval = 300 // 5 minutes

    init(ntpServer: String = "pool.ntp.org") {
        self.ntpClient = NTPClient(server: ntpServer)
    }

    func synchronizeTime() async {
        print("TimeSync: Starting NTP time synchronization...")

        // Update status on main actor
        await MainActor.run {
            syncStatus = "Synchronizing..."
        }

        var successfulSyncs: [(offset: TimeInterval, rtt: TimeInterval)] = []

        // Perform multiple sync attempts
        for attempt in 1...syncAttempts {
            do {
                print("TimeSync: Sync attempt \(attempt)/\(syncAttempts)")
                let (ntpTime, roundTripTime) = try await ntpClient.getNTPTime()

                // Calculate time offset
                let localTime = Date().timeIntervalSince1970
                let networkDelay = roundTripTime / 2
                let adjustedNtpTime = ntpTime + networkDelay
                let offset = adjustedNtpTime - localTime

                print("TimeSync: Attempt \(attempt) - offset: \(Int(offset * 1000))ms, RTT: \(Int(roundTripTime * 1000))ms")

                // Only use results with reasonable RTT
                if roundTripTime <= maxAcceptableRTT {
                    successfulSyncs.append((offset: offset, rtt: roundTripTime))
                    print("TimeSync: Attempt \(attempt) accepted")
                } else {
                    print("TimeSync: Attempt \(attempt) rejected (high RTT: \(Int(roundTripTime * 1000))ms)")
                }

            } catch {
                print("TimeSync: Attempt \(attempt) failed: \(error.localizedDescription)")
            }

            // Small delay between attempts to avoid overwhelming the server
            if attempt < syncAttempts {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000) // 500ms delay
                } catch {
                    print("TimeSync: Sleep interrupted")
                    break
                }
            }
        }

        // Calculate final offset from successful attempts and update UI on main actor
        if !successfulSyncs.isEmpty {
            let averageOffset = successfulSyncs.reduce(0) { $0 + $1.offset } / Double(successfulSyncs.count)

            // Update UI properties on main actor
            await MainActor.run {
                self.timeOffset = averageOffset
                self.isSynchronized = true
                self.lastSyncTime = Date()
                self.syncStatus = "Synchronized (offset: \(Int(averageOffset * 1000))ms)"
                print("TimeSync: UI properties updated - isSynchronized: \(self.isSynchronized), status: \(self.syncStatus)")
            }

            print("TimeSync: Synchronization complete - average offset: \(Int(averageOffset * 1000))ms from \(successfulSyncs.count) attempts")
        } else {
            // Update UI properties on main actor
            await MainActor.run {
                self.isSynchronized = false
                self.syncStatus = "Synchronization failed"
            }
            print("TimeSync: All synchronization attempts failed")
        }
    }

    func getSynchronizedTime() -> TimeInterval {
        if !isSynchronized {
            print("TimeSync: Warning - returning unsynchronized time")
            return Date().timeIntervalSince1970
        }

        return Date().timeIntervalSince1970 + timeOffset
    }

    func shouldResync() -> Bool {
        guard let lastSync = lastSyncTime else {
            return true
        }

        let timeSinceSync = Date().timeIntervalSince(lastSync)
        return timeSinceSync > resyncInterval
    }

    func getTimeSinceLastSync() -> TimeInterval? {
        guard let lastSync = lastSyncTime else {
            return nil
        }
        return Date().timeIntervalSince(lastSync)
    }

    func calculateDelayUntil(targetTime: TimeInterval) -> TimeInterval {
        let currentSyncTime = getSynchronizedTime()
        let delay = targetTime - currentSyncTime

        print("TimeSync: Target time: \(targetTime), Current sync time: \(currentSyncTime), Delay: \(Int(delay * 1000))ms")

        return delay
    }

    // Debug information
    func getDebugInfo() -> String {
        let syncTime = getSynchronizedTime()
        let systemTime = Date().timeIntervalSince1970
        let offsetMs = Int(timeOffset * 1000)
        let timeSinceSync = getTimeSinceLastSync().map { Int($0) } ?? 0

        return """
        Synchronized: \(isSynchronized)
        Offset: \(offsetMs)ms
        System time: \(systemTime)
        Sync time: \(syncTime)
        Time since last sync: \(timeSinceSync)s
        """
    }
}