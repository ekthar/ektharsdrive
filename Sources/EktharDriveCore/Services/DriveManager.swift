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
    public func state(_ id: String) -> DriveRuntime { runtime[id] ?? DriveRuntime() }
    public var allActiveTransfers: [Transfer] { activeTransfers.values.flatMap { $0 }.sorted { $0.startedAt > $1.startedAt } }
    public var googleDrive: DriveConfiguration? { drives.first { $0.provider == .googleDrive } }
    public var oracleDrive: DriveConfiguration? { drives.first { $0.provider == .oracleSFTP } }

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
        let remotes = Set((try? await rclone.listRemotes()) ?? [])
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
            let engine = (try? dependencies?.resolve(settings.mountEngine)) ?? .nfs
            update(d.id) {
                $0.phase = .mounted
                $0.pid = info.pid
                $0.engine = engine
                $0.mountPath = MountPathResolver.path(for: d, engine: engine)
            }
            log(d.id, "mount", "Reattached to \(d.name), which kept running while Ekthar Drive was closed.", .info)
        }
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
            }
            var engine = (settings.mountEngine == .automatic && macFUSEUnusable && deps.nfsUsable) ? .nfs : resolved
            let manager = MountManager(paths: paths, supervisor: supervisor, rcloneURL: rclone.binary.url)
            let env = try rclone.environment(extra: extra)
            var mountPath = MountPathResolver.path(for: d, engine: engine)
            let pid: Int32
            do {
                pid = try await manager.mount(MountRequest(drive: d, engine: engine, mountPath: mountPath, environment: env, globals: settings.globals))
            } catch DriveError.dependencyMissing(.macFUSE, let detail) where engine == .macFUSE && settings.mountEngine == .automatic && deps.nfsUsable {
                // macFUSE is installed but cannot mount (e.g. its extension is switched off). Use the built-in engine.
                macFUSEUnusable = true
                log(id, "mount", "macFUSE could not mount (\(detail)) Using the built-in NFS engine instead.", .warning)
                engine = .nfs
                mountPath = MountPathResolver.path(for: d, engine: engine)
                pid = try await manager.mount(MountRequest(drive: d, engine: engine, mountPath: mountPath, environment: env, globals: settings.globals))
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
        let rt = state(id)
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
            let error: DriveError = {
                let classified = ErrorClassifier.classify(output: recent, exitCode: status, host: d.name)
                if case .processExited = classified, status == 0 {
                    return .processExited(code: 0, detail: "The volume was ejected outside Ekthar Drive.")
                }
                return classified
            }()
            update(id) { $0.pid = nil; $0.lastError = error }
            if status == 0, case .processExited = error {
                // Ejected in Finder: respect it, do not remount.
                desiredMounted.remove(id)
                update(id) { $0.phase = .unmounted }
                log(id, "mount", "\(d.name) was ejected.", .info)
                return
            }
            log(id, "process", "\(d.name) stopped unexpectedly: \(error.title).", .error)
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
        diskWarning = cacheManager.diskWarning(minFreeBytes: settings.globals.minFreeSpaceBytes)
        for id in await supervisor.checkAdopted() where desiredMounted.contains(id) {
            if let d = drive(id) { finishStopped(id); scheduleRetryOrFail(d, .processExited(code: -1, detail: "The reattached rclone process stopped.")) }
        }
        var busy = false
        for d in drives where state(d.id).phase.isActive {
            let rc = RcClient(socketPath: paths.rcSocket(for: d.id).path, timeoutSeconds: 5)
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
                let queue = (try? await rc.vfsQueue())?.queue ?? []
                var tracker = trackers[d.id] ?? TransferTracker(driveID: d.id, remoteName: d.remoteName)
                let result = tracker.update(transferring: stats.transferring ?? [], completed: done, queue: queue)
                trackers[d.id] = tracker
                activeTransfers[d.id] = result.active
                for t in result.finished {
                    try? database.upsertTransfer(t)
                    transferHistory.insert(t, at: 0)
                    if t.status == .failed { log(d.id, "transfer", "\(t.direction == .upload ? "Upload" : "Download") of \(t.name) failed: \(t.errorMessage ?? "unknown error")", .error) }
                }
                if transferHistory.count > 500 { transferHistory.removeLast(transferHistory.count - 500) }
                update(d.id) {
                    $0.cache = cache
                    if case .rcUnavailable = $0.lastError { $0.lastError = nil }
                    if cache.outOfSpace { $0.lastError = .cacheFull }
                }
                if !result.active.isEmpty || cache.pendingUploads > 0 { busy = true }
                if lastUsageRefresh[d.id].map({ Date().timeIntervalSince($0) > 300 }) ?? true {
                    lastUsageRefresh[d.id] = Date()
                    if let about = try? await rc.about(fs: d.remoteSpec) { update(d.id) { $0.usage = about.usage } }
                }
            } catch let e {
                update(d.id) { $0.lastError = e }
            }
        }
        return busy
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
