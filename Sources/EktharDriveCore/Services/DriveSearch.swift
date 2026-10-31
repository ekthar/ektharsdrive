import Foundation

/// One file or folder found by a drive-wide search. `path` is relative to the drive's mount point.
public struct DriveFile: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var path: String
    public var size: Int64?
    public var modified: Date?
    public var mimeType: String
    public var md5: String?
    public var webLink: URL?
    public var isFolder: Bool { mimeType == DriveSearchQuery.folderMime }

    public init(id: String, name: String, path: String, size: Int64?, modified: Date?, mimeType: String, md5: String? = nil, webLink: URL? = nil) {
        self.id = id; self.name = name; self.path = path; self.size = size
        self.modified = modified; self.mimeType = mimeType; self.md5 = md5; self.webLink = webLink
    }
}

/// What to look for. Also the stored form of a smart folder.
public struct DriveSearchQuery: Sendable, Hashable, Codable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case any, folders, documents, spreadsheets, presentations, pdfs, images, videos, audio, archives

        public var label: String {
            switch self {
            case .any: "Any kind"
            case .pdfs: "PDFs"
            default: rawValue.capitalized
            }
        }

        /// Google Drive `q` clause for this kind (nil = no filter).
        var clause: String? {
            func eq(_ m: String) -> String { "mimeType = '\(m)'" }
            func has(_ m: String) -> String { "mimeType contains '\(m)'" }
            func or(_ c: [String]) -> String { "(" + c.joined(separator: " or ") + ")" }
            switch self {
            case .any: return nil
            case .folders: return eq(DriveSearchQuery.folderMime)
            case .documents: return or([eq("application/vnd.google-apps.document"), has("wordprocessingml"), eq("application/msword"), eq("text/plain"), eq("application/rtf")])
            case .spreadsheets: return or([eq("application/vnd.google-apps.spreadsheet"), has("spreadsheetml"), eq("application/vnd.ms-excel"), eq("text/csv")])
            case .presentations: return or([eq("application/vnd.google-apps.presentation"), has("presentationml"), eq("application/vnd.ms-powerpoint")])
            case .pdfs: return eq("application/pdf")
            case .images: return has("image/")
            case .videos: return has("video/")
            case .audio: return has("audio/")
            case .archives: return or([eq("application/zip"), has("x-7z"), has("x-rar"), has("gzip"), has("x-tar"), has("x-bzip")])
            }
        }

        /// Same rule applied to a MIME type locally (SFTP drives, and a safety check on results).
        public func matches(mime: String) -> Bool {
            let m = mime.lowercased()
            switch self {
            case .any: return true
            case .folders: return m == DriveSearchQuery.folderMime || m == "inode/directory"
            case .documents: return m.contains("google-apps.document") || m.contains("wordprocessingml") || m == "application/msword" || m == "text/plain" || m == "application/rtf"
            case .spreadsheets: return m.contains("google-apps.spreadsheet") || m.contains("spreadsheetml") || m == "application/vnd.ms-excel" || m == "text/csv"
            case .presentations: return m.contains("google-apps.presentation") || m.contains("presentationml") || m == "application/vnd.ms-powerpoint"
            case .pdfs: return m == "application/pdf"
            case .images: return m.hasPrefix("image/")
            case .videos: return m.hasPrefix("video/")
            case .audio: return m.hasPrefix("audio/")
            case .archives: return ["zip", "x-7z", "x-rar", "gzip", "x-tar", "x-bzip"].contains { m.contains($0) }
            }
        }
    }

    public var text: String
    public var kind: Kind
    public var modifiedWithinDays: Int?
    /// Drive's query language has no size filter, so this is applied to the results.
    public var minSizeBytes: Int64?
    public var filesOnly: Bool

    public init(text: String = "", kind: Kind = .any, modifiedWithinDays: Int? = nil, minSizeBytes: Int64? = nil, filesOnly: Bool = false) {
        self.text = text; self.kind = kind; self.modifiedWithinDays = modifiedWithinDays
        self.minSizeBytes = minSizeBytes; self.filesOnly = filesOnly
    }

    public static let folderMime = "application/vnd.google-apps.folder"

    /// Files changed in the last 30 days, newest first.
    public static let recents = DriveSearchQuery(modifiedWithinDays: 30, filesOnly: true)

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && kind == .any && modifiedWithinDays == nil && minSizeBytes == nil
    }

    /// A Drive string literal. Backslash and quote are the only characters that need escaping.
    public static func literal(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// The Google Drive `q` expression for this search.
    public func googleQuery(now: Date = Date()) -> String {
        var parts = ["trashed = false"]
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { parts.append("name contains \(Self.literal(t))") }
        if let c = kind.clause { parts.append(c) }
        if filesOnly, kind != .folders { parts.append("mimeType != '\(Self.folderMime)'") }
        if let days = modifiedWithinDays {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            f.timeZone = TimeZone(identifier: "UTC")
            parts.append("modifiedTime > '\(f.string(from: now.addingTimeInterval(-Double(days) * 86_400)))'")
        }
        return parts.joined(separator: " and ")
    }

    /// Local check, used for SFTP drives and for the size filter.
    public func matches(_ f: DriveFile, now: Date = Date()) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, !f.name.localizedCaseInsensitiveContains(t) { return false }
        if !kind.matches(mime: f.mimeType) { return false }
        if filesOnly, f.isFolder { return false }
        if let days = modifiedWithinDays, (f.modified ?? .distantPast) < now.addingTimeInterval(-Double(days) * 86_400) { return false }
        if let min = minSizeBytes, (f.size ?? 0) < min { return false }
        return true
    }
}

