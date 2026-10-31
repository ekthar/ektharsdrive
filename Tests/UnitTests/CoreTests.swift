import Foundation
import Testing
@testable import EktharDriveCore

@Suite struct ConfigurationTests {
    @Test func defaultsAreValid() throws {
        try DriveConfiguration.googleDefault.validate()
        try DriveConfiguration.oracleDefault.validate()
        #expect(DriveConfiguration.googleDefault.remoteSpec == "gdrive:")
        #expect(DriveConfiguration.oracleDefault.remoteSpec == "oracle:/srv/ekthar-drive/files")
        #expect(DriveConfiguration.googleDefault.cache.maxSizeBytes == 8 * .gibibyte)
        #expect(DriveConfiguration.oracleDefault.cache.bufferSizeMB == 16)
    }

    @Test(arguments: ["", "a/b", "x:y", ".hidden", String(repeating: "n", count: 65)])
    func rejectsBadNames(_ name: String) {
        var d = DriveConfiguration.googleDefault
        d.name = name
        #expect(throws: DriveError.self) { try d.validate() }
    }

    @Test(arguments: ["relative/path", "/", "/Volumes", "/System", "/Users/../etc"])
    func rejectsDangerousMountPaths(_ path: String) {
        var d = DriveConfiguration.googleDefault
        d.mountPath = path
        #expect(throws: DriveError.self) { try d.validate() }
    }

    @Test func rejectsTraversalAndRelativeOracleDir() {
        var d = DriveConfiguration.oracleDefault
        d.remotePath = "srv/files"
        #expect(throws: DriveError.self) { try d.validate() }
        d.remotePath = "/srv/../etc"
        #expect(throws: DriveError.self) { try d.validate() }
    }

    @Test func rejectsTinyCache() {
        var d = DriveConfiguration.googleDefault
        d.cache.maxSizeBytes = 10 * .mebibyte
        #expect(throws: DriveError.self) { try d.validate() }
    }

    @Test func sftpRejectsRootAndBadHost() throws {
        let key = FileManager.default.temporaryDirectory.appendingPathComponent("k-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: key.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: key) }
        #expect(throws: DriveError.self) { try SFTPConnection(host: "1.2.3.4", username: "root", privateKeyPath: key.path).validate() }
        #expect(throws: DriveError.self) { try SFTPConnection(host: "bad host;rm", username: "ekthar", privateKeyPath: key.path).validate() }
        #expect(throws: DriveError.self) { try SFTPConnection(host: "1.2.3.4", port: 0, username: "ekthar", privateKeyPath: key.path).validate() }
        #expect(throws: DriveError.self) { try SFTPConnection(host: "1.2.3.4", username: "ekthar", privateKeyPath: "/nope/key").validate() }
        try SFTPConnection(host: "vm.example.com", username: "ekthar-drive", privateKeyPath: key.path).validate()
        try SFTPConnection(host: "129.146.10.2", port: 2222, username: "ekthar", privateKeyPath: key.path).validate()
    }
}

@Suite struct MountCommandTests {
    let common = (cache: "/c", socket: "/r/g.sock", config: "/s/rclone.conf")

    func args(_ d: DriveConfiguration, _ e: MountEngine, globals: MountGlobals = MountGlobals()) throws -> [String] {
        try MountCommandBuilder.arguments(drive: d, engine: e, mountPath: "/Volumes/\(d.name)", cacheDirectory: common.cache,
                                          rcSocket: common.socket, configPath: common.config, globals: globals, nfsPort: 47000)
    }

    func value(_ args: [String], _ flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }

    @Test func googleFUSEArguments() throws {
        let a = try args(.googleDefault, .macFUSE)
        #expect(Array(a.prefix(3)) == ["mount", "gdrive:", "/Volumes/Google Drive"])
        #expect(value(a, "--vfs-cache-mode") == "full")
        #expect(value(a, "--vfs-cache-max-size") == "8G")
        #expect(value(a, "--vfs-cache-max-age") == "168h")
        #expect(value(a, "--buffer-size") == "32M")
        #expect(value(a, "--dir-cache-time") == "1440m")
        #expect(value(a, "--poll-interval") == "1m")
        #expect(value(a, "--vfs-write-back") == "5s")
        #expect(value(a, "--vfs-cache-min-free-space") == "5G")
        #expect(value(a, "--rc-addr") == "unix:///r/g.sock")
        #expect(a.contains("--rc-no-auth"))
        #expect(a.contains("--noappledouble"))
        #expect(value(a, "--volname") == "Google Drive")
    }

