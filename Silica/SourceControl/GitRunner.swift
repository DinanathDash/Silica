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
            var stdoutData = Data()
            var stderrData = Data()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    stdoutData.append(chunk)
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    stderrData.append(chunk)
                }
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingOut.isEmpty { stdoutData.append(remainingOut) }
                let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingErr.isEmpty { stderrData.append(remainingErr) }

                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()

                let stdout = String(decoding: stdoutData, as: UTF8.self)
                let stderr = String(decoding: stderrData, as: UTF8.self)
                continuation.resume(returning: Result(
                    exitCode: proc.terminationStatus,
                    stdout: stdout,
                    stderr: stderr
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
