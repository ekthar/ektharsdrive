import Foundation

/// Schema migrations + repositories. Secrets are never stored here (Keychain / encrypted rclone.conf only).
public final class AppDatabase: @unchecked Sendable {
    public let db: SQLiteDatabase
    /// Set when a corrupt database was moved aside during open.
    public private(set) var recoveredFrom: URL?

    static let migrations: [String] = [
        // v1
        """
        CREATE TABLE drives (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            provider TEXT NOT NULL,
            remote_name TEXT NOT NULL,
            remote_path TEXT NOT NULL DEFAULT '',
            mount_path TEXT,
            enabled INTEGER NOT NULL DEFAULT 1,
            auto_mount INTEGER NOT NULL DEFAULT 0,
            cache_limit INTEGER NOT NULL,
            status TEXT NOT NULL DEFAULT 'unmounted',
            config_json TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE transfers (
            id TEXT PRIMARY KEY,
            drive_id TEXT NOT NULL,
            source_path TEXT NOT NULL,
            destination_path TEXT NOT NULL,
            direction TEXT NOT NULL,
            total_bytes INTEGER,
            transferred_bytes INTEGER NOT NULL DEFAULT 0,
            speed REAL,
            status TEXT NOT NULL,
            started_at REAL NOT NULL,
            completed_at REAL,
            error_message TEXT
        );
        CREATE INDEX transfers_started ON transfers(started_at DESC);
        CREATE TABLE activity (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            drive_id TEXT,
            event_type TEXT NOT NULL,
            message TEXT NOT NULL,
            severity TEXT NOT NULL,
            timestamp REAL NOT NULL
        );
        CREATE INDEX activity_time ON activity(timestamp DESC);
        CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        """,
        // v2: non-secret SFTP connection details
        """
        CREATE TABLE sftp_connections (
            drive_id TEXT PRIMARY KEY,
            host TEXT NOT NULL,
            port INTEGER NOT NULL,
            username TEXT NOT NULL,
            private_key_path TEXT NOT NULL,
            key_has_passphrase INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL
        );
        """,
    ]

    public static var schemaVersion: Int { migrations.count }

    /// Opens (creating if needed) and migrates. A database that fails to open or fails `integrity_check`
    /// is renamed to `*.corrupt-<timestamp>` (never deleted) and a fresh one is created.
    public init(url: URL) throws {
        do {
            let opened = try SQLiteDatabase(url: url)
            guard opened.integrityCheck() else { throw DatabaseError.corrupt("integrity_check failed") }
            db = opened
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = url.appendingPathExtension("corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: url, to: aside)
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.moveItem(atPath: url.path + suffix, toPath: aside.path + suffix)
            }
            recoveredFrom = aside
            db = try SQLiteDatabase(url: url)
        }
        try migrate()
    }

    private func migrate() throws {
        let current = db.userVersion
        guard current < Self.migrations.count else { return }
        for version in current..<Self.migrations.count {
            try db.transaction {
                for statement in Self.migrations[version].components(separatedBy: ";\n") {
                    let sql = statement.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sql.isEmpty { try db.execute(sql) }
                }
                try db.execute("PRAGMA user_version = \(version + 1)")
            }
        }
    }

    // MARK: Drives

    public func saveDrive(_ d: DriveConfiguration, status: String = "unmounted") throws {
        let json = String(decoding: try JSONEncoder().encode(d), as: UTF8.self)
        try db.execute("""
            INSERT INTO drives (id, name, provider, remote_name, remote_path, mount_path, enabled, auto_mount, cache_limit, status, config_json, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, provider=excluded.provider, remote_name=excluded.remote_name,
              remote_path=excluded.remote_path, mount_path=excluded.mount_path, enabled=excluded.enabled, auto_mount=excluded.auto_mount,
              cache_limit=excluded.cache_limit, config_json=excluded.config_json, updated_at=excluded.updated_at
            """, [.text(d.id), .text(d.name), .text(d.provider.rawValue), .text(d.remoteName), .text(d.remotePath),
                  d.mountPath.map(SQLiteValue.text) ?? .null, .integer(d.enabled ? 1 : 0), .integer(d.autoMount ? 1 : 0),
                  .integer(d.cache.maxSizeBytes), .text(status), .text(json),
                  .real(d.createdAt.timeIntervalSince1970), .real(Date().timeIntervalSince1970)])
    }

