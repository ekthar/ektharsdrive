import Foundation
import Darwin

/// Events from supervised long-running processes.
public enum SupervisorEvent: Sendable {
    case output(driveID: String, line: String)
    case exited(driveID: String, pid: Int32, status: Int32, reason: Process.TerminationReason, recentOutput: [String])
}

public struct SupervisedProcessInfo: Sendable, Equatable {
    public var driveID: String
    public var pid: Int32
    public var startedAt: Date
    /// True when this app did not launch the process (found running after a crash/relaunch).
    public var adopted: Bool
}

final class ProcessHandle: @unchecked Sendable {
    let process: Process
    let driveID: String
    let startedAt = Date()
    var recent = RingBuffer<String>(capacity: 200)
    let lock = NSLock()

    init(process: Process, driveID: String) {
        self.process = process
        self.driveID = driveID
    }

    func record(_ line: String) {
        lock.lock(); recent.append(line); lock.unlock()
    }

    func recentLines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return recent.elements
    }
}

/// Owns every long-running rclone process. Guarantees one process per drive, captures output,
/// records PID files so a relaunched app can find (and adopt) processes that outlived it,
/// and never sends SIGKILL.
public actor ProcessSupervisor {
    private var handles: [String: ProcessHandle] = [:]
    private var adopted: [String: SupervisedProcessInfo] = [:]
    private let paths: AppPaths
    private let logger = AppLogger(category: "supervisor")
    private let continuation: AsyncStream<SupervisorEvent>.Continuation
    public nonisolated let events: AsyncStream<SupervisorEvent>
    private var logFiles: [String: RotatingLogFile] = [:]

    public init(paths: AppPaths) {
        self.paths = paths
        var c: AsyncStream<SupervisorEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(1000)) { c = $0 }
        continuation = c
    }

    public func info(for driveID: String) -> SupervisedProcessInfo? {
        if let h = handles[driveID], h.process.isRunning {
            return SupervisedProcessInfo(driveID: driveID, pid: h.process.processIdentifier, startedAt: h.startedAt, adopted: false)
        }
        if let a = adopted[driveID], Self.isAlive(a.pid) { return a }
        return nil
    }

    public func isRunning(_ driveID: String) -> Bool { info(for: driveID) != nil }

    public func recentOutput(for driveID: String) -> [String] { handles[driveID]?.recentLines() ?? [] }

    /// Launches `executable` with argv `arguments`. Throws `.alreadyRunning` if this drive has a live process.
    @discardableResult
    public func launch(driveID: String, executable: URL, arguments: [String], environment: [String: String]) throws(DriveError) -> Int32 {
        if isRunning(driveID) { throw .alreadyRunning }
        handles[driveID] = nil
        adopted[driveID] = nil

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = ProcessHandle(process: process, driveID: driveID)
        let logFile = logFiles[driveID] ?? RotatingLogFile(url: paths.logFile(for: driveID))
        logFiles[driveID] = logFile
        let cont = continuation
        let pending = Locked(Data())

        pipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            let lines: [String] = pending.withLock { buf in
                buf.append(data)
                var out: [String] = []
                while let nl = buf.firstIndex(of: 0x0A) {
                    let lineData = buf[buf.startIndex..<nl]
                    buf.removeSubrange(buf.startIndex...nl)
                    out.append(String(decoding: lineData, as: UTF8.self))
                }
                return out
            }
            for raw in lines where !raw.isEmpty {
                let line = Redactor.redact(raw)
                handle.record(line)
                logFile.append(line)
                cont.yield(.output(driveID: driveID, line: line))
            }
        }

        let pidFile = paths.pidFile(for: driveID)
        process.terminationHandler = { p in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            let tail = String(decoding: pending.current + rest, as: UTF8.self)
            for raw in tail.split(whereSeparator: \.isNewline) {
                let line = Redactor.redact(String(raw))
                handle.record(line)
                logFile.append(line)
            }
            try? FileManager.default.removeItem(at: pidFile)
            cont.yield(.exited(driveID: driveID, pid: p.processIdentifier, status: p.terminationStatus,
                               reason: p.terminationReason, recentOutput: handle.recentLines()))
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw .unknown("Could not launch rclone: \(error.localizedDescription)")
        }
        handles[driveID] = handle
        let pid = process.processIdentifier
        let record = "\(pid)\n\(executable.path)\n"
        FileManager.default.createFile(atPath: pidFile.path, contents: Data(record.utf8), attributes: [.posixPermissions: 0o600])
        logger.info("Launched rclone for \(driveID) pid=\(pid) args=\(arguments.joined(separator: " "))")
        return pid
    }

    /// Sends SIGTERM (rclone unmounts and exits cleanly on SIGTERM/SIGINT). Never SIGKILL: a killed
    /// rclone can leave a stale mount, and dirty cache files would only upload on the next mount.
    public func terminate(_ driveID: String) {
        if let h = handles[driveID], h.process.isRunning {
            h.process.terminate()
        } else if let a = adopted[driveID], Self.isAlive(a.pid) {
            kill(a.pid, SIGTERM)
        }
    }

    /// Waits up to `timeout` for the drive's process to exit.
    public func waitForExit(_ driveID: String, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !isRunning(driveID) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return !isRunning(driveID)
    }

    /// Finds rclone processes recorded in PID files from a previous app run. Live ones whose command line
    /// still matches this drive are adopted (their mounts keep working); stale PID files are removed.
    public func adoptOrphans(driveIDs: [String], runner: ProcessRunning = ProcessRunner()) async -> [SupervisedProcessInfo] {
        var found: [SupervisedProcessInfo] = []
        for id in driveIDs where handles[id] == nil {
            let pidFile = paths.pidFile(for: id)
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
                  let pid = Int32(text.split(separator: "\n").first ?? "") else { continue }
            guard Self.isAlive(pid) else {
                try? FileManager.default.removeItem(at: pidFile)
                continue
            }
            let result = try? await runner.run(URL(fileURLWithPath: "/bin/ps"), arguments: ["-o", "command=", "-p", String(pid)],
                                               timeout: .seconds(5))
            let command = result?.stdout ?? ""
            if command.contains("rclone"), command.contains(paths.rcSocket(for: id).path) {
                let info = SupervisedProcessInfo(driveID: id, pid: pid, startedAt: Date(), adopted: true)
                adopted[id] = info
                found.append(info)
                logger.notice("Adopted running rclone for \(id) pid=\(pid)")
            } else {
                try? FileManager.default.removeItem(at: pidFile)
            }
        }
        return found
    }

    /// Called when an adopted process disappears (detected by polling, since we have no termination handler).
    public func checkAdopted() -> [String] {
        var gone: [String] = []
        for (id, info) in adopted where !Self.isAlive(info.pid) {
            adopted[id] = nil
            try? FileManager.default.removeItem(at: paths.pidFile(for: id))
            gone.append(id)
        }
        return gone
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
