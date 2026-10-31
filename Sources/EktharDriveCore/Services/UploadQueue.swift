import Foundation

/// Controls for rclone's upload queue (`vfs/queue-set-expiry`) and for async jobs (`job/stop`).
/// A file in the queue is already safe in the local cache; these calls only change WHEN it uploads.
public enum UploadQueue {
    /// Holding moves the start time about 31 years ahead, which rclone documents as the way to delay.
    public static let holdSeconds: Double = 1_000_000_000
    /// Anything starting later than ~3 years counts as held.
    public static let holdThreshold: Double = 100_000_000
    /// rclone documents a large negative number as "upload as soon as possible".
    public static let nowSeconds: Double = -1_000_000_000

    public static func items(_ rc: RcClient) async throws(DriveError) -> [RcVFSQueue.Item] {
        try await rc.vfsQueue().queue ?? []
    }

    /// Sets when one queued upload may start, in seconds from now.
    public static func setStart(_ rc: RcClient, id: Int64, seconds: Double) async throws(DriveError) {
        _ = try await rc.callJSON("vfs/queue-set-expiry", ["id": id, "expiry": seconds, "relative": false])
    }

    public static func startNow(_ rc: RcClient, id: Int64) async throws(DriveError) { try await setStart(rc, id: id, seconds: nowSeconds) }
    public static func hold(_ rc: RcClient, id: Int64) async throws(DriveError) { try await setStart(rc, id: id, seconds: holdSeconds) }
    /// Back to normal: upload when rclone's write-back delay allows (immediately for a long-waiting file).
    public static func release(_ rc: RcClient, id: Int64) async throws(DriveError) { try await setStart(rc, id: id, seconds: 0) }

    /// Stops an async job (a Copy to). Files already copied stay; the one in progress is abandoned.
    public static func cancelJob(_ rc: RcClient, jobID: Int) async throws(DriveError) {
        _ = try await rc.callJSON("job/stop", ["jobid": jobID])
    }

    /// Queue items that should be held but are not (e.g. after a remount, rclone re-queues with a fresh time).
    public static func needsHold(_ items: [RcVFSQueue.Item], held: Set<String>) -> [RcVFSQueue.Item] {
        items.filter { held.contains($0.name) && $0.uploading != true && ($0.expiry ?? 0) <= holdThreshold && $0.id != nil }
    }

    public static func decodeHeld(_ json: String?) -> [String: Set<String>] {
        guard let json, let d = try? JSONDecoder().decode([String: Set<String>].self, from: Data(json.utf8)) else { return [:] }
        return d
    }

    public static func encodeHeld(_ held: [String: Set<String>]) -> String {
        (try? String(data: JSONEncoder().encode(held.filter { !$0.value.isEmpty }), encoding: .utf8)) ?? "{}"
    }
}
