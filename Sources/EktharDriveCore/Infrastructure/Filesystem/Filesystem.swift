import Foundation
import Darwin

public struct MountEntry: Sendable, Equatable {
    public var mountPoint: String
    public var source: String
    public var fsType: String
}

/// Reads the kernel mount table (getfsstat). Used to detect real mounts; a directory existing is never treated as a mount.
public enum MountTable {
    public static func entries() -> [MountEntry] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        let empty = statfs()
        var buffer = Array(repeating: empty, count: Int(count))
        let size = Int32(MemoryLayout<statfs>.stride * buffer.count)
        let n = buffer.withUnsafeMutableBufferPointer { getfsstat($0.baseAddress, size, MNT_NOWAIT) }
        guard n > 0 else { return [] }
        return buffer.prefix(Int(n)).map { st in
            var s = st
            return MountEntry(
                mountPoint: cString(&s.f_mntonname),
                source: cString(&s.f_mntfromname),
                fsType: cString(&s.f_fstypename))
        }
    }

    public static func entry(at path: String) -> MountEntry? {
        let target = normalize(path)
        return entries().first { normalize($0.mountPoint) == target }
    }

    public static func isMounted(_ path: String) -> Bool { entry(at: path) != nil }

    /// Text-only cleanup. NSString.standardizingPath looks at the disk, and on a hung volume that look
    /// fails, which made a frozen mount read as "not mounted" (and the drive was stopped as if ejected).
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { _ = parts.popLast(); continue }
            parts.append(c)
        }
        var p = "/" + parts.joined(separator: "/")
        if p.hasPrefix("/private/var/") { p = String(p.dropFirst("/private".count)) }
        return p
    }

    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

public enum DiskSpace {
    /// Free bytes available to this user on the volume containing `path` (statfs f_bavail).
    public static func freeBytes(at path: String) -> Int64? {
        var st = statfs()
        var probe = path
        while !FileManager.default.fileExists(atPath: probe), probe != "/" {
            probe = (probe as NSString).deletingLastPathComponent
        }
        guard statfs(probe, &st) == 0 else { return nil }
        return Int64(st.f_bavail) * Int64(st.f_bsize)
    }

    public static func totalBytes(at path: String) -> Int64? {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return nil }
        return Int64(st.f_blocks) * Int64(st.f_bsize)
    }
}

public enum DirectoryMeasure {
    public struct Result: Sendable, Equatable {
        public var bytes: Int64
        public var files: Int
    }

    /// Allocated size and file count of a directory tree. Does not follow symlinks.
    public static func measure(_ url: URL) -> Result {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return Result(bytes: 0, files: 0)
        }
        var bytes: Int64 = 0, files = 0
        for case let item as URL in e {
            guard let v = try? item.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true, v.isRegularFile == true else { continue }
            bytes += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            files += 1
        }
        return Result(bytes: bytes, files: files)
    }
}
