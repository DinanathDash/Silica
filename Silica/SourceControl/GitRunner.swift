import Foundation

/// Git CLI runner that runs commands safely using async Process execution.
/// Limits buffer allocations, drains pipes asynchronously, and avoids memory retention.
actor GitRunner {
    static let shared = GitRunner()

    private let gitExecutable = "/usr/bin/git"

    struct Result: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var isSuccess: Bool { exitCode == 0 }
    }

    /// Runs a git command in the target repository path.
    func run(arguments: [String], in directory: URL) async -> Result {
        let process = Process()
        process.executableURL = URL(filePath: gitExecutable)
        process.arguments = ["-C", directory.path(percentEncoded: false)] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return await withCheckedContinuation { continuation in
            let stdoutBuf = OutputBuffer()
            let stderrBuf = OutputBuffer()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    stdoutBuf.append(chunk)
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    stderrBuf.append(chunk)
                }
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingOut.isEmpty { stdoutBuf.append(remainingOut) }
                let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingErr.isEmpty { stderrBuf.append(remainingErr) }

                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()

                continuation.resume(returning: Result(
                    exitCode: proc.terminationStatus,
                    stdout: stdoutBuf.string(),
                    stderr: stderrBuf.string()
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: Result(
                    exitCode: -1,
                    stdout: "",
                    stderr: error.localizedDescription
                ))
            }
        }
    }

    /// Runs a GitHub CLI (`gh`) command.
    func runGH(arguments: [String], in directory: URL) async -> Result {
        let ghPaths = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh"
        ]
        let foundPath = ghPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
        let process = Process()
        if let foundPath {
            process.executableURL = URL(filePath: foundPath)
            process.arguments = arguments
        } else {
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = ["gh"] + arguments
        }
        process.currentDirectoryURL = directory

        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return await withCheckedContinuation { continuation in
            let stdoutBuf = OutputBuffer()
            let stderrBuf = OutputBuffer()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { stdoutBuf.append(chunk) }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { stderrBuf.append(chunk) }
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: Result(
                    exitCode: proc.terminationStatus,
                    stdout: stdoutBuf.string(),
                    stderr: stderrBuf.string()
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: Result(
                    exitCode: -1,
                    stdout: "",
                    stderr: error.localizedDescription
                ))
            }
        }
    }
}

/// Thread-safe buffer for capturing standard process pipe output without mutation warnings.
private nonisolated final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
