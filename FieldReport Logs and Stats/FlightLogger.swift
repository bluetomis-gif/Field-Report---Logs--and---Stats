//
//  FlightLogger.swift
//  FieldReport: Logs and Stats
//
//  Watches the telemetry stream for motor arm/disarm events and automatically
//  opens / closes a CSV log file in the app's Documents/FlightLogs directory.
//
//  Auto-start logic:
//    motors_on:  false → true   ⇒  open new log file
//    motors_on:  true  → false  ⇒  close log file (flight ended)
//
//  Each log file is also accompanied by a tiny JSON sidecar containing
//  the bit-packed "black box" strings for every frame.
//

import Foundation
import Observation
import UserNotifications

@Observable
@MainActor
final class FlightLogger {

    // MARK: - Published State

    private(set) var isLogging      = false
    private(set) var currentLogURL: URL?
    private(set) var recordCount    = 0

    /// All flight log files, sorted newest-first.
    private(set) var allLogs: [FlightLogMeta] = []
    /// Flight-level events (arm/disarm, recording milestones) for the timeline view.
    private(set) var events: [FlightEvent] = []

    // MARK: - Private

    private var csvFileHandle:  FileHandle?
    private var sidecarHandle:  FileHandle?
    private var sidecarFirst    = true   // tracks comma separation in JSON array
    private var wasMotorsOn     = false
    private var snapshotMode    = false  // true when logging a post-flight snapshot (motors off)
    private var snapshotTask:   Task<Void, Never>?

