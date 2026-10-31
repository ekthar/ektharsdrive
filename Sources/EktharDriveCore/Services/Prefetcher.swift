import Foundation
import os

/// A folder (or file) the user asked to keep on this Mac. `path` is relative to the drive's mount point.
public struct OfflinePin: Codable, Sendable, Hashable, Identifiable {
    public var driveID: String
    public var path: String
    public var id: String { "\(driveID):\(path)" }
    public var name: String { path.isEmpty ? "Whole drive" : (path as NSString).lastPathComponent }

    public init(driveID: String, path: String) {
        self.driveID = driveID
        self.path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

public enum PinStatus: Sendable, Equatable {
    case waiting
    case downloading(doneBytes: Int64, totalBytes: Int64)
    case ready(files: Int, bytes: Int64, at: Date)
    case failed(String)
}

/// Reads files through the mounted volume so rclone keeps their contents in its local cache.
/// rclone has no "download into cache" call, and reading through the mount is exactly what fills it.
public enum Prefetcher {
    /// Reads the first `bytes` of a file, so opening it (Quick Look, Preview, QuickTime) starts from disk.
    public static func warmStart(_ url: URL, bytes: Int = 2 << 20) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        var left = bytes
        while left > 0, let chunk = try? h.read(upToCount: min(left, 1 << 20)), !chunk.isEmpty { left -= chunk.count }
    }

    /// Files under `root` (or `root` itself if it is a file), with sizes. Skips hidden files.
    public static func inventory(_ root: URL) -> [(url: URL, size: Int64)] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        if (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            return [(root, Int64((try? root.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))]
        }
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var out: [(URL, Int64)] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isDirectory != true else { continue }
            out.append((url, Int64(v.fileSize ?? 0)))
        }
        return out
    }

    /// Reads every file completely. Calls `progress(done, total)` about once per megabyte.
    /// Throws when the files do not fit in `budgetBytes` (the drive's cache size), since rclone would
    /// evict the first ones while reading the last.
    public static func download(_ root: URL, budgetBytes: Int64,
                                progress: @Sendable (Int64, Int64) -> Void,
                                cancelled: @Sendable () -> Bool) throws(DriveError) -> (files: Int, bytes: Int64) {
        let files = inventory(root)
        let total = files.reduce(0) { $0 + $1.size }
        guard total <= budgetBytes else {
            throw .invalidConfiguration("“\(root.lastPathComponent)” is \(ByteFormat.string(total)), more than this drive's cache (\(ByteFormat.string(budgetBytes))). Make the cache larger in Settings, or keep a smaller folder offline.")
        }
        var done: Int64 = 0
        progress(0, total)
        for f in files {
            if cancelled() { break }
            guard let h = try? FileHandle(forReadingFrom: f.url) else { continue }
            defer { try? h.close() }
            while !cancelled() {
                guard let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                done += Int64(chunk.count)
                progress(done, total)
            }
        }
        return (files.count, done)
    }

    /// Decodes the stored pin list. Unknown or broken data gives an empty list.
    public static func decodePins(_ json: String?) -> [OfflinePin] {
        guard let json, let pins = try? JSONDecoder().decode([OfflinePin].self, from: Data(json.utf8)) else { return [] }
        return pins
    }

    public static func encodePins(_ pins: [OfflinePin]) -> String {
        (try? String(data: JSONEncoder().encode(pins), encoding: .utf8)) ?? "[]"
    }
}

/// Thread-safe "stop now" flag shared with a background read loop.
public final class StopFlag: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    public init() {}
    public func set() { flag.withLock { $0 = true } }
    @Sendable public func isSet() -> Bool { flag.withLock { $0 } }
}

/// Passes progress on at most every 8 MB (and at the end), so the UI is not flooded.
public final class ProgressThrottle: Sendable {
    private let last = OSAllocatedUnfairLock<Int64>(initialState: -1)
    private let step: Int64
    private let sink: @Sendable (Int64, Int64) -> Void

    public init(step: Int64 = 8 << 20, _ sink: @escaping @Sendable (Int64, Int64) -> Void) {
        self.step = step
        self.sink = sink
    }

    @Sendable public func report(_ done: Int64, _ total: Int64) {
        let send = last.withLock { l -> Bool in
            guard l < 0 || done - l >= step || done >= total else { return false }
            l = done
            return true
        }
        if send { sink(done, total) }
    }
}
