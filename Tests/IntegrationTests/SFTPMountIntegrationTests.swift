import CryptoKit
import Foundation
import Testing
@testable import EktharDriveCore

// These tests use a REAL rclone binary, a REAL SFTP server (`rclone serve sftp` on 127.0.0.1 with its own
// host key and public-key auth) and a REAL macOS NFS mount. They stand in for the Oracle VM.
// Enable with EKTHAR_RCLONE=/path/to/official/rclone. Optional EKTHAR_TEST_ROOT for a short scratch path.

let rclonePath = ProcessInfo.processInfo.environment["EKTHAR_RCLONE"]
let integrationEnabled = rclonePath.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false
/// EKTHAR_ENGINE=macfuse runs the same suite through macFUSE instead of the built-in NFS engine.
let testEngine: MountEngine = ProcessInfo.processInfo.environment["EKTHAR_ENGINE"].flatMap(MountEngine.init(rawValue:)) ?? .nfs

func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func writeRandom(_ url: URL, bytes: Int) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let h = try FileHandle(forWritingTo: url)
    defer { try? h.close() }
    var remaining = bytes
    while remaining > 0 {
        let n = min(remaining, 1 << 20)
        var chunk = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &chunk)
        try h.write(contentsOf: chunk)
        remaining -= n
    }
}

@MainActor
func eventually(_ timeout: Duration, poll: Duration = .milliseconds(250), _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: poll)
    }
    return await condition()
}

/// A local SFTP server standing in for the Oracle VM.
final class SFTPServer: @unchecked Sendable {
    let root: URL
    let data: URL
    let port: Int
    let clientKey: URL
    let hostKey: URL
    private var process: Process?

    init(root: URL) async throws {
        self.root = root
        data = root.appendingPathComponent("server-data")
        try FileManager.default.createDirectory(at: data.appendingPathComponent("files"), withIntermediateDirectories: true)
        clientKey = root.appendingPathComponent("client_ed25519")
        hostKey = root.appendingPathComponent("host_ed25519")
        port = Int.random(in: 20000...45000)
        for key in [clientKey, hostKey] {
            let r = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/ssh-keygen"), arguments: ["-q", "-t", "ed25519", "-N", "", "-f", key.path])
            precondition(r.exitCode == 0, "ssh-keygen failed: \(r.stderr)")
        }
        try start()
    }

