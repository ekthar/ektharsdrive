import Foundation
import Testing
@testable import EktharDriveCore

func makeTempDir(_ name: String = "t") throws -> URL {
    let base = ProcessInfo.processInfo.environment["EKTHAR_TEST_ROOT"].map(URL.init(fileURLWithPath:)) ?? FileManager.default.temporaryDirectory
    let url = base.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct DatabaseTests {
    @Test func migratesAndRoundTrips() throws {
        let dir = try makeTempDir("db")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase(url: dir.appendingPathComponent("a.sqlite"))
        #expect(db.db.userVersion == AppDatabase.schemaVersion)
        #expect(FilePermissions.isOwnerOnly(dir.appendingPathComponent("a.sqlite").path))

        var d = DriveConfiguration.oracleDefault
        d.autoMount = true
        try db.saveDrive(d)
        try db.saveDrive(.googleDefault)
        let loaded = try db.drives()
        #expect(loaded.count == 2)
        #expect(loaded.first { $0.id == "oracle" }?.autoMount == true)
        try db.setDriveStatus("oracle", "mounted")
        #expect(try db.driveStatus("oracle") == "mounted")

        let t = Transfer(driveID: "oracle", name: "a.bin", sourcePath: "a.bin", destinationPath: "oracle:a.bin", direction: .upload,
                         totalBytes: 10, transferredBytes: 4, status: .running)
        try db.upsertTransfer(t)
        var t2 = t
        t2.status = .completed
        t2.transferredBytes = 10
        try db.upsertTransfer(t2)
        let ts = try db.recentTransfers()
        #expect(ts.count == 1 && ts[0].status == .completed && ts[0].transferredBytes == 10)

        let running = Transfer(driveID: "oracle", name: "b", sourcePath: "b", destinationPath: "x", direction: .upload, totalBytes: 1, status: .running)
        try db.upsertTransfer(running)
        try db.markStaleTransfersInterrupted()
        #expect(try db.recentTransfers().first { $0.id == running.id }?.status == .failed)

        try db.addActivity(ActivityEvent(driveID: "oracle", eventType: "mount", message: "Mounted 100%_done", severity: .info))
        try db.addActivity(ActivityEvent(driveID: "google", eventType: "error", message: "token = ya29.SECRET", severity: .error))
        #expect(try db.activity(driveID: "oracle").count == 1)
        #expect(try db.activity(minimumSeverity: .error).count == 1)
        #expect(try db.activity(search: "100%_").count == 1, "LIKE wildcards are escaped")
        #expect(try db.activity(search: "%").count == 1, "literal % matches only the message containing it")
        #expect(try db.activity(search: "_d_").count == 0, "_ is not a wildcard")
        #expect(try db.activity().allSatisfy { !$0.message.contains("ya29.SECRET") }, "activity is redacted before storage")

        try db.setSetting("k", "v1")
        try db.setSetting("k", "v2")
        #expect(db.setting("k") == "v2")

        let key = dir.appendingPathComponent("key")
        FileManager.default.createFile(atPath: key.path, contents: Data())
        try db.saveSFTP(SFTPConnection(host: "h.example", port: 2222, username: "u", privateKeyPath: key.path), driveID: "oracle")
        #expect(try db.sftp(driveID: "oracle")?.port == 2222)
    }

    @Test func noSecretColumnsInSchema() throws {
        let dir = try makeTempDir("db")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase(url: dir.appendingPathComponent("a.sqlite"))
        let schema = try db.db.query("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL").compactMap { $0["sql"]?.string }.joined().lowercased()
            .replacingOccurrences(of: "key_has_passphrase integer", with: "") // boolean flag only; the passphrase lives in the Keychain
        for word in ["token", "secret", "password", "passphrase", "private_key "] {
            #expect(!schema.contains(word), "schema mentions \(word)")
        }
    }

    @Test func recoversFromCorruptDatabase() throws {
        let dir = try makeTempDir("db")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.sqlite")
        try Data(repeating: 0x42, count: 8192).write(to: url)
        let db = try AppDatabase(url: url)
        #expect(db.recoveredFrom != nil)
        #expect(FileManager.default.fileExists(atPath: db.recoveredFrom!.path), "corrupt file is kept, not deleted")
        try db.saveDrive(.googleDefault)
        #expect(try db.drives().count == 1)
    }

    @Test func reopenKeepsData() throws {
        let dir = try makeTempDir("db")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.sqlite")
        do { try AppDatabase(url: url).saveDrive(.googleDefault) }
        let again = try AppDatabase(url: url)
        #expect(again.recoveredFrom == nil)
        #expect(try again.drives().map(\.id) == ["google"])
    }
}

@Suite struct CacheManagerTests {
    func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func clearsOnlyUploadedFiles() throws {
        let root = try makeTempDir("cache")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(supportDirectory: root.appendingPathComponent("s"), cacheRoot: root.appendingPathComponent("c"), logsDirectory: root.appendingPathComponent("l"))
        let base = paths.cacheDirectory(for: "oracle")
        let clean = "srv/files/clean.bin", dirty = "srv/files/sub/dirty.bin", unknown = "srv/files/weird.bin"
        try write(base.appendingPathComponent("vfs/oracle/\(clean)"), String(repeating: "a", count: 5000))
        try write(base.appendingPathComponent("vfsMeta/oracle/\(clean)"), #"{"Size":5000,"Dirty":false}"#)
        try write(base.appendingPathComponent("vfs/oracle/\(dirty)"), "pending")
        try write(base.appendingPathComponent("vfsMeta/oracle/\(dirty)"), #"{"Size":7,"Dirty":true}"#)
        try write(base.appendingPathComponent("vfs/oracle/\(unknown)"), "??")
        try write(base.appendingPathComponent("vfsMeta/oracle/\(unknown)"), "not json")

        let cm = CacheManager(paths: paths)
        let before = cm.diskStats("oracle")
        #expect(before.files == 3 && before.uploadsQueued == 1 && before.source == .diskScan)

        #expect(throws: DriveError.self) { try cm.clearSafeCache("oracle", isMounted: true) }
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("vfs/oracle/\(clean)").path), "nothing deleted while mounted")

        let r = try cm.clearSafeCache("oracle", isMounted: false)
        #expect(r.removedFiles == 1 && r.keptDirty == 1 && r.keptUnknown == 1 && r.freedBytes > 0)
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("vfs/oracle/\(clean)").path))
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("vfs/oracle/\(dirty)").path), "dirty file kept")
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("vfsMeta/oracle/\(dirty)").path))
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("vfs/oracle/\(unknown)").path), "unreadable metadata kept")
    }

    @Test func ignoresSymlinkEscape() throws {
        let root = try makeTempDir("cache")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(supportDirectory: root.appendingPathComponent("s"), cacheRoot: root.appendingPathComponent("c"), logsDirectory: root.appendingPathComponent("l"))
        let outside = root.appendingPathComponent("precious.txt")
        try write(outside, "keep me")
        let base = paths.cacheDirectory(for: "g")
        try write(base.appendingPathComponent("vfsMeta/gdrive/x"), #"{"Dirty":false}"#)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("vfs"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("vfs/gdrive"), withDestinationURL: root)
        _ = try CacheManager(paths: paths).clearSafeCache("g", isMounted: false)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}

@Suite struct TransferTrackerTests {
    func item(_ name: String, _ bytes: Int64, _ size: Int64, dst: String = "oracle:") -> RcTransferring {
        RcTransferring(name: name, bytes: bytes, size: size, speed: 1000, speedAvg: 1000, eta: 2, percentage: nil,
                       srcFs: ":local:/cache/vfs/oracle", dstFs: dst, group: "global_stats")
    }

    @Test func tracksLifecycleFromRcloneData() {
        var t = TransferTracker(driveID: "oracle", remoteName: "oracle", ignoreExistingHistory: true)
        let old = RcCompletedTransfer(name: "old.txt", size: 1, bytes: 1, error: nil, checked: false, startedAt: "2026-10-30T10:00:00Z", completedAt: "2026-10-30T10:00:01Z")
        var u = t.update(transferring: [], completed: [old], queue: [])
        #expect(u.active.isEmpty && u.finished.isEmpty, "history from before observation is ignored")

        u = t.update(transferring: [], completed: [old], queue: [RcVFSQueue.Item(name: "up.bin", id: 1, size: 100, expiry: 1, tries: 0, delay: 5, uploading: false)])
        #expect(u.active.count == 1 && u.active[0].status == .queued && u.active[0].direction == .upload)

        u = t.update(transferring: [item("up.bin", 40, 100)], completed: [old], queue: [])
        #expect(u.active.count == 1)
        let running = u.active[0]
        #expect(running.status == .running && running.transferredBytes == 40 && running.totalBytes == 100 && running.fraction == 0.4)

        let done = RcCompletedTransfer(name: "up.bin", size: 100, bytes: 100, error: "", checked: false,
                                       startedAt: "2026-10-31T11:43:26.802267123+05:30", completedAt: "2026-10-31T11:43:30.1+05:30")
        u = t.update(transferring: [], completed: [old, done], queue: [])
        #expect(u.active.isEmpty)
        #expect(u.finished.count == 1 && u.finished[0].status == .completed && u.finished[0].id == running.id)
        #expect(u.finished[0].completedAt != nil)

        u = t.update(transferring: [], completed: [old, done], queue: [])
        #expect(u.finished.isEmpty, "completion is reported once")
    }

    @Test func reportsFailuresAndFastTransfers() {
        var t = TransferTracker(driveID: "g", remoteName: "gdrive")
        _ = t.update(transferring: [], completed: [], queue: [])
        let failed = RcCompletedTransfer(name: "x.zip", size: 10, bytes: 3, error: "googleapi: Error 403: storageQuotaExceeded token=ya29.SECRET", checked: false, startedAt: nil, completedAt: nil, dstFs: "gdrive:")
        let fast = RcCompletedTransfer(name: "dl.pdf", size: 5, bytes: 5, error: nil, checked: false, startedAt: nil, completedAt: "2026-10-31T00:00:00Z", srcFs: "gdrive:", dstFs: ":local:/cache")
        let checkOnly = RcCompletedTransfer(name: "c", size: 0, bytes: 0, error: nil, checked: true, startedAt: nil, completedAt: nil)
        let u = t.update(transferring: [], completed: [failed, fast, checkOnly], queue: [])
        #expect(u.finished.count == 2)
        let f = u.finished.first { $0.name == "x.zip" }!
        #expect(f.status == .failed && f.direction == .upload && !(f.errorMessage ?? "").contains("ya29.SECRET"))
        #expect(u.finished.first { $0.name == "dl.pdf" }?.direction == .download)
    }

    @Test func freshProcessKeepsTransfersThatFinishedBeforeFirstPoll() {
        var t = TransferTracker(driveID: "o", remoteName: "oracle")
        let done = RcCompletedTransfer(name: "fast.bin", size: 9, bytes: 9, error: nil, checked: false, startedAt: nil, completedAt: "2026-10-31T00:00:00Z", dstFs: "oracle:")
        let u = t.update(transferring: [], completed: [done], queue: [])
        #expect(u.finished.map(\.name) == ["fast.bin"])
    }

    @Test func stopMarksOpenTransfersFailed() {
        var t = TransferTracker(driveID: "o", remoteName: "oracle")
        _ = t.update(transferring: [], completed: [], queue: [])
        _ = t.update(transferring: [item("a", 1, 10)], completed: [], queue: [])
        let open = t.stop()
        #expect(open.count == 1 && open[0].status == .failed && open[0].errorMessage != nil)
    }

    @Test func parsesRcloneDates() {
        #expect(TransferTracker.parseDate("2026-10-31T11:43:26.802267123+05:30") != nil)
        #expect(TransferTracker.parseDate("2026-10-31T06:13:26Z") != nil)
        #expect(TransferTracker.parseDate("garbage") == nil)
    }
}

@Suite(.serialized) struct KeychainTests {
    @Test func realKeychainRoundTrip() throws {
        let store = KeychainStore(service: "com.ekthar.drive.tests.\(UUID().uuidString.prefix(6))")
        defer { try? store.delete(.oracleKeyPassphrase) }
        #expect(try store.get(.oracleKeyPassphrase) == nil)
        try store.set("first", for: .oracleKeyPassphrase)
        #expect(try store.get(.oracleKeyPassphrase) == "first")
        try store.set("second", for: .oracleKeyPassphrase)
        #expect(try store.get(.oracleKeyPassphrase) == "second")
        try store.delete(.oracleKeyPassphrase)
        #expect(try store.get(.oracleKeyPassphrase) == nil)
        try store.delete(.oracleKeyPassphrase)
    }

    @Test func randomPasswordsAreStrongAndUnique() {
        let a = KeychainStore.randomPassword(), b = KeychainStore.randomPassword()
        #expect(a != b && a.count >= 42)
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }
}

@Suite struct FilesystemHelperTests {
    @Test func mountTableSeesRoot() {
        #expect(MountTable.isMounted("/"))
        let dir = FileManager.default.temporaryDirectory.path
        #expect(!MountTable.isMounted(dir), "a directory is not a mount")
        #expect(DiskSpace.freeBytes(at: dir) ?? 0 > 0)
    }

    @Test func appPathsArePrivate() throws {
        let root = try makeTempDir("paths")
        defer { try? FileManager.default.removeItem(at: root) }
        let p = AppPaths(supportDirectory: root.appendingPathComponent("s"), cacheRoot: root.appendingPathComponent("c"), logsDirectory: root.appendingPathComponent("l"))
        try p.prepare()
        #expect(FilePermissions.isOwnerOnly(p.supportDirectory.path))
        #expect(FilePermissions.isOwnerOnly(p.runDirectory.path))
        #expect(FilePermissions.isOwnerOnly(p.cacheRoot.path))
        #expect(p.rcSocket(for: "google").path.utf8.count < 104 || root.path.utf8.count > 60)
    }

    @Test func rotatingLogRedacts() throws {
        let root = try makeTempDir("log")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("x.log")
        let log = RotatingLogFile(url: url, maxBytes: 200)
        for i in 0..<20 { log.append("line \(i) RCLONE_CONFIG_PASS=topsecret") }
        log.flush()
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let rotated = (try? String(contentsOf: url.appendingPathExtension("1"), encoding: .utf8)) ?? ""
        #expect(!(text + rotated).contains("topsecret"))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path), "rotated at size limit")
        #expect(FilePermissions.isOwnerOnly(url.path))
    }
}

@Suite struct ProcessTests {
    @Test func runnerUsesArgvNotShell() async throws {
        let r = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/echo"), arguments: ["a; echo injected", "$(whoami)"])
        #expect(r.stdout == "a; echo injected $(whoami)\n")
    }

    @Test func runnerTimesOut() async throws {
        let r = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: .milliseconds(300))
        #expect(r.timedOut && !r.succeeded)
    }

    @Test func safeEnvironmentDropsInheritedSecrets() {
        setenv("AWS_SECRET_ACCESS_KEY", "leak", 1)
        defer { unsetenv("AWS_SECRET_ACCESS_KEY") }
        let env = SafeEnvironment.base()
        #expect(env["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(env["PATH"] != nil && env["HOME"] != nil)
    }

    @Test func supervisorPreventsDuplicatesAndReportsExit() async throws {
        let root = try makeTempDir("sup")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(supportDirectory: root.appendingPathComponent("s"), cacheRoot: root.appendingPathComponent("c"), logsDirectory: root.appendingPathComponent("l"))
        try paths.prepare()
        let sup = ProcessSupervisor(paths: paths)
        let pid = try await sup.launch(driveID: "d", executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo started; sleep 30"], environment: SafeEnvironment.base())
        #expect(pid > 0)
        #expect(await sup.isRunning("d"))
        #expect(FileManager.default.fileExists(atPath: paths.pidFile(for: "d").path))
        await #expect(throws: DriveError.alreadyRunning) {
            try await sup.launch(driveID: "d", executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["1"], environment: [:])
        }
        var iterator = sup.events.makeAsyncIterator()
        for _ in 0..<50 where !(await sup.recentOutput(for: "d").contains("started")) { try await Task.sleep(for: .milliseconds(100)) }
        await sup.terminate("d")
        var exited = false
        while let e = await iterator.next() {
            if case .exited(let id, _, _, _, let recent) = e {
                #expect(id == "d")
                #expect(recent.contains("started"))
                exited = true
                break
            }
        }
        #expect(exited)
        #expect(await sup.waitForExit("d", timeout: .seconds(2)))
        #expect(!FileManager.default.fileExists(atPath: paths.pidFile(for: "d").path), "pid file removed on exit")
    }

    @Test func staleOrUnrelatedPidFilesAreNotAdopted() async throws {
        let root = try makeTempDir("sup")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(supportDirectory: root.appendingPathComponent("s"), cacheRoot: root.appendingPathComponent("c"), logsDirectory: root.appendingPathComponent("l"))
        try paths.prepare()
        // A live process that is NOT rclone (this test process) must not be adopted.
        try Data("\(getpid())\n/x\n".utf8).write(to: paths.pidFile(for: "a"))
        try Data("999999\n/x\n".utf8).write(to: paths.pidFile(for: "b"))
        let adopted = await ProcessSupervisor(paths: paths).adoptOrphans(driveIDs: ["a", "b"])
        #expect(adopted.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paths.pidFile(for: "b").path))
    }
}
