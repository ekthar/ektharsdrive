import Foundation
import os
import Testing
@testable import EktharDriveCore

@Suite struct DriveSearchQueryTests {
    @Test func escapesQuotesAndBackslashes() {
        #expect(DriveSearchQuery.literal("it's") == #"'it\'s'"#)
        #expect(DriveSearchQuery.literal(#"a\b"#) == #"'a\\b'"#)
        #expect(DriveSearchQuery.literal(#"x' or name contains 'y"#) == #"'x\' or name contains \'y'"#)
    }

    @Test func buildsGoogleQuery() {
        let now = ISO8601DateFormatter().date(from: "2026-03-31T12:00:00Z")!
        let q = DriveSearchQuery(text: "  Report ", kind: .pdfs, modifiedWithinDays: 30, filesOnly: true)
        #expect(q.googleQuery(now: now) ==
            "trashed = false and name contains 'Report' and mimeType = 'application/pdf' and mimeType != 'application/vnd.google-apps.folder' and modifiedTime > '2026-03-01T12:00:00Z'")
        #expect(DriveSearchQuery().googleQuery() == "trashed = false")
        #expect(DriveSearchQuery(kind: .folders, filesOnly: true).googleQuery() == "trashed = false and mimeType = 'application/vnd.google-apps.folder'")
    }

    @Test func emptiness() {
        #expect(DriveSearchQuery().isEmpty)
        #expect(DriveSearchQuery(text: "   ").isEmpty)
        #expect(!DriveSearchQuery(kind: .images).isEmpty)
        #expect(!DriveSearchQuery.recents.isEmpty)
    }

    @Test func localMatching() {
        let now = Date()
        let f = DriveFile(id: "1", name: "Holiday Photo.JPG", path: "Pics/Holiday Photo.JPG", size: 5 << 20,
                          modified: now.addingTimeInterval(-3 * 86_400), mimeType: "image/jpeg")
        #expect(DriveSearchQuery(text: "photo").matches(f, now: now))
        #expect(!DriveSearchQuery(text: "video").matches(f, now: now))
        #expect(DriveSearchQuery(kind: .images).matches(f, now: now))
        #expect(!DriveSearchQuery(kind: .videos).matches(f, now: now))
        #expect(DriveSearchQuery(modifiedWithinDays: 7).matches(f, now: now))
        #expect(!DriveSearchQuery(modifiedWithinDays: 1).matches(f, now: now))
        #expect(!DriveSearchQuery(minSizeBytes: 10 << 20).matches(f, now: now))
        let folder = DriveFile(id: "2", name: "Photos", path: "Photos", size: nil, modified: nil, mimeType: DriveSearchQuery.folderMime)
        #expect(!DriveSearchQuery(text: "photo", filesOnly: true).matches(folder, now: now))
        #expect(DriveSearchQuery(kind: .folders).matches(folder, now: now))
    }

    @Test func smartFoldersRoundTrip() {
        let list = [SmartFolder(name: "Big videos", driveID: "google", query: DriveSearchQuery(kind: .videos, minSizeBytes: 1 << 30))]
        #expect(SmartFolder.decode(SmartFolder.encode(list)) == list)
        #expect(SmartFolder.decode("not json").isEmpty)
        #expect(SmartFolder.decode(nil).isEmpty)
    }
}

@Suite struct FolderTreeTests {
    let tree = FolderTree(folders: [
        "A": ("Projects", "ROOT"),
        "B": ("2026", "A"),
        "S": ("Shared thing", "SOMEONE_ELSE"),
        "L1": ("loop", "L2"), "L2": ("loop", "L1"),
    ], rootID: "ROOT")

    @Test func resolvesPaths() {
        #expect(tree.path(name: "plan.pdf", parent: "B") == "Projects/2026/plan.pdf")
        #expect(tree.path(name: "top.txt", parent: "ROOT") == "top.txt")
        #expect(tree.path(name: "Projects", parent: "ROOT") == "Projects")
        #expect(tree.path(name: "a/b.txt", parent: "ROOT") == "a\u{FF0F}b.txt")
        #expect(tree.path(name: "line1\nline2\t", parent: "ROOT") == "line1\u{240A}line2\u{2409}")
    }

    @Test func rejectsItemsOutsideMyDrive() {
        #expect(tree.path(name: "x", parent: "S") == nil)
        #expect(tree.path(name: "x", parent: "UNKNOWN") == nil)
        #expect(tree.path(name: "x", parent: nil) == nil)
        #expect(tree.path(name: "x", parent: "L1") == nil) // a cycle ends, it does not hang
    }

    @Test func parsesQueryRow() {
        let row: [String: Any] = ["id": "f1", "name": "plan.pdf", "parents": ["B"], "size": "2048",
                                  "modifiedTime": "2026-02-01T10:00:00.123Z", "mimeType": "application/pdf",
                                  "md5Checksum": "abc", "webViewLink": "https://drive.google.com/file/d/f1/view"]
        let f = DriveSearch.parse(row, tree: tree)
        #expect(f?.path == "Projects/2026/plan.pdf")
        #expect(f?.size == 2048)
        #expect(f?.md5 == "abc")
        #expect(f?.modified != nil)
        #expect(f?.webLink?.host == "drive.google.com")
        // Google Docs have no size.
        let doc = DriveSearch.parse(["id": "d", "name": "Notes", "parents": ["ROOT"], "mimeType": "application/vnd.google-apps.document"], tree: tree)
        #expect(doc?.size == nil)
    }
}