    /// Removes a drive's settings row. Its transfer and activity history is kept.
    public func deleteDrive(_ id: String) throws {
        try db.execute("DELETE FROM drives WHERE id=?", [.text(id)])
    }

    public func setDriveStatus(_ id: String, _ status: String) throws {
        try db.execute("UPDATE drives SET status=?, updated_at=? WHERE id=?", [.text(status), .real(Date().timeIntervalSince1970), .text(id)])
    }

    public func drives() throws -> [DriveConfiguration] {
        try db.query("SELECT config_json FROM drives ORDER BY created_at, id").compactMap { row in
            guard let json = row["config_json"]?.string else { return nil }
            return try? JSONDecoder().decode(DriveConfiguration.self, from: Data(json.utf8))
        }
    }

    public func driveStatus(_ id: String) throws -> String? {
        try db.query("SELECT status FROM drives WHERE id=?", [.text(id)]).first?["status"]?.string
    }

    // MARK: SFTP

    public func saveSFTP(_ c: SFTPConnection, driveID: String) throws {
        try db.execute("""
            INSERT INTO sftp_connections (drive_id, host, port, username, private_key_path, key_has_passphrase, updated_at)
            VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(drive_id) DO UPDATE SET host=excluded.host, port=excluded.port, username=excluded.username,
              private_key_path=excluded.private_key_path, key_has_passphrase=excluded.key_has_passphrase, updated_at=excluded.updated_at
            """, [.text(driveID), .text(c.host), .integer(Int64(c.port)), .text(c.username), .text(c.privateKeyPath),
                  .integer(c.keyHasPassphrase ? 1 : 0), .real(Date().timeIntervalSince1970)])
    }

    public func sftp(driveID: String) throws -> SFTPConnection? {
        guard let r = try db.query("SELECT * FROM sftp_connections WHERE drive_id=?", [.text(driveID)]).first else { return nil }
        return SFTPConnection(host: r["host"]?.string ?? "", port: Int(r["port"]?.int ?? 22), username: r["username"]?.string ?? "",
                              privateKeyPath: r["private_key_path"]?.string ?? "", keyHasPassphrase: (r["key_has_passphrase"]?.int ?? 0) != 0)
    }

    public func deleteSFTP(driveID: String) throws {
        try db.execute("DELETE FROM sftp_connections WHERE drive_id=?", [.text(driveID)])
    }

    // MARK: Transfers

    public func upsertTransfer(_ t: Transfer) throws {
        try db.execute("""
            INSERT INTO transfers (id, drive_id, source_path, destination_path, direction, total_bytes, transferred_bytes, speed, status, started_at, completed_at, error_message)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET total_bytes=excluded.total_bytes, transferred_bytes=excluded.transferred_bytes,
              speed=excluded.speed, status=excluded.status, completed_at=excluded.completed_at, error_message=excluded.error_message
            """, [.text(t.id.uuidString), .text(t.driveID), .text(t.sourcePath), .text(t.destinationPath), .text(t.direction.rawValue),
                  t.totalBytes.map(SQLiteValue.integer) ?? .null, .integer(t.transferredBytes), t.speed.map(SQLiteValue.real) ?? .null,
                  .text(t.status.rawValue), .real(t.startedAt.timeIntervalSince1970),
                  t.completedAt.map { .real($0.timeIntervalSince1970) } ?? .null, t.errorMessage.map(SQLiteValue.text) ?? .null])
    }