    @Test func speedTuning() throws {
        let g = try args(.googleDefault, .nfs)
        #expect(value(g, "--vfs-read-chunk-size") == "8M")
        #expect(value(g, "--vfs-read-chunk-size-limit") == "256M")
        #expect(value(try args(.googleDefault, .macFUSE), "--attr-timeout") == "5s")
        #expect(value(g, "--dir-cache-time") == "1440m", "Google keeps listings; polling catches changes")
        #expect(value(try args(.oracleDefault, .nfs), "--dir-cache-time") == "5m", "SFTP has no change feed")
    }

    @Test func fskitBackendOnlyForMacFUSE() throws {
        let fs = try args(.googleDefault, .macFUSE, globals: MountGlobals(macFUSEUsesFSKit: true))
        #expect(value(fs, "-o") == "backend=fskit")
        let kext = try args(.googleDefault, .macFUSE, globals: MountGlobals(macFUSEUsesFSKit: false))
        #expect(!kext.contains("backend=fskit"))
        let nfs = try args(.oracleDefault, .nfs, globals: MountGlobals(macFUSEUsesFSKit: true))
        #expect(!nfs.contains("-o"))
        #expect(value(nfs, "--nfs-cache-type") == "disk")
        #expect(value(nfs, "--nfs-cache-dir") == "/c/nfs-handles")
        #expect(!fs.contains("--nfs-cache-type"), "NFS-only flag")
    }

    @Test func classifiesMacFUSEExtensionErrors() {
        if case .dependencyMissing(.macFUSE, let d) = ErrorClassifier.classify(output: ["MFMount: MFMount(_:_:_:_:): File system extension not enabled"]) {
            #expect(d.contains("File System Extensions"))
        } else { Issue.record("expected macFUSE extension error") }
        if case .dependencyMissing(.macFUSE, _) = ErrorClassifier.classify(output: ["fuse: failed to exec mount program: Operation not permitted"]) {} else { Issue.record("expected macFUSE helper error") }
        // Real line from the app's google.log on this Mac:
        let real = #"{"level":"critical","msg":"Fatal error: failed to mount FUSE fs: failed to retrieve mount path information: stat /Volumes/Google Drive: no such file or directory"}"#
        let e = ErrorClassifier.classify(output: [real], exitCode: 1)
        if case .dependencyMissing(.macFUSE, _) = e { #expect(!e.isRetryable, "must not start a retry loop") } else { Issue.record("expected macFUSE error, got \(e)") }
    }

    @Test func oracleNFSArguments() throws {
        let a = try args(.oracleDefault, .nfs)
        #expect(Array(a.prefix(5)) == ["serve", "nfs", "oracle:/srv/ekthar-drive/files", "--addr", "127.0.0.1:47000"], "loopback only")
        #expect(throws: DriveError.self) {
            try MountCommandBuilder.arguments(drive: .oracleDefault, engine: .nfs, mountPath: "/m", cacheDirectory: "/c",
                                              rcSocket: "/s", configPath: "/k", globals: MountGlobals(), nfsPort: nil)
        }
        let opts = MountCommandBuilder.nfsMountOptions(port: 47000)
        for o in ["locallocks", "nfc", "tcp", "vers=3", "rsize=1048576", "port=47000", "mountport=47000"] {
            #expect(opts.split(separator: ",").contains(Substring(o)), "missing \(o)")
        }
        #expect(MountCommandBuilder.nfsMountArguments(port: 47000, mountPath: "/m").suffix(2) == ["localhost:/", "/m"])
        let port = try #require(MountCommandBuilder.freeLocalPort())
        #expect(port >= 1024)
        #expect(value(a, "--vfs-cache-max-size") == "4G")
        #expect(value(a, "--buffer-size") == "16M")
        #expect(!a.contains("--poll-interval"), "SFTP has no change notifications")
        #expect(!a.contains("--noappledouble"), "FUSE-only flag")
    }

