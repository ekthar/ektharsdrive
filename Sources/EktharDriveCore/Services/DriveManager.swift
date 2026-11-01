import Foundation
import Observation

/// What the app should do when the user quits.
public enum TerminationCheck: Sendable, Equatable {
    case safe
    case pendingUploads(Int)
}

/// The single source of truth for drive state. Lives on the main actor so SwiftUI can observe it directly;
/// all blocking or slow work happens in actors/child processes it awaits.
@MainActor
@Observable
public final class DriveManager {
    // MARK: Observable state
    public private(set) var drives: [DriveConfiguration] = []
    public private(set) var runtime: [String: DriveRuntime] = [:]
    public private(set) var activeTransfers: [String: [Transfer]] = [:]
    public private(set) var transferHistory: [Transfer] = []
    public private(set) var recentActivity: [ActivityEvent] = []
    public private(set) var dependencies: DependencyReport?
    public private(set) var settings = AppSettings()
    public private(set) var diskWarning: DiskWarning?
    public private(set) var isOnline = true
    public private(set) var sftpConnection: SFTPConnection?
    public private(set) var startupError: String?
    public private(set) var lastCacheClear: [String: Date] = [:]
    /// Folders kept on this Mac, and how far each one is.
    public private(set) var offlinePins: [OfflinePin] = []
    public private(set) var pinStatus: [String: PinStatus] = [:]
    @ObservationIgnored private var pinTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastPinSync: [String: Date] = [:]
    static let pinsKey = "offline.pins"
    /// Uploads the user paused, by drive, by path. Kept across remounts and app restarts.
    public private(set) var heldUploads: [String: Set<String>] = [:]
    static let heldUploadsKey = "uploads.held"
    /// Saved searches shown in the sidebar.
    public private(set) var smartFolders: [SmartFolder] = []
    static let smartFoldersKey = "smart.folders"

    // MARK: Dependencies
    public let paths: AppPaths
    public let secrets: SecretStore
    public let supervisor: ProcessSupervisor
    public let database: AppDatabase
    public let cacheManager: CacheManager
    private let notifier: Notifier
    private let network = NetworkMonitor()
    private let logger = AppLogger(category: "drives")

    @ObservationIgnored private var trackers: [String: TransferTracker] = [:]
    @ObservationIgnored private var desiredMounted: Set<String> = []
    @ObservationIgnored private var stopping: Set<String> = []
    @ObservationIgnored private var retryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var unmountTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var lastUsageRefresh: [String: Date] = [:]
    /// rclone recomputes `bytesUsed` only on its cache-poll interval (1 min), so it lags behind writes.
    /// We also measure the cache directory on disk, at most every 30 s, and show the larger real value.
    @ObservationIgnored private var diskMeasure: [String: (bytes: Int64, at: Date)] = [:]
    @ObservationIgnored private var lastLoggedError: [String: (String, Date)] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var mountingNow: Set<String> = []
    /// Set when rclone.conf could not be read at startup; auto-mount retries once this clears.
    public private(set) var configReadError: DriveError?
    @ObservationIgnored private var pollFailures: [String: Int] = [:]
    @ObservationIgnored private var probeFailures: [String: Int] = [:]
    @ObservationIgnored private var lastProbe: [String: Date] = [:]
    @ObservationIgnored private let sleepGuard = UploadSleepGuard()
    @ObservationIgnored private var lastDiskWarningLevel: DiskWarning.Level?
    /// Watchdog: restart rclone after this many failed checks in a row (rc ~15 s apart, volume probes 30 s apart).
    static let watchdogRestartAfter = 4
    public private(set) var watchdogRestarts = 0
    @ObservationIgnored private var watchdogStopping: Set<String> = []
    static let pollFailuresBeforeError = 3
    /// Set once macFUSE fails to mount in Automatic mode; later mounts this session go straight to NFS.
    @ObservationIgnored private var macFUSEUnusable = false

    public init(paths: AppPaths, secrets: SecretStore, database: AppDatabase, notifier: Notifier = NullNotifier()) {
        self.paths = paths
        self.secrets = secrets
        self.database = database
        self.notifier = notifier
        self.supervisor = ProcessSupervisor(paths: paths)
        self.cacheManager = CacheManager(paths: paths)
    }

    // MARK: Accessors

    public func drive(_ id: String) -> DriveConfiguration? { drives.first { $0.id == id } }

    /// The engine a mount would really use now, including the NFS fallback after a macFUSE failure.
    public var effectiveEngine: MountEngine? {
        guard let deps = dependencies, let resolved = try? deps.resolve(settings.mountEngine) else { return nil }
        return settings.mountEngine == .automatic && macFUSEUnusable && deps.nfsUsable ? .nfs : resolved
    }

    /// Where the drive is (or would be) mounted. Used by the UI so it never shows a path that will not be used.
    public func mountLocation(_ id: String) -> String? {
        guard let d = drive(id) else { return nil }
        if let p = state(id).mountPath, state(id).phase.isActive { return p }
        return MountPathResolver.path(for: d, engine: effectiveEngine ?? .nfs)
    }
    public func state(_ id: String) -> DriveRuntime { runtime[id] ?? DriveRuntime() }
    public var allActiveTransfers: [Transfer] { activeTransfers.values.flatMap { $0 }.sorted { $0.startedAt > $1.startedAt } }
    public var googleDrive: DriveConfiguration? { drives.first { $0.provider == .googleDrive } }
    public var oracleDrive: DriveConfiguration? { drives.first { $0.provider == .oracleSFTP } }
    public var vaultDrive: DriveConfiguration? { drives.first { $0.provider == .vault } }

    public var overallHealth: HealthLevel {
        let levels = drives.filter(\.enabled).map { state($0.id).health }
        if diskWarning?.level == .critical { return .error }
        return levels.max() ?? .inactive
    }

    public var connectedCount: Int {
        drives.filter { if case .connected = state($0.id).connection { return true }; return state($0.id).phase == .mounted }.count
    }

    public var rcloneService: RcloneService? {
        dependencies?.rclone.map { RcloneService(paths: paths, secrets: secrets, binary: $0) }
    }

    func google() -> GoogleDriveProvider? {
        guard let rclone = rcloneService, let d = googleDrive else { return nil }
        return GoogleDriveProvider(rclone: rclone, remoteName: d.remoteName)
    }

    func vault() -> VaultProvider? {
        guard let rclone = rcloneService, let g = googleDrive else { return nil }
        let base = (try? google()?.runtimeEnvironment()) ?? [:]
        return VaultProvider(rclone: rclone, remoteName: vaultDrive?.remoteName ?? DriveConfiguration.vaultDefault.remoteName,
                             baseRemote: g.remoteName, baseEnvironment: base ?? [:])
    }

    func oracle() -> OracleSFTPProvider? {
        guard let rclone = rcloneService, let d = oracleDrive else { return nil }
        return OracleSFTPProvider(rclone: rclone, verifier: HostKeyVerifier(knownHostsURL: paths.knownHostsURL), remoteName: d.remoteName)
    }

    // MARK: Startup

    public func start() async {
        guard !started else { return }
        started = true
        do {
            try paths.prepare()
        } catch {
            startupError = "Could not create application folders: \(error.localizedDescription)"
        }
        if let corrupt = database.recoveredFrom {
            log(nil, "database", "The local database was damaged and has been rebuilt. The old file was kept at \(corrupt.path).", .warning)
        }
        loadSettings()
        loadDrives()
        offlinePins = Prefetcher.decodePins(database.setting(Self.pinsKey))
        for p in offlinePins { pinStatus[p.id] = .waiting }
        smartFolders = SmartFolder.decode(database.setting(Self.smartFoldersKey))
        heldUploads = UploadQueue.decodeHeld(database.setting(Self.heldUploadsKey))
        try? database.markStaleTransfersInterrupted()
        transferHistory = (try? database.recentTransfers()) ?? []
        recentActivity = (try? database.activity(limit: 300)) ?? []
        sftpConnection = try? database.sftp(driveID: oracleDrive?.id ?? "oracle")

        eventTask = Task { [weak self] in
            guard let events = self?.supervisor.events else { return }
            for await event in events { self?.handle(event) }
        }
        network.start { [weak self] online in
            Task { @MainActor in self?.networkChanged(online) }
        }

        // Read Keychain secrets off the main thread first: a Keychain permission prompt blocks the caller.
        if let caching = secrets as? CachingSecretStore { await caching.warmUp() }
        await refreshDependencies()
        await refreshConfiguredState()
        await adoptRunningMounts()
        log(nil, "app", "Ekthar Drive started.", .info)
        startPolling()
        await autoMount()
    }