/// Folder IDs to names and parents, so search results (which only carry a parent ID) get full paths.
public struct FolderTree: Sendable {
    public var folders: [String: (name: String, parent: String?)]
    public var rootID: String

    public init(folders: [String: (name: String, parent: String?)], rootID: String) {
        self.folders = folders
        self.rootID = rootID
    }

    /// Path from My Drive's root, or nil when the item is not under it (e.g. "Shared with me").
    public func path(name: String, parent: String?) -> String? {
        var parts = [Self.onDisk(name)]
        var id = parent
        var depth = 0
        while let current = id, current != rootID {
            guard let f = folders[current], depth < 64 else { return nil }
            parts.append(Self.onDisk(f.name))
            id = f.parent
            depth += 1
        }
        return id == rootID ? parts.reversed().joined(separator: "/") : nil
    }

    /// The name as rclone shows it on the volume. Google allows "/" and control characters (even
    /// newlines) in names; rclone shows "/" as the full-width "／" and control characters as the
    /// matching "Control Pictures" symbol (newline becomes "␊").
    static func onDisk(_ name: String) -> String {
        var out = String.UnicodeScalarView()
        for s in name.unicodeScalars {
            switch s.value {
            case 0x2F: out.append("\u{FF0F}")
            case 0x01...0x1F: out.append(Unicode.Scalar(0x2400 + s.value)!)
            case 0x7F: out.append("\u{2421}")
            default: out.append(s)
            }
        }
        return String(out)
    }
}

/// Drive-wide search and the views built on it (Recents, Duplicates, Space). Metadata only:
/// nothing is downloaded. Google uses the Drive API's own search through rclone; SFTP walks the tree.
public struct DriveSearch: Sendable {
    public let socketPath: String
    public let drive: DriveConfiguration

    public init(socketPath: String, drive: DriveConfiguration) {
        self.socketPath = socketPath
        self.drive = drive
    }

    private var rc: RcClient { RcClient(socketPath: socketPath, timeoutSeconds: 300) }

    public func search(_ q: DriveSearchQuery, limit: Int = 1000) async throws(DriveError) -> [DriveFile] {
        let found: [DriveFile]
        if drive.provider == .googleDrive {
            let tree = try await folderTree()
            found = try await googleQuery(q.googleQuery(), tree: tree).filter { q.matches($0) }
        } else {
            found = try await walk().filter { q.matches($0) }
        }
        let sorted = q.modifiedWithinDays != nil
            ? found.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            : found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Array(sorted.prefix(limit))
    }