    @Test func noSecretsOrShellInArguments() throws {
        let a = try args(.googleDefault, .macFUSE)
        for arg in a {
            #expect(!arg.lowercased().contains("pass") || arg == "--password-command" ? true : !arg.contains("="))
            #expect(!arg.contains("RCLONE_CONFIG_PASS"))
        }
        #expect(!a.contains("--rc-pass") && !a.contains("--rc-user"))
        #expect(!a.contains("--rc-addr") || !(value(a, "--rc-addr") ?? "").contains(":5572"), "no TCP control port")
    }

    @Test func refusesUnresolvedEngineAndBadLogLevel() {
        #expect(throws: DriveError.self) { try args(.googleDefault, .automatic) }
        #expect(throws: DriveError.self) { try args(.googleDefault, .nfs, globals: MountGlobals(logLevel: "TRACE; rm")) }
    }

    @Test func defaultMountPaths() {
        let home = URL(fileURLWithPath: "/Users/test")
        #expect(MountPathResolver.path(for: .googleDefault, engine: .macFUSE, home: home) == "/Users/test/Volumes/Google Drive")
        #expect(MountPathResolver.path(for: .oracleDefault, engine: .nfs, home: home) == "/Users/test/Volumes/Oracle Drive")
        var d = DriveConfiguration.oracleDefault
        d.mountPath = "/Users/test/Mounts/O"
        #expect(MountPathResolver.path(for: d, engine: .macFUSE, home: home) == "/Users/test/Mounts/O")
    }

    @Test func rcloneSizes() {
        #expect(ByteFormat.rcloneSize(8 * .gibibyte) == "8G")
        #expect(ByteFormat.rcloneSize(512 * .mebibyte) == "512M")
        #expect(ByteFormat.rcloneSize(1500) == "1500B")
    }
}

@Suite struct RetryAndErrorTests {
    @Test func boundedBackoff() {
        let p = RetryPolicy.standard
        #expect(p.delay(forAttempt: 1) == .seconds(2))
        #expect(p.delay(forAttempt: 2) == .seconds(5))
        #expect(p.delay(forAttempt: 3) == .seconds(15))
        #expect(p.delay(forAttempt: 4) == .seconds(30))
        #expect(p.delay(forAttempt: 5) == .seconds(60))
        #expect(p.delay(forAttempt: 6) == nil, "stops after five attempts")
        #expect(p.delay(forAttempt: 3, maxAttempts: 2) == nil)
        #expect(p.delay(forAttempt: 0) == nil)
    }