    private func loadSettings() {
        if let json = database.setting("app"), let s = try? JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)) {
            settings = s
        }
    }

    private func loadDrives() {
        var list = (try? database.drives()) ?? []
        for d in [DriveConfiguration.googleDefault, .oracleDefault] where !list.contains(where: { $0.id == d.id }) {
            try? database.saveDrive(d)
            list.append(d)
        }
        // Upgrade drives saved with the old 5-minute folder cache: change polling keeps a long cache fresh.
        for i in list.indices where list[i].provider.supportsChangePolling && list[i].cache.dirCacheMinutes == 5 {
            list[i].cache.dirCacheMinutes = CachePolicy.googleDefault.dirCacheMinutes
            try? database.saveDrive(list[i])
        }
        drives = list
        for d in list where runtime[d.id] == nil {
            runtime[d.id] = DriveRuntime()
            trackers[d.id] = TransferTracker(driveID: d.id, remoteName: d.remoteName)
        }
    }

    public func installRclone(progress: @escaping @Sendable (String) -> Void) async throws(DriveError) {
        let bin = try await RcloneInstaller.install(into: paths.binDirectory, progress: progress)
        var s = settings
        s.rclonePath = bin.url.path
        saveSettings(s)
        await refreshDependencies()
        log(nil, "dependency", "Installed rclone \(bin.version) at \(bin.url.path).", .info)
    }

    public func refreshDependencies() async {
        dependencies = await DependencyChecker.check(paths: paths, configuredRclone: settings.rclonePath)
    }

    /// Updates `connection` from rclone.conf (does not touch the network).
    public func refreshConfiguredState() async {
        guard let rclone = rcloneService else {
            for d in drives { update(d.id) { $0.connection = .notConfigured } }
            return
        }
        let remotes: Set<String>
        do {
            remotes = Set(try await rclone.listRemotes())
        } catch {
            // Do NOT report "not connected" when we simply could not read the config (e.g. the Keychain
            // refused access to its password). That hid the real cause and skipped auto-mount.
            log(nil, "config", "Could not read the drive configuration: \(error.title). \(error.detail)", .error)
            for d in drives { update(d.id) { $0.lastError = error } }
            configReadError = error
            return
        }
        configReadError = nil
        for d in drives {
            let configured = remotes.contains(d.remoteName)
            update(d.id) { rt in
                if !configured { rt.connection = .notConfigured }
                else if rt.connection == .notConfigured { rt.connection = .unverified }
            }
        }
    }

    private func adoptRunningMounts() async {
        let adopted = await supervisor.adoptOrphans(driveIDs: drives.map(\.id))
        for info in adopted {
            guard let d = drive(info.driveID) else { continue }
            let rc = RcClient(socketPath: paths.rcSocket(for: d.id).path)
            guard await rc.isResponsive() else { continue }
            desiredMounted.insert(d.id)
            trackers[d.id] = TransferTracker(driveID: d.id, remoteName: d.remoteName, ignoreExistingHistory: true)
            // Use the mount that really exists. Guessing from settings picked the macFUSE path while the drive
            // was mounted with NFS, so the eject check saw "no mount" and stopped a healthy drive.
            // All engines now share ~/Volumes/<name>; older versions used /Volumes for macFUSE.
            let paths = [MountPathResolver.path(for: d, engine: .nfs), "/Volumes/\(d.name)"]
            guard let path = paths.first(where: { MountTable.isMounted($0) }), let entry = MountTable.entry(at: path) else {
                log(d.id, "mount", "Found \(d.name)'s rclone running but its volume is gone; stopping it.", .warning)
                await supervisor.terminate(d.id)
                continue
            }
            let engine = Self.engine(fsType: entry.fsType, source: entry.source)
            update(d.id) {
                $0.phase = .mounted
                $0.pid = info.pid
                $0.engine = engine
                $0.mountPath = path
            }
            log(d.id, "mount", "Reattached to \(d.name), which kept running while Ekthar Drive was closed.", .info)
            if TimeMachineDisk.exists(mountPath: path) { await openTimeMachineDisk(d.id) }
        }
    }

    /// Which engine made a mount, from the mount table. Our NFS engine mounts "localhost:/"; FUSE-T is
    /// also NFS underneath but with its own source name; macFUSE reports a "macfuse" file system.
    nonisolated static func engine(fsType: String, source: String) -> MountEngine {
        if fsType.lowercased().contains("fuse") { return .macFUSE }
        if fsType == "nfs", source.hasPrefix("localhost:") || source.hasPrefix("127.0.0.1:") { return .nfs }
        return .fuseT
    }

    private func autoMount() async {
        for d in drives where d.enabled && d.autoMount && !state(d.id).phase.isActive {
            guard state(d.id).connection.isConfigured else {
                log(d.id, "mount", "Skipped auto-mount of \(d.name): no account is connected.", .warning)
                continue
            }
            if d.provider == .oracleSFTP, let c = sftpConnection,
               !HostKeyVerifier(knownHostsURL: paths.knownHostsURL).isTrusted(host: c.host, port: c.port) {
                log(d.id, "security", "Skipped auto-mount of \(d.name): the server's host key is not verified.", .warning)
                continue
            }
            await mount(d.id)
        }
    }

    // MARK: Mount / unmount

    public func mount(_ id: String) async {
        guard let d = drive(id) else { return }
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        desiredMounted.insert(id)
        update(id) { $0.retryAttempt = 0 }
        await performMount(d)
    }

    private func performMount(_ d: DriveConfiguration) async {
        let id = d.id
        guard desiredMounted.contains(id), !mountingNow.contains(id) else { return }
        // While a mount attempt is in flight, its own error handling owns retries; the process-exit
        // handler must not schedule a second retry chain.
        mountingNow.insert(id)
        defer { mountingNow.remove(id) }
        update(id) { $0.phase = .mounting; $0.lastError = nil }
        do {
            guard d.enabled else { throw DriveError.invalidConfiguration("\(d.name) is disabled in settings.") }
            if dependencies?.rclone == nil { await refreshDependencies() }
            guard let deps = dependencies, let rclone = rcloneService else {
                throw DriveError.dependencyMissing(.rclone, detail: "Install rclone from Settings > Advanced.")
            }
            let resolved = try deps.resolve(settings.mountEngine)
            guard await rclone.remoteExists(d.remoteName) else { throw DriveError.notConfigured }
            if let warning = cacheManager.diskWarning(minFreeBytes: settings.globals.minFreeSpaceBytes), warning.level == .critical {
                throw DriveError.localDiskFull(freeBytes: warning.freeBytes)
            }
            var extra: [String: String] = [:]
            switch d.provider {
            case .googleDrive:
                extra = try google()?.runtimeEnvironment() ?? [:]
            case .oracleSFTP:
                guard let c = sftpConnection else { throw DriveError.notConfigured }
                guard HostKeyVerifier(knownHostsURL: paths.knownHostsURL).isTrusted(host: c.host, port: c.port) else {
                    throw DriveError.hostKeyUnknown(host: c.host)
                }
                extra = try await oracle()?.runtimeEnvironment() ?? [:]
            case .vault:
                guard let v = vault() else { throw DriveError.notConfigured }
                extra = try await v.runtimeEnvironment()
            }
            var engine = (settings.mountEngine == .automatic && macFUSEUnusable && deps.nfsUsable) ? .nfs : resolved
            let manager = MountManager(paths: paths, supervisor: supervisor, rcloneURL: rclone.binary.url)
            let env = try rclone.environment(extra: extra)
            var mountPath = MountPathResolver.path(for: d, engine: engine)
            let pid: Int32
            do {
                let engineEnv = env.merging(DependencyChecker.environment(for: engine)) { _, new in new }
                pid = try await manager.mount(MountRequest(drive: d, engine: engine, mountPath: mountPath, environment: engineEnv, globals: settings.globals))
            } catch DriveError.dependencyMissing(.macFUSE, let detail) where engine == .fuseT {
                // rclone's FUSE errors mention macFUSE even when FUSE-T is the library in use.
                throw DriveError.dependencyMissing(.fuseT, detail: "FUSE-T is installed but rclone could not mount with it (\(detail)) Reinstall FUSE-T, or choose the Built-in NFS engine in Settings > Advanced.")
            } catch DriveError.dependencyMissing(.macFUSE, let detail) where engine == .macFUSE {
                // macFUSE has two backends. The kernel one loads on its first mount (so it is often not
                // loaded yet after a restart); FSKit is a separate switch. Try the other one before giving up.
                var other = settings.globals
                other.macFUSEUsesFSKit.toggle()
                do {
                    pid = try await manager.mount(MountRequest(drive: d, engine: engine, mountPath: mountPath, environment: env, globals: other))
                    log(id, "mount", "macFUSE mounted with its \(other.macFUSEUsesFSKit ? "FSKit" : "kernel") backend.", .info)
                } catch DriveError.dependencyMissing(.macFUSE, _) where settings.mountEngine == .automatic && deps.nfsUsable {
                    // Neither backend works (e.g. the extension is switched off). Use the built-in engine.
                    macFUSEUnusable = true
                    log(id, "mount", "macFUSE could not mount (\(detail)) Using the built-in NFS engine instead.", .warning)
                    engine = .nfs
                    mountPath = MountPathResolver.path(for: d, engine: engine)
                    pid = try await manager.mount(MountRequest(drive: d, engine: engine, mountPath: mountPath, environment: env, globals: settings.globals))
                }
            }
            guard desiredMounted.contains(id) else {
                // User asked to unmount while we were mounting.
                try? await manager.unmount(driveID: id, mountPath: mountPath, waitForUploads: true)
                update(id) { $0.phase = .unmounted }
                return
            }
            trackers[id] = TransferTracker(driveID: id, remoteName: d.remoteName)
            update(id) {
                $0.phase = .mounted
                $0.pid = pid
                $0.engine = engine
                $0.mountPath = mountPath
                $0.retryAttempt = 0
                $0.connection = .connected(at: Date())
                $0.lastSuccessfulConnection = Date()
            }
            try? database.setDriveStatus(id, "mounted")
            log(id, "mount", "\(d.name) mounted at \(mountPath) (\(engine.displayName)).", .info)
            lastUsageRefresh[id] = nil
            Task { await self.refreshUsage(id) }
            if let limit = settings.bandwidthLimitMBps, limit > 0 { try? await cloudActions(id)?.setBandwidth(megabytesPerSecond: limit) }
            Task.detached(priority: .utility) { [paths, mountPath] in await Self.prewarm(socket: paths.rcSocket(for: id).path, mountPath: mountPath) }
            lastPinSync[id] = nil // the poll loop starts offline folders shortly after mounting
            if TimeMachineDisk.exists(mountPath: mountPath) { await openTimeMachineDisk(id) }
        } catch let error as DriveError {
            mountFailed(d, error)
        } catch {
            mountFailed(d, .unknown(error.localizedDescription))
        }
    }

    private func mountFailed(_ d: DriveConfiguration, _ error: DriveError) {
        let id = d.id
        update(id) { $0.lastError = error; $0.pid = nil }
        if case .authenticationFailed = error { update(id) { $0.connection = .failed(error) } }
        if case .hostKeyMismatch = error { update(id) { $0.connection = .failed(error) } }
        scheduleRetryOrFail(d, error)
    }

    private func scheduleRetryOrFail(_ d: DriveConfiguration, _ error: DriveError) {
        let id = d.id
        let attempt = state(id).retryAttempt + 1
        if desiredMounted.contains(id), settings.autoReconnect, error.isRetryable,
           !(error == .networkUnavailable || !isOnline),
           let delay = RetryPolicy.standard.delay(forAttempt: attempt, maxAttempts: d.maxRetryAttempts) {
            let at = Date().addingTimeInterval(Double(delay.components.seconds))
            update(id) { $0.phase = .retrying(attempt: attempt, at: at); $0.retryAttempt = attempt }
            log(id, "retry", "\(d.name): \(error.title). Retrying in \(delay.components.seconds)s (attempt \(attempt) of \(d.maxRetryAttempts)).", .warning)
            retryTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, let current = self.drive(id) else { return }
                await self.performMount(current)
            }
        } else {
            update(id) { $0.phase = .failed }
            try? database.setDriveStatus(id, "failed")
            let offlineNote = (!isOnline && error.isRetryable) ? " Ekthar Drive will reconnect when the network returns." : ""
            log(id, "error", "\(d.name): \(error.title). \(error.detail)\(offlineNote)", .error)
            if settings.notificationsEnabled { notifier.notify(title: "\(d.name): \(error.title)", body: error.detail) }
        }
    }

    /// Safe unmount. With `waitForUploads == false` and uploads pending, this sets `lastError = .pendingWrites`
    /// and leaves the drive mounted.
    public func unmount(_ id: String, waitForUploads: Bool) async {
        guard let d = drive(id) else { return }
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        pinTasks[id]?.cancel()
        pinTasks[id] = nil
        let rt = state(id)
        // "Wait for uploads" means the user wants them sent, so paused ones must start, or the wait never ends.
        if waitForUploads, rt.phase.isActive, !(heldUploads[id] ?? []).isEmpty { await resumeAllUploads(id) }
        let processRunning = await supervisor.isRunning(id)
        guard rt.phase.isActive || rt.phase == .mounting || processRunning else {
            desiredMounted.remove(id)
            if case .retrying = rt.phase { update(id) { $0.phase = .unmounted } }
            if rt.phase == .failed { update(id) { $0.phase = .unmounted } }
            return
        }
        guard let rclone = rcloneService else { return }
        let manager = MountManager(paths: paths, supervisor: supervisor, rcloneURL: rclone.binary.url)
        let mountPath = rt.mountPath ?? MountPathResolver.path(for: d, engine: rt.engine ?? .nfs)
        // The Time Machine disk lives on this drive; close it first or the volume stays busy.
        if rt.phase.isActive, TimeMachineDisk.attachedVolume != nil, TimeMachineDisk.exists(mountPath: mountPath) {
            do { try await TimeMachineDisk.detach() } catch {
                update(id) { $0.lastError = error }
                log(id, "timemachine", "Did not eject \(d.name): the Time Machine disk is in use. Let the backup finish, then eject again.", .warning)
                return
            }
        }
        stopping.insert(id)
        update(id) { $0.phase = waitForUploads ? .unmounting : .unmounting }
        do {
            try await manager.unmount(driveID: id, mountPath: mountPath, waitForUploads: waitForUploads) { remaining in
                Task { @MainActor in self.update(id) { $0.phase = .waitingForUploads(count: remaining) } }
            }
            desiredMounted.remove(id)
            stopping.remove(id)
            finishStopped(id)
            update(id) { $0.phase = .unmounted; $0.lastError = nil; $0.pid = nil }
            try? database.setDriveStatus(id, "unmounted")
            log(id, "mount", "\(d.name) unmounted.", .info)
        } catch let error as DriveError {
            stopping.remove(id)
            let stillRunning = await supervisor.isRunning(id)
            update(id) { $0.phase = stillRunning ? .mounted : .unmounted; $0.lastError = error }
            log(id, "unmount", "\(d.name) was not unmounted: \(error.title). \(error.detail)", error.category == .pendingWrite ? .warning : .error)
        } catch {
            stopping.remove(id)
        }
    }

    /// Starts a background "wait for uploads, then unmount" that the UI can cancel (cancelling stops the wait only).
    public func unmountWhenUploadsFinish(_ id: String) {
        unmountTasks[id]?.cancel()
        unmountTasks[id] = Task { await self.unmount(id, waitForUploads: true) }
    }

    public func cancelPendingUnmount(_ id: String) {
        unmountTasks[id]?.cancel()
        unmountTasks[id] = nil
    }

    public func mountAll() async {
        for d in drives where d.enabled && state(d.id).connection.isConfigured && !state(d.id).phase.isActive {
            await mount(d.id)
        }
    }

    public func unmountAll(waitForUploads: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for d in drives where state(d.id).phase.isActive || state(d.id).phase == .mounting {
                group.addTask { await self.unmount(d.id, waitForUploads: waitForUploads) }
            }
        }
    }

    private func finishStopped(_ id: String) {
        if var tracker = trackers[id] {
            for t in tracker.stop() { try? database.upsertTransfer(t); transferHistory.insert(t, at: 0) }
            trackers[id] = tracker
        }
        activeTransfers[id] = []
        if let d = drive(id) { trackers[id] = TransferTracker(driveID: id, remoteName: d.remoteName) }
        update(id) { $0.cache = self.cacheManager.diskStats(id) }
    }

    // MARK: Process events

    private func handle(_ event: SupervisorEvent) {
        switch event {
        case .output(let id, let line):
            let parsed = LogLine.parse(line)
            guard ["error", "critical"].contains(parsed.level) else { return }
            let error = ErrorClassifier.classify(output: [line], host: drive(id)?.name)
            if error.category == .authentication {
                update(id) { $0.lastError = error; $0.connection = .failed(error) }
            }
            // Throttle identical messages so a failing upload does not flood Activity.
            let message = (parsed.object.map { "\($0): " } ?? "") + parsed.message
            if let (last, at) = lastLoggedError[id], last == message, Date().timeIntervalSince(at) < 60 { return }
            lastLoggedError[id] = (message, Date())
            log(id, "rclone", message, .error)
        case .exited(let id, _, let status, _, let recent):
            guard let d = drive(id) else { return }
            if stopping.contains(id) || !desiredMounted.contains(id) {
                return // expected exit during unmount
            }
            if mountingNow.contains(id) || state(id).phase != .mounted {
                return // the mount attempt (or a pending retry) already handles this failure
            }
            finishStopped(id)
            if let p = state(id).mountPath, let rclone = rcloneService {
                // rclone serving NFS died: the volume would hang Finder. Remove it before retrying.
                Task { await MountManager(paths: paths, supervisor: supervisor, rcloneURL: rclone.binary.url).removeStaleNFSMount(p) }
            }
            let error: DriveError = {
                let classified = ErrorClassifier.classify(output: recent, exitCode: status, host: d.name)
                if case .processExited = classified, status == 0 {
                    return .processExited(code: 0, detail: "The volume was ejected outside Ekthar Drive.")
                }
                return classified
            }()
            update(id) { $0.pid = nil; $0.lastError = error }
            let fromWatchdog = watchdogStopping.remove(id) != nil
            if fromWatchdog {
                CrashReporter.write(driveID: id, driveName: d.name, status: status, error: error, recentOutput: recent, logsDirectory: paths.logsDirectory)
                update(id) { $0.retryAttempt = 0; $0.phase = .retrying(attempt: 1, at: Date()) }
                Task {
                    if let p = self.state(id).mountPath { await MountManager(paths: self.paths, supervisor: self.supervisor, rcloneURL: URL(fileURLWithPath: "/usr/bin/true")).removeStaleNFSMount(p) }
                    try? await Task.sleep(for: .seconds(1))
                    if let current = self.drive(id) { await self.performMount(current) }
                }
                return
            }
            if status == 0, case .processExited = error {
                // Ejected in Finder: respect it, do not remount.
                desiredMounted.remove(id)
                update(id) { $0.phase = .unmounted }
                log(id, "mount", "\(d.name) was ejected.", .info)
                return
            }
            let report = CrashReporter.write(driveID: id, driveName: d.name, status: status, error: error,
                                             recentOutput: recent, logsDirectory: paths.logsDirectory)
            log(id, "process", "\(d.name) stopped unexpectedly: \(error.title).\(report.map { " Report saved: \($0.lastPathComponent)" } ?? "")", .error)
            scheduleRetryOrFail(d, error)
        }
    }

    // MARK: Polling (only while something is mounted)

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let busy = await self.pollOnce()
                try? await Task.sleep(for: busy ? .seconds(1) : .seconds(5))
            }
        }
    }

    /// Returns true when transfers are active (poll faster).
    @discardableResult
    public func pollOnce() async -> Bool {
        // Assign only on change: every write to observed state redraws every screen that reads it.
        let warning = cacheManager.diskWarning(minFreeBytes: settings.globals.minFreeSpaceBytes)
        if warning != diskWarning { diskWarning = warning }
        if warning?.level != lastDiskWarningLevel {
            lastDiskWarningLevel = warning?.level
            if let w = warning {
                let msg = "Only \(ByteFormat.string(w.freeBytes)) free on this Mac. The cache stops growing below \(ByteFormat.string(w.thresholdBytes)); files waiting to upload are kept."
                log(nil, "disk", msg, w.level == .critical ? .error : .warning)
                if settings.notificationsEnabled { notifier.notify(title: w.level == .critical ? "Mac disk almost full" : "Mac disk getting full", body: msg) }
            }
        }
        for id in await supervisor.checkAdopted() where desiredMounted.contains(id) {
            if let d = drive(id) { finishStopped(id); scheduleRetryOrFail(d, .processExited(code: -1, detail: "The reattached rclone process stopped.")) }
        }
        // A volume ejected in Finder (or dropped by macOS) leaves an NFS-serving rclone behind. Notice it,
        // let pending uploads finish, then stop the process.
        // Not while the watchdog is restarting it: its volume is gone on purpose and it comes back by itself.
        for d in drives where state(d.id).phase == .mounted && !stopping.contains(d.id) && !watchdogStopping.contains(d.id) {
            if let p = state(d.id).mountPath, !MountTable.isMounted(p) {
                // macOS drops an NFS volume by itself about 20 s after its server stops answering. That is a
                // hang, not the user ejecting: restart rclone instead of stopping the drive.
                if !(await RcClient(socketPath: paths.rcSocket(for: d.id).path, timeoutSeconds: 5).isResponsive()) {
                    watchdogRestart(d, reason: "it stopped answering and macOS removed its volume")
                    continue
                }
                log(d.id, "mount", "\(d.name) was ejected outside Ekthar Drive. Finishing any uploads, then stopping it.", .info)
                desiredMounted.remove(d.id)
                Task { await self.unmount(d.id, waitForUploads: true) }
            }
        }
        // Re-read offline folders every 6 hours: picks up new files and keeps rclone from aging them out.
        for d in drives where state(d.id).phase == .mounted && pinTasks[d.id] == nil
            && offlinePins.contains(where: { $0.driveID == d.id })
            && Date().timeIntervalSince(lastPinSync[d.id] ?? .distantPast) > 6 * 3600 {
            syncPins(d.id)
        }
        var busy = false
        for d in drives where state(d.id).phase.isActive {
            let rc = RcClient(socketPath: paths.rcSocket(for: d.id).path, timeoutSeconds: 15)
            do {
                var cache = try await cacheManager.liveStats(rc)
                if diskMeasure[d.id].map({ Date().timeIntervalSince($0.at) > 30 }) ?? true {
                    let dir = cacheManager.cacheDirectory(d.id).appendingPathComponent("vfs")
                    let bytes = await Task.detached(priority: .utility) { DirectoryMeasure.measure(dir).bytes }.value
                    diskMeasure[d.id] = (bytes, Date())
                }
                cache.bytesUsed = max(cache.bytesUsed, diskMeasure[d.id]?.bytes ?? 0)
                let stats = try await rc.coreStats()
                let done = (try? await rc.transferred())?.transferred ?? []
                var queue = (try? await rc.vfsQueue())?.queue ?? []
                // Re-apply pauses rclone forgot (it re-queues cached files with a fresh start time on mount).
                let rehold = UploadQueue.needsHold(queue, held: heldUploads[d.id] ?? [])
                for item in rehold { try? await UploadQueue.hold(rc, id: item.id!) }
                if !rehold.isEmpty { queue = (try? await rc.vfsQueue())?.queue ?? queue }
                var tracker = trackers[d.id] ?? TransferTracker(driveID: d.id, remoteName: d.remoteName)
                let result = tracker.update(transferring: stats.transferring ?? [], completed: done, queue: queue)
                trackers[d.id] = tracker
                if activeTransfers[d.id] != result.active { activeTransfers[d.id] = result.active }
                for t in result.finished {
                    try? database.upsertTransfer(t)
                    transferHistory.insert(t, at: 0)
                    if t.status == .failed { log(d.id, "transfer", "\(t.direction == .upload ? "Upload" : "Download") of \(t.name) failed: \(t.errorMessage ?? "unknown error")", .error) }
                }
                if transferHistory.count > 500 { transferHistory.removeLast(transferHistory.count - 500) }
                update(d.id) {
                    if $0.cache?.sameMeasurement(as: cache) != true { $0.cache = cache }
                    // A good answer clears any earlier "not answering" state.
                    switch $0.lastError {
                    case .rcUnavailable?, .timeout?: $0.lastError = nil
                    default: break
                    }
                    if cache.outOfSpace { $0.lastError = .cacheFull }
                }
                pollFailures[d.id] = 0
                if !result.active.isEmpty || cache.pendingUploads > 0 { busy = true }
                if lastUsageRefresh[d.id].map({ Date().timeIntervalSince($0) > 300 }) ?? true {
                    lastUsageRefresh[d.id] = Date()
                    if let about = try? await rc.about(fs: d.remoteSpec) { update(d.id) { $0.usage = about.usage } }
                }
            } catch let e {
                // rclone can be briefly busy (a big first listing, opening a large file). One slow answer is
                // not a problem; only report it after 3 misses in a row (about 45 s or more).
                let misses = (pollFailures[d.id] ?? 0) + 1
                pollFailures[d.id] = misses
                if misses >= Self.watchdogRestartAfter, state(d.id).phase == .mounted {
                    watchdogRestart(d, reason: "its control channel stopped answering")
                }
                if misses >= Self.pollFailuresBeforeError {
                    update(d.id) { $0.lastError = .rcUnavailable("\(d.name) is not answering. Files may open slowly. Ekthar Drive keeps checking.") }
                }
                _ = e
            }
        }
        let pendingTotal = drives.compactMap { state($0.id).cache?.pendingUploads }.reduce(0, +)
        sleepGuard.update(pendingUploads: pendingTotal)
        await probeVolumes()
        return busy
    }

    /// Watchdog part 2: the volume itself must answer a stat within 10 s (checked every 30 s).
    private func probeVolumes() async {
        for d in drives where state(d.id).phase == .mounted && !stopping.contains(d.id) {
            guard let p = state(d.id).mountPath, lastProbe[d.id].map({ Date().timeIntervalSince($0) >= 30 }) ?? true else { continue }
            lastProbe[d.id] = Date()
            if await VolumeProbe.responds(p, within: 10) {
                probeFailures[d.id] = 0
            } else {
                let n = (probeFailures[d.id] ?? 0) + 1
                probeFailures[d.id] = n
                log(d.id, "watchdog", "\(d.name) did not answer a file check within 10 s (\(n) of 2).", .warning)
                if n >= 2 { probeFailures[d.id] = 0; watchdogRestart(d, reason: "the volume stopped answering") }
            }
        }
    }

    /// Restarts a hung rclone. Safe for data: files waiting to upload stay in the cache on disk and resume
    /// when the new process starts. The normal exit handler removes the dead volume and remounts.
    private func watchdogRestart(_ d: DriveConfiguration, reason: String) {
        guard state(d.id).phase == .mounted else { return }
        pollFailures[d.id] = 0
        watchdogRestarts += 1
        log(d.id, "watchdog", "Restarting \(d.name) because \(reason). Pending uploads are kept and resume after the restart.", .warning)
        watchdogStopping.insert(d.id)
        Task {
            await supervisor.terminate(d.id)
            // A hung rclone often ignores SIGTERM. Give it 15 s, then stop it hard.
            if !(await supervisor.waitForExit(d.id, timeout: .seconds(15))) {
                log(d.id, "watchdog", "\(d.name) did not stop; forcing it to quit.", .warning)
                await supervisor.forceKill(d.id)
            }
        }
    }

    /// Loads the top folder and each first-level folder into rclone's listing cache right after mounting,
    /// so the first clicks in Finder do not wait for the cloud. Metadata only; no file contents. Max 20 folders.
    nonisolated static func prewarm(socket: String, mountPath: String) async {
        let rc = RcClient(socketPath: socket, timeoutSeconds: 60)
        _ = try? await rc.call("vfs/refresh", params: ["recursive": "false"])
        let top = (try? FileManager.default.contentsOfDirectory(atPath: mountPath)) ?? []
        var dirs: [String] = []
        for name in top where !name.hasPrefix(".") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: mountPath + "/" + name, isDirectory: &isDir), isDir.boolValue { dirs.append(name) }
            if dirs.count >= 20 { break }
        }
        // One folder at a time with a pause, so warming never competes with what the user is opening
        // (Google rate-limits API calls per account).
        for name in dirs {
            try? await Task.sleep(for: .milliseconds(500))
            _ = try? await rc.call("vfs/refresh", params: ["dir": name, "recursive": "false"])
        }
    }

    /// Reads capacity. Uses the live process when mounted, otherwise a one-off rclone call.
    public func refreshUsage(_ id: String) async {
        guard let d = drive(id), state(id).connection.isConfigured else { return }
        lastUsageRefresh[id] = Date()
        if state(id).phase.isActive, let about = try? await RcClient(socketPath: paths.rcSocket(for: id).path).about(fs: d.remoteSpec) {
            update(id) { $0.usage = about.usage }
            return
        }
        do {
            let usage: StorageUsage
            switch d.provider {
            case .googleDrive:
                guard let g = google() else { return }
                usage = try await g.usage()
            case .oracleSFTP:
                guard let o = oracle(), let c = sftpConnection else { return }
                usage = try await o.usage(remotePath: d.remotePath, host: c.host)
            case .vault:
                guard let v = vault() else { return }
                usage = try await v.usage()
            }
            update(id) { $0.usage = usage; $0.connection = .connected(at: Date()); $0.lastSuccessfulConnection = Date() }
        } catch let error {
            update(id) { $0.lastError = error }
        }
        if !state(id).phase.isActive { update(id) { $0.cache = cacheManager.diskStats(id) } }
    }

    public func refreshAll() async {
        await refreshDependencies()
        await refreshConfiguredState()
        for d in drives where state(d.id).connection.isConfigured { await refreshUsage(d.id) }
        _ = await pollOnce()
    }

    // MARK: Cloud actions

    public func cloudActions(_ id: String) -> CloudActions? {
        guard let d = drive(id), state(id).phase.isActive else { return nil }
        return CloudActions(rc: RcClient(socketPath: paths.rcSocket(for: id).path, timeoutSeconds: 60), drive: d)
    }

    // MARK: Time Machine

    /// Drive holding the Time Machine disk, if any is mounted.
    public var timeMachineDriveID: String? {
        drives.first { d in state(d.id).phase.isActive && state(d.id).mountPath.map(TimeMachineDisk.exists) == true }?.id
    }

    public private(set) var timeMachineBusy: String?

    /// Creates the backup disk on a mounted drive, then opens it.
    public func createTimeMachineDisk(_ id: String, sizeGB: Int) async throws(DriveError) {
        guard let d = drive(id), state(id).phase == .mounted, let mount = state(id).mountPath else {
            throw .invalidConfiguration("Mount the drive first.")
        }
        guard d.provider != .vault else { throw .invalidConfiguration("Use Google Drive or Oracle Drive. Time Machine can encrypt the backup itself.") }
        guard timeMachineDriveID == nil else { throw .invalidConfiguration("A Time Machine disk already exists.") }
        timeMachineBusy = "Creating the backup disk…"
        defer { timeMachineBusy = nil }
        do { try await TimeMachineDisk.create(mountPath: mount, sizeGB: sizeGB) } catch {
            log(id, "timemachine", "Could not create the Time Machine disk: \(error.detail)", .error)
            throw error
        }
        log(id, "timemachine", "Created a \(sizeGB) GB Time Machine disk on \(d.name).", .info)
        await openTimeMachineDisk(id)
    }

    public func openTimeMachineDisk(_ id: String) async {
        guard let mount = state(id).mountPath else { return }
        timeMachineBusy = "Opening the backup disk…"
        defer { timeMachineBusy = nil }
        do {
            try await TimeMachineDisk.attach(mountPath: mount)
            log(id, "timemachine", "Time Machine disk ready at /Volumes/\(TimeMachineDisk.volumeName).", .info)
        } catch {
            log(id, "timemachine", "Could not open the Time Machine disk: \(error.detail)", .error)
        }
    }

    public func closeTimeMachineDisk() async throws(DriveError) {
        try await TimeMachineDisk.detach()
    }

    // MARK: Upload queue

    private func queueRC(_ id: String) -> RcClient? {
        state(id).phase.isActive ? RcClient(socketPath: paths.rcSocket(for: id).path, timeoutSeconds: 15) : nil
    }

    private func saveHeld() { try? database.setSetting(Self.heldUploadsKey, UploadQueue.encodeHeld(heldUploads)) }

    /// Starts a queued upload now, skipping the write-back delay and any pause.
    public func uploadNow(_ t: Transfer) async {
        guard let rc = queueRC(t.driveID), let qid = t.queueID else { return }
        heldUploads[t.driveID]?.remove(Self.queueName(t))
        saveHeld()
        do { try await UploadQueue.startNow(rc, id: qid) } catch { log(t.driveID, "transfer", "Could not start \(t.name): \(error.detail)", .warning) }
        _ = await pollOnce()
    }

    /// Keeps a queued upload on this Mac until resumed. The file stays safe in the cache.
    public func pauseUpload(_ t: Transfer) async {
        guard let rc = queueRC(t.driveID), let qid = t.queueID else { return }
        heldUploads[t.driveID, default: []].insert(Self.queueName(t))
        saveHeld()
        do { try await UploadQueue.hold(rc, id: qid) } catch { log(t.driveID, "transfer", "Could not pause \(t.name): \(error.detail)", .warning) }
        _ = await pollOnce()
    }

    public func resumeUpload(_ t: Transfer) async {
        guard let rc = queueRC(t.driveID), let qid = t.queueID else { return }
        heldUploads[t.driveID]?.remove(Self.queueName(t))
        saveHeld()
        do { try await UploadQueue.release(rc, id: qid) } catch { log(t.driveID, "transfer", "Could not resume \(t.name): \(error.detail)", .warning) }
        _ = await pollOnce()
    }

    /// Pauses every upload still waiting on this drive. Ones already sending finish.
    public func pauseAllUploads(_ id: String) async {
        guard let rc = queueRC(id), let items = try? await UploadQueue.items(rc) else { return }
        let waiting = items.filter { $0.uploading != true && $0.id != nil }
        heldUploads[id, default: []].formUnion(waiting.map(\.name))
        saveHeld()
        for item in waiting { try? await UploadQueue.hold(rc, id: item.id!) }
        if !waiting.isEmpty { log(id, "transfer", "Paused \(waiting.count) upload\(waiting.count == 1 ? "" : "s"). They stay on this Mac until resumed.", .info) }
        _ = await pollOnce()
    }

    public func resumeAllUploads(_ id: String) async {
        let held = heldUploads[id] ?? []
        heldUploads[id] = nil
        saveHeld()
        guard let rc = queueRC(id), let items = try? await UploadQueue.items(rc) else { return }
        for item in items where held.contains(item.name) && item.id != nil { try? await UploadQueue.release(rc, id: item.id!) }
        if !held.isEmpty { log(id, "transfer", "Resumed paused uploads.", .info) }
        _ = await pollOnce()
    }

    /// Stops a Copy to job. Already copied files stay where they are.
    public func cancelJob(_ t: Transfer) async {
        guard let rc = queueRC(t.driveID), let job = t.jobID else { return }
        do {
            try await UploadQueue.cancelJob(rc, jobID: job)
            log(t.driveID, "transfer", "Cancelled copying \(t.name).", .info)
        } catch { log(t.driveID, "transfer", "Could not cancel \(t.name): \(error.detail)", .warning) }
        _ = await pollOnce()
    }

    public func hasHeldUploads(_ id: String) -> Bool { !(heldUploads[id] ?? []).isEmpty }

    /// The queue's own name for an upload: its path inside the drive (the tracker stores it as the source).
    static func queueName(_ t: Transfer) -> String { t.sourcePath }

    /// Drive-wide search through the running rclone. Nil when the drive is not mounted.
    public func search(_ id: String) -> DriveSearch? {
        guard let d = drive(id), state(id).phase.isActive else { return nil }
        return DriveSearch(socketPath: paths.rcSocket(for: id).path, drive: d)
    }

    public func saveSmartFolder(_ f: SmartFolder) {
        if let i = smartFolders.firstIndex(where: { $0.id == f.id }) { smartFolders[i] = f } else { smartFolders.append(f) }
        try? database.setSetting(Self.smartFoldersKey, SmartFolder.encode(smartFolders))
    }

    public func deleteSmartFolder(_ id: String) {
        smartFolders.removeAll { $0.id == id }
        try? database.setSetting(Self.smartFoldersKey, SmartFolder.encode(smartFolders))
    }

    // MARK: Offline folders and prefetch

    public func pin(for driveID: String, path: String) -> OfflinePin? {
        let p = OfflinePin(driveID: driveID, path: path)
        return offlinePins.first { $0.id == p.id }
    }

    /// Keeps a folder or file on this Mac. It downloads in the background and is re-read every 6 hours.
    public func keepOffline(_ driveID: String, path: String) {
        let p = OfflinePin(driveID: driveID, path: path)
        guard !offlinePins.contains(p) else { return }
        offlinePins.append(p)
        pinStatus[p.id] = .waiting
        savePins()
        log(driveID, "offline", "Keeping “\(p.name)” on this Mac.", .info)
        syncPins(driveID, restart: true)
    }

    /// Stops keeping it. Already downloaded data stays in the cache until rclone ages it out.
    public func removeOffline(_ pin: OfflinePin) {
        offlinePins.removeAll { $0 == pin }
        pinStatus[pin.id] = nil
        savePins()
        if pinTasks[pin.driveID] != nil { syncPins(pin.driveID, restart: true) }
    }

    private func savePins() { try? database.setSetting(Self.pinsKey, Prefetcher.encodePins(offlinePins)) }

    /// Downloads this drive's offline folders one after another, off the main thread.
    public func syncPins(_ driveID: String, restart: Bool = false) {
        if restart { pinTasks[driveID]?.cancel(); pinTasks[driveID] = nil }
        guard pinTasks[driveID] == nil, let d = drive(driveID), state(driveID).phase == .mounted,
              let mount = state(driveID).mountPath else { return }
        let pins = offlinePins.filter { $0.driveID == driveID }
        guard !pins.isEmpty else { return }
        lastPinSync[driveID] = Date()
        let budget = Int64(Double(d.cache.maxSizeBytes) * 0.9)
        pinTasks[driveID] = Task { [weak self] in
            var used: Int64 = 0
            for pin in pins {
                guard !Task.isCancelled else { break }
                let url = URL(fileURLWithPath: mount).appendingPathComponent(pin.path)
                self?.pinStatus[pin.id] = .downloading(doneBytes: 0, totalBytes: 0)
                let reporter = ProgressThrottle { done, total in
                    Task { @MainActor in
                        if case .downloading = self?.pinStatus[pin.id] { self?.pinStatus[pin.id] = .downloading(doneBytes: done, totalBytes: total) }
                    }
                }
                let left = budget - used
                let stop = StopFlag()
                let result: Result<(files: Int, bytes: Int64), DriveError> = await withTaskCancellationHandler {
                    await Task.detached(priority: .utility) {
                        Result { () throws(DriveError) in
                            try Prefetcher.download(url, budgetBytes: left, progress: reporter.report, cancelled: stop.isSet)
                        }
                    }.value
                } onCancel: { stop.set() }
                guard !Task.isCancelled, let self else { break }
                switch result {
                case .success(let r):
                    used += r.bytes
                    pinStatus[pin.id] = .ready(files: r.files, bytes: r.bytes, at: Date())
                case .failure(let e):
                    pinStatus[pin.id] = .failed(e.detail)
                    log(driveID, "offline", "Could not keep “\(pin.name)” offline: \(e.detail)", .warning)
                }
            }
            self?.pinTasks[driveID] = nil
        }
    }

    /// Reads the start of a file in the background so opening it does not wait for the network.
    public func warmStart(_ url: URL) {
        Task.detached(priority: .utility) { Prefetcher.warmStart(url) }
    }

    /// Loads the listings of the given folders into rclone's cache, so opening them is instant.
    public func prefetchListings(_ id: String, relativeDirs: [String]) {
        guard state(id).phase.isActive, !relativeDirs.isEmpty else { return }
        let socket = paths.rcSocket(for: id).path
        Task.detached(priority: .utility) {
            let rc = RcClient(socketPath: socket, timeoutSeconds: 30)
            for dir in relativeDirs.prefix(12) {
                _ = try? await rc.call("vfs/refresh", params: ["dir": dir, "recursive": "false"])
            }
        }
    }

    /// Other drives a file can be copied to directly (configured in the same rclone.conf).
    public func copyTargets(from id: String) -> [DriveConfiguration] {
        // Not into the vault: the copy runs in the source drive's rclone, which never gets the vault password.
        // Dragging into the Vault volume in Finder encrypts on the way in.
        drives.filter { $0.id != id && state($0.id).connection.isConfigured && $0.provider != .vault }
    }

    /// Applies the saved speed limit to every running drive.
    public func applyBandwidthLimit() async {
        let limit = settings.bandwidthLimitMBps.flatMap { $0 > 0 ? $0 : nil }
        for d in drives where state(d.id).phase.isActive {
            try? await cloudActions(d.id)?.setBandwidth(megabytesPerSecond: limit)
        }
    }

    // MARK: Network / sleep

    private func networkChanged(_ online: Bool) {
        isOnline = online
        if online {
            log(nil, "network", "Network connection restored.", .info)
            reconnectAfterInterruption()
        } else {
            log(nil, "network", "Network connection lost. Mounted volumes may be slow or unavailable; pending uploads stay in the cache.", .warning)
        }
    }

    /// Remount drives the user wanted mounted that stopped because of a recoverable error.
    public func reconnectAfterInterruption() {
        for d in drives where desiredMounted.contains(d.id) {
            let rt = state(d.id)
            guard rt.phase == .failed || { if case .retrying = rt.phase { return true }; return false }() else { continue }
            guard rt.lastError?.isRetryable ?? true else { continue }
            retryTasks[d.id]?.cancel()
            update(d.id) { $0.retryAttempt = 0 }
            Task { await self.performMount(d) }
        }
    }

    public func systemDidWake() {
        log(nil, "power", "Mac woke from sleep; checking volumes.", .info)
        Task {
            try? await Task.sleep(for: .seconds(3))
            _ = await self.pollOnce()
            self.reconnectAfterInterruption()
        }
    }

    // MARK: Termination

    public func terminationCheck() async -> TerminationCheck {
        var pending = 0
        for d in drives where state(d.id).phase.isActive {
            pending += await MountManager(paths: paths, supervisor: supervisor, rcloneURL: URL(fileURLWithPath: "/usr/bin/true")).pendingUploads(d.id) ?? 0
        }
        return pending > 0 ? .pendingUploads(pending) : .safe
    }

    /// Stops polling and unmounts everything (waiting for uploads).
    public func shutdown() async {
        pollTask?.cancel()
        for t in retryTasks.values { t.cancel() }
        await unmountAll(waitForUploads: true)
        network.stop()
    }

    /// Quit but leave volumes mounted; rclone keeps uploading and the next launch reattaches.
    public func detachForQuit() {
        pollTask?.cancel()
        network.stop()
        log(nil, "app", "Ekthar Drive quit and left mounted volumes running in the background.", .info)
    }

    // MARK: Accounts

    public func connectGoogle(clientID: String?, clientSecret: String?, onAuthURL: @escaping @Sendable (URL) -> Void) async throws(DriveError) {
        guard let g = google(), let d = googleDrive else { throw .dependencyMissing(.rclone, detail: "Install rclone first.") }
        if state(d.id).phase.isActive { throw .alreadyRunning }
        update(d.id) { $0.connection = .testing }
        do {
            let usage = try await g.connect(clientID: clientID, clientSecret: clientSecret, onAuthURL: onAuthURL)
            var s = settings
            s.googleClientID = (clientID?.isEmpty ?? true) ? nil : clientID
            saveSettings(s)
            let label = await g.accountLabel()
            update(d.id) { $0.connection = .connected(at: Date()); $0.usage = usage; $0.accountLabel = label; $0.lastError = nil; $0.lastSuccessfulConnection = Date() }
            log(d.id, "account", "Google Drive connected\(label.map { " as \($0)" } ?? "").", .info)
        } catch {
            update(d.id) { $0.connection = (error.category == .authentication) ? .failed(error) : .notConfigured; $0.lastError = error }
            log(d.id, "account", "Google sign-in failed: \(error.detail)", .error)
            throw error
        }
    }

    public func scanOracleHostKeys(host: String, port: Int) async throws(DriveError) -> [HostKey] {
        guard let o = oracle() else { throw .dependencyMissing(.rclone, detail: "Install rclone first.") }
        return try await o.scanHostKeys(host: host, port: port)
    }

    public func trustOracleHostKeys(_ keys: [HostKey], host: String, port: Int) throws(DriveError) {
        try HostKeyVerifier(knownHostsURL: paths.knownHostsURL).trust(keys, host: host, port: port)
        log(oracleDrive?.id, "security", "Trusted SSH host key \(keys.first?.fingerprint ?? "") for \(host):\(port).", .info)
    }

    public func trustedOracleFingerprints() async -> [String] {
        guard let c = sftpConnection else { return [] }
        return await HostKeyVerifier(knownHostsURL: paths.knownHostsURL).trustedFingerprints(host: c.host, port: c.port)
    }

    /// Saves the Oracle connection and proves it with a real SFTP listing of the remote directory.
    public func configureOracle(_ c: SFTPConnection, passphrase: String?, remoteDirectory: String) async throws(DriveError) {
        guard let o = oracle(), var d = oracleDrive else { throw .dependencyMissing(.rclone, detail: "Install rclone first.") }
        if state(d.id).phase.isActive { throw .alreadyRunning }
        d.remotePath = remoteDirectory
        try d.validate()
        update(d.id) { $0.connection = .testing }
        do {
            try await o.configure(c, passphrase: passphrase)
            try? database.saveSFTP(c, driveID: d.id)
            sftpConnection = c
            try saveDrive(d)
            try await o.testConnection(remotePath: d.remotePath, host: c.host)
            update(d.id) { $0.connection = .connected(at: Date()); $0.lastError = nil; $0.lastSuccessfulConnection = Date(); $0.accountLabel = "\(c.username)@\(c.host)" }
            log(d.id, "account", "Connected to \(c.username)@\(c.host):\(c.port)\(d.remotePath).", .info)
            await refreshUsage(d.id)
        } catch {
            update(d.id) { $0.connection = .failed(error); $0.lastError = error }
            log(d.id, "account", "Oracle connection test failed: \(error.title). \(error.detail)", .error)
            throw error
        }
    }

    // MARK: Vault

    /// Creates the vault (or reconnects to an existing one with its password) and adds it as a drive.
    public func setUpVault(password: String) async throws(DriveError) {
        guard let g = googleDrive, state(g.id).connection.isConfigured else {
            throw .invalidConfiguration("Connect Google Drive first. The vault is a folder inside it.")
        }
        guard let v = vault() else { throw .dependencyMissing(.rclone, detail: "Install rclone first.") }
        if let d = vaultDrive, state(d.id).phase.isActive { throw .alreadyRunning }
        let d = vaultDrive ?? .vaultDefault
        try saveDrive(d)
        if runtime[d.id] == nil {
            runtime[d.id] = DriveRuntime()
            trackers[d.id] = TransferTracker(driveID: d.id, remoteName: d.remoteName)
        }
        update(d.id) { $0.connection = .testing }
        do {
            try await v.configure(password: password)
            update(d.id) { $0.connection = .connected(at: Date()); $0.lastError = nil; $0.lastSuccessfulConnection = Date(); $0.accountLabel = "Encrypted in “\(v.folder)”" }
            log(d.id, "account", "Vault ready in Google Drive folder “\(v.folder)”.", .info)
        } catch {
            update(d.id) { $0.connection = .failed(error); $0.lastError = error }
            log(d.id, "account", "Vault setup failed: \(error.title). \(error.detail)", .error)
            throw error
        }
    }

    public var vaultHasSavedPassword: Bool { vault()?.hasSavedPassword() ?? false }

    /// Ejects the vault and forgets its password on this Mac. Opening it again needs the password.
    public func lockVault() async {
        guard let d = vaultDrive else { return }
        if state(d.id).phase.isActive { await unmount(d.id, waitForUploads: true) }
        guard !state(d.id).phase.isActive else { return }
        do { try vault()?.lock(); log(d.id, "account", "Vault locked. Its password was removed from this Mac.", .info) }
        catch { log(d.id, "account", "Could not forget the vault password: \(error.detail)", .error) }
        update(d.id) { $0.connection = .unverified }
    }

    public func testConnection(_ id: String) async {
        guard let d = drive(id) else { return }
        update(id) { $0.connection = .testing }
        do {
            switch d.provider {
            case .googleDrive:
                guard let g = google() else { throw DriveError.dependencyMissing(.rclone, detail: "Install rclone first.") }
                try await g.testConnection()
                let label = await g.accountLabel()
                update(id) { $0.accountLabel = label ?? $0.accountLabel }
            case .oracleSFTP:
                guard let o = oracle(), let c = sftpConnection else { throw DriveError.notConfigured }
                try await o.testConnection(remotePath: d.remotePath, host: c.host)
                update(id) { $0.accountLabel = "\(c.username)@\(c.host)" }
            case .vault:
                guard let v = vault() else { throw DriveError.notConfigured }
                try await v.testConnection()
                update(id) { $0.accountLabel = "Encrypted in “\(v.folder)”" }
            }
            update(id) { $0.connection = .connected(at: Date()); $0.lastSuccessfulConnection = Date(); if $0.lastError?.category == .authentication { $0.lastError = nil } }
            log(id, "connection", "\(d.name) connection test succeeded.", .info)
            await refreshUsage(id)
        } catch let error as DriveError {
            update(id) { $0.connection = error == .notConfigured ? .notConfigured : .failed(error); $0.lastError = error }
            log(id, "connection", "\(d.name) connection test failed: \(error.title). \(error.detail)", .error)
        } catch {}
    }

    /// Removes the account. Refuses while mounted. Revokes the Google token where possible.
    public func disconnect(_ id: String) async throws(DriveError) {
        guard let d = drive(id) else { return }
        guard !state(id).phase.isActive else { throw .alreadyRunning }
        desiredMounted.remove(id)
        switch d.provider {
        case .googleDrive:
            let revoked = try await google()?.disconnect() ?? false
            log(id, "account", revoked ? "Google Drive disconnected and access revoked." : "Google Drive disconnected. Google did not confirm revocation; you can also remove access at myaccount.google.com/permissions.", revoked ? .info : .warning)
        case .oracleSFTP:
            try await oracle()?.disconnect(host: sftpConnection?.host, port: sftpConnection?.port)
            try? database.deleteSFTP(driveID: id)
            sftpConnection = nil
            log(id, "account", "Oracle Drive disconnected and its trusted host key removed.", .info)
        case .vault:
            try await vault()?.disconnect()
            drives.removeAll { $0.id == id }
            try? database.deleteDrive(id)
            log(id, "account", "Vault removed from this Mac. The encrypted files stay in Google Drive; the same password opens them again.", .info)
            runtime[id] = nil
            return
        }
        update(id) { $0 = DriveRuntime(); $0.cache = self.cacheManager.diskStats(id) }
    }

    // MARK: Cache

    public func clearSafeCache(_ id: String) throws(DriveError) -> CacheClearResult {
        let result = try cacheManager.clearSafeCache(id, isMounted: state(id).phase.isActive)
        lastCacheClear[id] = Date()
        update(id) { $0.cache = cacheManager.diskStats(id) }
        log(id, "cache", "Cleared \(result.removedFiles) cached file(s), freed \(ByteFormat.string(result.freedBytes)). Kept \(result.keptDirty) not-yet-uploaded file(s).", .info)
        return result
    }

    public func measureCaches() {
        for d in drives where !state(d.id).phase.isActive { update(d.id) { $0.cache = cacheManager.diskStats(d.id) } }
    }

    // MARK: Settings & drive config

    public func saveSettings(_ s: AppSettings) {
        let engineChanged = s.mountEngine != settings.mountEngine || s.rclonePath != settings.rclonePath
        settings = s
        if let data = try? JSONEncoder().encode(s) { try? database.setSetting("app", String(decoding: data, as: UTF8.self)) }
        if engineChanged { Task { await refreshDependencies() } }
    }

    public func saveDrive(_ d: DriveConfiguration) throws(DriveError) {
        try d.validate()
        var copy = d
        copy.updatedAt = Date()
        do { try database.saveDrive(copy) } catch { throw .unknown("Could not save settings: \(error.localizedDescription)") }
        if let i = drives.firstIndex(where: { $0.id == d.id }) { drives[i] = copy } else { drives.append(copy) }
    }

    // MARK: Activity

    public func log(_ driveID: String?, _ type: String, _ message: String, _ severity: Severity) {
        let event = ActivityEvent(driveID: driveID, eventType: type, message: Redactor.redact(message), severity: severity)
        var stored = event
        stored.id = try? database.addActivity(event)
        recentActivity.insert(stored, at: 0)
        if recentActivity.count > 300 { recentActivity.removeLast(recentActivity.count - 300) }
        switch severity {
        case .error: logger.error("[\(driveID ?? "app")] \(message)")
        case .warning: logger.warning("[\(driveID ?? "app")] \(message)")
        case .info: logger.info("[\(driveID ?? "app")] \(message)")
        }
    }

    public func searchActivity(driveID: String?, minimumSeverity: Severity?, search: String) -> [ActivityEvent] {
        (try? database.activity(limit: 1000, driveID: driveID, minimumSeverity: minimumSeverity, search: search)) ?? []
    }

    public func update(_ id: String, _ body: (inout DriveRuntime) -> Void) {
        var rt = runtime[id] ?? DriveRuntime()
        body(&rt)
        if rt != runtime[id] { runtime[id] = rt }
    }

    // MARK: Diagnostics

    public func diagnosticsReport() async -> String {
        var lines: [String] = ["Ekthar Drive diagnostics", "Generated: \(Date())", ""]
        let deps = dependencies
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("rclone: \(deps?.rclone.map { "\($0.version) at \($0.url.path) fuse=\($0.supportsFUSEMount) nfs=\($0.supportsNFSMount)" } ?? "not found")")
        lines.append("macFUSE: \(deps?.macFUSEVersion ?? "not installed") libfuse=\(deps?.libfuseInstalled ?? false)")
        lines.append("Engine setting: \(settings.mountEngine.rawValue)")
        lines.append("Online: \(isOnline)")
        lines.append("Free local space: \(ByteFormat.string(DiskSpace.freeBytes(at: paths.cacheRoot.path)))")
        lines.append("rclone.conf owner-only: \(FilePermissions.isOwnerOnly(paths.rcloneConfigURL.path))")
        lines.append("")
        for d in drives {
            let rt = state(d.id)
            lines.append("[\(d.name)] provider=\(d.provider.rawValue) remote=\(d.remoteSpec) phase=\(rt.phase.label) health=\(rt.health)")
            lines.append("  mount=\(rt.mountPath ?? "-") engine=\(rt.engine?.rawValue ?? "-") pid=\(rt.pid.map(String.init) ?? "-")")
            lines.append("  connection=\(rt.connection) lastError=\(rt.lastError.map { "\($0.title): \($0.detail)" } ?? "none")")
            lines.append("  cache=\(ByteFormat.string(rt.cache?.bytesUsed)) pending=\(rt.cache?.pendingUploads ?? 0) errored=\(rt.cache?.erroredFiles ?? 0)")
            lines.append("  recent rclone output:")
            for l in await supervisor.recentOutput(for: d.id).suffix(40) { lines.append("    " + l) }
        }
        lines.append("")
        lines.append("Recent activity:")
        for e in recentActivity.prefix(100) { lines.append("  \(e.timestamp) [\(e.severity.rawValue)] \(e.driveID ?? "app"): \(e.message)") }
        return Redactor.redact(lines.joined(separator: "\n"))
    }
}
