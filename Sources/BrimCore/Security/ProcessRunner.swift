import Foundation

/// The only code in Brim that starts another program.
///
/// It runs one binary by absolute path with fixed arguments — never through a
/// shell, never with anything interpolated from a file or a response. The child
/// gets a minimal environment, no terminal, no stdin, and a hard timeout. Its
/// output is returned to the caller's parser and nowhere else: not logged, not
/// saved, not shown.
public struct ProcessRunner: Sendable {
    public enum RunError: Error, Equatable {
        case notExecutable
        case launchFailed
        case timedOut
        case exited(Int32)
        case outputTooLarge
    }

    public var timeout: TimeInterval
    public var maxOutput: Int

    public init(timeout: TimeInterval = 25, maxOutput: Int = 256 << 10) {
        self.timeout = timeout
        self.maxOutput = maxOutput
    }

    /// Environment variables passed through; everything else is dropped.
    static let passedThrough = ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR"]

    public func run(_ binary: URL, arguments: [String], workingDirectory: URL,
                    extraEnvironment: [String: String] = [:]) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw RunError.notExecutable }
        let timeout = self.timeout
        let maxOutput = self.maxOutput
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = binary
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                var environment: [String: String] = [:]
                let current = ProcessInfo.processInfo.environment
                for key in Self.passedThrough { environment[key] = current[key] }
                // Node-based CLIs need a PATH to find `node`; only standard
                // system and Homebrew locations are offered.
                environment["PATH"] = "\(binary.deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                environment["PWD"] = workingDirectory.path
                for (key, value) in extraEnvironment { environment[key] = value }
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: RunError.launchFailed)
                    return
                }

                let expired = Flag()
                let deadline = DispatchWorkItem {
                    if process.isRunning {
                        expired.set()
                        process.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        }
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)

                var output = Data()
                var overflow = false
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    if output.count + chunk.count > maxOutput {
                        overflow = true
                        process.terminate()
                        break
                    }
                    output.append(chunk)
                }
                process.waitUntilExit()
                deadline.cancel()

                if overflow {
                    continuation.resume(throwing: RunError.outputTooLarge)
                } else if expired.isSet {
                    continuation.resume(throwing: RunError.timedOut)
                } else if process.terminationStatus != 0 {
                    continuation.resume(throwing: RunError.exited(process.terminationStatus))
                } else {
                    continuation.resume(returning: output)
                }
            }
        }
    }
}

/// A one-way switch shared between the timeout and the reader.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