@Suite struct DriveAnalysisTests {
    func file(_ path: String, _ size: Int64?, md5: String? = nil, folder: Bool = false) -> DriveFile {
        DriveFile(id: path, name: (path as NSString).lastPathComponent, path: path, size: size, modified: nil,
                  mimeType: folder ? DriveSearchQuery.folderMime : "application/octet-stream", md5: md5)
    }

    @Test func findsDuplicatesByChecksumAndSize() {
        let files = [
            file("a/movie.mp4", 1000, md5: "m1"), file("b/movie copy.mp4", 1000, md5: "m1"), file("c/movie.mp4", 1000, md5: "m1"),
            file("x.txt", 10, md5: "t1"), file("y.txt", 10, md5: "t1"),
            file("unique.bin", 50, md5: "u1"),
            file("empty1", 0, md5: "e"), file("empty2", 0, md5: "e"),   // empty files are not duplicates worth showing
            file("doc1", nil), file("doc2", nil),                        // Google Docs: no checksum
            file("same-md5-other-size", 999, md5: "m1"),
        ]
        let groups = DriveAnalysis.duplicates(files)
        #expect(groups.count == 2)
        #expect(groups[0].checksum == "m1")
        #expect(groups[0].files.count == 3)
        #expect(groups[0].wastedBytes == 2000)
        #expect(groups[1].wastedBytes == 10)
    }

    @Test func spaceMapTotalsByChild() {
        let files = [
            file("Videos/a.mp4", 500), file("Videos/2026/b.mp4", 300), file("Docs/c.pdf", 100),
            file("top.zip", 250), file("Videos", nil, folder: true),
        ]
        let top = DriveAnalysis.spaceMap(files)
        #expect(top.map(\.name) == ["Videos", "top.zip", "Docs"])
        #expect(top[0].bytes == 800)
        #expect(top[0].fileCount == 2)
        #expect(top[0].isFolder)
        #expect(!top[1].isFolder)
        let inside = DriveAnalysis.spaceMap(files, in: "/Videos/")
        #expect(inside.map(\.path) == ["Videos/a.mp4", "Videos/2026"])
        #expect(DriveAnalysis.spaceMap(files, in: "Nope").isEmpty)
    }
}

@Suite struct PrefetchTests {
    func tempDir() throws -> URL {
        let base = ProcessInfo.processInfo.environment["EKTHAR_TEST_ROOT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("prefetch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        return dir
    }

    @Test func readsEveryFileAndReportsProgress() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 3 << 20).write(to: dir.appendingPathComponent("a.bin"))
        try Data(count: 1000).write(to: dir.appendingPathComponent("sub/b.bin"))
        try Data(count: 10).write(to: dir.appendingPathComponent(".hidden"))
        let seen = OSAllocatedUnfairLock(initialState: [Int64]())
        let r = try Prefetcher.download(dir, budgetBytes: 10 << 20, progress: { d, _ in seen.withLock { $0.append(d) } }, cancelled: { false })
        #expect(r.files == 2)
        #expect(r.bytes == (3 << 20) + 1000)
        let last: Int64 = seen.withLock { $0.last ?? -1 }
        #expect(last == Int64(3 << 20) + 1000)
    }

    @Test func refusesWhatDoesNotFitTheCache() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 2000).write(to: dir.appendingPathComponent("a.bin"))
        #expect(throws: DriveError.self) {
            try Prefetcher.download(dir, budgetBytes: 1000, progress: { _, _ in }, cancelled: { false })
        }
    }

    @Test func stopsWhenCancelled() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 4 << 20).write(to: dir.appendingPathComponent("a.bin"))
        let stop = StopFlag()
        stop.set()
        let r = try Prefetcher.download(dir, budgetBytes: 10 << 20, progress: { _, _ in }, cancelled: stop.isSet)
        #expect(r.bytes == 0)
    }

    @Test func pinsRoundTripAndNormalise() {
        let p = OfflinePin(driveID: "google", path: "/Projects/2026/")
        #expect(p.path == "Projects/2026")
        #expect(p.name == "2026")
        #expect(OfflinePin(driveID: "google", path: "").name == "Whole drive")
        #expect(Prefetcher.decodePins(Prefetcher.encodePins([p])) == [p])
        #expect(Prefetcher.decodePins("garbage").isEmpty)
    }

    @Test func throttleLimitsUpdates() {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let t = ProgressThrottle(step: 100) { _, _ in count.withLock { $0 += 1 } }
        for d in stride(from: Int64(0), through: 1000, by: 10) { t.report(d, 1000) }
        // First call, every 100 bytes after, and the final one.
        #expect(count.withLock { $0 } == 11)
    }

    @Test func oldSettingsGetSpeedDefaults() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"theme":"dark"}"#.utf8))
        #expect(s.showPreviews)
        #expect(s.prefetchSelection)
        #expect(s.theme == .dark)
    }
}
