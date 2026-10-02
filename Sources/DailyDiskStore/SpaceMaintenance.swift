import CryptoKit
import DailyDiskCore
import Darwin
import Foundation

public struct DatabaseSpaceUsage: Equatable, Sendable {
    public let allocatedBytes: Int64
    public let databaseBytes: Int64
    public let reusableBytes: Int64
    public let maintenanceStatus: String?
    public let lastMaintenanceAt: Date?
    public let lastReclaimedBytes: Int64?
}

public enum SpaceMaintenanceError: Error, Equatable, Sendable {
    case recoveryPending
    case insufficientSpace
    case verificationFailed
    case interrupted
}

public struct SpaceMaintenancePolicy: Sendable {
    public let recoveryWindow: TimeInterval
    public let minimumFreeBytes: Int64
    public let minimumFreeFraction: Double
    public let cooldown: TimeInterval
    public let spaceReserve: Int64

    public init() {
        recoveryWindow = 24 * 60 * 60
        minimumFreeBytes = 1_000_000_000
        minimumFreeFraction = 0.25
        cooldown = 7 * 24 * 60 * 60
        spaceReserve = 1_000_000_000
    }

    public func shouldCompact(usage: DatabaseSpaceUsage, lastAttempt: Date?, now: Date) -> Bool {
        usage.reusableBytes > minimumFreeBytes
            && Double(usage.reusableBytes) > Double(usage.databaseBytes) * minimumFreeFraction
            && (lastAttempt.map { now.timeIntervalSince($0) >= cooldown } ?? true)
    }
}

extension SQLiteInventoryStore {
    /// No inventory, report, ledger or checkpoint is rewritten by the maintenance protocol.
    /// The writer lease remains held throughout native SQLite recovery and VACUUM.
    public func maintainSpace(
        at now: Date = Date(),
        force: Bool = false,
        observer: any ScanProgressTracking = NoopScanProgressTracker(),
        availableBytes: (@Sendable () throws -> Int64)? = nil
    ) async throws {
        if let status = try database.scalarText("SELECT status FROM space_maintenance WHERE singleton = 1"),
            status == "running" || status == "failed"
        {
            try await observer.transition(to: .verifyingMaintenance, mode: nil)
            try recoverSpaceMaintenance()
            try await observer.transition(to: .preparing, mode: nil)
        }
        guard try maintenanceIsIdle() else {
            if force { throw SpaceMaintenanceError.recoveryPending }
            return
        }
        let hasReuseHistory = try database.scalarInt64("SELECT EXISTS(SELECT 1 FROM inventory_reuse_history)") == 1
        if hasReuseHistory { try await observer.transition(to: .cleaningRetiredInventory, mode: nil) }
        try pruneReuseHistory(at: now)
        let policy = SpaceMaintenancePolicy()
        let initialUsage = try database.spaceUsage()
        let expired = try retirementCandidates(at: now, window: policy.recoveryWindow)
        if !expired.isEmpty {
            try await observer.transition(to: .cleaningRetiredInventory, mode: nil)
            try pruneRetiredGenerations(at: now)
        }
        try database.collectHybridNodes()
        let usage = try database.spaceUsage()
        let lastAttempt = try database.scalarDouble("SELECT attempted_at FROM space_maintenance WHERE singleton = 1")
            .map(Date.init(timeIntervalSince1970:))
        guard force || policy.shouldCompact(usage: usage, lastAttempt: lastAttempt, now: now) else {
            if !expired.isEmpty || hasReuseHistory { try await observer.transition(to: .preparing, mode: nil) }
            return
        }
        let available: Int64
        if let availableBytes {
            available = try availableBytes()
        } else {
            var info = statfs()
            guard statfs(database.url.deletingLastPathComponent().path, &info) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            available = try AccountingMath.multiply(Int64(info.f_bavail), Int64(info.f_bsize))
        }
        // SQLite VACUUM can need twice the original file size in additional space.
        let required = try AccountingMath.add(
            AccountingMath.multiply(usage.databaseBytes, 2), policy.spaceReserve
        )
        guard available >= required else {
            try recordMaintenance(status: "insufficientSpace", at: now, before: initialUsage.allocatedBytes)
            if force { throw SpaceMaintenanceError.insufficientSpace }
            if !expired.isEmpty { try await observer.transition(to: .preparing, mode: nil) }
            return
        }
        try await observer.transition(to: .reclaimingSpace, mode: nil)
        guard try maintenanceIsIdle() else { throw SpaceMaintenanceError.recoveryPending }
        try recordMaintenance(status: "running", at: now, before: initialUsage.allocatedBytes)
        do {
            try verifyMaintenanceDatabase()
            let basis = try maintenanceBasis()
            // No open statement/transaction spans VACUUM. Native SQLite provides
            // transactional rollback on interruption; we never swap database files.
            try database.execute("VACUUM")
            try database.checkpointWAL()
            try await observer.transition(to: .verifyingMaintenance, mode: nil)
            try verifyMaintenanceDatabase()
            guard try basis == maintenanceBasis() else { throw SpaceMaintenanceError.verificationFailed }
            let after = try database.spaceUsage().allocatedBytes
            try database.transaction {
                let statement = try database.prepare(
                    """
                    UPDATE space_maintenance SET status = 'completed', completed_at = ?, after_bytes = ?,
                        last_success_at = ?, last_reclaimed_bytes = ? WHERE singleton = 1
                    """
                )
                let finished = Date().timeIntervalSince1970
                try statement.bind(finished, at: 1)
                try statement.bind(after, at: 2)
                try statement.bind(finished, at: 3)
                try statement.bind(try AccountingMath.subtract(initialUsage.allocatedBytes, after), at: 4)
                _ = try statement.step()
            }
        } catch {
            try? database.transaction {
                try database.execute("UPDATE space_maintenance SET status = 'failed' WHERE singleton = 1")
            }
            throw error
        }
        if !force { try await observer.transition(to: .preparing, mode: nil) }
    }