    /// Every file on the drive (no folders). For Duplicates and Space.
    public func allFiles() async throws(DriveError) -> [DriveFile] {
        try await search(DriveSearchQuery(filesOnly: true), limit: .max)
    }

    // MARK: Google

    func googleQuery(_ q: String, tree: FolderTree) async throws(DriveError) -> [DriveFile] {
        let rows = try await rawQuery(q)
        let base = drive.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rows.compactMap { row in
            guard let file = Self.parse(row, tree: tree) else { return nil }
            guard !base.isEmpty else { return file }
            // A drive rooted in a subfolder only sees what is inside it.
            guard file.path.hasPrefix(base + "/") else { return nil }
            var f = file
            f.path = String(file.path.dropFirst(base.count + 1))
            return f
        }
    }

    func rawQuery(_ q: String) async throws(DriveError) -> [[String: Any]] {
        let r = try await rc.callJSON("backend/command", ["command": "query", "fs": "\(drive.remoteName):", "arg": [q]])
        if let e = r["error"] as? String { throw .remoteUnavailable("Google Drive search failed: \(e)") }
        return (r["result"] as? [[String: Any]]) ?? []
    }

    /// All folders on the drive, cached for five minutes (one quick query: about 1 s for a few hundred folders).
    func folderTree() async throws(DriveError) -> FolderTree {
        if let cached = await FolderTreeCache.shared.get(drive.id) { return cached }
        let rows = try await rawQuery("mimeType = '\(DriveSearchQuery.folderMime)' and trashed = false")
        var folders: [String: (name: String, parent: String?)] = [:]
        for r in rows {
            guard let id = r["id"] as? String, let name = r["name"] as? String else { continue }
            folders[id] = (name, (r["parents"] as? [String])?.first)
        }
        let root = try await rootID(folders: folders)
        let tree = FolderTree(folders: folders, rootID: root)
        await FolderTreeCache.shared.set(drive.id, tree)
        return tree
    }

    private func rootID(folders: [String: (name: String, parent: String?)]) async throws(DriveError) -> String {
        // Any item directly in My Drive carries the root's ID as its parent.
        let rows = try await rawQuery("'root' in parents and trashed = false")
        if let id = rows.lazy.compactMap({ ($0["parents"] as? [String])?.first }).first { return id }
        return "root"
    }

    static func parse(_ r: [String: Any], tree: FolderTree) -> DriveFile? {
        guard let id = r["id"] as? String, let name = r["name"] as? String,
              let path = tree.path(name: name, parent: (r["parents"] as? [String])?.first) else { return nil }
        let size = (r["size"] as? String).flatMap(Int64.init) ?? (r["size"] as? NSNumber)?.int64Value
        return DriveFile(id: id, name: name, path: path, size: size,
                         modified: (r["modifiedTime"] as? String).flatMap(Self.date),
                         mimeType: (r["mimeType"] as? String) ?? "application/octet-stream",
                         md5: r["md5Checksum"] as? String,
                         webLink: (r["webViewLink"] as? String).flatMap(URL.init(string:)))
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: TransferTracker.normalizeFraction(s)) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: SFTP

    /// Lists the whole tree through the running rclone (metadata only).
    func walk() async throws(DriveError) -> [DriveFile] {
        let r = try await rc.callJSON("operations/list", ["fs": "\(drive.remoteName):\(drive.remotePath)", "remote": "",
                                                          "opt": ["recurse": true, "noMimeType": false]])
        let list = (r["list"] as? [[String: Any]]) ?? []
        return list.compactMap { e in
            guard let path = e["Path"] as? String, let name = e["Name"] as? String else { return nil }
            let isDir = (e["IsDir"] as? Bool) ?? false
            let size = (e["Size"] as? NSNumber)?.int64Value
            return DriveFile(id: path, name: name, path: path, size: (size ?? -1) >= 0 ? size : nil,
                             modified: (e["ModTime"] as? String).flatMap(Self.date),
                             mimeType: isDir ? DriveSearchQuery.folderMime : ((e["MimeType"] as? String) ?? "application/octet-stream"))
        }
    }
}

