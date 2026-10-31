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

        let args = try MountCommandBuilder.arguments(drive: request.drive, engine: request.engine, mountPath: request.mountPath,
                                                     cacheDirectory: cacheDir.path, rcSocket: paths.rcSocket(for: id).path,
                                                     configPath: paths.rcloneConfigURL.path, globals: request.globals)
        let pid = try await supervisor.launch(driveID: id, executable: rcloneURL, arguments: args, environment: request.environment)

        let deadline = ContinuousClock.now + readyTimeout
        let client = rc(id)
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
        if !(await supervisor.waitForExit(driveID, timeout: .seconds(15))) {
            await supervisor.terminate(driveID)
            _ = await supervisor.waitForExit(driveID, timeout: .seconds(20))
        }
        try? FileManager.default.removeItem(at: paths.rcSocket(for: driveID))
        logger.notice("Unmounted \(driveID)")
    }
}