    func start() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: rclonePath!)
        p.arguments = ["serve", "sftp", data.path, "--addr", "127.0.0.1:\(port)", "--authorized-keys", clientKey.path + ".pub",
                       "--key", hostKey.path, "--config", "/dev/null", "--log-level", "ERROR"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        // wait for the port to accept connections
        for _ in 0..<50 {
            if canConnect() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func stop() {
        process?.terminate()
        process?.waitUntilExit()
        process = nil
    }

    func canConnect() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    deinit { stop() }
}

@MainActor
struct Harness {
    let root: URL
    let paths: AppPaths
    let server: SFTPServer
    let manager: DriveManager
    let mountPath: String

    static func make(writeBack: Int = 1, name: String = "it") async throws -> Harness {
        let base = ProcessInfo.processInfo.environment["EKTHAR_TEST_ROOT"].map(URL.init(fileURLWithPath:)) ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = AppPaths(supportDirectory: root.appendingPathComponent("s"), cacheRoot: root.appendingPathComponent("c"), logsDirectory: root.appendingPathComponent("l"))
        try paths.prepare()
        let server = try await SFTPServer(root: root)
        let db = try AppDatabase(url: paths.databaseURL)
        var settings = AppSettings()
        settings.rclonePath = rclonePath
        settings.mountEngine = testEngine
        settings.minFreeSpaceGB = 1
        settings.notificationsEnabled = false
        try db.setSetting("app", String(decoding: try JSONEncoder().encode(settings), as: UTF8.self))
        let mountPath = root.appendingPathComponent("mnt/Oracle Drive").path
        var oracle = DriveConfiguration.oracleDefault
        oracle.mountPath = mountPath
        oracle.remotePath = "/files"
        oracle.cache.writeBackSeconds = writeBack
        oracle.cache.maxSizeBytes = 1 * .gibibyte
        oracle.maxRetryAttempts = 2
        try db.saveDrive(oracle)
        let manager = DriveManager(paths: paths, secrets: InMemorySecretStore(), database: db)
        await manager.start()
        return Harness(root: root, paths: paths, server: server, manager: manager, mountPath: mountPath)
    }

    var connection: SFTPConnection {
        SFTPConnection(host: "127.0.0.1", port: server.port, username: "ekthar-drive", privateKeyPath: server.clientKey.path)
    }

    func connect() async throws {
        let keys = try await manager.scanOracleHostKeys(host: "127.0.0.1", port: server.port)
        try manager.trustOracleHostKeys(keys, host: "127.0.0.1", port: server.port)
        try await manager.configureOracle(connection, passphrase: nil, remoteDirectory: "/files")
    }

    func pending() async -> Int {
        await MountManager(paths: paths, supervisor: manager.supervisor, rcloneURL: URL(fileURLWithPath: rclonePath!)).pendingUploads("oracle") ?? -1
    }

    func cleanUp() async {
        await manager.unmountAll(waitForUploads: true)
        // Anything else a test mounted under its root (extra volumes, half-finished mounts).
        for entry in MountTable.entries() where MountTable.normalize(entry.mountPoint).hasPrefix(MountTable.normalize(root.path)) {
            _ = try? await ProcessRunner().run(URL(fileURLWithPath: "/sbin/umount"), arguments: [entry.mountPoint], timeout: .seconds(20))
        }
        for id in ["oracle", "vol-a", "vol-b"] { await manager.supervisor.terminate(id) }
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

/// Runs `body` with a fresh harness and always unmounts / stops the server afterwards, even on failure.
@MainActor
func withHarness(writeBack: Int = 1, name: String = "it", _ body: @MainActor (Harness) async throws -> Void) async throws {
    let h = try await Harness.make(writeBack: writeBack, name: name)
    do {
        try await body(h)
    } catch {
        await h.cleanUp()
        throw error
    }
    await h.cleanUp()
}

@MainActor
@Suite(.serialized, .enabled(if: integrationEnabled, "Set EKTHAR_RCLONE to an official rclone binary"))
struct SFTPMountIntegrationTests {

    @Test func fullLifecycleOnRealMount() async throws {
        try await withHarness(writeBack: 3) { h in
            let m = h.manager
            #expect(m.dependencies?.rclone != nil)
            #expect(m.dependencies?.nfsUsable == true)

            // Seed the "server" before mounting.
            let serverFiles = h.server.data.appendingPathComponent("files")
            try Data("hello from oracle\n".utf8).write(to: serverFiles.appendingPathComponent("existing.txt"))
            try writeRandom(serverFiles.appendingPathComponent("download.bin"), bytes: 32 << 20)
            let downloadHash = try sha256(serverFiles.appendingPathComponent("download.bin"))

            // Configure: host key verification + real SFTP connection test + real capacity.
            try await h.connect()
            guard case .connected = m.state("oracle").connection else { Issue.record("not connected: \(m.state("oracle"))"); return }
            let usage = try #require(m.state("oracle").usage)
            #expect((usage.total ?? 0) > 0 && (usage.free ?? 0) > 0, "capacity comes from the server filesystem")
            #expect(FilePermissions.isOwnerOnly(h.paths.knownHostsURL.path))
            #expect(FilePermissions.isOwnerOnly(h.paths.rcloneConfigURL.path))
            let conf = try String(contentsOf: h.paths.rcloneConfigURL, encoding: .utf8)
            #expect(conf.contains("RCLONE_ENCRYPT_V0:") && !conf.contains("127.0.0.1"), "rclone.conf is encrypted at rest")

            // Mount
            await m.mount("oracle")
            #expect(m.state("oracle").phase == .mounted, "\(String(describing: m.state("oracle").lastError))")
            #expect(MountTable.isMounted(h.mountPath))
            let mnt = URL(fileURLWithPath: h.mountPath)
            let fm = FileManager.default

            // 1. Listing + 2. reading existing files
            let listing = try fm.contentsOfDirectory(atPath: mnt.path)
            #expect(listing.contains("existing.txt") && listing.contains("download.bin"))
            #expect(try String(contentsOf: mnt.appendingPathComponent("existing.txt"), encoding: .utf8) == "hello from oracle\n")
            // 9. Large download integrity
            #expect(try sha256(mnt.appendingPathComponent("download.bin")) == downloadHash)

            // 3/4. Create + write, 10. Unicode names
            try Data("note".utf8).write(to: mnt.appendingPathComponent("note.txt"))
            try fm.createDirectory(at: mnt.appendingPathComponent("Ünïcødé 文件夹"), withIntermediateDirectories: true)
            try Data("unicode".utf8).write(to: mnt.appendingPathComponent("Ünïcødé 文件夹/файл ✓.txt"))
            // 8. Large upload
            try writeRandom(mnt.appendingPathComponent("upload.bin"), bytes: 64 << 20)
            let uploadHash = try sha256(mnt.appendingPathComponent("upload.bin"))
            // 5. Rename, 6. Move, 7. Delete
            try Data("rename me".utf8).write(to: mnt.appendingPathComponent("before.txt"))
            try fm.moveItem(at: mnt.appendingPathComponent("before.txt"), to: mnt.appendingPathComponent("after.txt"))
            try fm.createDirectory(at: mnt.appendingPathComponent("archive"), withIntermediateDirectories: true)
            try fm.moveItem(at: mnt.appendingPathComponent("note.txt"), to: mnt.appendingPathComponent("archive/note.txt"))
            try fm.removeItem(at: mnt.appendingPathComponent("existing.txt"))

            // Wait for write-back to drain, observed through rclone itself.
            #expect(await eventually(.seconds(120)) { await h.pending() == 0 }, "uploads drained")
            _ = await m.pollOnce()

            // Verify on the server side.
            #expect(try sha256(serverFiles.appendingPathComponent("upload.bin")) == uploadHash, "SHA-256 of uploaded file matches")
            #expect(try String(contentsOf: serverFiles.appendingPathComponent("Ünïcødé 文件夹/файл ✓.txt"), encoding: .utf8) == "unicode")
            #expect(fm.fileExists(atPath: serverFiles.appendingPathComponent("after.txt").path))
            #expect(!fm.fileExists(atPath: serverFiles.appendingPathComponent("before.txt").path))
            #expect(fm.fileExists(atPath: serverFiles.appendingPathComponent("archive/note.txt").path))
            #expect(!fm.fileExists(atPath: serverFiles.appendingPathComponent("note.txt").path))
            #expect(!fm.fileExists(atPath: serverFiles.appendingPathComponent("existing.txt").path))

            // Transfer history built from rclone's own records.
            let up = m.transferHistory.first { $0.name == "upload.bin" && $0.status == .completed }
            #expect(up != nil, "upload recorded: \(m.transferHistory.map { "\($0.name):\($0.status)" })")
            #expect(up?.transferredBytes == Int64(64 << 20))
            #expect(up?.direction == .upload)

            // Cache stats are live from rclone.
            let cache = try #require(m.state("oracle").cache)
            #expect(cache.source == .liveProcess && cache.bytesUsed > 0)

            // File locks must work, or sandboxed apps like Preview refuse to open files ("no permission").
            let lockFD = open(mnt.appendingPathComponent("after.txt").path, O_RDONLY | O_SHLOCK | O_NONBLOCK)
            #expect(lockFD >= 0, "O_SHLOCK failed: \(String(cString: strerror(errno)))")
            if lockFD >= 0 { close(lockFD) }

            // Pending-write protection: a fresh write is held for write-back (3s); unmount must refuse.
            try Data("last minute".utf8).write(to: mnt.appendingPathComponent("pending.txt"))
            try await Task.sleep(for: .milliseconds(300))
            await m.unmount("oracle", waitForUploads: false)
            if case .pendingWrites(let n)? = m.state("oracle").lastError { #expect(n >= 1) } else { Issue.record("expected pendingWrites, got \(String(describing: m.state("oracle").lastError))") }
            #expect(m.state("oracle").phase == .mounted, "still mounted after refusal")
            #expect(MountTable.isMounted(h.mountPath))

            // 13. Safe unmount waits for the upload, then unmounts.
            await m.unmount("oracle", waitForUploads: true)
            #expect(m.state("oracle").phase == .unmounted)
            #expect(!MountTable.isMounted(h.mountPath))
            #expect(await !m.supervisor.isRunning("oracle"))
            #expect(try String(contentsOf: serverFiles.appendingPathComponent("pending.txt"), encoding: .utf8) == "last minute", "pending write was not lost")

            // Logs must not contain secrets.
            let log = (try? String(contentsOf: h.paths.logFile(for: "oracle"), encoding: .utf8)) ?? ""
            #expect(!log.contains("RCLONE_CONFIG_PASS="))
            let report = await m.diagnosticsReport()
            #expect(!report.contains(try #require(InMemorySecretStore().get(.rcloneConfigPassword) ?? "~never~")))
        }
    }

    @Test func speedLimitAndCloudListingThroughRunningProcess() async throws {
        try await withHarness(name: "ca") { h in
            try await h.connect()
            await h.manager.mount("oracle")
            let actions = try #require(h.manager.cloudActions("oracle"))
            try await actions.setBandwidth(megabytesPerSecond: 2)
            let limited = try await actions.rc.callJSON("core/bwlimit", [:])
            #expect((limited["rate"] as? String)?.hasPrefix("2") == true, "limit applied live: \(limited)")
            try await actions.setBandwidth(megabytesPerSecond: nil)
            let off = try await actions.rc.callJSON("core/bwlimit", [:])
            #expect((off["rate"] as? String) == "off")
            // Cloud-side copy within the same remote, through the running rclone (no Mac disk involved).
            // Write through the mount like a user would (the test SFTP server caches its own listings).
            let mnt = URL(fileURLWithPath: h.mountPath)
            try FileManager.default.createDirectory(at: mnt.appendingPathComponent("copies"), withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: mnt.appendingPathComponent("src.txt"))
            #expect(await eventually(.seconds(30)) { await h.pending() == 0 })
            var self2 = h.manager.drive("oracle")!
            self2.id = "oracle-copy"; self2.remotePath = "/files/copies"
            let job = try await actions.copy(relativePath: "src.txt", isDirectory: false, to: self2)
            #expect(job > 0, "async job started")
            #expect(await eventually(.seconds(20)) { FileManager.default.fileExists(atPath: h.server.data.appendingPathComponent("files/copies/src.txt").path) })
        }
    }

    /// Freezes rclone (SIGSTOP) to simulate a hang. The watchdog must decide to restart it; once the process
    /// can run again it exits, the dead volume is removed and a fresh rclone mounts the drive.
    @Test func watchdogRestartsHungProcess() async throws {
        try await withHarness(name: "wd") { h in
            try await h.connect()
            await h.manager.mount("oracle")
            let pid = try #require(h.manager.state("oracle").pid)
            kill(pid, SIGSTOP)
            let before = h.manager.watchdogRestarts
            for _ in 0..<(DriveManager.watchdogRestartAfter + 1) where h.manager.watchdogRestarts == before {
                _ = await h.manager.pollOnce()
            }
            #expect(h.manager.watchdogRestarts == before + 1, "watchdog decided to restart")
            kill(pid, SIGCONT)
            #expect(await eventually(.seconds(90), poll: .seconds(1)) {
                h.manager.state("oracle").phase == .mounted && h.manager.state("oracle").pid != pid
            }, "remounted with a new process: \(h.manager.state("oracle"))")
            #expect(MountTable.isMounted(h.mountPath))
            let reports = (try? FileManager.default.contentsOfDirectory(atPath: h.paths.logsDirectory.path))?.filter { $0.hasPrefix("crash-") } ?? []
            #expect(!reports.isEmpty, "crash report written")
        }
    }

    @Test func hostKeyMismatchIsRefusedAndNeverRetried() async throws {
        try await withHarness(name: "hk") { h in
            try await h.connect()
            guard case .connected = h.manager.state("oracle").connection else { Issue.record("setup failed"); return }

            // Replace the trusted key with a different one (simulates a changed / spoofed server).
            let other = h.root.appendingPathComponent("other_host")
            _ = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/ssh-keygen"), arguments: ["-q", "-t", "ed25519", "-N", "", "-f", other.path])
            let pub = try String(contentsOf: other.appendingPathExtension("pub"), encoding: .utf8)
            let line = "[127.0.0.1]:\(h.server.port) " + pub.split(separator: " ").prefix(2).joined(separator: " ")
            try HostKeyVerifier(knownHostsURL: h.paths.knownHostsURL).trust([HostKey(knownHostsLine: line, keyType: "ssh-ed25519", fingerprint: "x")],
                                                                            host: "127.0.0.1", port: h.server.port)

            await h.manager.testConnection("oracle")
            #expect(h.manager.state("oracle").connection == .failed(.hostKeyMismatch(host: "127.0.0.1")))

            await h.manager.mount("oracle")
            #expect(h.manager.state("oracle").phase == .failed, "security failures stop immediately")
            #expect(h.manager.state("oracle").lastError == .hostKeyMismatch(host: "Oracle Drive"))
            #expect(!MountTable.isMounted(h.mountPath))

            // Untrusted host: refuses before even launching rclone.
            try HostKeyVerifier(knownHostsURL: h.paths.knownHostsURL).forget(host: "127.0.0.1", port: h.server.port)
            await h.manager.mount("oracle")
            #expect(h.manager.state("oracle").lastError == .hostKeyUnknown(host: "127.0.0.1"))
        }
    }

    @Test func invalidKeyIsAuthenticationFailure() async throws {
        try await withHarness(name: "ak") { h in
            let keys = try await h.manager.scanOracleHostKeys(host: "127.0.0.1", port: h.server.port)
            try h.manager.trustOracleHostKeys(keys, host: "127.0.0.1", port: h.server.port)
            let wrong = h.root.appendingPathComponent("wrong_client")
            _ = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/ssh-keygen"), arguments: ["-q", "-t", "ed25519", "-N", "", "-f", wrong.path])
            var c = h.connection
            c.privateKeyPath = wrong.path
            await #expect(throws: DriveError.self) { try await h.manager.configureOracle(c, passphrase: nil, remoteDirectory: "/files") }
            if case .failed(.authenticationFailed) = h.manager.state("oracle").connection {} else {
                Issue.record("expected authenticationFailed, got \(h.manager.state("oracle").connection)")
            }
        }
    }

    @Test func uploadSurvivesServerOutageAndReconnects() async throws {
        try await withHarness(writeBack: 5, name: "ro") { h in
            try await h.connect()
            await h.manager.mount("oracle")
            #expect(h.manager.state("oracle").phase == .mounted)
            let mnt = URL(fileURLWithPath: h.mountPath)

            // 11/12. File written while the server is up; the server goes away before the (5 s delayed)
            // write-back upload runs. The data sits in the cache and rclone retries the upload.
            try writeRandom(mnt.appendingPathComponent("during-outage.bin"), bytes: 8 << 20)
            let hash = try sha256(mnt.appendingPathComponent("during-outage.bin"))
            h.server.stop()
            try await Task.sleep(for: .seconds(8))
            #expect(await h.pending() >= 1, "upload is pending while the server is down")
            #expect(h.manager.state("oracle").phase == .mounted, "the volume stays mounted during an outage")

            try h.server.start()
            let target = h.server.data.appendingPathComponent("files/during-outage.bin")
            #expect(await eventually(.seconds(150), poll: .seconds(1)) { await h.pending() == 0 && FileManager.default.fileExists(atPath: target.path) },
                    "upload completed after the server came back")
            #expect(try sha256(target) == hash, "content intact after interrupted upload")
        }
    }

    @Test func unreachableServerRetriesWithBackoff() async throws {
        try await withHarness(name: "rt") { h in
            try await h.connect()
            h.server.stop()
            await h.manager.mount("oracle")
            guard case .retrying(let attempt, _) = h.manager.state("oracle").phase else {
                Issue.record("expected retrying, got \(h.manager.state("oracle").phase) \(String(describing: h.manager.state("oracle").lastError))"); return
            }
            #expect(attempt >= 1 && attempt <= 2, "bounded retry started (attempt \(attempt))")
            if case .remoteUnavailable = h.manager.state("oracle").lastError {} else { Issue.record("expected remoteUnavailable") }

            // Server returns: the scheduled retry mounts it.
            try h.server.start()
            #expect(await eventually(.seconds(40)) { h.manager.state("oracle").phase == .mounted }, "reconnected by retry")
        }
    }

    @Test func twoIndependentMounts() async throws {
        try await withHarness(name: "mm") { h in
            try await h.connect()
            try FileManager.default.createDirectory(at: h.server.data.appendingPathComponent("second"), withIntermediateDirectories: true)
            let rclone = try #require(h.manager.rcloneService)
            let mm = MountManager(paths: h.paths, supervisor: h.manager.supervisor, rcloneURL: rclone.binary.url)
            var a = DriveConfiguration.oracleDefault
            a.id = "vol-a"; a.name = "Vol A"; a.remotePath = "/files"; a.mountPath = h.root.appendingPathComponent("mnt/A").path
            var b = a
            b.id = "vol-b"; b.name = "Vol B"; b.remotePath = "/second"; b.mountPath = h.root.appendingPathComponent("mnt/B").path
            for d in [a, b] {
                try await mm.mount(MountRequest(drive: d, engine: testEngine, mountPath: d.mountPath!, environment: try rclone.environment(), globals: MountGlobals()))
            }
            #expect(MountTable.isMounted(a.mountPath!) && MountTable.isMounted(b.mountPath!))
            #expect(await h.manager.supervisor.info(for: "vol-a")?.pid != h.manager.supervisor.info(for: "vol-b")?.pid, "separate processes")

            // Duplicate mount is refused.
            await #expect(throws: DriveError.self) {
                try await mm.mount(MountRequest(drive: a, engine: testEngine, mountPath: h.root.appendingPathComponent("mnt/A2").path, environment: try rclone.environment(), globals: MountGlobals()))
            }

            try Data("b".utf8).write(to: URL(fileURLWithPath: b.mountPath!).appendingPathComponent("b.txt"))
            try await mm.unmount(driveID: "vol-a", mountPath: a.mountPath!, waitForUploads: true)
            #expect(!MountTable.isMounted(a.mountPath!))
            #expect(MountTable.isMounted(b.mountPath!), "unmounting one volume leaves the other alone")
            #expect(try String(contentsOf: URL(fileURLWithPath: b.mountPath!).appendingPathComponent("b.txt"), encoding: .utf8) == "b")
            try await mm.unmount(driveID: "vol-b", mountPath: b.mountPath!, waitForUploads: true)
            #expect(FileManager.default.fileExists(atPath: h.server.data.appendingPathComponent("second/b.txt").path))
        }
    }

    @Test func occupiedMountPointIsRefused() async throws {
        try await withHarness(name: "oc") { h in
            try await h.connect()
            try FileManager.default.createDirectory(atPath: h.mountPath, withIntermediateDirectories: true)
            try Data("mine".utf8).write(to: URL(fileURLWithPath: h.mountPath).appendingPathComponent("user-file.txt"))
            await h.manager.mount("oracle")
            if case .mountPointOccupied = h.manager.state("oracle").lastError {} else { Issue.record("expected occupied, got \(String(describing: h.manager.state("oracle").lastError))") }
            #expect(h.manager.state("oracle").phase == .failed)
            #expect(FileManager.default.fileExists(atPath: h.mountPath + "/user-file.txt"), "user files untouched")
        }
    }

    @Test func ejectOutsideAppStopsProcessAfterUploads() async throws {
        try await withHarness(writeBack: 3, name: "ej") { h in
            try await h.connect()
            await h.manager.mount("oracle")
            #expect(h.manager.state("oracle").phase == .mounted)
            let pid = try #require(h.manager.state("oracle").pid)
            try Data("eject me".utf8).write(to: URL(fileURLWithPath: h.mountPath).appendingPathComponent("late.txt"))
            // Simulate Finder's Eject.
            let r = try await ProcessRunner().run(URL(fileURLWithPath: "/sbin/umount"), arguments: [h.mountPath], timeout: .seconds(20))
            #expect(r.exitCode == 0)
            _ = await h.manager.pollOnce()
            #expect(await eventually(.seconds(40)) { h.manager.state("oracle").phase == .unmounted }, "app notices the eject")
            #expect(await eventually(.seconds(10)) { !ProcessSupervisor.isAlive(pid) }, "no orphan rclone left serving")
            // rclone may stop as soon as the volume is ejected. A not-yet-uploaded file must then be kept in the
            // cache and uploaded on the next mount. Either way it must reach the server: no data loss.
            let target = h.server.data.appendingPathComponent("files/late.txt")
            if !FileManager.default.fileExists(atPath: target.path) {
                #expect(h.manager.cacheManager.diskStats("oracle").uploadsQueued >= 1, "kept in cache as a pending upload")
                await h.manager.mount("oracle")
                #expect(await eventually(.seconds(60)) { FileManager.default.fileExists(atPath: target.path) }, "uploaded on next mount")
            }
            #expect(try String(contentsOf: target, encoding: .utf8) == "eject me")
        }
    }

    @Test func relaunchAdoptsRunningMount() async throws {
        try await withHarness(name: "ad") { h in
            try await h.connect()
            await h.manager.mount("oracle")
            let pid = try #require(h.manager.state("oracle").pid)

            // A second app instance (as after a crash) must reattach instead of mounting twice.
            let db2 = try AppDatabase(url: h.paths.databaseURL)
            let m2 = DriveManager(paths: h.paths, secrets: h.manager.secrets, database: db2)
            await m2.start()
            #expect(m2.state("oracle").phase == .mounted)
            #expect(m2.state("oracle").pid == pid)
            #expect(m2.state("oracle").mountPath == h.mountPath, "reattached to the real mount path")
        _ = await m2.pollOnce()
        #expect(m2.state("oracle").phase == .mounted, "not mistaken for an eject after reattaching")
        let pending = await MountManager(paths: h.paths, supervisor: m2.supervisor, rcloneURL: URL(fileURLWithPath: rclonePath!)).pendingUploads("oracle")
            #expect(pending == 0)
            await m2.unmount("oracle", waitForUploads: true)
            #expect(!MountTable.isMounted(h.mountPath))
            #expect(await eventually(.seconds(10)) { !ProcessSupervisor.isAlive(pid) })
        }
    }
}

