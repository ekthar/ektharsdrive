import Foundation

/// Checks that a mounted volume still answers file-system calls, without ever blocking the caller.
/// A stuck NFS server makes `stat` hang forever, so the probe runs on its own thread with a deadline.
public enum VolumeProbe {
    public static func responds(_ path: String, within seconds: Double) async -> Bool {
        await withCheckedContinuation { cont in
            let done = Locked(false)
            let thread = Thread {
                var st = stat()
                let ok = stat(path, &st) == 0
                let first = done.withLock { d -> Bool in if d { return false }; d = true; return true }
                if first { cont.resume(returning: ok) }
            }
            thread.stackSize = 64 * 1024
            thread.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                let first = done.withLock { d -> Bool in if d { return false }; d = true; return true }
                if first { cont.resume(returning: false) } // the probe thread stays blocked; it is tiny and exits when the mount recovers or goes away
            }
        }
    }
}

/// Keeps the Mac from idle-sleeping while uploads are pending, and lets it sleep again once they finish.
/// Display sleep still happens; only system idle sleep is held off.
public final class UploadSleepGuard: @unchecked Sendable {
    private var activity: NSObjectProtocol?
    private let lock = NSLock()

    public init() {}

    public var isHolding: Bool { lock.lock(); defer { lock.unlock() }; return activity != nil }

    public func update(pendingUploads: Int) {
        lock.lock(); defer { lock.unlock() }
        if pendingUploads > 0, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                                                            reason: "Ekthar Drive is finishing \(pendingUploads) upload(s)")
        } else if pendingUploads == 0, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }
}

/// Writes a small, redacted report when rclone stops unexpectedly, so problems can be diagnosed later.
public enum CrashReporter {
    @discardableResult
    public static func write(driveID: String, driveName: String, status: Int32, error: DriveError,
                             recentOutput: [String], logsDirectory: URL, now: Date = Date()) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let url = logsDirectory.appendingPathComponent("crash-\(driveID)-\(stamp).txt")
        var lines = [
            "Ekthar Drive crash report",
            "Drive: \(driveName) (\(driveID))",
            "Time: \(now)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "rclone exit status: \(status)",
            "Classified as: \(error.title). \(error.detail)",
            "",
            "Last \(min(recentOutput.count, 200)) lines of rclone output:",
        ]
        lines += recentOutput.suffix(200)
        let text = Redactor.redact(lines.joined(separator: "\n")) + "\n"
        guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { return nil }
        prune(logsDirectory, keep: 20)
        return url
    }

    /// Keeps only the newest `keep` reports.
    static func prune(_ dir: URL, keep: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let reports = files.filter { $0.lastPathComponent.hasPrefix("crash-") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                      ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for old in reports.dropFirst(keep) { try? fm.removeItem(at: old) }
    }
}