    public func recoverSpaceMaintenance(verifyRegardless: Bool = false) throws {
        let status = try database.scalarText("SELECT status FROM space_maintenance WHERE singleton = 1")
        guard verifyRegardless || status == "running" || status == "failed" else { return }
        // SQLite has opened/recovered its transaction before this query. Never
        // automatically retry an interrupted compaction; validate before scanning.
        try verifyMaintenanceDatabase()
        try database.transaction {
            try database.execute(
                "UPDATE space_maintenance SET status = 'interrupted' WHERE singleton = 1 AND status IN ('running', 'failed')"
            )
        }
    }

    public func pruneRetiredGenerations(at now: Date = Date()) throws {
        guard try maintenanceIsIdle() else { return }
        try pruneReuseHistory(at: now)
        let candidates = try retirementCandidates(at: now, window: SpaceMaintenancePolicy().recoveryWindow)
        guard !candidates.isEmpty else { return }
        try database.transaction {
            for id in candidates {
                let deletion = try database.prepare(
                    "DELETE FROM inventory_generations WHERE id = ? AND state = 'retired'")
                try deletion.bind(id, at: 1)
                _ = try deletion.step()
            }
        }
    }

    private func retirementCandidates(at now: Date, window: TimeInterval) throws -> [String] {
        let query = try database.prepare(
            """
            SELECT g.id FROM inventory_generations g
            WHERE g.state = 'retired' AND g.retired_at IS NOT NULL
              AND (g.retired_at <= ? OR g.id != (
                  SELECT r.id FROM inventory_generations r
                  WHERE r.volume_id = g.volume_id AND r.state = 'retired'
                  ORDER BY r.retired_at DESC, r.created_at DESC, r.id DESC LIMIT 1))
              AND NOT EXISTS (SELECT 1 FROM inventory_reuse_history h WHERE h.generation_id = g.id)
              AND NOT EXISTS (SELECT 1 FROM run_targets t WHERE t.base_generation_id = g.id)
              AND NOT EXISTS (SELECT 1 FROM checkpoints c WHERE c.active_generation_id = g.id)
              AND EXISTS (
                  SELECT 1 FROM checkpoints c
                  JOIN inventory_generations a ON a.id = c.active_generation_id AND a.state = 'active'
                  JOIN scan_runs s ON s.id = a.created_by_run_id AND s.status = 'succeeded'
                  JOIN volumes v ON v.id = a.volume_id
                  JOIN daily_reports d ON d.run_id = s.id AND d.storage_domain_id = v.storage_domain_id
                  WHERE c.volume_id = g.volume_id)
            """
        )
        try query.bind(now.addingTimeInterval(-window).timeIntervalSince1970, at: 1)
        var ids: [String] = []
        while try query.step() { if let id = query.columnText(0) { ids.append(id) } }
        return ids
    }

    private func maintenanceIsIdle() throws -> Bool {
        try database.scalarInt64(
            """
            SELECT NOT EXISTS (SELECT 1 FROM scan_runs WHERE status = 'running')
              AND NOT EXISTS (SELECT 1 FROM run_targets)
              AND NOT EXISTS (SELECT 1 FROM inventory_generations WHERE state = 'staging')
              AND NOT EXISTS (
                SELECT 1 FROM storage_samples s JOIN scan_runs r ON r.id = s.run_id
                WHERE r.status = 'succeeded' AND NOT EXISTS (
                  SELECT 1 FROM daily_reports d WHERE d.run_id = s.run_id AND d.storage_domain_id = s.storage_domain_id))
            """
        ) == 1
    }

