import DailyDiskCore
import Foundation

public struct StoredVolumeStatus: Codable, Equatable, Sendable {
    public let volumeID: String
    public let name: String
    public let role: String
    public let inventoryMode: String
    public let mountPath: String?
    public let lastEventID: UInt64?
    public let lastIncrementalAt: Date?
    public let lastFullAt: Date?
    public let indexedObjectCount: Int64
}

public struct DatabaseVerification: Codable, Equatable, Sendable {
    public let integrityCheck: String
    public let foreignKeyViolationCount: Int
    public let invariantViolationCount: Int
    public let abandonedRunCount: Int
    public let schemaVersion: Int
    public let expectedSchemaVersion: Int
    public let reportPayloadViolationCount: Int
    public let writerIsActive: Bool

    public var isHealthy: Bool {
        integrityCheck == "ok"
            && foreignKeyViolationCount == 0
            && invariantViolationCount == 0
            && abandonedRunCount == 0
            && schemaVersion == expectedSchemaVersion
            && reportPayloadViolationCount == 0
    }
}

public struct DatabaseWriterState: Codable, Equatable, Sendable {
    public let leaseIsHeld: Bool
    public let activeRuns: [ScanRun]

    public init(leaseIsHeld: Bool, activeRuns: [ScanRun]) {
        self.leaseIsHeld = leaseIsHeld
        self.activeRuns = activeRuns
    }

    public var hasOrphanedRuns: Bool {
        !activeRuns.isEmpty && !leaseIsHeld
    }
}

public struct DatabaseDiagnostics: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let tableCounts: [String: Int64]
    public let databaseBytes: Int64
    public let walBytes: Int64
}

public final class DatabaseResetLease: @unchecked Sendable {
    private let lease: StableDataLease

    public init(databaseURL: URL = SQLiteInventoryStore.defaultDatabaseURL) throws {
        lease = try StableDataLease(
            databaseURL: databaseURL,
            exclusive: true,
            create: true
        )
    }
}

