import Foundation

public struct MountRequest: Sendable {
    public var drive: DriveConfiguration
    public var engine: MountEngine
    public var mountPath: String
    public var environment: [String: String]
    public var globals: MountGlobals

    public init(drive: DriveConfiguration, engine: MountEngine, mountPath: String, environment: [String: String], globals: MountGlobals) {
        self.drive = drive
        self.engine = engine
        self.mountPath = mountPath
        self.environment = environment
        self.globals = globals
    }
}

public enum PreflightResult: Sendable, Equatable {
    case ready
    /// Our own rclone is already serving this mount point (e.g. adopted after an app restart).
    case alreadyMountedByUs
}

/// Starts and stops one drive's mount. Holds no state of its own; process ownership is in `ProcessSupervisor`.
public struct MountManager: Sendable {
    public let paths: AppPaths
    public let supervisor: ProcessSupervisor
    public let rcloneURL: URL
    private let runner = ProcessRunner()
    private let logger = AppLogger(category: "mount")

    public init(paths: AppPaths, supervisor: ProcessSupervisor, rcloneURL: URL) {
        self.paths = paths
        self.supervisor = supervisor
        self.rcloneURL = rcloneURL
    }

    public func rc(_ driveID: String) -> RcClient { RcClient(socketPath: paths.rcSocket(for: driveID).path) }