actor FolderTreeCache {
    static let shared = FolderTreeCache()
    private var entries: [String: (FolderTree, Date)] = [:]
    func get(_ id: String) -> FolderTree? {
        guard let (tree, at) = entries[id], Date().timeIntervalSince(at) < 300 else { return nil }
        return tree
    }
    func set(_ id: String, _ tree: FolderTree) { entries[id] = (tree, Date()) }
    func clear(_ id: String) { entries[id] = nil }
}

// MARK: - Analysis

public struct DuplicateGroup: Sendable, Identifiable, Hashable {
    public var checksum: String
    public var size: Int64
    public var files: [DriveFile]
    public var id: String { checksum }
    /// Space that would be freed by keeping one copy.
    public var wastedBytes: Int64 { size * Int64(max(0, files.count - 1)) }
}

public struct SpaceEntry: Sendable, Identifiable, Hashable {
    public var name: String
    /// Relative to the drive's mount point.
    public var path: String
    public var bytes: Int64
    public var fileCount: Int
    public var isFolder: Bool
    public var id: String { path }
}

public enum DriveAnalysis {
    /// Files with identical content (same MD5 and size). Google Docs have no checksum and are skipped.
    public static func duplicates(_ files: [DriveFile]) -> [DuplicateGroup] {
        var groups: [String: [DriveFile]] = [:]
        for f in files where !f.isFolder {
            guard let md5 = f.md5, !md5.isEmpty, let size = f.size, size > 0 else { continue }
            groups["\(md5)-\(size)", default: []].append(f)
        }
        return groups.compactMap { _, list in
            guard list.count > 1, let first = list.first else { return nil }
            return DuplicateGroup(checksum: first.md5!, size: first.size!, files: list.sorted { $0.path < $1.path })
        }
        .sorted { $0.wastedBytes == $1.wastedBytes ? $0.checksum < $1.checksum : $0.wastedBytes > $1.wastedBytes }
    }

    /// Size of each item directly inside `folder` ("" = the drive's top level), counting everything below it.
    public static func spaceMap(_ files: [DriveFile], in folder: String = "") -> [SpaceEntry] {
        let prefix = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var totals: [String: (bytes: Int64, count: Int, folder: Bool)] = [:]
        for f in files where !f.isFolder {
            let rel: Substring
            if prefix.isEmpty { rel = Substring(f.path) }
            else if f.path.hasPrefix(prefix + "/") { rel = f.path.dropFirst(prefix.count + 1) }
            else { continue }
            let parts = rel.split(separator: "/", maxSplits: 1)
            guard let head = parts.first else { continue }
            var t = totals[String(head)] ?? (0, 0, parts.count > 1)
            t.bytes += f.size ?? 0
            t.count += 1
            t.folder = t.folder || parts.count > 1
            totals[String(head)] = t
        }
        return totals.map { name, t in
            SpaceEntry(name: name, path: prefix.isEmpty ? name : prefix + "/" + name, bytes: t.bytes, fileCount: t.count, isFolder: t.folder)
        }
        .sorted { $0.bytes == $1.bytes ? $0.name < $1.name : $0.bytes > $1.bytes }
    }
}

// MARK: - Smart folders

/// A saved search shown in the sidebar.
public struct SmartFolder: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var driveID: String
    public var query: DriveSearchQuery

    public init(id: String = UUID().uuidString, name: String, driveID: String, query: DriveSearchQuery) {
        self.id = id; self.name = name; self.driveID = driveID; self.query = query
    }

    public static func decode(_ json: String?) -> [SmartFolder] {
        guard let json, let list = try? JSONDecoder().decode([SmartFolder].self, from: Data(json.utf8)) else { return [] }
        return list
    }

    public static func encode(_ list: [SmartFolder]) -> String {
        (try? String(data: JSONEncoder().encode(list), encoding: .utf8)) ?? "[]"
    }
}