public actor SQLiteReportStore {
    /// A full only satisfies daily work after its report was durably published.
    /// Its day is the actual inventory completion day, not a delayed publication day.
    /// Query full/recovery rows, not the latest run: later failures or increments
    /// must not erase a successful full.
    public func latestSuccessfulFullReportDate(for storageDomainID: StorageDomain.ID) throws -> Date? {
        let statement = try database.prepare(
            """
            SELECT MAX(r.inventory_completed_at) FROM daily_reports d
            JOIN scan_runs r ON r.id = d.run_id
            WHERE d.storage_domain_id = ? AND r.status = 'succeeded' AND r.kind IN ('full','recovery')
            """)
        try statement.bind(storageDomainID.rawValue, at: 1)
        guard try statement.step(), !statement.columnIsNull(0) else { return nil }
        return Date(timeIntervalSince1970: statement.columnDouble(0))
    }

    public static func writerIsActive(
        databaseURL: URL = SQLiteInventoryStore.defaultDatabaseURL
    ) -> Bool {
        ProcessLease.isWriterActive(databaseURL: databaseURL)
    }

    private let readLease: ProcessReadLease?
    private let stableReadLease: StableDataLease?
    private let isStrictReadOnly: Bool
    private let database: SQLiteDatabase
    private let decoder = JSONDecoder()

    public init(
        databaseURL: URL = SQLiteInventoryStore.defaultDatabaseURL,
        strictReadOnly: Bool = false
    ) throws {
        isStrictReadOnly = strictReadOnly
        if strictReadOnly {
            readLease = try ProcessReadLease(databaseURL: databaseURL)
            stableReadLease = nil
            database = try SQLiteDatabase(url: databaseURL, readOnly: true, immutable: true)
        } else {
            readLease = nil
            stableReadLease = try StableDataLease(
                databaseURL: databaseURL,
                exclusive: false,
                create: false
            )
            database = try SQLiteDatabase(url: databaseURL, readOnly: true)
        }
    }

    public func latestReport(for storageDomainID: StorageDomain.ID) async throws -> DailyReport? {
        let statement = try database.prepare(
            """
            SELECT run_id, storage_domain_id, payload_json FROM daily_reports
            WHERE storage_domain_id = ?
            ORDER BY generated_at DESC, run_id DESC
            LIMIT 1
            """
        )
        try statement.bind(storageDomainID.rawValue, at: 1)
        guard try statement.step() else { return nil }
        return try decodeReportRow(statement)
    }

    public func report(
        runID: ScanRun.ID,
        storageDomainID: StorageDomain.ID
    ) async throws -> DailyReport? {
        let statement = try database.prepare(
            """
            SELECT run_id, storage_domain_id, payload_json FROM daily_reports
            WHERE run_id = ? AND storage_domain_id = ?
            """
        )
        try statement.bind(runID.rawValue.uuidString, at: 1)
        try statement.bind(storageDomainID.rawValue, at: 2)
        guard try statement.step() else { return nil }
        return try decodeReportRow(statement)
    }

    public func report(runID: ScanRun.ID) async throws -> DailyReport? {
        let statement = try database.prepare(
            """
            SELECT run_id, storage_domain_id, payload_json FROM daily_reports
            WHERE run_id = ? ORDER BY storage_domain_id LIMIT 1
            """
        )
        try statement.bind(runID.rawValue.uuidString, at: 1)
        guard try statement.step() else { return nil }
        return try decodeReportRow(statement)
    }

    public func recentReports(limit: Int = 30) async throws -> [DailyReport] {
        guard limit > 0 else { return [] }
        let statement = try database.prepare(
            """
            SELECT run_id, storage_domain_id, payload_json FROM daily_reports
            ORDER BY generated_at DESC, run_id DESC LIMIT ?
            """
        )
        try statement.bind(Int64(limit), at: 1)
        var reports: [DailyReport] = []
        while try statement.step() { reports.append(try decodeReportRow(statement)) }
        return reports
    }

    public func reportHistory(
        for storageDomainID: StorageDomain.ID,
        limit: Int = 30
    ) async throws -> [DailyReport] {
        guard limit > 0 else { return [] }
        let statement = try database.prepare(
            """
            SELECT run_id, storage_domain_id, payload_json FROM daily_reports
            WHERE storage_domain_id = ?
            ORDER BY generated_at DESC, run_id DESC
            LIMIT ?
            """
        )
        try statement.bind(storageDomainID.rawValue, at: 1)
        try statement.bind(Int64(limit), at: 2)
        var reports: [DailyReport] = []
        while try statement.step() { reports.append(try decodeReportRow(statement)) }
        return reports
    }

    public func recentRuns(limit: Int = 30) async throws -> [ScanRun] {
        guard limit > 0 else { return [] }
        let statement = try database.prepare(
            """
            SELECT id, kind, reason, status, started_at, finished_at, error_count
            FROM scan_runs
            ORDER BY started_at DESC
            LIMIT ?
            """
        )
        try statement.bind(Int64(limit), at: 1)
        var runs: [ScanRun] = []
        while try statement.step() {
            runs.append(try decodeScanRun(statement))
        }
        return runs
    }

    public func volumeStatuses() async throws -> [StoredVolumeStatus] {
        let statement = try database.prepare(
            """
            SELECT v.id, v.display_name, v.role, v.inventory_mode, v.mount_path,
                   c.last_committed_event_id, c.last_successful_incremental_at,
                   c.last_successful_full_scan_at,
                   COALESCE((
                       SELECT COUNT(*) FROM inventory_objects o
                       WHERE o.generation_id = c.active_generation_id
                   ), 0)
            FROM volumes v
            LEFT JOIN checkpoints c ON c.volume_id = v.id
            ORDER BY v.storage_domain_id, v.role, v.id
            """
        )
        var result: [StoredVolumeStatus] = []
        while try statement.step() {
            guard let id = statement.columnText(0),
                let name = statement.columnText(1),
                let role = statement.columnText(2),
                let mode = statement.columnText(3)
            else { throw StoreInvariantError.corruptStoredValue("volume status") }
            result.append(
                StoredVolumeStatus(
                    volumeID: id,
                    name: name,
                    role: role,
                    inventoryMode: mode,
                    mountPath: statement.columnText(4),
                    lastEventID: statement.columnIsNull(5)
                        ? nil : UInt64(bitPattern: statement.columnInt64(5)),
                    lastIncrementalAt: statement.columnIsNull(6)
                        ? nil : Date(timeIntervalSince1970: statement.columnDouble(6)),
                    lastFullAt: statement.columnIsNull(7)
                        ? nil : Date(timeIntervalSince1970: statement.columnDouble(7)),
                    indexedObjectCount: statement.columnInt64(8)
                )
            )
        }
        return result
    }

    public func writerState() async throws -> DatabaseWriterState {
        // If no writer owns the lease, this shared probe remains held through
        // the query so a writer cannot start between the two observations.
        let probe = try ProcessWriterProbe(databaseURL: database.url)
        let statement = try database.prepare(
            """
            SELECT id, kind, reason, status, started_at, finished_at, error_count
            FROM scan_runs WHERE status = 'running'
            ORDER BY started_at DESC, id DESC
            """
        )
        var activeRuns: [ScanRun] = []
        while try statement.step() {
            activeRuns.append(try decodeScanRun(statement))
        }
        return DatabaseWriterState(
            leaseIsHeld: probe.writerIsActive,
            activeRuns: activeRuns
        )
    }

    public func verify() async throws -> DatabaseVerification {
        let integrity = try database.scalarText("PRAGMA integrity_check") ?? "missing result"
        let foreignKeys = try rowCount(sql: "PRAGMA foreign_key_check")
        let schemaVersion = Int(try database.scalarInt64("PRAGMA user_version") ?? 0)
        let hasMetadata =
            try database.scalarInt64(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'schema_metadata'"
            ) == 1
        var schemaValid = false
        if hasMetadata {
            let metadata = try database.prepare("SELECT version, name FROM schema_metadata ORDER BY version")
            var rows: [(Int, String)] = []
            while try metadata.step() {
                guard let name = metadata.columnText(1) else { continue }
                rows.append((Int(metadata.columnInt64(0)), name))
            }
            schemaValid =
                rows.elementsEqual(DailyDiskSchema.expectedMigrations) {
                    $0.0 == $1.version && $0.1 == $1.name
                } && schemaVersion == DailyDiskSchema.currentVersion
        }
        let writerIsActive =
            isStrictReadOnly
            ? false
            : ProcessLease.isWriterActive(databaseURL: database.url)
        guard schemaValid else {
            return DatabaseVerification(
                integrityCheck: integrity,
                foreignKeyViolationCount: foreignKeys,
                invariantViolationCount: 1,
                abandonedRunCount: 0,
                schemaVersion: schemaVersion,
                expectedSchemaVersion: DailyDiskSchema.currentVersion,
                reportPayloadViolationCount: 0,
                writerIsActive: writerIsActive
            )
        }

        var invariants = Int(
            try database.scalarInt64(
                """
                SELECT
                  (SELECT COUNT(*) FROM checkpoints c
                   JOIN inventory_generations g ON g.id = c.active_generation_id
                   WHERE g.volume_id != c.volume_id OR g.state != 'active')
                + (SELECT COUNT(*) FROM inventory_generations g
                   WHERE g.state = 'active'
                     AND NOT EXISTS (SELECT 1 FROM checkpoints c WHERE c.active_generation_id = g.id))
                """
            ) ?? 0
        )
        if schemaVersion >= 6 { invariants += try database.verifyHybridOrdering() }
        let running = Int(
            try database.scalarInt64("SELECT COUNT(*) FROM scan_runs WHERE status = 'running'") ?? 0
        )
        return DatabaseVerification(
            integrityCheck: integrity,
            foreignKeyViolationCount: foreignKeys,
            invariantViolationCount: invariants,
            abandonedRunCount: writerIsActive ? 0 : running,
            schemaVersion: schemaVersion,
            expectedSchemaVersion: DailyDiskSchema.currentVersion,
            reportPayloadViolationCount: try reportPayloadViolationCount(),
            writerIsActive: writerIsActive
        )
    }

    public func spaceUsage() throws -> DatabaseSpaceUsage {
        try database.spaceUsage()
    }

    public func diagnostics() async throws -> DatabaseDiagnostics {
        let tables = [
            "schema_metadata", "storage_domains", "volumes", "scan_runs", "scan_summaries",
            "inventory_generations", "inventory_objects", "inventory_paths", "canonical_attributions",
            "checkpoints", "run_targets", "run_object_mutations", "run_mutations",
            "run_canonical_attributions", "change_ledger", "storage_samples", "overhead_samples",
            "snapshot_observations", "snapshot_samples", "daily_reports", "scan_errors", "settings",
        ]
        var counts: [String: Int64] = [:]
        for table in tables {
            counts[table] = try database.scalarInt64("SELECT COUNT(*) FROM \(table)") ?? 0
        }
        return DatabaseDiagnostics(
            schemaVersion: Int(try database.scalarInt64("PRAGMA user_version") ?? 0),
            tableCounts: counts,
            databaseBytes: fileSize(database.url),
            walBytes: fileSize(URL(fileURLWithPath: database.url.path + "-wal"))
        )
    }

    public func errors(for runID: ScanRun.ID) async throws -> [ScanErrorRecord] {
        let statement = try database.prepare(
            """
            SELECT volume_id, kind, path, error_code, message
            FROM scan_errors
            WHERE run_id = ?
            ORDER BY id
            """
        )
        try statement.bind(runID.rawValue.uuidString, at: 1)
        var errors: [ScanErrorRecord] = []
        while try statement.step() {
            guard let kindString = statement.columnText(1),
                let kind = ScanErrorRecord.Kind(rawValue: kindString),
                let message = statement.columnText(4)
            else {
                throw StoreInvariantError.corruptStoredValue("scan error")
            }
            let path: RelativePath?
            if let bytes = statement.columnData(2) {
                path = try RelativePath(validating: bytes)
            } else {
                path = nil
            }
            errors.append(
                ScanErrorRecord(
                    runID: runID,
                    volumeID: statement.columnText(0).map(MonitoredVolume.ID.init),
                    kind: kind,
                    path: path,
                    errorCode: statement.columnIsNull(3) ? nil : Int32(statement.columnInt64(3)),
                    message: message
                )
            )
        }
        return errors
    }

    private func decodeScanRun(_ statement: SQLiteStatement) throws -> ScanRun {
        guard let idString = statement.columnText(0),
            let id = UUID(uuidString: idString),
            let kindString = statement.columnText(1),
            let kind = ScanRun.Kind(rawValue: kindString),
            let reasonString = statement.columnText(2),
            let reason = ScanRun.Reason(rawValue: reasonString),
            let statusString = statement.columnText(3),
            let status = ScanRun.Status(rawValue: statusString)
        else {
            throw StoreInvariantError.corruptStoredValue("scan run")
        }
        return ScanRun(
            id: ScanRun.ID(id),
            kind: kind,
            reason: reason,
            status: status,
            startedAt: Date(timeIntervalSince1970: statement.columnDouble(4)),
            finishedAt: statement.columnIsNull(5)
                ? nil : Date(timeIntervalSince1970: statement.columnDouble(5)),
            errorCount: Int(statement.columnInt64(6))
        )
    }

    private func decodeReportRow(_ statement: SQLiteStatement) throws -> DailyReport {
        guard let runString = statement.columnText(0),
            let runUUID = UUID(uuidString: runString),
            let domain = statement.columnText(1),
            let payload = statement.columnData(2)
        else { throw StoreInvariantError.corruptStoredValue("report row") }
        let report = try decoder.decode(DailyReport.self, from: payload)
        guard report.runID == ScanRun.ID(runUUID),
            report.storageDomainID == StorageDomain.ID(domain)
        else { throw StoreInvariantError.corruptStoredValue("report payload identity") }
        return report
    }

    private func reportPayloadViolationCount() throws -> Int {
        let statement = try database.prepare(
            """
            SELECT run_id, storage_domain_id, generated_at,
                   event_attributed_delta, reconciliation_correction,
                   reconciled_indexed_delta, dailydisk_overhead_delta,
                   physical_used_delta, physical_unattributed_delta, payload_json, snapshot_compared_delta
            FROM daily_reports
            """
        )
        var violations = 0
        while try statement.step() {
            guard let runString = statement.columnText(0),
                let runUUID = UUID(uuidString: runString),
                let domain = statement.columnText(1),
                let payload = statement.columnData(9),
                let report = try? decoder.decode(DailyReport.self, from: payload)
            else {
                violations += 1
                continue
            }
            let accounting = report.accounting
            let physicalUsedDelta = optionalInt64(statement, column: 7)
            let physicalUnattributedDelta = optionalInt64(statement, column: 8)
            let matches =
                report.runID == ScanRun.ID(runUUID)
                && report.storageDomainID == StorageDomain.ID(domain)
                && report.generatedAt.timeIntervalSince1970 == statement.columnDouble(2)
                && accounting.snapshotComparedDelta == statement.columnInt64(10)
                && accounting.eventAttributedDelta == statement.columnInt64(3)
                && accounting.reconciliationCorrection == statement.columnInt64(4)
                && accounting.reconciledIndexedDelta == statement.columnInt64(5)
                && accounting.dailyDiskOverheadDelta == statement.columnInt64(6)
                && physicalUsedDelta == accounting.physicalUsedDelta
                && physicalUnattributedDelta == accounting.physicalUnattributedDelta
            if !matches { violations += 1 }
        }
        return violations
    }

    private func optionalInt64(_ statement: SQLiteStatement, column: Int32) -> Int64? {
        statement.columnIsNull(column) ? nil : statement.columnInt64(column)
    }

    private func rowCount(sql: String) throws -> Int {
        let statement = try database.prepare(sql)
        var count = 0
        while try statement.step() { count += 1 }
        return count
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
