import Foundation

/// A file or folder seen through rclone directly (not through the mounted volume).
public struct RemoteEntry: Sendable, Identifiable, Hashable {
    public var path: String
    public var name: String
    public var size: Int64?
    public var modified: Date?
    public var isDirectory: Bool
    public var mimeType: String?
    public var id: String { path }
}

/// Cloud-side actions that go through the drive's running rclone process. Nothing here downloads
/// file contents to the Mac.
public struct CloudActions: Sendable {
    public let rc: RcClient
    public let drive: DriveConfiguration

    public init(rc: RcClient, drive: DriveConfiguration) {
        self.rc = rc
        self.drive = drive
    }

    /// Path of `url` inside the drive, relative to its mount point.
    public static func remotePath(of url: URL, mountPath: String) -> String? {
        let root = URL(fileURLWithPath: mountPath).standardizedFileURL.path
        let p = url.standardizedFileURL.path
        guard p == root || p.hasPrefix(root + "/") else { return nil }
        return String(p.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Joins the drive's own base path (e.g. Oracle's /srv/... directory) with a relative path.
    func fullRemote(_ relative: String) -> String {
        let base = drive.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rel = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let joined = [base, rel].filter { !$0.isEmpty }.joined(separator: "/")
        return drive.remotePath.hasPrefix("/") ? "/" + joined : joined
    }

    // MARK: Share link

    /// A link anyone with it can open (Google: "anyone with the link can view").
    public func publicLink(relativePath: String) async throws(DriveError) -> URL {
        guard drive.provider == .googleDrive else {
            throw .invalidConfiguration("Share links are only available for Google Drive.")
        }
        let r = try await rc.callJSON("operations/publiclink", ["fs": "\(drive.remoteName):", "remote": fullRemote(relativePath)])
        guard let s = r["url"] as? String, let url = URL(string: s) else { throw .remoteUnavailable("Google did not return a link.") }
        return url
    }

    // MARK: Listings (Starred, Trash)

    public enum Collection: String, Sendable { case starred, trash }

    /// Lists Google's Starred or Trash items, recursively, metadata only.
    public func list(_ collection: Collection, limit: Int = 2000) async throws(DriveError) -> [RemoteEntry] {
        guard drive.provider == .googleDrive else { return [] }
        let option = collection == .starred ? "starred_only=true" : "trashed_only=true"
        let r = try await RcClient(socketPath: rc.socketPath, timeoutSeconds: 120)
            .callJSON("operations/list", ["fs": "\(drive.remoteName),\(option):", "remote": "", "opt": ["recurse": true, "noMimeType": false]])
        let list = (r["list"] as? [[String: Any]]) ?? []
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return list.prefix(limit).map { e in
            let size = (e["Size"] as? NSNumber)?.int64Value
            let mod = (e["ModTime"] as? String).flatMap { f.date(from: TransferTracker.normalizeFraction($0)) }
            return RemoteEntry(path: (e["Path"] as? String) ?? "", name: (e["Name"] as? String) ?? "",
                               size: (size ?? -1) >= 0 ? size : nil, modified: mod,
                               isDirectory: (e["IsDir"] as? Bool) ?? false, mimeType: e["MimeType"] as? String)
        }
        .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    /// Restores everything in Google's Trash under `relativeDir` ("" = all of it).
    public func untrash(relativeDir: String) async throws(DriveError) {
        _ = try await RcClient(socketPath: rc.socketPath, timeoutSeconds: 300)
            .callJSON("backend/command", ["command": "untrash", "fs": "\(drive.remoteName):\(relativeDir)"])
    }

    // MARK: Cloud-to-cloud copy

    /// Copies a file or folder from this drive straight to another configured drive. Data streams
    /// through rclone; nothing is kept on the Mac. Returns the rc job id (async), visible in Transfers.
    @discardableResult
    public func copy(relativePath: String, isDirectory: Bool, to target: DriveConfiguration, targetRelativeDir: String = "") async throws(DriveError) -> Int {
        // The drive's base folder goes in the Fs (e.g. "oracle:/srv/ekthar-drive/files"); the item path is
        // relative to it. Putting an absolute path in the remote part makes rclone look in the wrong place.
        let name = (relativePath as NSString).lastPathComponent
        let rel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let dir = targetRelativeDir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let dest = dir.isEmpty ? name : dir + "/" + name
        let srcFs = "\(drive.remoteName):\(drive.remotePath)"
        let dstFs = "\(target.remoteName):\(target.remotePath)"
        let r: [String: Any]
        if isDirectory {
            r = try await rc.callJSON("sync/copy", [
                "srcFs": srcFs + (drive.remotePath.isEmpty || drive.remotePath.hasSuffix("/") ? "" : "/") + rel,
                "dstFs": dstFs + (target.remotePath.isEmpty || target.remotePath.hasSuffix("/") ? "" : "/") + dest,
                "_async": true,
            ])
        } else {
            r = try await rc.callJSON("operations/copyfile", [
                "srcFs": srcFs, "srcRemote": rel,
                "dstFs": dstFs, "dstRemote": dest,
                "_async": true,
            ])
        }
        return (r["jobid"] as? NSNumber)?.intValue ?? 0
    }

    // MARK: Speed limit

    /// Applies an upload/download limit to the running process. `nil` = unlimited.
    public func setBandwidth(megabytesPerSecond: Double?) async throws(DriveError) {
        let rate = megabytesPerSecond.map { String(format: "%.1fM", $0) } ?? "off"
        _ = try await rc.callJSON("core/bwlimit", ["rate": rate])
    }
}

extension TransferTracker {
    /// rclone emits up to 9 fractional digits; ISO8601DateFormatter accepts 3.
    static func normalizeFraction(_ s: String) -> String {
        guard let dot = s.firstIndex(of: "."), let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) else { return s }
        return String(s[..<dot]) + "." + s[s.index(after: dot)..<tz].prefix(3) + String(s[tz...])
    }
}