@Suite(.enabled(if: integrationEnabled))
struct RcloneServiceIntegrationTests {
    @Test func versionDetectionAndEncryptedConfig() async throws {
        let bin = try #require(await RcloneService.probe(URL(fileURLWithPath: rclonePath!)))
        #expect(bin.version.hasPrefix("v1."))
        #expect(bin.supportsNFSMount)
        let root = try makeRoot("rs")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(supportDirectory: root.appendingPathComponent("s"), cacheRoot: root.appendingPathComponent("c"), logsDirectory: root.appendingPathComponent("l"))
        try paths.prepare()
        let secrets = InMemorySecretStore()
        let svc = RcloneService(paths: paths, secrets: secrets, binary: bin)
        try await svc.ensureEncryptedConfig()
        try await svc.ensureEncryptedConfig() // idempotent
        try await svc.createRemote("loc", type: "local", options: [])
        #expect(try await svc.listRemotes() == ["loc"])
        #expect(try String(contentsOf: paths.rcloneConfigURL, encoding: .utf8).contains("RCLONE_ENCRYPT_V0:"))
        // Wrong password is a typed auth error, not a hang.
        try secrets.set("wrong", for: .rcloneConfigPassword)
        await #expect(throws: DriveError.self) { try await svc.listRemotes() }
    }

    func makeRoot(_ n: String) throws -> URL {
        let base = ProcessInfo.processInfo.environment["EKTHAR_TEST_ROOT"].map(URL.init(fileURLWithPath:)) ?? FileManager.default.temporaryDirectory
        let u = base.appendingPathComponent("\(n)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
