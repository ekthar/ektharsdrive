import Foundation
import Testing
@testable import EktharDriveCore

/// Runs against a real, mounted Google Drive. Opt in by pointing EKTHAR_LIVE_GOOGLE_SOCKET at the
/// drive's rc socket (~/Library/Application Support/EktharDrive/run/google.sock). Read-only.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["EKTHAR_LIVE_GOOGLE_SOCKET"] != nil))
struct LiveGoogleSearchTests {
    let search = DriveSearch(socketPath: ProcessInfo.processInfo.environment["EKTHAR_LIVE_GOOGLE_SOCKET"] ?? "", drive: .googleDefault)

    @Test func searchResolvesRealPaths() async throws {
        let all = try await search.allFiles()
        #expect(!all.isEmpty)
        // Pick a real file name and search for its first word; it must come back with the same path.
        let target = try #require(all.first { $0.name.count >= 4 && !$0.name.hasPrefix(".") })
        let word = String(target.name.prefix { $0.isLetter || $0.isNumber })
        let found = try await search.search(DriveSearchQuery(text: word.isEmpty ? target.name : word))
        #expect(found.contains { $0.path == target.path })
        // Every resolved path exists on the mounted volume, when it is mounted at the usual place.
        let mount = NSHomeDirectory() + "/Volumes/Google Drive"
        if FileManager.default.fileExists(atPath: mount) {
            #expect(FileManager.default.fileExists(atPath: mount + "/" + target.path))
            let sample = all.prefix(300)
            let missing = sample.filter { !FileManager.default.fileExists(atPath: mount + "/" + $0.path) }
            print("live: \(sample.count - missing.count)/\(sample.count) paths found on the volume; missing: \(missing.prefix(5).map(\.path))")
            #expect(missing.count <= sample.count / 100) // allows for files changing while the test runs
        }
    }

    @Test func recentsAreRecentAndSorted() async throws {
        let recent = try await search.search(.recents)
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        #expect(recent.allSatisfy { ($0.modified ?? .distantPast) > cutoff && !$0.isFolder })
        #expect(zip(recent, recent.dropFirst()).allSatisfy { ($0.modified ?? .distantPast) >= ($1.modified ?? .distantPast) })
    }

    @Test func duplicatesAndSpaceAddUp() async throws {
        let all = try await search.allFiles()
        let groups = DriveAnalysis.duplicates(all)
        #expect(groups.allSatisfy { g in g.files.count > 1 && g.files.allSatisfy { $0.md5 == g.checksum && $0.size == g.size } })
        let total = all.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        #expect(DriveAnalysis.spaceMap(all).reduce(Int64(0)) { $0 + $1.bytes } == total)
        print("live: \(all.count) files, \(ByteFormat.string(total)), \(groups.count) duplicate sets, \(ByteFormat.string(groups.reduce(0) { $0 + $1.wastedBytes })) extra")
    }
}
