import Foundation

/// Turns rclone's `core/stats`, `core/transferred` and `vfs/queue` snapshots into `Transfer` records.
/// Every number comes from rclone; nothing is interpolated.
public struct TransferTracker: Sendable {
    public let driveID: String
    /// e.g. `gdrive:` -- a transfer whose destination starts with this is an upload.
    public let remoteName: String
    public private(set) var active: [String: Transfer] = [:]
    private var queued: [String: Transfer] = [:]
    private var consumed: Set<String> = []
    private var seeded: Bool

    /// `ignoreExistingHistory` is for reattaching to a process that ran before we observed it; a freshly
    /// launched process has no earlier history, so everything it reports is ours.
    public init(driveID: String, remoteName: String, ignoreExistingHistory: Bool = false) {
        self.driveID = driveID
        self.remoteName = remoteName
        self.seeded = !ignoreExistingHistory
    }

    public struct Update: Sendable {
        public var active: [Transfer]
        public var finished: [Transfer]
    }

    public mutating func update(transferring: [RcTransferring], completed: [RcCompletedTransfer], queue: [RcVFSQueue.Item],
                                now: Date = Date()) -> Update {
        var finished: [Transfer] = []
        let relevantCompleted = completed.filter { $0.checked != true }

        if !seeded {
            // History from before we started observing belongs to an earlier session.
            consumed = Set(relevantCompleted.map(Self.key))
            seeded = true
        }

        // Running transfers
        var stillRunning = Set<String>()
        for item in transferring {
            stillRunning.insert(item.name)
            var t = active[item.name] ?? queued.removeValue(forKey: item.name) ?? makeTransfer(name: item.name, src: item.srcFs, dst: item.dstFs, size: item.size, now: now)
            t.direction = direction(dst: item.dstFs)
            t.transferredBytes = item.bytes
            t.totalBytes = (item.size ?? -1) >= 0 ? item.size : t.totalBytes
            t.speed = item.speed
            t.eta = item.eta
            t.status = .running
            active[item.name] = t
        }

        // Newly completed (including ones that started and finished between polls)
        for c in relevantCompleted {
            let key = Self.key(c)
            guard !consumed.contains(key) else { continue }
            consumed.insert(key)
            var t = active.removeValue(forKey: c.name) ?? queued.removeValue(forKey: c.name)
                ?? makeTransfer(name: c.name, src: c.srcFs, dst: c.dstFs, size: c.size, now: Self.parseDate(c.startedAt) ?? now)
            if let started = Self.parseDate(c.startedAt), t.startedAt > started { t.startedAt = started }
            t.direction = direction(dst: c.dstFs)
            t.transferredBytes = c.bytes ?? t.transferredBytes
            if let size = c.size, size >= 0 { t.totalBytes = size }
            t.completedAt = Self.parseDate(c.completedAt) ?? now
            t.speed = nil
            t.eta = nil
            if let err = c.error, !err.isEmpty {
                t.status = .failed
                t.errorMessage = Redactor.redact(err)
            } else {
                t.status = .completed
            }
            stillRunning.remove(c.name)
            finished.append(t)
        }

        // Transfers that vanished from `transferring` with no completion record yet stay "waiting" until one shows up.
        for (name, var t) in active where !stillRunning.contains(name) {
            t.status = .waiting
            t.speed = nil
            t.eta = nil
            active[name] = t
        }

        // Upload queue (dirty files waiting for write-back or retry)
        var queuedNow: [String: Transfer] = [:]
        for q in queue where q.uploading != true && active[q.name] == nil {
            var t = queued[q.name] ?? makeTransfer(name: q.name, src: "local cache", dst: remoteName + ":", size: q.size, now: now)
            t.direction = .upload
            t.totalBytes = q.size ?? t.totalBytes
            t.status = (q.tries ?? 0) > 0 ? .waiting : .queued
            if (q.tries ?? 0) > 0 { t.errorMessage = "Upload will retry (attempt \((q.tries ?? 0) + 1))." }
            queuedNow[q.name] = t
        }
        queued = queuedNow

        if consumed.count > 5000 { consumed = Set(relevantCompleted.map(Self.key)) }
        let list = (Array(active.values) + Array(queued.values)).sorted { $0.startedAt > $1.startedAt }
        return Update(active: list, finished: finished)
    }

    /// When the process stops, anything not completed can no longer be observed.
    public mutating func stop(now: Date = Date()) -> [Transfer] {
        let open = Array(active.values)
        active.removeAll()
        queued.removeAll()
        return open.map { t in
            var t = t
            t.status = .failed
            t.completedAt = now
            t.errorMessage = "The filesystem process stopped before this transfer finished. Pending uploads stay in the cache and resume on the next mount."
            return t
        }
    }

    private func direction(dst: String?) -> TransferDirection {
        guard let dst else { return .upload }
        return dst.hasPrefix(remoteName + ":") ? .upload : .download
    }

    private func makeTransfer(name: String, src: String?, dst: String?, size: Int64?, now: Date) -> Transfer {
        let dir = direction(dst: dst)
        let remotePath = remoteName + ":" + name
        return Transfer(driveID: driveID, name: (name as NSString).lastPathComponent,
                        sourcePath: dir == .upload ? name : remotePath,
                        destinationPath: dir == .upload ? remotePath : name,
                        direction: dir, totalBytes: (size ?? -1) >= 0 ? size : nil, status: .running, startedAt: now)
    }

    static func key(_ c: RcCompletedTransfer) -> String { "\(c.name)|\(c.completedAt ?? "")|\(c.startedAt ?? "")" }

    /// rclone emits RFC 3339 with up to 9 fractional digits.
    public static func parseDate(_ s: String?) -> Date? {
        guard var s, !s.isEmpty else { return nil }
        if let dot = s.firstIndex(of: "."), let tzStart = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let fraction = s[s.index(after: dot)..<tzStart].prefix(3)
            s = String(s[..<dot]) + "." + fraction + String(s[tzStart...])
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
