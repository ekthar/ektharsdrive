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

/// Follows a growing log file and calls `onLine` for each complete line. Polls every 250 ms (cheap: one
/// read of new bytes). The file is 0600 in the app's 0700 logs folder.
final class LogTailer: @unchecked Sendable {
    private let url: URL
    private let onLine: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "com.ekthar.drive.logtail")
    private var handle: FileHandle?
    private var buffer = Data()
    private var timer: DispatchSourceTimer?

    init(url: URL, onLine: @escaping @Sendable (String) -> Void) {
        self.url = url
        self.onLine = onLine
    }

    func start() {
        queue.async { [self] in
            handle = FileHandle(forReadingAtPath: url.path)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(250))
            t.setEventHandler { [weak self] in self?.readNew() }
            t.resume()
            timer = t
        }
    }

    func stop(drain: Bool) {
        queue.sync {
            if drain { readNew(flushPartial: true) }
            timer?.cancel()
            timer = nil
            try? handle?.close()
            handle = nil
        }
    }

    private func readNew(flushPartial: Bool = false) {
        guard let handle, let data = try? handle.readToEnd(), !data.isEmpty || flushPartial else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            if !line.isEmpty { onLine(line) }
        }
        if flushPartial, !buffer.isEmpty {
            onLine(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
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
        // rclone writes straight into a log FILE, never a pipe. With a pipe, quitting or crashing the app
        // closes the read end and rclone dies of SIGPIPE on its next log line, which leaves a dead volume
        // that freezes Finder. A file has no reader to lose, so mounts keep working after the app quits.
        let logURL = paths.logFile(for: driveID)
        let fm = FileManager.default
        if fm.fileExists(atPath: logURL.path) {
            let previous = logURL.appendingPathExtension("1")
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: logURL, to: previous)
        }
        fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let logOut = FileHandle(forWritingAtPath: logURL.path) else {
            throw .permissionDenied("Could not open the log file \(logURL.path).")
        }
        process.standardOutput = logOut
        process.standardError = logOut
        let handle = ProcessHandle(process: process, driveID: driveID)
        let cont = continuation
        let tailer = LogTailer(url: logURL) { raw in
            let line = Redactor.redact(raw)
            handle.record(line)
            cont.yield(.output(driveID: driveID, line: line))
        }

        let pidFile = paths.pidFile(for: driveID)
        process.terminationHandler = { p in
            tailer.stop(drain: true)
            try? FileManager.default.removeItem(at: pidFile)
            cont.yield(.exited(driveID: driveID, pid: p.processIdentifier, status: p.terminationStatus,
                               reason: p.terminationReason, recentOutput: handle.recentLines()))
        }

        do {
            try process.run()
        } catch {
            try? logOut.close()
            throw .unknown("Could not launch rclone: \(error.localizedDescription)")
        }
        try? logOut.close() // the child keeps its own copy of the descriptor
        tailer.start()
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
    public func adoptOrphans(driveIDs: [String]) async -> [SupervisedProcessInfo] {
        var found: [SupervisedProcessInfo] = []
        for id in driveIDs where handles[id] == nil {
            let pidFile = paths.pidFile(for: id)
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
                  let pid = Int32(text.split(separator: "\n").first ?? "") else { continue }
            guard Self.isAlive(pid) else {
                try? FileManager.default.removeItem(at: pidFile)
                continue
            }
            let argv = Self.arguments(of: pid) ?? []
            let isRclone = argv.first.map { ($0 as NSString).lastPathComponent == "rclone" } ?? false
            if isRclone, argv.contains("unix://" + paths.rcSocket(for: id).path) {
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

    /// argv of a process owned by this user, read from the kernel (KERN_PROCARGS2). No `ps`, no truncation.
    public static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // skip exec path, then NUL padding
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
