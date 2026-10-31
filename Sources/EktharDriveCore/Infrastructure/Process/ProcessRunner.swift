import Foundation

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public var succeeded: Bool { exitCode == 0 && !timedOut }
    public var combinedLines: [String] {
        (stderr + "\n" + stdout).split(whereSeparator: \.isNewline).map(String.init)
    }
}

/// Runs short-lived commands. Arguments are always passed as an argv array, never through a shell.
public protocol ProcessRunning: Sendable {
    func run(_ executable: URL, arguments: [String], environment: [String: String], stdin: Data?,
             timeout: Duration?) async throws -> ProcessResult
}

public extension ProcessRunning {
    func run(_ executable: URL, arguments: [String], environment: [String: String] = SafeEnvironment.base(),
             stdin: Data? = nil, timeout: Duration? = .seconds(60)) async throws -> ProcessResult {
        try await run(executable, arguments: arguments, environment: environment, stdin: stdin, timeout: timeout)
    }
}

/// A minimal environment for child processes so unrelated secrets in the app's environment are not inherited.
public enum SafeEnvironment {
    public static func base(extra: [String: String] = [:]) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"] {
            if let v = inherited[key] { env[key] = v }
        }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env.merge(extra) { _, new in new }
        return env
    }
}

final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

public struct ProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ executable: URL, arguments: [String], environment: [String: String], stdin: Data?,
                    timeout: Duration?) async throws -> ProcessResult {
        try await run(executable, arguments: arguments, environment: environment, stdin: stdin, timeout: timeout, onOutput: nil)
    }

    /// Same as `run`, but calls `onOutput` with each chunk of (unredacted) combined output as it arrives.
    /// Callers must redact before logging or displaying.
    public func run(_ executable: URL, arguments: [String], environment: [String: String], stdin: Data?,
                    timeout: Duration?, onOutput: (@Sendable (String) -> Void)?) async throws -> ProcessResult {
        let process = Process()
        let box = ProcessBox(process)
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        process.standardInput = inPipe ?? FileHandle.nullDevice

        let out = Locked(Data()), err = Locked(Data())
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { out.withLock { $0.append(d) }; onOutput?(String(decoding: d, as: UTF8.self)) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { err.withLock { $0.append(d) }; onOutput?(String(decoding: d, as: UTF8.self)) }
        }
        let timedOut = Locked(false)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let restOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                    out.withLock { $0.append(restOut) }
                    err.withLock { $0.append(restErr) }
                    cont.resume(returning: ProcessResult(
                        exitCode: p.terminationStatus,
                        stdout: String(decoding: out.current, as: UTF8.self),
                        stderr: String(decoding: err.current, as: UTF8.self),
                        timedOut: timedOut.current))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: DriveError.unknown("Could not start \(executable.lastPathComponent): \(error.localizedDescription)"))
                    return
                }
                if let inPipe, let stdin {
                    let w = inPipe.fileHandleForWriting
                    try? w.write(contentsOf: stdin)
                    try? w.close()
                }
                if let timeout {
                    Task.detached {
                        try? await Task.sleep(for: timeout)
                        if box.process.isRunning {
                            timedOut.withLock { $0 = true }
                            box.process.terminate()
                        }
                    }
                }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
    }
}
