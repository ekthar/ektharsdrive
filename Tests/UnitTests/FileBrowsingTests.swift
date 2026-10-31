import Foundation
import Testing
@testable import EktharDriveCore

@Suite struct FileBrowsingTests {
    func makeTree() throws -> URL {
        let root = try makeTempDir("fb")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Photos/2026"), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: root.appendingPathComponent("b.txt"))
        try Data("abcdef".utf8).write(to: root.appendingPathComponent("A report.pdf"))
        try Data("x".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        try Data("x".utf8).write(to: root.appendingPathComponent("file 10.txt"))
        try Data("x".utf8).write(to: root.appendingPathComponent("file 9.txt"))
        return root
    }

    @Test func listsWithFoldersFirstAndNaturalOrder() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let items = FileBrowsing.sorted(try FileBrowsing.list(root), by: .name)
        #expect(items.map(\.name) == ["Photos", "A report.pdf", "b.txt", "file 9.txt", "file 10.txt"], "hidden files skipped, natural sort")
        #expect(items[0].isDirectory && items[0].size == nil)
        #expect(items.first { $0.name == "A report.pdf" }?.size == 6)
        let bySize = FileBrowsing.sorted(items, by: .size, ascending: false)
        #expect(bySize.first?.name == "Photos" && bySize[1].name == "A report.pdf")
    }

    @Test func containmentResolvesDotDot() throws {
        let root = URL(fileURLWithPath: "/Volumes/Oracle Drive")
        #expect(FileBrowsing.isInside(root.appendingPathComponent("a/b"), root: root))
        #expect(FileBrowsing.isInside(root, root: root))
        #expect(!FileBrowsing.isInside(root.appendingPathComponent("../Google Drive/x"), root: root))
        #expect(!FileBrowsing.isInside(URL(fileURLWithPath: "/Volumes/Oracle Drive 2/x"), root: root), "prefix lookalike is outside")
    }

    @Test func validatesNames() throws {
        #expect(try FileBrowsing.validateName("  Notes  ") == "Notes")
        for bad in ["", "  ", ".", "..", "a/b", String(repeating: "é", count: 200)] {
            #expect(throws: DriveError.self) { try FileBrowsing.validateName(bad) }
        }
    }

    @Test func uniqueNamesNeverOverwrite() {
        let dir = URL(fileURLWithPath: "/x")
        let taken: Set<String> = ["/x/untitled folder", "/x/untitled folder 2", "/x/report.pdf"]
        #expect(FileBrowsing.uniqueName(for: "untitled folder", in: dir) { taken.contains($0.path) } == "untitled folder 3")
        #expect(FileBrowsing.uniqueName(for: "report.pdf", in: dir) { taken.contains($0.path) } == "report 2.pdf")
        #expect(FileBrowsing.uniqueName(for: "new.txt", in: dir) { taken.contains($0.path) } == "new.txt")
    }

    @Test func folderRenameMoveDeleteStayInsideRoot() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try FileBrowsing.createFolder(in: root, root: root)
        #expect(folder.lastPathComponent == "untitled folder")
        #expect(try FileBrowsing.createFolder(in: root, root: root).lastPathComponent == "untitled folder 2")

        let renamed = try FileBrowsing.rename(root.appendingPathComponent("b.txt"), to: "c.txt", root: root)
        #expect(renamed.lastPathComponent == "c.txt")
        #expect(throws: DriveError.self) { try FileBrowsing.rename(renamed, to: "A report.pdf", root: root) }
        #expect(throws: DriveError.self) { try FileBrowsing.rename(root, to: "x", root: root) }

        let moved = try FileBrowsing.move([renamed], into: folder, root: root)
        #expect(FileManager.default.fileExists(atPath: moved[0].path))
        #expect(throws: DriveError.self) { try FileBrowsing.move([root.appendingPathComponent("Photos")], into: root.appendingPathComponent("Photos/2026"), root: root) }

        let outside = try makeTempDir("outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("keep".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        #expect(throws: DriveError.self) { try FileBrowsing.delete([outside.appendingPathComponent("keep.txt")], root: root) }
        #expect(throws: DriveError.self) { try FileBrowsing.delete([root], root: root) }
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.txt").path))

        try FileBrowsing.delete([moved[0]], root: root)
        #expect(!FileManager.default.fileExists(atPath: moved[0].path))

        let copied = try await FileBrowsing.copyIn([outside.appendingPathComponent("keep.txt")], to: folder, root: root)
        let again = try await FileBrowsing.copyIn([outside.appendingPathComponent("keep.txt")], to: folder, root: root)
        #expect(copied[0].lastPathComponent == "keep.txt" && again[0].lastPathComponent == "keep 2.txt", "no overwrite on copy")
        let out = try await FileBrowsing.copyOut([copied[0]], to: outside)
        #expect(out[0].lastPathComponent == "keep 2.txt")
    }

    @Test func copiesWholeFoldersInAndOut() async throws {
        let root = try makeTempDir("fbroot")
        let outside = try makeTempDir("fbsrc")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let src = outside.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: src.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: src.appendingPathComponent("sub/deeper/b.txt"))

        let copied = try await FileBrowsing.copyIn([src], to: root, root: root)
        #expect(try String(contentsOf: copied[0].appendingPathComponent("sub/deeper/b.txt"), encoding: .utf8) == "b", "folder copied with its tree")
        let again = try await FileBrowsing.copyIn([src], to: root, root: root)
        #expect(again[0].lastPathComponent == "Project 2", "never merges into or overwrites an existing folder")

        let back = try await FileBrowsing.copyOut([copied[0]], to: outside)
        #expect(back[0].lastPathComponent == "Project 2")
        #expect(FileManager.default.fileExists(atPath: back[0].appendingPathComponent("a.txt").path))
        await #expect(throws: DriveError.self) { _ = try await FileBrowsing.copyIn([root], to: root.appendingPathComponent("Project"), root: root) }
    }

    @Test func cloudPathsAreRelativeToTheMountAndDriveBase() {
        #expect(CloudActions.remotePath(of: URL(fileURLWithPath: "/Users/e/Volumes/Google Drive/Work/a b.pdf"), mountPath: "/Users/e/Volumes/Google Drive") == "Work/a b.pdf")
        #expect(CloudActions.remotePath(of: URL(fileURLWithPath: "/Users/e/Volumes/Google Drive 2/x"), mountPath: "/Users/e/Volumes/Google Drive") == nil, "lookalike prefix")
        #expect(CloudActions.remotePath(of: URL(fileURLWithPath: "/Users/e/Volumes/Google Drive"), mountPath: "/Users/e/Volumes/Google Drive") == "")
        let oracle = CloudActions(rc: RcClient(socketPath: "/x"), drive: .oracleDefault)
        #expect(oracle.fullRemote("Work/a.pdf") == "/srv/ekthar-drive/files/Work/a.pdf")
        #expect(oracle.fullRemote("") == "/srv/ekthar-drive/files")
        let google = CloudActions(rc: RcClient(socketPath: "/x"), drive: .googleDefault)
        #expect(google.fullRemote("Work/a.pdf") == "Work/a.pdf")
    }

    @Test func breadcrumbs() {
        let root = URL(fileURLWithPath: "/Volumes/Google Drive")
        let crumbs = FileBrowsing.breadcrumbs(for: root.appendingPathComponent("Work/2026"), root: root, rootName: "Google Drive")
        #expect(crumbs.map(\.name) == ["Google Drive", "Work", "2026"])
        #expect(crumbs.last?.url.path == "/Volumes/Google Drive/Work/2026")
    }
}