    var logDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlightLogs", isDirectory: true)
    }

    // MARK: - Public API

    /// Called when the drone first comes online after a reconnection.
    /// Starts a 30-second post-flight snapshot if motors are currently off.
    func droneReconnected(frame: DJITelemetryFrame) {
        guard !isLogging else { return }
        guard !(frame.data.motorsOn ?? false) else { return }
        startNewLog(frame: frame, prefix: "report")
        snapshotMode = true
        snapshotTask?.cancel()
        snapshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, self.snapshotMode else { return }
            self.snapshotMode = false
            self.stopLogging()
        }
    }

    /// Call this from ContentView.onChange(of: bridge.frameCount)
    func processFrame(_ frame: DJITelemetryFrame) {
        let motorsOn = frame.data.motorsOn ?? false

        // ── Motors just armed ────────────────────────────────────────────────
        if motorsOn && !wasMotorsOn {
            // If we were capturing a post-flight snapshot, close it first
            if snapshotMode {
                snapshotTask?.cancel(); snapshotTask = nil
                snapshotMode = false
                stopLogging()
            }
            startNewLog(frame: frame, prefix: "flight")
        }

        // ── Motors just disarmed ─────────────────────────────────────────────
        // Only stop for flight logs (not snapshot mode)
        if !motorsOn && wasMotorsOn && isLogging && !snapshotMode {
            stopLogging()
        }

        wasMotorsOn = motorsOn

        if isLogging {
            writeRecord(frame)
        }
    }

    /// Manually stop an in-progress log (e.g., from Settings UI).
    func forceStop() {
        guard isLogging else { return }
        stopLogging()
    }

    /// Refresh the allLogs list (call on view appear).
    func refreshLogs() {
        allLogs = scanLogDirectory()
    }

    /// Delete a log file and its sidecar.
    func deleteLog(_ meta: FlightLogMeta) {
        try? FileManager.default.removeItem(at: meta.csvURL)
        let sidecar = meta.csvURL.deletingPathExtension().appendingPathExtension("json")
        try? FileManager.default.removeItem(at: sidecar)
        allLogs.removeAll { $0.id == meta.id }
    }

    // MARK: - Internal: Open / Close

    private func startNewLog(frame: DJITelemetryFrame, prefix: String = "flight") {
        // Ensure directory exists
        try? FileManager.default.createDirectory(
            at: logDirectory, withIntermediateDirectories: true)

        // Build filename: flight_<SN>_<YYYYMMDD_HHmmss>.csv
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = df.string(from: Date())
        let base  = "\(prefix)_\(frame.deviceSn)_\(stamp)"

        let csvURL     = logDirectory.appendingPathComponent("\(base).csv")
        let sidecarURL = logDirectory.appendingPathComponent("\(base).json")

        // CSV
        let header = FlightLogRecord.csvHeader + "\n"
        FileManager.default.createFile(atPath: csvURL.path, contents: Data(header.utf8))
        csvFileHandle = try? FileHandle(forWritingTo: csvURL)
        csvFileHandle?.seekToEndOfFile()

        // JSON sidecar (array of bit-packed strings)
        let jsonOpener = "[\n"
        FileManager.default.createFile(atPath: sidecarURL.path, contents: Data(jsonOpener.utf8))
        sidecarHandle = try? FileHandle(forWritingTo: sidecarURL)
        sidecarHandle?.seekToEndOfFile()
        sidecarFirst = true

        currentLogURL = csvURL
        recordCount   = 0
        isLogging     = true
        let isReport  = prefix == "report"
        events.append(FlightEvent(
            time:   Date(),
            title:  isReport ? "Snapshot Started" : "Recording Started",
            detail: isReport ? "\(base).csv · Post-flight (30 s)" : "\(base).csv · Motors armed",
            kind:   .success
        ))

        // Notify pilot — useful when screen is locked during pre-flight checks
        let notification       = UNMutableNotificationContent()
        notification.title     = isReport ? "Snapshot Started" : "Recording Started"
        notification.body      = isReport ? "Post-flight data captured · \(frame.deviceSn)" : "Motors armed · \(base).csv"
        notification.sound     = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "log_started", content: notification, trigger: nil)
        )
    }

    private func stopLogging() {
        // Close JSON array
        sidecarHandle?.write(Data("\n]\n".utf8))
        sidecarHandle?.closeFile()
        sidecarHandle = nil

        csvFileHandle?.closeFile()
        csvFileHandle = nil

        isLogging = false
        events.append(FlightEvent(time: Date(), title: "Recording Saved",
                                  detail: "\(recordCount) frames written to CSV", kind: .info))
        refreshLogs()
    }

    // MARK: - Internal: Write

    private func writeRecord(_ frame: DJITelemetryFrame) {
        let record = FlightLogRecord(wallTime: Date(), frame: frame)

        // CSV row
        let row = record.csvRow + "\n"
        csvFileHandle?.write(Data(row.utf8))

        // JSON sidecar entry
        let packed  = BitPackEncoder.encode(frame)
        let comma   = sidecarFirst ? "  " : ",\n  "
        let jsonRow = "\(comma)\"\(packed)\""
        sidecarHandle?.write(Data(jsonRow.utf8))
        sidecarFirst = false

        recordCount += 1
    }

    // MARK: - Directory Scan

    private func scanLogDirectory() -> [FlightLogMeta] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return urls
            .filter { $0.pathExtension == "csv" }
            .compactMap { url -> FlightLogMeta? in
                let res = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                return FlightLogMeta(
                    csvURL:      url,
                    createdAt:   res?.creationDate ?? Date.distantPast,
                    fileSizeKB:  (res?.fileSize ?? 0) / 1024
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

// MARK: - FlightLogMeta

struct FlightLogMeta: Identifiable {
    let id = UUID()
    let csvURL: URL
    let createdAt: Date
    let fileSizeKB: Int

    var displayName: String { csvURL.deletingPathExtension().lastPathComponent }

    var hasSidecar: Bool {
        let sc = csvURL.deletingPathExtension().appendingPathExtension("json")
        return FileManager.default.fileExists(atPath: sc.path)
    }

    var sidecarURL: URL {
        csvURL.deletingPathExtension().appendingPathExtension("json")
    }
}