    private func recordMaintenance(status: String, at now: Date, before: Int64) throws {
        try database.transaction {
            let statement = try database.prepare(
                """
                INSERT INTO space_maintenance(singleton,status,attempted_at,before_bytes) VALUES (1,?,?,?)
                ON CONFLICT(singleton) DO UPDATE SET status=excluded.status, attempted_at=excluded.attempted_at,
                    before_bytes=excluded.before_bytes, after_bytes=NULL, completed_at=NULL
                """
            )
            try statement.bind(status, at: 1)
            try statement.bind(now.timeIntervalSince1970, at: 2)
            try statement.bind(before, at: 3)
            _ = try statement.step()
        }
    }

    private func verifyMaintenanceDatabase() throws {
        guard try database.verifyHybridOrdering() == 0 else {
            throw SpaceMaintenanceError.verificationFailed
        }
        guard try database.scalarText("PRAGMA integrity_check") == "ok" else {
            throw SpaceMaintenanceError.verificationFailed
        }
        let foreignKeys = try database.prepare("PRAGMA foreign_key_check")
        guard try !foreignKeys.step() else { throw SpaceMaintenanceError.verificationFailed }
        guard
            try database.scalarInt64(
                """
                SELECT COUNT(*) FROM checkpoints c JOIN inventory_generations g ON g.id = c.active_generation_id
                WHERE g.state != 'active' OR g.volume_id != c.volume_id
                """
            ) == 0
        else { throw SpaceMaintenanceError.verificationFailed }
    }

    private func maintenanceBasis() throws -> [String] {
        let checkpoints = try database.prepare(
            """
            SELECT volume_id, event_store_uuid, last_committed_event_id, active_generation_id,
                topology_fingerprint, last_successful_incremental_at, last_successful_full_scan_at
            FROM checkpoints ORDER BY volume_id
            """
        )
        var values: [String] = []
        while try checkpoints.step() {
            for column in 0..<7 { values.append(checkpoints.columnText(Int32(column)) ?? "<null>") }
        }
        for table in [
            "inventory_paths", "inventory_objects", "canonical_attributions", "daily_reports",
            "change_ledger", "storage_samples", "overhead_samples", "snapshot_samples",
        ] {
            values.append(String(try database.scalarInt64("SELECT COUNT(*) FROM \(table)") ?? -1))
        }
        let reports = try database.prepare("SELECT payload_json FROM daily_reports ORDER BY run_id, storage_domain_id")
        var digest = SHA256()
        while try reports.step() {
            guard let payload = reports.columnData(0) else { throw SpaceMaintenanceError.verificationFailed }
            digest.update(data: payload)
        }
        values.append(digest.finalize().description)
        return values
    }
}

extension SQLiteDatabase {
    func scalarDouble(_ sql: String) throws -> Double? {
        let statement = try prepare(sql)
        guard try statement.step(), !statement.columnIsNull(0) else { return nil }
        return statement.columnDouble(0)
    }

    func spaceUsage() throws -> DatabaseSpaceUsage {
        let pageSize = try scalarInt64("PRAGMA page_size") ?? 0
        let pages = try scalarInt64("PRAGMA page_count") ?? 0
        let free = try scalarInt64("PRAGMA freelist_count") ?? 0
        var allocated: Int64 = 0
        let root = url.deletingLastPathComponent()
        if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let file as URL in files {
                var info = stat()
                if lstat(file.path, &info) == 0 {
                    allocated = try AccountingMath.add(allocated, AccountingMath.multiply(Int64(info.st_blocks), 512))
                }
            }
        }
        var status: String?
        var completed: Date?
        var reclaimed: Int64?
        if try scalarInt64("SELECT COUNT(*) FROM sqlite_master WHERE name = 'space_maintenance'") == 1 {
            let record = try prepare(
                "SELECT status,last_success_at,last_reclaimed_bytes FROM space_maintenance WHERE singleton = 1")
            if try record.step() {
                status = record.columnText(0)
                if !record.columnIsNull(1) { completed = Date(timeIntervalSince1970: record.columnDouble(1)) }
                if !record.columnIsNull(2) { reclaimed = record.columnInt64(2) }
            }
        }
        return DatabaseSpaceUsage(
            allocatedBytes: allocated,
            databaseBytes: try AccountingMath.multiply(pages, pageSize),
            reusableBytes: try AccountingMath.multiply(free, pageSize),
            maintenanceStatus: status, lastMaintenanceAt: completed, lastReclaimedBytes: reclaimed
        )
    }
}
