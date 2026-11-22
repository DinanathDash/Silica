import AppKit
import Foundation
import MachO

nonisolated(unsafe) private let uncaughtExceptionHandler: (@convention(c) (NSException) -> Void) = { exception in
    let symbols = exception.callStackSymbols.joined(separator: "\n  ")
    let msg = "CRASH: Uncaught exception '\(exception.name.rawValue)': \(exception.reason ?? "Unknown reason")\nCall stack:\n  \(symbols)"
    AppLogger.emergencyLogSync(category: "CrashHandler", message: msg)
}

nonisolated(unsafe) private let fatalSignalHandler: (@convention(c) (Int32) -> Void) = { signum in
    let symbols = Thread.callStackSymbols.joined(separator: "\n  ")
    let msg = "CRASH: Received fatal signal \(signum)\nCall stack:\n  \(symbols)"
    AppLogger.emergencyLogSync(category: "SignalHandler", message: msg)
    exit(signum)
}

/// High-performance, memory-aware logging system with automatic log rotation,
/// maximum file size caps, and age-based purging.
actor AppLogger {
    static let shared = AppLogger()

    enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
        case memory = "MEMORY"
    }

    private let maxFileSize: UInt64 = 5 * 1024 * 1024 // 5 MB per log file
    private let maxRotatedFiles = 5                  // Keep silica.log, silica.1.log ... silica.5.log (~30 MB max)
    private let maxAgeSeconds: TimeInterval = 7 * 86400 // 7 days auto-purge

    private let fileManager = FileManager.default
    private let logDirectory: URL
    private let currentLogFileURL: URL
    private var fileHandle: FileHandle?
    private var currentFileSize: UInt64 = 0

    private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let logsDir = libraryURL.appending(path: "Logs/Silica", directoryHint: .isDirectory)
        self.logDirectory = logsDir
        let currentURL = logsDir.appending(path: "silica.log")
        self.currentLogFileURL = currentURL

        try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: currentURL.path(percentEncoded: false)) {
            fileManager.createFile(atPath: currentURL.path(percentEncoded: false), contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: currentURL)
        if let handle {
            _ = try? handle.seekToEnd()
            self.currentFileSize = (try? handle.offset()) ?? 0
        } else {
            self.currentFileSize = 0
        }
        self.fileHandle = handle
    }

    // MARK: - Public API (Synchronous Dispatch via Task)

    nonisolated static func debug(_ category: String, _ message: String) {
        Task { await shared.write(level: .debug, category: category, message: message) }
    }

    nonisolated static func info(_ category: String, _ message: String) {
        Task { await shared.write(level: .info, category: category, message: message) }
    }

    nonisolated static func warn(_ category: String, _ message: String) {
        Task { await shared.write(level: .warn, category: category, message: message) }
    }

    nonisolated static func error(_ category: String, _ message: String) {
        Task { await shared.write(level: .error, category: category, message: message) }
    }

    nonisolated static func memory(_ category: String, _ message: String) {
        let residentMB = currentResidentMemoryMB()
        let formatted = String(format: "%.1f MB | %@", residentMB, message)
        Task { await shared.write(level: .memory, category: category, message: formatted) }
    }

    nonisolated static var logFolderURL: URL {
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        return libraryURL.appending(path: "Logs/Silica", directoryHint: .isDirectory)
    }

    @MainActor
    static func revealLogInFinder() {
        let folder = logFolderURL
        if !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let currentLog = folder.appending(path: "silica.log")
        if FileManager.default.fileExists(atPath: currentLog.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([currentLog])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    @MainActor
    static func exportLogs(to destinationURL: URL) throws {
        let folder = logFolderURL
        let currentLog = folder.appending(path: "silica.log")
        guard FileManager.default.fileExists(atPath: currentLog.path(percentEncoded: false)) else {
            FileManager.default.createFile(atPath: destinationURL.path(percentEncoded: false), contents: Data("No logs recorded.\n".utf8))
            return
        }
        if FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: currentLog, to: destinationURL)
    }

    // MARK: - Crash & Exception Diagnostics

    nonisolated static func installCrashAndExceptionHandlers() {
        NSSetUncaughtExceptionHandler(uncaughtExceptionHandler)
        let signals = [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE]
        for sig in signals {
            signal(sig, fatalSignalHandler)
        }
    }

    nonisolated static func emergencyLogSync(category: String, message: String) {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [ERROR] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let logDir = logFolderURL
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let fileURL = logDir.appending(path: "silica.log")
        if !FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: fileURL.path(percentEncoded: false), contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    // MARK: - Memory Measurement

    nonisolated static func currentResidentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024 * 1024)
    }

    // MARK: - Internal File Writing & Rotation

    private func write(level: Level, category: String, message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level.rawValue)] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        // Check if current file needs rotation
        if currentFileSize + UInt64(data.count) > maxFileSize {
            rotateLogs()
        }

        if let handle = fileHandle {
            try? handle.write(contentsOf: data)
            currentFileSize += UInt64(data.count)
        }
    }

    private func openCurrentLogFileSync() {
        if !fileManager.fileExists(atPath: currentLogFileURL.path(percentEncoded: false)) {
            fileManager.createFile(atPath: currentLogFileURL.path(percentEncoded: false), contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: currentLogFileURL)
        if let handle = fileHandle {
            _ = try? handle.seekToEnd()
            currentFileSize = (try? handle.offset()) ?? 0
        }
    }

    private func rotateLogs() {
        try? fileHandle?.close()
        fileHandle = nil

        // Shift silica.N.log files: e.g. silica.4.log -> silica.5.log
        for i in (1..<maxRotatedFiles).reversed() {
            let src = logDirectory.appending(path: "silica.\(i).log")
            let dst = logDirectory.appending(path: "silica.\(i + 1).log")
            if fileManager.fileExists(atPath: src.path(percentEncoded: false)) {
                try? fileManager.removeItem(at: dst)
                try? fileManager.moveItem(at: src, to: dst)
            }
        }

        // silica.log -> silica.1.log
        let firstRotated = logDirectory.appending(path: "silica.1.log")
        try? fileManager.removeItem(at: firstRotated)
        try? fileManager.moveItem(at: currentLogFileURL, to: firstRotated)

        // Purge anything exceeding age limits
        purgeOldLogsSync()

        // Create fresh silica.log
        openCurrentLogFileSync()
    }

    private func purgeOldLogsSync() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return }

        let now = Date()
        for url in urls where url.pathExtension == "log" {
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let modDate = values.contentModificationDate,
               now.timeIntervalSince(modDate) > maxAgeSeconds {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