    public func preflight(driveID: String, mountPath: String, engine: MountEngine) async throws(DriveError) -> PreflightResult {
        if let entry = MountTable.entry(at: mountPath) {
            if await supervisor.isRunning(driveID), await rc(driveID).isResponsive() { return .alreadyMountedByUs }
            // Our own NFS volume whose rclone server is gone: it is dead (no data can flow), so remove it.
            if entry.fsType == "nfs", entry.source.hasPrefix("localhost:"), !(await supervisor.isRunning(driveID)) {
                await removeStaleNFSMount(mountPath)
                if !MountTable.isMounted(mountPath) { return try await preflight(driveID: driveID, mountPath: mountPath, engine: engine) }
            }
            throw .mountPointOccupied(path: mountPath, by: "\(entry.source) (\(entry.fsType))")
        }
        if await supervisor.isRunning(driveID) { throw .alreadyRunning }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: mountPath, isDirectory: &isDir) {
            guard isDir.boolValue else { throw .mountPointOccupied(path: mountPath, by: "a file") }
            let contents = (try? fm.contentsOfDirectory(atPath: mountPath))?.filter { $0 != ".DS_Store" } ?? []
            guard contents.isEmpty else {
                throw .mountPointOccupied(path: mountPath, by: "a folder that already contains files (mounting would hide them)")
            }
        } else if engine == .nfs || !mountPath.hasPrefix("/Volumes/") {
            // macFUSE creates /Volumes/<name> itself; anywhere else we create the empty mount point.
            do {
                try fm.createDirectory(atPath: mountPath, withIntermediateDirectories: true)
            } catch {
                throw .permissionDenied("Could not create mount point \(mountPath): \(error.localizedDescription)")
            }
        }
        return .ready
    }

    /// Launches rclone and waits until the kernel reports the mount and the control socket answers.
    @discardableResult
    public func mount(_ request: MountRequest, readyTimeout: Duration = .seconds(45)) async throws(DriveError) -> Int32 {
        let id = request.drive.id
        switch try await preflight(driveID: id, mountPath: request.mountPath, engine: request.engine) {
        case .alreadyMountedByUs: return await supervisor.info(for: id)?.pid ?? 0
        case .ready: break
        }
        let cacheDir = paths.cacheDirectory(for: id)
        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try FilePermissions.set(cacheDir.path, mode: 0o700)
        } catch {
            throw .permissionDenied("Could not prepare cache directory \(cacheDir.path).")
        }
        try? FileManager.default.removeItem(at: paths.rcSocket(for: id))

        var nfsPort: Int?
        if request.engine == .nfs {
            guard let port = MountCommandBuilder.freeLocalPort() else { throw .mountFailed("No free local port for the NFS server.") }
            nfsPort = port
        }
        let args = try MountCommandBuilder.arguments(drive: request.drive, engine: request.engine, mountPath: request.mountPath,
                                                     cacheDirectory: cacheDir.path, rcSocket: paths.rcSocket(for: id).path,
                                                     configPath: paths.rcloneConfigURL.path, globals: request.globals, nfsPort: nfsPort)
        let pid = try await supervisor.launch(driveID: id, executable: rcloneURL, arguments: args, environment: request.environment)

        let deadline = ContinuousClock.now + readyTimeout
        let client = rc(id)
        if let nfsPort {
            try await mountNFS(driveID: id, port: nfsPort, mountPath: request.mountPath, driveName: request.drive.name, deadline: deadline)
        }
        while ContinuousClock.now < deadline {
            if !(await supervisor.isRunning(id)) {
                let lines = await supervisor.recentOutput(for: id)
                throw ErrorClassifier.classify(output: lines, exitCode: 1, host: request.drive.name)
            }
            if MountTable.isMounted(request.mountPath), await client.isResponsive() {
                logger.notice("Mounted \(id) at \(request.mountPath) via \(request.engine.rawValue)")
                return pid
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        let lines = await supervisor.recentOutput(for: id)
        await supervisor.terminate(id)
        _ = await supervisor.waitForExit(id, timeout: .seconds(10))
        let cause = ErrorClassifier.classify(output: lines, host: request.drive.name)
        if case .unknown = cause { throw .timeout("The volume did not appear within \(readyTimeout). The remote may be slow or unreachable.") }
        throw cause
    }

    /// Waits for rclone's NFS server to answer, then mounts it with tuned options. Stops the server on failure.
    private func mountNFS(driveID id: String, port: Int, mountPath: String, driveName: String, deadline: ContinuousClock.Instant) async throws(DriveError) {
        let client = rc(id)
        while ContinuousClock.now < deadline {
            if !(await supervisor.isRunning(id)) {
                throw ErrorClassifier.classify(output: await supervisor.recentOutput(for: id), exitCode: 1, host: driveName)
            }
            if await client.isResponsive(), Self.portOpen(port) { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let r = try? await runner.run(URL(fileURLWithPath: "/sbin/mount_nfs"),
                                      arguments: MountCommandBuilder.nfsMountArguments(port: port, mountPath: mountPath),
                                      timeout: .seconds(30))
        guard let r, r.exitCode == 0, MountTable.isMounted(mountPath) else {
            await supervisor.terminate(id)
            _ = await supervisor.waitForExit(id, timeout: .seconds(10))
            let detail = r.map { ($0.stderr + $0.stdout).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "mount_nfs did not run"
            throw .mountFailed("macOS could not mount the volume: \(Redactor.redact(detail))")
        }
    }

    /// Unmounts an NFS volume left behind after its rclone server stopped. Only ever called for our own
    /// `localhost:` mounts whose server is not running, so nothing pending can be lost.
    public func removeStaleNFSMount(_ mountPath: String) async {
        guard let e = MountTable.entry(at: mountPath), e.fsType == "nfs", e.source.hasPrefix("localhost:") else { return }
        _ = try? await runner.run(URL(fileURLWithPath: "/sbin/umount"), arguments: ["-f", mountPath], timeout: .seconds(20))
        logger.notice("Removed stale NFS mount at \(mountPath)")
    }

    static func portOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    public func pendingUploads(_ driveID: String) async -> Int? {
        guard let s = try? await rc(driveID).vfsStats(), let d = s.diskCache else { return nil }
        return d.uploadsInProgress + d.uploadsQueued
    }

    /// Safe unmount:
    /// 1. ask rclone how many uploads are pending; refuse if any and `waitForUploads` is false;
    /// 2. otherwise wait (cancelling the wait never cancels uploads);
    /// 3. `umount` the volume (refused by the kernel if files are open: reported as busy, never forced);
    /// 4. let rclone exit on its own; SIGTERM only if it lingers; never SIGKILL.
    public func unmount(driveID: String, mountPath: String, waitForUploads: Bool,
                        progress: (@Sendable (Int) -> Void)? = nil) async throws(DriveError) {
        if await supervisor.isRunning(driveID) {
            if let pending = await pendingUploads(driveID), pending > 0 {
                guard waitForUploads else { throw .pendingWrites(count: pending) }
                var remaining = pending
                while remaining > 0 {
                    progress?(remaining)
                    if Task.isCancelled { throw .pendingWrites(count: remaining) }
                    try? await Task.sleep(for: .seconds(2))
                    guard await supervisor.isRunning(driveID) else { break }
                    remaining = await pendingUploads(driveID) ?? remaining
                }
            } else if await pendingUploads(driveID) == nil, await supervisor.isRunning(driveID) {
                // Process alive but not answering: we cannot prove there are no pending writes.
                if !waitForUploads { throw .rcUnavailable("Ekthar Drive cannot confirm whether uploads are pending, so it will not unmount yet. Try again, or use Wait for Uploads.") }
            }
        }

        if MountTable.isMounted(mountPath) {
            let r = try? await runner.run(URL(fileURLWithPath: "/sbin/umount"), arguments: [mountPath], timeout: .seconds(30))
            if let r, r.exitCode != 0 {
                let text = (r.stderr + r.stdout).lowercased()
                if text.contains("busy") { throw .mountPointBusy(path: mountPath) }
                if MountTable.isMounted(mountPath) {
                    throw .mountFailed("Could not unmount \(mountPath): \(Redactor.redact(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))")
                }
            }
        }
        // The volume is gone and uploads are done. rclone's NFS server does not exit by itself when its
        // mount disappears, so ask it to stop now (SIGTERM; FUSE rclone is already exiting).
        if !MountTable.isMounted(mountPath), await supervisor.isRunning(driveID) {
            await supervisor.terminate(driveID)
        }
        if !(await supervisor.waitForExit(driveID, timeout: .seconds(15))) {
            await supervisor.terminate(driveID)
            _ = await supervisor.waitForExit(driveID, timeout: .seconds(20))
        }
        try? FileManager.default.removeItem(at: paths.rcSocket(for: driveID))
        logger.notice("Unmounted \(driveID)")
    }
}
