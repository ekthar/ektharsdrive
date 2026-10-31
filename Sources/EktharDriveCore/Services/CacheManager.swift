import Foundation

public struct CacheClearResult: Sendable, Equatable {
    public var removedFiles: Int
    public var freedBytes: Int64
    /// Files kept because rclone marked them dirty (not yet uploaded).
    public var keptDirty: Int
    /// Files kept because their metadata could not be read (kept to be safe).
    public var keptUnknown: Int
}

public struct DiskWarning: Sendable, Equatable {
    public enum Level: Sendable { case low, critical }
    public var level: Level
    public var freeBytes: Int64
    public var thresholdBytes: Int64
}

/// Reads and cleans rclone's VFS cache for one drive. rclone owns the cache lifecycle while mounted;
/// this type only measures it, and cleans it when the drive is not mounted.
public struct CacheManager: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    public func cacheDirectory(_ driveID: String) -> URL { paths.cacheDirectory(for: driveID) }

    /// Live numbers from the running rclone process.
    public func liveStats(_ rc: RcClient) async throws(DriveError) -> CacheStats {
        let s = try await rc.vfsStats()
        guard let d = s.diskCache else { throw .rcUnavailable("rclone did not report cache statistics.") }
        return CacheStats(bytesUsed: d.bytesUsed, files: d.files, uploadsInProgress: d.uploadsInProgress, uploadsQueued: d.uploadsQueued,
                          erroredFiles: d.erroredFiles, outOfSpace: d.outOfSpace, source: .liveProcess)
    }

    /// Measured from disk when no process is running. Dirty files left from an earlier session are counted as queued uploads.
    public func diskStats(_ driveID: String) -> CacheStats {
        let root = cacheDirectory(driveID)
        let content = DirectoryMeasure.measure(root.appendingPathComponent("vfs"))
        let dirty = scanMetadata(driveID).filter { $0.dirty == true }.count
        return CacheStats(bytesUsed: content.bytes, files: content.files, uploadsQueued: dirty, source: .diskScan)
    }

    struct MetaEntry {
        var metaURL: URL
        var contentURL: URL
        var dirty: Bool?
    }

    private struct ItemMeta: Decodable { var Dirty: Bool? }

    func scanMetadata(_ driveID: String) -> [MetaEntry] {
        let root = cacheDirectory(driveID).standardizedFileURL.resolvingSymlinksInPath()
        let metaRoot = root.appendingPathComponent("vfsMeta")
        let contentRoot = root.appendingPathComponent("vfs")
        guard let e = FileManager.default.enumerator(at: metaRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        var entries: [MetaEntry] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), v.isRegularFile == true, v.isSymbolicLink != true else { continue }
            let rel = url.path.dropFirst(metaRoot.path.count)
            let content = URL(fileURLWithPath: contentRoot.path + rel)
            var dirty: Bool?
            if let data = try? Data(contentsOf: url), let meta = try? JSONDecoder().decode(ItemMeta.self, from: data) { dirty = meta.Dirty }
            entries.append(MetaEntry(metaURL: url, contentURL: content, dirty: dirty))
        }
        return entries
    }

    /// Deletes cached copies that are already uploaded. Refuses while the drive is mounted (rclone owns the
    /// files then and may have them open). Never deletes dirty files, files with unreadable metadata, or anything remote.
    public func clearSafeCache(_ driveID: String, isMounted: Bool) throws(DriveError) -> CacheClearResult {
        guard !isMounted else {
            throw .mountPointBusy(path: "the \(driveID) cache. Unmount the drive first; while mounted, rclone evicts old cache files itself using the size and age limits")
        }
        let root = cacheDirectory(driveID).standardizedFileURL.resolvingSymlinksInPath().path
        var result = CacheClearResult(removedFiles: 0, freedBytes: 0, keptDirty: 0, keptUnknown: 0)
        let fm = FileManager.default
        for entry in scanMetadata(driveID) {
            guard entry.contentURL.standardizedFileURL.path.hasPrefix(root + "/"), entry.metaURL.standardizedFileURL.path.hasPrefix(root + "/") else { continue }
            switch entry.dirty {
            case true?: result.keptDirty += 1
            case nil: result.keptUnknown += 1
            case false?:
                let size = (try? entry.contentURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize).flatMap { $0 } ?? 0
                if fm.fileExists(atPath: entry.contentURL.path) {
                    do { try fm.removeItem(at: entry.contentURL) } catch { result.keptUnknown += 1; continue }
                    result.freedBytes += Int64(size)
                }
                try? fm.removeItem(at: entry.metaURL)
                result.removedFiles += 1
            }
        }
        // Content files with no metadata at all are orphans rclone would discard; leave them (rclone cleans them on next start).
        return result
    }

    public func diskWarning(minFreeBytes: Int64) -> DiskWarning? {
        guard let free = DiskSpace.freeBytes(at: paths.cacheRoot.path) else { return nil }
        if free < minFreeBytes / 2 { return DiskWarning(level: .critical, freeBytes: free, thresholdBytes: minFreeBytes) }
        if free < minFreeBytes { return DiskWarning(level: .low, freeBytes: free, thresholdBytes: minFreeBytes) }
        return nil
    }
}