    public func recentTransfers(limit: Int = 200) throws -> [Transfer] {
        try db.query("SELECT * FROM transfers ORDER BY started_at DESC LIMIT ?", [.integer(Int64(limit))]).compactMap { r in
            guard let id = r["id"]?.string.flatMap(UUID.init(uuidString:)) else { return nil }
            let src = r["source_path"]?.string ?? ""
            return Transfer(id: id, driveID: r["drive_id"]?.string ?? "", name: (src as NSString).lastPathComponent,
                            sourcePath: src, destinationPath: r["destination_path"]?.string ?? "",
                            direction: TransferDirection(rawValue: r["direction"]?.string ?? "") ?? .upload,
                            totalBytes: r["total_bytes"]?.int, transferredBytes: r["transferred_bytes"]?.int ?? 0,
                            speed: r["speed"]?.double, status: TransferStatus(rawValue: r["status"]?.string ?? "") ?? .failed,
                            startedAt: Date(timeIntervalSince1970: r["started_at"]?.double ?? 0),
                            completedAt: r["completed_at"]?.double.map(Date.init(timeIntervalSince1970:)),
                            errorMessage: r["error_message"]?.string)
        }
    }

    /// Transfers still marked running from a previous app run cannot be observed any more.
    public func markStaleTransfersInterrupted() throws {
        try db.execute("UPDATE transfers SET status='failed', error_message='Ekthar Drive stopped observing this transfer (app quit or crashed). rclone retries pending uploads from its cache.' WHERE status IN ('running','queued','waiting')")
    }

    public func pruneTransfers(keep: Int = 2000) throws {
        try db.execute("DELETE FROM transfers WHERE id NOT IN (SELECT id FROM transfers ORDER BY started_at DESC LIMIT ?)", [.integer(Int64(keep))])
    }

    // MARK: Activity

    @discardableResult
    public func addActivity(_ e: ActivityEvent) throws -> Int64 {
        try db.execute("INSERT INTO activity (drive_id, event_type, message, severity, timestamp) VALUES (?,?,?,?,?)",
                       [e.driveID.map(SQLiteValue.text) ?? .null, .text(e.eventType), .text(Redactor.redact(e.message)),
                        .text(e.severity.rawValue), .real(e.timestamp.timeIntervalSince1970)])
        return db.lastInsertRowID
    }

    public func activity(limit: Int = 500, driveID: String? = nil, minimumSeverity: Severity? = nil, search: String? = nil) throws -> [ActivityEvent] {
        var clauses: [String] = [], params: [SQLiteValue] = []
        if let driveID { clauses.append("drive_id = ?"); params.append(.text(driveID)) }
        if let minimumSeverity {
            let allowed = Severity.allCases.filter { $0 >= minimumSeverity }.map { "'\($0.rawValue)'" }.joined(separator: ",")
            clauses.append("severity IN (\(allowed))")
        }
        if let search, !search.isEmpty {
            clauses.append("message LIKE ? ESCAPE '\\'")
            let escaped = search.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            params.append(.text("%\(escaped)%"))
        }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        params.append(.integer(Int64(limit)))
        return try db.query("SELECT * FROM activity \(whereSQL) ORDER BY timestamp DESC, id DESC LIMIT ?", params).map { r in
            ActivityEvent(id: r["id"]?.int, driveID: r["drive_id"]?.string, eventType: r["event_type"]?.string ?? "",
                          message: r["message"]?.string ?? "", severity: Severity(rawValue: r["severity"]?.string ?? "") ?? .info,
                          timestamp: Date(timeIntervalSince1970: r["timestamp"]?.double ?? 0))
        }
    }

    public func pruneActivity(keep: Int = 5000) throws {
        try db.execute("DELETE FROM activity WHERE id NOT IN (SELECT id FROM activity ORDER BY timestamp DESC LIMIT ?)", [.integer(Int64(keep))])
    }

    // MARK: Settings

    public func setting(_ key: String) -> String? {
        (try? db.query("SELECT value FROM settings WHERE key=?", [.text(key)]).first?["value"]?.string) ?? nil
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try db.execute("INSERT INTO settings (key, value, updated_at) VALUES (?,?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
                       [.text(key), .text(value), .real(Date().timeIntervalSince1970)])
    }
}
