import Foundation

/// One entry in a mounted volume, read with metadata only (never file contents).
public struct FileItem: Identifiable, Hashable, Sendable {
    public var url: URL
    public var name: String
    public var isDirectory: Bool
    public var size: Int64?
    public var modified: Date?
    public var id: URL { url }
    public var pathExtension: String { url.pathExtension }

    public init(url: URL, name: String, isDirectory: Bool, size: Int64?, modified: Date?) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

public enum FileSort: String, Sendable, CaseIterable {
    case name, modified, size, kind
}

/// File operations used by the in-app browser. All of them stay inside the mounted volume root.
public enum FileBrowsing {
    /// Lists a directory using only metadata keys, so remote files are not downloaded.
    public static func list(_ directory: URL, showHidden: Bool = false) throws(DriveError) -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                               options: showHidden ? [] : [.skipsHiddenFiles])
        } catch {
            let ns = error as NSError
            if ns.code == NSFileReadNoPermissionError { throw .permissionDenied("No permission to read \(directory.lastPathComponent).") }
            if ns.code == NSFileReadNoSuchFileError { throw .remoteUnavailable("\(directory.lastPathComponent) no longer exists. It may have been moved or deleted elsewhere.") }
            throw .remoteUnavailable("Could not read \(directory.lastPathComponent): \(ns.localizedDescription)")
        }
        return urls.compactMap { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            if !showHidden, name.hasPrefix(".") || name == "Icon\r" { return nil }
            let dir = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
            return FileItem(url: url, name: name, isDirectory: dir, size: dir ? nil : v?.fileSize.map(Int64.init), modified: v?.contentModificationDate)
        }
    }

    public static func sorted(_ items: [FileItem], by sort: FileSort, ascending: Bool = true) -> [FileItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order: ComparisonResult
            switch sort {
            case .name: order = a.name.localizedStandardCompare(b.name)
            case .modified: order = compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
            case .size: order = compare(a.size ?? -1, b.size ?? -1)
            case .kind:
                let k = a.pathExtension.localizedCaseInsensitiveCompare(b.pathExtension)
                order = k == .orderedSame ? a.name.localizedStandardCompare(b.name) : k
            }
            if order == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    /// True when `url` is `root` or below it, after removing `.` and `..`.
    /// Purely textual: it never touches the disk, so the UI can call it on a slow network volume without
    /// freezing. rclone volumes contain no symlinks, so resolving them is not needed.
    public static func isInside(_ url: URL, root: URL) -> Bool {
        let r = root.standardizedFileURL.path
        let u = url.standardizedFileURL.path
        return u == r || u.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    /// Validates a user-typed file or folder name.
    public static func validateName(_ raw: String) throws(DriveError) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .invalidConfiguration("A name cannot be empty.") }
        guard name != ".", name != ".." else { throw .invalidConfiguration("That name is reserved.") }
        guard !name.contains("/"), !name.contains("\0") else { throw .invalidConfiguration("Names cannot contain “/”.") }
        guard name.utf8.count <= 255 else { throw .invalidConfiguration("That name is too long.") }
        return name
    }

    /// "untitled folder", "untitled folder 2", … or "report.pdf", "report 2.pdf", …
    public static func uniqueName(for name: String, in directory: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> String {
        guard exists(directory.appendingPathComponent(name)) else { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var i = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            if !exists(directory.appendingPathComponent(candidate)) { return candidate }
            i += 1
        }
    }

    public static func createFolder(in directory: URL, root: URL) throws(DriveError) -> URL {
        guard isInside(directory, root: root) else { throw .permissionDenied("That folder is outside the drive.") }
        let url = directory.appendingPathComponent(uniqueName(for: "untitled folder", in: directory))
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        catch { throw .remoteUnavailable("Could not create the folder: \(error.localizedDescription)") }
        return url
    }

    public static func rename(_ url: URL, to newName: String, root: URL) throws(DriveError) -> URL {
        let name = try validateName(newName)
        guard isInside(url, root: root), url.standardizedFileURL != root.standardizedFileURL else { throw .permissionDenied("That item cannot be renamed.") }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        if target.lastPathComponent == url.lastPathComponent { return url }
        guard !FileManager.default.fileExists(atPath: target.path) || target.path.lowercased() == url.path.lowercased() else {
            throw .invalidConfiguration("An item named “\(name)” already exists here.")
        }
        do { try FileManager.default.moveItem(at: url, to: target) }
        catch { throw .remoteUnavailable("Could not rename: \(error.localizedDescription)") }
        return target
    }

    /// Moves items into `folder` (same volume). Refuses to move a folder into itself.
    public static func move(_ urls: [URL], into folder: URL, root: URL) throws(DriveError) -> [URL] {
        guard isInside(folder, root: root) else { throw .permissionDenied("The destination is outside the drive.") }
        var moved: [URL] = []
        for url in urls {
            guard isInside(url, root: root) else { throw .permissionDenied("\(url.lastPathComponent) is outside the drive.") }
            guard !isInside(folder, root: url) else { throw .invalidConfiguration("A folder cannot be moved into itself.") }
            if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { continue }
            let target = folder.appendingPathComponent(uniqueName(for: url.lastPathComponent, in: folder))
            do { try FileManager.default.moveItem(at: url, to: target) }
            catch { throw .remoteUnavailable("Could not move \(url.lastPathComponent): \(error.localizedDescription)") }
            moved.append(target)
        }
        return moved
    }

    /// Deletes items on the drive. Callers must confirm with the user first.
    public static func delete(_ urls: [URL], root: URL) throws(DriveError) {
        for url in urls {
            guard isInside(url, root: root), url.standardizedFileURL != root.standardizedFileURL else {
                throw .permissionDenied("\(url.lastPathComponent) cannot be deleted from here.")
            }
            do { try FileManager.default.removeItem(at: url) }
            catch { throw .remoteUnavailable("Could not delete \(url.lastPathComponent): \(error.localizedDescription)") }
        }
    }

    /// Copies local files into the drive. Name clashes get " 2", " 3"… instead of overwriting.
    public static func copyIn(_ sources: [URL], to folder: URL, root: URL) async throws(DriveError) -> [URL] {
        guard isInside(folder, root: root) else { throw .permissionDenied("The destination is outside the drive.") }
        let result: Result<[URL], DriveError> = await Task.detached(priority: .userInitiated) {
            var done: [URL] = []
            for src in sources {
                if isInside(folder, root: src) { return .failure(.invalidConfiguration("A folder cannot be copied into itself.")) }
                let target = folder.appendingPathComponent(uniqueName(for: src.lastPathComponent, in: folder))
                do { try FileManager.default.copyItem(at: src, to: target) }
                catch { return .failure(.remoteUnavailable("Could not copy \(src.lastPathComponent): \(error.localizedDescription)")) }
                done.append(target)
            }
            return .success(done)
        }.value
        return try result.get()
    }

    /// Copies items out of the drive to a local folder (downloads them through rclone).
    public static func copyOut(_ items: [URL], to destination: URL) async throws(DriveError) -> [URL] {
        let result: Result<[URL], DriveError> = await Task.detached(priority: .userInitiated) {
            var done: [URL] = []
            for src in items {
                let target = destination.appendingPathComponent(uniqueName(for: src.lastPathComponent, in: destination))
                do { try FileManager.default.copyItem(at: src, to: target) }
                catch { return .failure(.remoteUnavailable("Could not download \(src.lastPathComponent): \(error.localizedDescription)")) }
                done.append(target)
            }
            return .success(done)
        }.value
        return try result.get()
    }

    /// Path components from the volume root down to `url`, for a path bar.
    public static func breadcrumbs(for url: URL, root: URL, rootName: String) -> [(name: String, url: URL)] {
        guard isInside(url, root: root) else { return [(rootName, root)] }
        let rootPath = root.standardizedFileURL.path
        let rel = url.standardizedFileURL.path.dropFirst(rootPath.count).split(separator: "/").map(String.init)
        var crumbs: [(String, URL)] = [(rootName, root)]
        var current = root
        for part in rel {
            current = current.appendingPathComponent(part)
            crumbs.append((part, current))
        }
        return crumbs
    }
}