    @Test func classifiesRealRcloneOutput() {
        let mismatch = "2026/10/31 11:43:50 CRITICAL: Failed to create file system for \"oracle:\": NewFs: couldn't connect SSH: ssh: handshake failed: knownhosts: key mismatch"
        #expect(ErrorClassifier.classify(output: [mismatch], host: "vm") == .hostKeyMismatch(host: "vm"))
        #expect(ErrorClassifier.classify(output: ["ssh: handshake failed: knownhosts: key is unknown"], host: "vm") == .hostKeyUnknown(host: "vm"))
        if case .authenticationFailed = ErrorClassifier.classify(output: [#"{"level":"error","msg":"couldn't fetch token: invalid_grant: maybe token expired?"}"#]) {} else { Issue.record("expected auth failure") }
        if case .authenticationFailed = ErrorClassifier.classify(output: ["ssh: handshake failed: ssh: unable to authenticate, attempted methods [none publickey]"]) {} else { Issue.record("expected auth failure") }
        if case .remoteUnavailable = ErrorClassifier.classify(output: ["dial tcp 10.0.0.1:22: connect: connection refused"]) {} else { Issue.record("expected remote unavailable") }
        #expect(ErrorClassifier.classify(output: ["dial tcp: lookup x: network is unreachable"]) == .networkUnavailable)
        if case .localDiskFull = ErrorClassifier.classify(output: ["write /c/vfs/x: no space left on device"]) {} else { Issue.record("expected disk full") }
        if case .dependencyMissing(.macFUSE, _) = ErrorClassifier.classify(output: ["mount helper error: mount_macfuse: the file system is not available"]) {} else { Issue.record("expected macFUSE") }
        if case .processExited(let code, _) = ErrorClassifier.classify(output: ["something odd"], exitCode: 3) { #expect(code == 3) } else { Issue.record("expected processExited") }
    }

    @Test func explainsGoogleAPIErrors() {
        let disabled = """
        Failed to about: googleapi: got HTTP response code 403 with body: {
          "error": {
            "code": 403,
            "message": "Google Drive API has not been used in project 123456789012 before or it is disabled.",
            "details": [ { "@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "SERVICE_DISABLED" } ]
          }
        }
        """
        let e = ErrorClassifier.classify(output: disabled.components(separatedBy: "\n"), exitCode: 1)
        if case .authenticationFailed(let d) = e {
            #expect(d.contains("turned off") && d.contains("project=123456789012"), "\(d)")
        } else { Issue.record("got \(e)") }

        let scope = #"googleapi: Error 403: Request had insufficient authentication scopes., insufficientPermissions"#
        if case .authenticationFailed(let d) = ErrorClassifier.classify(output: [scope]) { #expect(d.contains("auth/drive")) } else { Issue.record("scope") }

        let other = #"googleapi: Error 404: File not found: abc., notFound"#
        if case .remoteUnavailable(let d) = ErrorClassifier.classify(output: [other]) { #expect(d.contains("File not found")) } else { Issue.record("other") }
    }

    @Test func securityErrorsNeverAutoRetry() {
        #expect(!DriveError.hostKeyMismatch(host: "h").isRetryable)
        #expect(!DriveError.authenticationFailed("x").isRetryable)
        #expect(!DriveError.invalidConfiguration("x").isRetryable)
        #expect(!DriveError.pendingWrites(count: 1).isRetryable)
        #expect(DriveError.remoteUnavailable("x").isRetryable)
        #expect(DriveError.processExited(code: 1, detail: "").isRetryable)
    }

    @Test func distinctCategories() {
        #expect(DriveError.networkUnavailable.category == .disconnected)
        #expect(DriveError.authenticationFailed("").category == .authentication)
        #expect(DriveError.mountPointOccupied(path: "", by: "").category == .mount)
        #expect(DriveError.remoteUnavailable("").category == .remoteStorage)
        #expect(DriveError.localDiskFull(freeBytes: 0).category == .localDisk)
        #expect(DriveError.pendingWrites(count: 2).category == .pendingWrite)
        #expect(DriveError.processExited(code: 1, detail: "").category == .degraded)
    }

    @Test func parsesLogLines() {
        let j = LogLine.parse(#"{"time":"x","level":"error","msg":"upload failed","object":"a.txt"}"#)
        #expect(j.level == "error" && j.message == "upload failed" && j.object == "a.txt")
        let t = LogLine.parse("2026/10/31 11:39:33 NOTICE: NFS Server running at 127.0.0.1:63946")
        #expect(t.level == "notice" && t.message == "NFS Server running at 127.0.0.1:63946")
    }
}

@Suite struct RedactionTests {
    @Test func redactsSecrets() {
        let samples = [
            #"token = {"access_token":"ya29.a0AfH6SMBxyz","token_type":"Bearer","refresh_token":"1//0gSECRETSECRETSECRETSECRET","expiry":"2026"}"#,
            "client_secret = GOCSPX-abcdefSECRET",
            "RCLONE_CONFIG_PASS=hunter2 rclone mount",
            "--sftp-key-file-pass hunter2",
            "Authorization: Bearer ya29.zzzz",
            "http://127.0.0.1:53682/auth?state=abcdef123&code=4/0Asecret",
            "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAA\n-----END OPENSSH PRIVATE KEY-----",
            #"{"pass":"obscuredvalue"}"#,
        ]
        let secrets = ["ya29.a0AfH6SMBxyz", "1//0gSECRETSECRETSECRETSECRET", "GOCSPX-abcdefSECRET", "hunter2", "ya29.zzzz",
                       "abcdef123", "4/0Asecret", "b3BlbnNzaC1rZXktdjEAAAA", "obscuredvalue"]
        for s in samples {
            let r = Redactor.redact(s)
            for secret in secrets { #expect(!r.contains(secret), "leaked \(secret) in \(r)") }
        }
    }

    @Test func leavesOrdinaryTextAlone() {
        let line = "Uploaded project.zip (24 MiB) to oracle:/srv/ekthar-drive/files"
        #expect(Redactor.redact(line) == line)
    }
}

@Suite struct ModelTests {
    @Test func usageFraction() {
        #expect(StorageUsage(total: 200, used: 50, free: 150).usedFraction == 0.25)
        #expect(StorageUsage(total: nil, used: 50, free: nil).usedFraction == nil)
        #expect(StorageUsage(total: 0, used: 0, free: 0).usedFraction == nil)
    }

    @Test func healthDerivation() {
        var rt = DriveRuntime()
        #expect(rt.health == .inactive)
        rt.phase = .mounted
        #expect(rt.health == .healthy)
        rt.cache = CacheStats(bytesUsed: 0, files: 0, erroredFiles: 1, source: .liveProcess)
        #expect(rt.health == .degraded)
        rt.phase = .failed
        #expect(rt.health == .error)
        rt.phase = .retrying(attempt: 1, at: Date())
        rt.cache = nil
        #expect(rt.health == .degraded)
    }

    @Test func dependencyResolution() throws {
        let fuseRclone = RcloneBinary(url: URL(fileURLWithPath: "/x"), version: "v1.75.2", supportsFUSEMount: true, supportsNFSMount: true)
        let brewRclone = RcloneBinary(url: URL(fileURLWithPath: "/x"), version: "v1.75.2", supportsFUSEMount: false, supportsNFSMount: true)
        var r = DependencyReport(rclone: fuseRclone, macFUSEVersion: "5.0", libfuseInstalled: true, nfsClientAvailable: true, checkedAt: Date())
        #expect(try r.resolve(.automatic) == .macFUSE)
        r.macFUSEVersion = nil
        #expect(try r.resolve(.automatic) == .nfs)
        #expect(throws: DriveError.self) { try r.resolve(.macFUSE) }
        r.rclone = brewRclone
        r.macFUSEVersion = "5.0"
        #expect(try r.resolve(.automatic) == .nfs, "Homebrew rclone cannot use macFUSE")
        r.rclone = nil
        #expect(throws: DriveError.self) { try r.resolve(.automatic) }
        #expect(RcloneService.compare("v1.65.0", atLeast: (1, 65)))
        #expect(!RcloneService.compare("v1.64.2", atLeast: (1, 65)))
        #expect(RcloneService.compare("v2.0.0-beta", atLeast: (1, 65)))
    }

    @Test func settingsDecodeIsForwardCompatible() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"theme":"dark"}"#.utf8))
        #expect(s.theme == .dark && s.minFreeSpaceGB == 5 && s.mountEngine == .automatic)
    }
}

@Suite struct UnixHTTPTests {
    @Test func parsesContentLengthAndChunkedReplies() throws {
        let plain = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)
        #expect(try UnixHTTP.parse(plain, path: "/x") == Data("{}".utf8))
        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n".utf8)
        #expect(try UnixHTTP.parse(chunked, path: "/x") == Data(#"{"a":1}"#.utf8))
        let failure = Data("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 17\r\n\r\n{\"error\":\"boom\"}\n".utf8)
        #expect(throws: DriveError.self) { try UnixHTTP.parse(failure, path: "/x") }
    }

    @Test func unreachableSocketIsTypedError() async {
        let rc = RcClient(socketPath: "/nonexistent/\(UUID().uuidString).sock", timeoutSeconds: 1)
        #expect(await rc.isResponsive() == false)
        await #expect(throws: DriveError.self) { try await rc.vfsStats() }
    }
}
