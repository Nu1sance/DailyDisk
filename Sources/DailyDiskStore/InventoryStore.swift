import DailyDiskCore
import Foundation

public actor SQLiteInventoryStore: InventoryStoring {
    public static var defaultDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DailyDisk", isDirectory: true)
            .appendingPathComponent("DailyDisk.sqlite", isDirectory: false)
    }

    private let processLease: ProcessLease
    private let database: SQLiteDatabase
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(databaseURL: URL = SQLiteInventoryStore.defaultDatabaseURL) throws {
        processLease = try ProcessLease(databaseURL: databaseURL)
        database = try SQLiteDatabase(url: databaseURL)
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    public func prepare() async throws {
        try DatabaseMigrator.migrate(database)
    }

    public func register(scope: StorageDomainScope) async throws {
        try database.transaction {
            try upsert(scope: scope)
        }
    }

    public func recoverInterruptedRuns(at date: Date) async throws {
        try database.transaction {
            try database.execute(
                """
                UPDATE scan_runs
                SET status = 'interrupted', finished_at = \(date.timeIntervalSince1970)
                WHERE status = 'running'
                """
            )
            try database.execute(
                """
                DELETE FROM run_targets
                WHERE run_id IN (SELECT id FROM scan_runs WHERE status = 'interrupted')
                """
            )
            try database.execute(
                """
                DELETE FROM inventory_generations
                WHERE state = 'staging'
                  AND created_by_run_id IN (SELECT id FROM scan_runs WHERE status = 'interrupted')
                """
            )
        }
    }

    public func interrupt(runID: ScanRun.ID, finishedAt: Date) async throws {
        try database.transaction {
            let status = try database.prepare("SELECT status FROM scan_runs WHERE id = ?")
            try status.bind(runID.rawValue.uuidString, at: 1)
            guard try status.step(), let value = status.columnText(0) else {
                throw StoreInvariantError.invalidRunState
            }
            if value == ScanRun.Status.interrupted.rawValue { return }
            guard value == ScanRun.Status.running.rawValue else {
                throw StoreInvariantError.invalidRunState
            }

            let update = try database.prepare(
                """
                UPDATE scan_runs
                SET status = 'interrupted', finished_at = ?, error_count = 0
                WHERE id = ? AND status = 'running'
                """
            )
            try update.bind(finishedAt.timeIntervalSince1970, at: 1)
            try update.bind(runID.rawValue.uuidString, at: 2)
            _ = try update.step()
            guard database.changes == 1 else {
                throw StoreInvariantError.invalidRunState
            }
            try cleanupStagingState(runID: runID)
            let generations = try database.prepare(
                "DELETE FROM inventory_generations WHERE state = 'staging' AND created_by_run_id = ?"
            )
            try generations.bind(runID.rawValue.uuidString, at: 1)
            _ = try generations.step()
        }
    }

    public func activeRuns() async throws -> [ScanRun] {
        let statement = try database.prepare(
            """
            SELECT id, kind, reason, status, started_at, finished_at, error_count
            FROM scan_runs WHERE status = 'running'
            ORDER BY started_at DESC, id DESC
            """
        )
        var runs: [ScanRun] = []
        while try statement.step() {
            runs.append(try decodeScanRun(statement))
        }
        return runs
    }

    public func scanRun(id: ScanRun.ID) async throws -> ScanRun? {
        let statement = try database.prepare(
            """
            SELECT id, kind, reason, status, started_at, finished_at, error_count
            FROM scan_runs WHERE id = ?
            """
        )
        try statement.bind(id.rawValue.uuidString, at: 1)
        guard try statement.step() else { return nil }
        return try decodeScanRun(statement)
    }

    public func state(for volumeID: MonitoredVolume.ID) async throws -> InventoryState? {
        try loadState(for: volumeID)
    }

    public func begin(run: ScanRun) async throws {
        guard run.status == .running, run.finishedAt == nil, run.errorCount == 0 else {
            throw StoreInvariantError.invalidRunState
        }
        try database.transaction {
            let statement = try database.prepare(
                """
                INSERT INTO scan_runs(id, kind, reason, status, started_at, finished_at, error_count)
                VALUES (?, ?, ?, ?, ?, NULL, 0)
                """
            )
            try statement.bind(run.id.rawValue.uuidString, at: 1)
            try statement.bind(run.kind.rawValue, at: 2)
            try statement.bind(run.reason.rawValue, at: 3)
            try statement.bind(run.status.rawValue, at: 4)
            try statement.bind(run.startedAt.timeIntervalSince1970, at: 5)
            _ = try statement.step()
        }
    }

    public func createStagingGeneration(
        volumeID: MonitoredVolume.ID,
        runID: ScanRun.ID,
        at date: Date
    ) async throws -> InventoryGeneration {
        try requireRunningRun(runID)
        guard let runKind = try loadRunKind(runID), runKind != .incremental else {
            throw StoreInvariantError.invalidRunState
        }
        try requireRegisteredVolume(volumeID)
        let generation = InventoryGeneration(
            volumeID: volumeID,
            createdByRunID: runID,
            state: .staging,
            createdAt: date
        )
        try database.transaction {
            let statement = try database.prepare(
                """
                INSERT INTO inventory_generations(id, volume_id, created_by_run_id, state, created_at)
                VALUES (?, ?, ?, 'staging', ?)
                """
            )
            try statement.bind(generation.id.rawValue.uuidString, at: 1)
            try statement.bind(volumeID.rawValue, at: 2)
            try statement.bind(runID.rawValue.uuidString, at: 3)
            try statement.bind(date.timeIntervalSince1970, at: 4)
            _ = try statement.step()

            let target = try database.prepare(
                """
                INSERT INTO run_targets(
                    run_id, target_kind, target_id, volume_id,
                    base_generation_id, revision, sealed_revision
                ) VALUES (?, 'generation', ?, ?, ?, 0, NULL)
                """
            )
            try target.bind(runID.rawValue.uuidString, at: 1)
            try target.bind(generation.id.rawValue.uuidString, at: 2)
            try target.bind(volumeID.rawValue, at: 3)
            try target.bind(generation.id.rawValue.uuidString, at: 4)
            _ = try target.step()
        }
        return generation
    }

    public func append(
        records: [InventoryRecord],
        to generationID: InventoryGeneration.ID
    ) async throws {
        guard !records.isEmpty else { return }
        let ownership = try generationOwnership(for: generationID, requiredState: .staging)
        try requireRunningRun(ownership.runID)
        guard records.allSatisfy({ $0.path.volumeID == ownership.volumeID }) else {
            throw StoreInvariantError.volumeMismatch
        }
        try database.transaction {
            let objectStatement = try database.prepare(Self.upsertObjectSQL)
            let pathStatement = try database.prepare(Self.upsertPathSQL)
            for (index, record) in records.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                try objectStatement.reset()
                try pathStatement.reset()
                try upsert(
                    record: record,
                    generationID: generationID,
                    objectStatement: objectStatement,
                    pathStatement: pathStatement
                )
            }
            try markTargetDirty(
                runID: ownership.runID,
                kind: "generation",
                id: generationID.rawValue.uuidString
            )
        }
    }

    public func stage(
        mutations: [InventoryMutation],
        target: InventoryMutationTarget,
        for runID: ScanRun.ID
    ) async throws {
        guard !mutations.isEmpty else { return }
        try requireRunningRun(runID)
        let descriptor = try resolve(target: target, runID: runID)
        try database.transaction {
            let statement = try database.prepare(Self.stageMutationSQL)
            let objectStatement = try database.prepare(Self.stageObjectMutationSQL)
            for (index, mutation) in mutations.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                try statement.reset()
                switch mutation {
                case .upsert(let record):
                    guard record.path.volumeID == descriptor.volumeID else {
                        throw StoreInvariantError.volumeMismatch
                    }
                    try bindMutation(
                        statement,
                        runID: runID,
                        descriptor: descriptor,
                        operation: "upsert",
                        record: record,
                        removedPath: nil
                    )
                    try objectStatement.reset()
                    try bindObjectMutation(
                        objectStatement,
                        runID: runID,
                        descriptor: descriptor,
                        object: record.object
                    )
                    _ = try objectStatement.step()
                case .remove(let volumeID, let path):
                    guard volumeID == descriptor.volumeID else {
                        throw StoreInvariantError.volumeMismatch
                    }
                    try bindMutation(
                        statement,
                        runID: runID,
                        descriptor: descriptor,
                        operation: "remove",
                        record: nil,
                        removedPath: path
                    )
                }
                _ = try statement.step()
            }
            try markTargetDirty(runID: runID, kind: descriptor.kind, id: descriptor.id)
        }
    }

    public func stageRemovalSubtree(
        root: RelativePath,
        target: InventoryMutationTarget,
        for runID: ScanRun.ID
    ) async throws {
        try requireRunningRun(runID)
        let descriptor = try resolve(target: target, runID: runID)
        let condition: String
        var prefix: Data?
        var upperBound: Data?
        if root == .root {
            condition = "1 = 1"
        } else {
            var lower = root.bytes
            lower.append(0x2F)
            var upper = root.bytes
            upper.append(0x30)
            prefix = lower
            upperBound = upper
            condition = "path = ? OR (path >= ? AND path < ?)"
        }

        try database.transaction {
            let insert = try database.prepare(
                """
                INSERT INTO run_mutations(
                    run_id, target_kind, target_id, volume_id, path, operation,
                    parent_path, device_id, inode, kind, logical_bytes, allocated_bytes,
                    link_count, modified_at, metadata_changed_at, classification
                )
                SELECT ?, ?, ?, p.volume_id, p.path, 'remove',
                       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
                FROM inventory_paths p
                WHERE p.generation_id = ? AND (\(condition.replacingOccurrences(of: "path", with: "p.path")))
                ON CONFLICT(run_id, target_kind, target_id, path) DO UPDATE SET
                    operation = 'remove', parent_path = NULL, device_id = NULL,
                    inode = NULL, kind = NULL, logical_bytes = NULL,
                    allocated_bytes = NULL, link_count = NULL, modified_at = NULL,
                    metadata_changed_at = NULL, classification = NULL
                """
            )
            try insert.bind(runID.rawValue.uuidString, at: 1)
            try insert.bind(descriptor.kind, at: 2)
            try insert.bind(descriptor.id, at: 3)
            try insert.bind(descriptor.baseGenerationID.rawValue.uuidString, at: 4)
            if root != .root {
                try insert.bind(root.bytes, at: 5)
                try insert.bind(prefix!, at: 6)
                try insert.bind(upperBound!, at: 7)
            }

            _ = try insert.step()

            let update = try database.prepare(
                """
                UPDATE run_mutations
                SET operation = 'remove', parent_path = NULL, device_id = NULL,
                    inode = NULL, kind = NULL, logical_bytes = NULL,
                    allocated_bytes = NULL, link_count = NULL, modified_at = NULL,
                    metadata_changed_at = NULL, classification = NULL
                WHERE run_id = ? AND target_kind = ? AND target_id = ?
                  AND (\(condition))
                """
            )
            try update.bind(runID.rawValue.uuidString, at: 1)
            try update.bind(descriptor.kind, at: 2)
            try update.bind(descriptor.id, at: 3)
            if root != .root {
                try update.bind(root.bytes, at: 4)
                try update.bind(prefix!, at: 5)
                try update.bind(upperBound!, at: 6)
            }
            _ = try update.step()
            try markTargetDirty(runID: runID, kind: descriptor.kind, id: descriptor.id)
        }
    }

    public func stageRemovalSubtree(
        root: RelativePath,
        target: InventoryMutationTarget,
        for runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws {
        try await observer.checkpoint()
        try requireRunningRun(runID)
        let descriptor = try resolve(target: target, runID: runID)
        var after: RelativePath?
        while true {
            try await observer.checkpoint()
            let page = try loadOverlayPage(
                descriptor: descriptor,
                runID: runID,
                after: after,
                limit: InventoryRecordBatch.maximumRecordCount,
                within: root
            )
            guard !page.isEmpty else { return }
            after = page.last?.path.relativePath
            let removals = page.compactMap { record -> InventoryMutation? in
                guard PathPolicy.isEqual(record.path.relativePath, orDescendantOf: root) else {
                    return nil
                }
                return .remove(
                    volumeID: descriptor.volumeID,
                    path: record.path.relativePath
                )
            }
            if !removals.isEmpty {
                try await stage(mutations: removals, target: target, for: runID)
            }
        }
    }

    public func copyMutations(
        from source: InventoryMutationTarget,
        to destination: InventoryMutationTarget,
        for runID: ScanRun.ID
    ) async throws {
        try await copyMutations(
            from: source,
            to: destination,
            for: runID,
            observer: TaskOnlyScanWorkObserver()
        )
    }

    public func copyMutations(
        from source: InventoryMutationTarget,
        to destination: InventoryMutationTarget,
        for runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws {
        try await withScanCancellationMonitoring(observer: observer) {
            try await self.copyMutationsObserved(
                from: source,
                to: destination,
                for: runID
            )
        }
    }

    private func copyMutationsObserved(
        from source: InventoryMutationTarget,
        to destination: InventoryMutationTarget,
        for runID: ScanRun.ID
    ) throws {
        try database.withTaskCancellationProgressHandler {
            try copyMutationsTransaction(from: source, to: destination, for: runID)
        }
    }

    private func copyMutationsTransaction(
        from source: InventoryMutationTarget,
        to destination: InventoryMutationTarget,
        for runID: ScanRun.ID
    ) throws {
        try requireRunningRun(runID)
        let sourceDescriptor = try resolve(target: source, runID: runID)
        let destinationDescriptor = try resolve(target: destination, runID: runID)
        guard sourceDescriptor.volumeID == destinationDescriptor.volumeID else {
            throw StoreInvariantError.volumeMismatch
        }
        let count = try database.prepare(
            """
            SELECT COUNT(*) FROM run_mutations
            WHERE run_id = ? AND target_kind = ? AND target_id = ?
            """
        )
        try count.bind(runID.rawValue.uuidString, at: 1)
        try count.bind(sourceDescriptor.kind, at: 2)
        try count.bind(sourceDescriptor.id, at: 3)
        guard try count.step(), count.columnInt64(0) > 0 else { return }

        try database.transaction {
            let objects = try database.prepare(
                """
                INSERT INTO run_object_mutations(
                    run_id, target_kind, target_id, volume_id, device_id, inode,
                    kind, logical_bytes, allocated_bytes, link_count,
                    modified_at, metadata_changed_at
                )
                SELECT run_id, ?, ?, volume_id, device_id, inode,
                       kind, logical_bytes, allocated_bytes, link_count,
                       modified_at, metadata_changed_at
                FROM run_object_mutations
                WHERE run_id = ? AND target_kind = ? AND target_id = ?
                ON CONFLICT(run_id, target_kind, target_id, device_id, inode) DO UPDATE SET
                    kind = excluded.kind,
                    logical_bytes = excluded.logical_bytes,
                    allocated_bytes = excluded.allocated_bytes,
                    link_count = excluded.link_count,
                    modified_at = excluded.modified_at,
                    metadata_changed_at = excluded.metadata_changed_at
                """
            )
            try objects.bind(destinationDescriptor.kind, at: 1)
            try objects.bind(destinationDescriptor.id, at: 2)
            try objects.bind(runID.rawValue.uuidString, at: 3)
            try objects.bind(sourceDescriptor.kind, at: 4)
            try objects.bind(sourceDescriptor.id, at: 5)
            _ = try objects.step()

            let paths = try database.prepare(
                """
                INSERT INTO run_mutations(
                    run_id, target_kind, target_id, volume_id, path, operation,
                    parent_path, device_id, inode, kind, logical_bytes, allocated_bytes,
                    link_count, modified_at, metadata_changed_at, classification
                )
                SELECT run_id, ?, ?, volume_id, path, operation,
                       parent_path, device_id, inode, kind, logical_bytes, allocated_bytes,
                       link_count, modified_at, metadata_changed_at, classification
                FROM run_mutations
                WHERE run_id = ? AND target_kind = ? AND target_id = ?
                ON CONFLICT(run_id, target_kind, target_id, path) DO UPDATE SET
                    operation = excluded.operation,
                    parent_path = excluded.parent_path,
                    device_id = excluded.device_id,
                    inode = excluded.inode,
                    kind = excluded.kind,
                    logical_bytes = excluded.logical_bytes,
                    allocated_bytes = excluded.allocated_bytes,
                    link_count = excluded.link_count,
                    modified_at = excluded.modified_at,
                    metadata_changed_at = excluded.metadata_changed_at,
                    classification = excluded.classification
                """
            )
            try paths.bind(destinationDescriptor.kind, at: 1)
            try paths.bind(destinationDescriptor.id, at: 2)
            try paths.bind(runID.rawValue.uuidString, at: 3)
            try paths.bind(sourceDescriptor.kind, at: 4)
            try paths.bind(sourceDescriptor.id, at: 5)
            _ = try paths.step()
            try markTargetDirty(
                runID: runID,
                kind: destinationDescriptor.kind,
                id: destinationDescriptor.id
            )
        }
    }

    public func preserveOpaqueSubtrees(
        roots: [RelativePath],
        from source: InventoryMutationTarget,
        to destination: InventoryMutationTarget,
        for runID: ScanRun.ID
    ) async throws {
        try await preserveOpaqueSubtrees(
            roots: roots,
            from: source,
            to: destination,
            for: runID,
            observer: TaskOnlyScanWorkObserver()
        )
    }

    public func preserveOpaqueSubtrees(
        roots: [RelativePath],
        from source: InventoryMutationTarget,
        to destination: InventoryMutationTarget,
        for runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws {
        try await observer.checkpoint()
        guard !roots.isEmpty else { return }
        try requireRunningRun(runID)
        let sourceDescriptor = try resolve(target: source, runID: runID)
        let destinationDescriptor = try resolve(target: destination, runID: runID)
        guard sourceDescriptor.volumeID == destinationDescriptor.volumeID,
            destinationDescriptor.kind == "generation"
        else { throw StoreInvariantError.volumeMismatch }

        let objectInsert = try database.prepare(
            """
            INSERT OR IGNORE INTO inventory_objects(
                generation_id, volume_id, device_id, inode, kind,
                logical_bytes, allocated_bytes, link_count,
                modified_at, metadata_changed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        let pathInsert = try database.prepare(
            """
            INSERT OR IGNORE INTO inventory_paths(
                generation_id, volume_id, path, parent_path,
                device_id, inode, classification
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        )
        var disjointRoots: [RelativePath] = []
        for root in Set(roots).sorted(by: { $0.bytes.lexicographicallyPrecedes($1.bytes) }) {
            if disjointRoots.contains(where: { PathPolicy.isEqual(root, orDescendantOf: $0) }) { continue }
            disjointRoots.append(root)
        }
        for root in disjointRoots {
            var after: RelativePath?
            while true {
                try await observer.checkpoint()
                let page = try loadOverlayPage(
                    descriptor: sourceDescriptor,
                    runID: runID,
                    after: after,
                    limit: InventoryRecordBatch.maximumRecordCount,
                    within: root
                )
                guard !page.isEmpty else { break }
                after = page.last?.path.relativePath
                try Task.checkCancellation()
                var preserved: UInt64 = 0
                try database.transaction {
                    for record in page {
                        try objectInsert.reset()
                        try objectInsert.bind(destinationDescriptor.baseGenerationID.rawValue.uuidString, at: 1)
                        try objectInsert.bind(record.object.identity.volumeID.rawValue, at: 2)
                        try objectInsert.bind(sqliteInteger(record.object.identity.deviceID), at: 3)
                        try objectInsert.bind(sqliteInteger(record.object.identity.inode), at: 4)
                        try objectInsert.bind(record.object.kind.rawValue, at: 5)
                        try objectInsert.bind(record.object.footprint.logicalBytes, at: 6)
                        try objectInsert.bind(record.object.footprint.allocatedBytes, at: 7)
                        try objectInsert.bind(sqliteInteger(record.object.linkCount), at: 8)
                        try objectInsert.bind(record.object.modifiedAt?.timeIntervalSince1970, at: 9)
                        try objectInsert.bind(record.object.metadataChangedAt?.timeIntervalSince1970, at: 10)
                        _ = try objectInsert.step()

                        try pathInsert.reset()
                        try pathInsert.bind(destinationDescriptor.baseGenerationID.rawValue.uuidString, at: 1)
                        try pathInsert.bind(record.path.volumeID.rawValue, at: 2)
                        try pathInsert.bind(record.path.relativePath.bytes, at: 3)
                        try pathInsert.bind(record.path.parentPath?.bytes, at: 4)
                        try pathInsert.bind(sqliteInteger(record.path.objectIdentity.deviceID), at: 5)
                        try pathInsert.bind(sqliteInteger(record.path.objectIdentity.inode), at: 6)
                        try pathInsert.bind(record.path.classification.rawValue, at: 7)
                        _ = try pathInsert.step()
                        if database.changes == 1 {
                            preserved += 1
                        }
                    }
                    if preserved > 0 {
                        try markTargetDirty(
                            runID: runID, kind: destinationDescriptor.kind, id: destinationDescriptor.id)
                    }
                }
                try await observer.checkpoint(ScanProgressDelta(preservedPaths: preserved))
            }
            try await observer.checkpoint(ScanProgressDelta(processedOpaqueRoots: 1))
        }
    }

    public func records(
        target: InventoryMutationTarget,
        runID: ScanRun.ID,
        paths: [RelativePath]
    ) async throws -> [InventoryRecord] {
        try requireRunningRun(runID)
        let descriptor = try resolve(target: target, runID: runID)
        var result: [InventoryRecord] = []
        result.reserveCapacity(paths.count)
        for path in paths {
            if let record = try loadOverlayRecord(
                descriptor: descriptor,
                runID: runID,
                path: path
            ) {
                result.append(record)
            }
        }
        return result
    }

    public func paths(
        target: InventoryMutationTarget,
        runID: ScanRun.ID,
        objectIdentity: FileIdentity
    ) async throws -> [RelativePath] {
        try requireRunningRun(runID)
        let descriptor = try resolve(target: target, runID: runID)
        guard objectIdentity.volumeID == descriptor.volumeID else {
            throw StoreInvariantError.volumeMismatch
        }
        let statement = try database.prepare(
            """
            WITH merged AS (
                SELECT p.path, p.device_id, p.inode
                FROM inventory_paths p
                WHERE p.generation_id = ?
                  AND NOT EXISTS (
                      SELECT 1 FROM run_mutations m
                      WHERE m.run_id = ? AND m.target_kind = ? AND m.target_id = ?
                        AND m.path = p.path
                  )
                UNION ALL
                SELECT m.path, m.device_id, m.inode
                FROM run_mutations m
                WHERE m.run_id = ? AND m.target_kind = ? AND m.target_id = ?
                  AND m.operation = 'upsert'
            )
            SELECT path FROM merged
            WHERE device_id = ? AND inode = ?
            ORDER BY path
            """
        )
        try statement.bind(descriptor.baseGenerationID.rawValue.uuidString, at: 1)
        try statement.bind(runID.rawValue.uuidString, at: 2)
        try statement.bind(descriptor.kind, at: 3)
        try statement.bind(descriptor.id, at: 4)
        try statement.bind(runID.rawValue.uuidString, at: 5)
        try statement.bind(descriptor.kind, at: 6)
        try statement.bind(descriptor.id, at: 7)
        try statement.bind(sqliteInteger(objectIdentity.deviceID), at: 8)
        try statement.bind(sqliteInteger(objectIdentity.inode), at: 9)
        var result: [RelativePath] = []
        while try statement.step() {
            guard let bytes = statement.columnData(0) else {
                throw StoreInvariantError.corruptStoredValue("object path")
            }
            result.append(try RelativePath(validating: bytes))
        }
        return result
    }

    public func deriveIncrementalChanges(
        target: InventoryMutationTarget,
        runID: ScanRun.ID
    ) async throws -> [ChangeRecord] {
        try await deriveIncrementalChanges(
            target: target,
            runID: runID,
            observer: TaskOnlyScanWorkObserver()
        )
    }

    public func deriveIncrementalChanges(
        target: InventoryMutationTarget,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws -> [ChangeRecord] {
        try await observer.checkpoint()
        try requireRunningRun(runID)
        let descriptor = try resolve(target: target, runID: runID)
        guard descriptor.isSealed else { throw StoreInvariantError.targetNotSealed }
        try verifyTargetSealed(descriptor, runID: runID)
        let changes = try await withScanCancellationMonitoring(observer: observer) {
            try await self.deriveIncrementalChanges(
                descriptor: descriptor,
                runID: runID
            )
        }
        try await observer.checkpoint()
        return changes
    }

    public func deriveReconciliationChanges(
        expected: InventoryMutationTarget,
        authoritative: InventoryMutationTarget,
        runID: ScanRun.ID
    ) async throws -> [ChangeRecord] {
        try await deriveReconciliationChanges(
            expected: expected,
            authoritative: authoritative,
            runID: runID,
            observer: TaskOnlyScanWorkObserver()
        )
    }

    public func deriveReconciliationChanges(
        expected: InventoryMutationTarget,
        authoritative: InventoryMutationTarget,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws -> [ChangeRecord] {
        try await observer.checkpoint()
        try requireRunningRun(runID)
        let expectedDescriptor = try resolve(target: expected, runID: runID)
        let authoritativeDescriptor = try resolve(target: authoritative, runID: runID)
        guard expectedDescriptor.isSealed, authoritativeDescriptor.isSealed else {
            throw StoreInvariantError.targetNotSealed
        }
        let changes = try await collectTransitionChanges(
            from: .overlay(expectedDescriptor, runID),
            to: .overlay(authoritativeDescriptor, runID),
            source: .reconciliation,
            runID: runID,
            observer: observer
        )
        try await observer.checkpoint()
        return changes
    }

    public func finalizeCanonicalAttribution(
        target: InventoryMutationTarget,
        runID: ScanRun.ID,
        consume: @escaping @Sendable (CanonicalAttributionBatch) async throws -> Void
    ) async throws {
        try await finalizeCanonicalAttribution(
            target: target,
            runID: runID,
            observer: TaskOnlyScanWorkObserver(),
            consume: consume
        )
    }

    public func finalizeCanonicalAttribution(
        target: InventoryMutationTarget,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (CanonicalAttributionBatch) async throws -> Void
    ) async throws {
        try await withScanCancellationMonitoring(observer: observer) {
            try await self.finalizeCanonicalAttributionObserved(
                target: target,
                runID: runID,
                observer: observer,
                consume: consume
            )
        }
    }

    private func finalizeCanonicalAttributionObserved(
        target: InventoryMutationTarget,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (CanonicalAttributionBatch) async throws -> Void
    ) async throws {
        try await observer.checkpoint()
        try requireRunningRun(runID)
        let runKind = try loadRunKind(runID)
        let descriptor = try resolve(target: target, runID: runID)

        try database.withTaskCancellationProgressHandler {
            try database.transaction {
                if descriptor.kind == "generation" {
                    try removeOrphanObjects(generationID: descriptor.baseGenerationID)
                }
                let remove = try database.prepare(
                    """
                    DELETE FROM run_canonical_attributions
                    WHERE run_id = ? AND target_kind = ? AND target_id = ?
                    """
                )
                try remove.bind(runID.rawValue.uuidString, at: 1)
                try remove.bind(descriptor.kind, at: 2)
                try remove.bind(descriptor.id, at: 3)
                _ = try remove.step()

                let insert = try database.prepare(
                    """
                    INSERT INTO run_canonical_attributions(
                        run_id, target_kind, target_id, volume_id,
                        device_id, inode, path, classification
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """
                )

                if descriptor.kind == "active", runKind == .incremental {
                    let candidates = try incrementalCandidateIdentities(descriptor: descriptor, runID: runID)
                    for (index, identity) in candidates.enumerated() {
                        if index.isMultiple(of: 256) { try Task.checkCancellation() }
                        if let path = try canonicalOverlayPath(
                            identity: identity,
                            descriptor: descriptor,
                            runID: runID
                        ) {
                            try insertRunCanonical(
                                path,
                                statement: insert,
                                descriptor: descriptor,
                                runID: runID
                            )
                        }
                    }
                } else {
                    let paths = try overlayPathStatement(descriptor: descriptor, runID: runID)
                    var previousIdentity: FileIdentity?
                    var rowCount = 0
                    while try paths.step() {
                        rowCount += 1
                        if rowCount.isMultiple(of: 256) { try Task.checkCancellation() }
                        let path = try decodeInventoryPath(from: paths, startingAt: 0)
                        guard path.objectIdentity != previousIdentity else { continue }
                        previousIdentity = path.objectIdentity
                        try insertRunCanonical(
                            path,
                            statement: insert,
                            descriptor: descriptor,
                            runID: runID
                        )
                    }
                }

                let seal = try database.prepare(
                    """
                    UPDATE run_targets SET sealed_revision = revision
                    WHERE run_id = ? AND target_kind = ? AND target_id = ? AND revision = ?
                    """
                )
                try seal.bind(runID.rawValue.uuidString, at: 1)
                try seal.bind(descriptor.kind, at: 2)
                try seal.bind(descriptor.id, at: 3)
                try seal.bind(descriptor.revision, at: 4)
                _ = try seal.step()
                guard database.changes == 1 else {
                    throw StoreInvariantError.targetRevisionMismatch
                }
            }
        }

        var after: (deviceID: Int64, inode: Int64)?
        while true {
            try await observer.checkpoint()
            let page = try loadCanonicalPage(
                runID: runID,
                descriptor: descriptor,
                after: after,
                limit: CanonicalAttributionBatch.maximumAttributionCount
            )
            guard !page.isEmpty else { break }
            try await consume(CanonicalAttributionBatch(attributions: page))
            try await observer.checkpoint()
            try verifyTargetSealed(descriptor, runID: runID)
            let last = page[page.count - 1].objectIdentity
            after = (sqliteInteger(last.deviceID), sqliteInteger(last.inode))
        }
    }

    public func diff(
        expected: InventoryMutationTarget,
        authoritative: InventoryMutationTarget,
        runID: ScanRun.ID,
        consume: @escaping @Sendable (InventoryDiffBatch) async throws -> Void
    ) async throws {
        try await diff(
            expected: expected,
            authoritative: authoritative,
            runID: runID,
            observer: TaskOnlyScanWorkObserver(),
            consume: consume
        )
    }

    public func diff(
        expected: InventoryMutationTarget,
        authoritative: InventoryMutationTarget,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (InventoryDiffBatch) async throws -> Void
    ) async throws {
        try await observer.checkpoint()
        try requireRunningRun(runID)
        let expectedDescriptor = try resolve(target: expected, runID: runID)
        let authoritativeDescriptor = try resolve(target: authoritative, runID: runID)
        guard expectedDescriptor.isSealed, authoritativeDescriptor.isSealed else {
            throw StoreInvariantError.targetNotSealed
        }
        var expectedPager = OverlayPager(descriptor: expectedDescriptor, runID: runID)
        var authoritativePager = OverlayPager(descriptor: authoritativeDescriptor, runID: runID)
        var expectedRecord = try nextRecord(using: &expectedPager)
        var authoritativeRecord = try nextRecord(using: &authoritativePager)
        var differences: [InventoryDiff] = []
        differences.reserveCapacity(InventoryDiffBatch.maximumDifferenceCount)

        var comparedCount = 0
        while expectedRecord != nil || authoritativeRecord != nil {
            comparedCount += 1
            if comparedCount.isMultiple(of: 256) {
                try await observer.checkpoint()
            }
            switch (expectedRecord, authoritativeRecord) {
            case (.some(let expectedValue), .some(let authoritativeValue)):
                if expectedValue.path.relativePath == authoritativeValue.path.relativePath {
                    if expectedValue != authoritativeValue {
                        differences.append(InventoryDiff(expected: expectedValue, authoritative: authoritativeValue))
                    }
                    expectedRecord = try nextRecord(using: &expectedPager)
                    authoritativeRecord = try nextRecord(using: &authoritativePager)
                } else if expectedValue.path.relativePath.bytes.lexicographicallyPrecedes(
                    authoritativeValue.path.relativePath.bytes
                ) {
                    differences.append(InventoryDiff(expected: expectedValue, authoritative: nil))
                    expectedRecord = try nextRecord(using: &expectedPager)
                } else {
                    differences.append(InventoryDiff(expected: nil, authoritative: authoritativeValue))
                    authoritativeRecord = try nextRecord(using: &authoritativePager)
                }
            case (.some(let expectedValue), .none):
                differences.append(InventoryDiff(expected: expectedValue, authoritative: nil))
                expectedRecord = try nextRecord(using: &expectedPager)
            case (.none, .some(let authoritativeValue)):
                differences.append(InventoryDiff(expected: nil, authoritative: authoritativeValue))
                authoritativeRecord = try nextRecord(using: &authoritativePager)
            case (.none, .none):
                break
            }
            if differences.count >= InventoryDiffBatch.maximumDifferenceCount {
                let batch = try InventoryDiffBatch(differences: differences)
                differences.removeAll(keepingCapacity: true)
                try await consume(batch)
                try await observer.checkpoint()
                try verifyTargetSealed(expectedDescriptor, runID: runID)
                try verifyTargetSealed(authoritativeDescriptor, runID: runID)
            }
        }
        if !differences.isEmpty {
            try await consume(InventoryDiffBatch(differences: differences))
            try await observer.checkpoint()
            try verifyTargetSealed(expectedDescriptor, runID: runID)
            try verifyTargetSealed(authoritativeDescriptor, runID: runID)
        }
    }

    public func commit(_ commit: ScanCommit, finishedAt: Date) async throws {
        try database.transaction {
            try requireRunningRun(commit.runID, kind: commit.runKind)
            try upsert(scope: commit.scope)
            try verifyPreviousCheckpoint(commit.previousCheckpoint, volumeID: commit.volumeID)

            switch commit.runKind {
            case .incremental:
                let descriptor = try resolve(
                    target: .expectedActive(volumeID: commit.volumeID),
                    runID: commit.runID
                )
                guard descriptor.isSealed else { throw StoreInvariantError.targetNotSealed }
                try verifyTargetSealed(descriptor, runID: commit.runID)
                try validateLedger(commit: commit, authoritative: descriptor)
                let candidates = try incrementalCandidateIdentities(
                    descriptor: descriptor,
                    runID: commit.runID,
                    allowCancellation: false
                )
                try clearCanonicalAttributions(
                    generationID: descriptor.baseGenerationID,
                    identities: candidates
                )
                try applyMutations(runID: commit.runID, descriptor: descriptor, orphanCandidates: candidates)
                try applyIncrementalCanonicalAttributions(
                    runID: commit.runID,
                    descriptor: descriptor,
                    generationID: commit.checkpoint.activeGenerationID,
                    candidates: candidates
                )
            case .full, .recovery:
                guard let activatedGenerationID = commit.activatedGenerationID else {
                    throw StoreInvariantError.missingActivatedGeneration
                }
                let descriptor = try resolve(
                    target: .stagingGeneration(activatedGenerationID),
                    runID: commit.runID
                )
                guard descriptor.isSealed else { throw StoreInvariantError.targetNotSealed }
                try verifyTargetSealed(descriptor, runID: commit.runID)
                try validateLedger(commit: commit, authoritative: descriptor)
                try clearCanonicalAttributions(generationID: descriptor.baseGenerationID)
                try applyMutations(runID: commit.runID, descriptor: descriptor)
                try applyCanonicalAttributions(
                    runID: commit.runID,
                    descriptor: descriptor,
                    generationID: activatedGenerationID
                )
                try activate(
                    generationID: activatedGenerationID,
                    volumeID: commit.volumeID
                )
            }

            try write(changes: commit.changes)
            try write(samples: commit.storageSamples, runID: commit.runID)
            try writeSnapshotObservations(
                volumeIDs: commit.snapshotObservedVolumeIDs,
                runID: commit.runID,
                observedAt: finishedAt
            )
            try write(snapshots: commit.snapshotSamples, runID: commit.runID)
            try write(overhead: commit.overheadSample, runID: commit.runID)
            try write(coverage: commit.coverage, runID: commit.runID)
            try write(errors: commit.scanErrors)
            try upsert(checkpoint: commit.checkpoint)

            let finish = try database.prepare(
                """
                UPDATE scan_runs
                SET status = 'succeeded', finished_at = ?, error_count = ?
                WHERE id = ? AND status = 'running'
                """
            )
            try finish.bind(finishedAt.timeIntervalSince1970, at: 1)
            try finish.bind(Int64(commit.scanErrors.count), at: 2)
            try finish.bind(commit.runID.rawValue.uuidString, at: 3)
            _ = try finish.step()
            guard database.changes == 1 else {
                throw StoreInvariantError.invalidRunState
            }
            try cleanupStagingState(runID: commit.runID)
            try pruneGenerations(volumeID: commit.volumeID, runID: commit.runID)
        }
    }

    public func commitReport(_ commit: ReportCommit) async throws {
        try database.transaction {
            try requireSucceededRun(commit.runID)
            let storedChanges = try loadChanges(runID: commit.runID)
            guard storedChanges == commit.changes else {
                throw StoreInvariantError.reportBasisMismatch
            }
            guard try contains(sample: commit.currentStorageSample, runID: commit.runID) else {
                throw StoreInvariantError.reportBasisMismatch
            }
            guard
                try latestSample(
                    before: commit.currentStorageSample.sampledAt,
                    storageDomainID: commit.scope.domain.id
                ) == commit.previousStorageSample
            else {
                throw StoreInvariantError.reportBasisMismatch
            }
            if let currentOverhead = commit.currentOverheadSample {
                guard try contains(overhead: currentOverhead, runID: commit.runID),
                    try latestOverhead(
                        storageDomainID: commit.scope.domain.id,
                        before: currentOverhead.sampledAt
                    ) == commit.previousOverheadSample
                else {
                    throw StoreInvariantError.reportBasisMismatch
                }
            } else if try containsOverhead(runID: commit.runID) || commit.previousOverheadSample != nil {
                throw StoreInvariantError.reportBasisMismatch
            }

            let payload = try encoder.encode(commit.report)
            let existing = try database.prepare(
                "SELECT payload_json FROM daily_reports WHERE run_id = ? AND storage_domain_id = ?"
            )
            try existing.bind(commit.runID.rawValue.uuidString, at: 1)
            try existing.bind(commit.scope.domain.id.rawValue, at: 2)
            if try existing.step() {
                guard let existingPayload = existing.columnData(0),
                    try decoder.decode(DailyReport.self, from: existingPayload) == commit.report
                else {
                    throw StoreInvariantError.reportAlreadyExists
                }
                return
            }

            let statement = try database.prepare(
                """
                INSERT INTO daily_reports(
                    run_id, storage_domain_id, generated_at,
                    event_attributed_delta, reconciliation_correction,
                    reconciled_indexed_delta, dailydisk_overhead_delta,
                    physical_used_delta, physical_unattributed_delta, payload_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            )
            let accounting = commit.report.accounting
            try statement.bind(commit.runID.rawValue.uuidString, at: 1)
            try statement.bind(commit.scope.domain.id.rawValue, at: 2)
            try statement.bind(commit.report.generatedAt.timeIntervalSince1970, at: 3)
            try statement.bind(accounting.eventAttributedDelta, at: 4)
            try statement.bind(accounting.reconciliationCorrection, at: 5)
            try statement.bind(accounting.reconciledIndexedDelta, at: 6)
            try statement.bind(accounting.dailyDiskOverheadDelta, at: 7)
            try statement.bind(accounting.physicalUsedDelta, at: 8)
            try statement.bind(accounting.physicalUnattributedDelta, at: 9)
            try statement.bind(payload, at: 10)
            _ = try statement.step()
        }
    }

    public func report(
        runID: ScanRun.ID,
        storageDomainID: StorageDomain.ID
    ) async throws -> DailyReport? {
        let statement = try database.prepare(
            """
            SELECT payload_json FROM daily_reports
            WHERE run_id = ? AND storage_domain_id = ?
            """
        )
        try statement.bind(runID.rawValue.uuidString, at: 1)
        try statement.bind(storageDomainID.rawValue, at: 2)
        guard try statement.step(), let data = statement.columnData(0) else { return nil }
        return try decoder.decode(DailyReport.self, from: data)
    }

    public func latestUnreportedBasis(
        storageDomainID: StorageDomain.ID
    ) async throws -> PersistedReportBasis? {
        let run = try database.prepare(
            """
            SELECT r.id, r.finished_at,
                   s.sampled_at, s.capacity_bytes, s.used_bytes, s.available_bytes,
                   s.important_available_bytes, s.opportunistic_available_bytes
            FROM scan_runs r
            JOIN storage_samples s ON s.run_id = r.id
            WHERE r.status = 'succeeded' AND s.storage_domain_id = ?
              AND s.sampled_at = (
                  SELECT MAX(s2.sampled_at) FROM storage_samples s2
                  WHERE s2.run_id = r.id AND s2.storage_domain_id = s.storage_domain_id
              )
              AND NOT EXISTS (
                  SELECT 1 FROM daily_reports d
                  WHERE d.run_id = r.id AND d.storage_domain_id = s.storage_domain_id
              )
            ORDER BY r.finished_at DESC, r.id DESC
            LIMIT 1
            """
        )
        try run.bind(storageDomainID.rawValue, at: 1)
        guard try run.step() else { return nil }
        guard let runString = run.columnText(0),
            let runUUID = UUID(uuidString: runString),
            !run.columnIsNull(1),
            run.columnDouble(1).isFinite
        else {
            throw StoreInvariantError.corruptStoredValue("unreported run identity or completion time")
        }
        let runID = ScanRun.ID(runUUID)
        let storageSample = try StorageSample(
            storageDomainID: storageDomainID,
            sampledAt: Date(timeIntervalSince1970: run.columnDouble(2)),
            capacityBytes: run.columnInt64(3),
            usedBytes: run.columnInt64(4),
            availableBytes: run.columnInt64(5),
            importantUsageAvailableBytes: optionalInt64(run, column: 6),
            opportunisticUsageAvailableBytes: optionalInt64(run, column: 7)
        )

        let observation = try database.prepare(
            "SELECT volume_id FROM snapshot_observations WHERE run_id = ?"
        )
        try observation.bind(runString, at: 1)
        var observedVolumeIDs: Set<MonitoredVolume.ID> = []
        while try observation.step() {
            if let value = observation.columnText(0) {
                observedVolumeIDs.insert(MonitoredVolume.ID(value))
            }
        }
        var snapshots: [SnapshotSample] = []
        let snapshotRows = try database.prepare(
            """
            SELECT volume_id, sampled_at, snapshot_uuid, name, created_at,
                   is_purgeable, allocated_bytes_estimate
            FROM snapshot_samples WHERE run_id = ? ORDER BY volume_id, name
            """
        )
        try snapshotRows.bind(runString, at: 1)
        while try snapshotRows.step() {
            guard let volume = snapshotRows.columnText(0),
                let name = snapshotRows.columnText(3)
            else { throw StoreInvariantError.corruptStoredValue("snapshot basis") }
            snapshots.append(
                try SnapshotSample(
                    volumeID: MonitoredVolume.ID(volume),
                    sampledAt: Date(timeIntervalSince1970: snapshotRows.columnDouble(1)),
                    snapshotUUID: try optionalUUID(snapshotRows.columnText(2), field: "snapshot_uuid"),
                    name: name,
                    createdAt: optionalDate(snapshotRows, column: 4),
                    isPurgeable: snapshotRows.columnIsNull(5)
                        ? nil : snapshotRows.columnInt64(5) != 0,
                    allocatedBytesEstimate: optionalInt64(snapshotRows, column: 6)
                )
            )
        }

        let overheadRow = try database.prepare(
            """
            SELECT sampled_at, allocated_bytes FROM overhead_samples
            WHERE run_id = ? AND storage_domain_id = ?
            """
        )
        try overheadRow.bind(runString, at: 1)
        try overheadRow.bind(storageDomainID.rawValue, at: 2)
        let overhead: DailyDiskOverheadSample?
        if try overheadRow.step() {
            overhead = try DailyDiskOverheadSample(
                storageDomainID: storageDomainID,
                sampledAt: Date(timeIntervalSince1970: overheadRow.columnDouble(0)),
                allocatedBytes: overheadRow.columnInt64(1)
            )
        } else {
            overhead = nil
        }

        let summary = try database.prepare(
            """
            SELECT visited_path_count, indexed_object_count,
                   unreadable_path_count, transient_error_count
            FROM scan_summaries WHERE run_id = ?
            """
        )
        try summary.bind(runString, at: 1)
        guard try summary.step() else {
            throw StoreInvariantError.corruptStoredValue("scan summary")
        }
        let coverage = ScanCoverage(
            visitedPathCount: UInt64(bitPattern: summary.columnInt64(0)),
            indexedObjectCount: UInt64(bitPattern: summary.columnInt64(1)),
            unreadablePathCount: UInt64(bitPattern: summary.columnInt64(2)),
            transientErrorCount: UInt64(bitPattern: summary.columnInt64(3))
        )
        let errors = try loadErrors(runID: runID)
        return PersistedReportBasis(
            runID: runID,
            checkpointDate: Date(timeIntervalSince1970: run.columnDouble(1)),
            changes: try loadChanges(runID: runID),
            currentStorageSample: storageSample,
            currentSnapshots: snapshots,
            snapshotObservedVolumeIDs: observedVolumeIDs,
            currentOverhead: overhead,
            coverage: coverage,
            scanErrors: errors
        )
    }

    public func latestStorageSample(
        storageDomainID: StorageDomain.ID,
        before date: Date
    ) async throws -> StorageSample? {
        try latestSample(before: date, storageDomainID: storageDomainID)
    }

    public func latestSnapshotSamples(
        volumeIDs: Set<MonitoredVolume.ID>,
        before date: Date
    ) async throws -> [SnapshotSample] {
        var result: [SnapshotSample] = []
        for volumeID in volumeIDs {
            let observation = try database.prepare(
                """
                SELECT run_id FROM snapshot_observations
                WHERE volume_id = ? AND observed_at < ?
                ORDER BY observed_at DESC, run_id DESC LIMIT 1
                """
            )
            try observation.bind(volumeID.rawValue, at: 1)
            try observation.bind(date.timeIntervalSince1970, at: 2)
            guard try observation.step(), let runID = observation.columnText(0) else { continue }
            let snapshots = try database.prepare(
                """
                SELECT sampled_at, snapshot_uuid, name, created_at,
                       is_purgeable, allocated_bytes_estimate
                FROM snapshot_samples
                WHERE run_id = ? AND volume_id = ?
                ORDER BY name
                """
            )
            try snapshots.bind(runID, at: 1)
            try snapshots.bind(volumeID.rawValue, at: 2)
            while try snapshots.step() {
                let uuid = try optionalUUID(snapshots.columnText(1), field: "snapshot_uuid")
                guard let name = snapshots.columnText(2) else {
                    throw StoreInvariantError.corruptStoredValue("snapshot name")
                }
                result.append(
                    try SnapshotSample(
                        volumeID: volumeID,
                        sampledAt: Date(timeIntervalSince1970: snapshots.columnDouble(0)),
                        snapshotUUID: uuid,
                        name: name,
                        createdAt: optionalDate(snapshots, column: 3),
                        isPurgeable: snapshots.columnIsNull(4)
                            ? nil : snapshots.columnInt64(4) != 0,
                        allocatedBytesEstimate: optionalInt64(snapshots, column: 5)
                    )
                )
            }
        }
        return result
    }

    public func latestOverheadSample(
        storageDomainID: StorageDomain.ID,
        before date: Date
    ) async throws -> DailyDiskOverheadSample? {
        let statement = try database.prepare(
            """
            SELECT sampled_at, allocated_bytes FROM overhead_samples
            WHERE storage_domain_id = ? AND sampled_at < ?
            ORDER BY sampled_at DESC, run_id DESC LIMIT 1
            """
        )
        try statement.bind(storageDomainID.rawValue, at: 1)
        try statement.bind(date.timeIntervalSince1970, at: 2)
        guard try statement.step() else { return nil }
        return try DailyDiskOverheadSample(
            storageDomainID: storageDomainID,
            sampledAt: Date(timeIntervalSince1970: statement.columnDouble(0)),
            allocatedBytes: statement.columnInt64(1)
        )
    }

    public func fail(
        runID: ScanRun.ID,
        errors: [ScanErrorRecord],
        finishedAt: Date
    ) async throws {
        guard errors.allSatisfy({ $0.runID == runID }) else {
            throw StoreInvariantError.runMismatch
        }
        try database.transaction {
            try requireRunningRun(runID)
            try write(errors: errors)
            let statement = try database.prepare(
                """
                UPDATE scan_runs
                SET status = 'failed', finished_at = ?, error_count = ?
                WHERE id = ? AND status = 'running'
                """
            )
            try statement.bind(finishedAt.timeIntervalSince1970, at: 1)
            try statement.bind(Int64(errors.count), at: 2)
            try statement.bind(runID.rawValue.uuidString, at: 3)
            _ = try statement.step()
            guard database.changes == 1 else {
                throw StoreInvariantError.invalidRunState
            }
            try cleanupStagingState(runID: runID)
            let removeGenerations = try database.prepare(
                "DELETE FROM inventory_generations WHERE state = 'staging' AND created_by_run_id = ?"
            )
            try removeGenerations.bind(runID.rawValue.uuidString, at: 1)
            _ = try removeGenerations.step()
        }
    }
}

// MARK: - Store errors

public enum StoreInvariantError: Error, Equatable, Sendable {
    case invalidRunState
    case runMismatch
    case volumeMismatch
    case unregisteredVolume
    case generationNotFound
    case generationStateMismatch
    case generationOwnershipMismatch
    case targetRevisionMismatch
    case targetNotSealed
    case checkpointMismatch
    case missingActivatedGeneration
    case missingCanonicalAttribution
    case ledgerMismatch
    case reportBasisMismatch
    case reportAlreadyExists
    case corruptStoredValue(String)
}

// MARK: - Internal persistence helpers

extension SQLiteInventoryStore {
    fileprivate struct TargetDescriptor: Sendable {
        let kind: String
        let id: String
        let volumeID: MonitoredVolume.ID
        let baseGenerationID: InventoryGeneration.ID
        let revision: Int64
        let sealedRevision: Int64?

        var isSealed: Bool { sealedRevision == revision }
    }

    fileprivate enum ValidationState {
        case generation(InventoryGeneration.ID)
        case overlay(TargetDescriptor, ScanRun.ID)
    }

    fileprivate struct AttributedFact {
        let identity: FileIdentity
        let footprint: FileFootprint
        let path: RelativePath
        let classification: InventoryClassification
    }

    fileprivate struct LedgerSemantic: Hashable {
        let identity: FileIdentity
        let kind: String
        let classification: String
        let pathBefore: RelativePath?
        let pathAfter: RelativePath?
        let effect: String
        let beforeLogical: Int64?
        let beforeAllocated: Int64?
        let afterLogical: Int64?
        let afterAllocated: Int64?
        let transferLogical: Int64?
        let transferAllocated: Int64?
        let transferDirection: String?
    }

    fileprivate struct OverlayPager {
        let descriptor: TargetDescriptor
        let runID: ScanRun.ID
        var page: [InventoryRecord] = []
        var index = 0
        var lastPath: RelativePath?
        var exhausted = false
    }

    fileprivate static let upsertObjectSQL = """
        INSERT INTO inventory_objects(
            generation_id, volume_id, device_id, inode, kind,
            logical_bytes, allocated_bytes, link_count,
            modified_at, metadata_changed_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(generation_id, device_id, inode) DO UPDATE SET
            kind = excluded.kind,
            logical_bytes = excluded.logical_bytes,
            allocated_bytes = excluded.allocated_bytes,
            link_count = excluded.link_count,
            modified_at = excluded.modified_at,
            metadata_changed_at = excluded.metadata_changed_at
        """

    fileprivate static let upsertPathSQL = """
        INSERT INTO inventory_paths(
            generation_id, volume_id, path, parent_path,
            device_id, inode, classification
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(generation_id, path) DO UPDATE SET
            volume_id = excluded.volume_id,
            parent_path = excluded.parent_path,
            device_id = excluded.device_id,
            inode = excluded.inode,
            classification = excluded.classification
        """

    fileprivate static let stageObjectMutationSQL = """
        INSERT INTO run_object_mutations(
            run_id, target_kind, target_id, volume_id, device_id, inode,
            kind, logical_bytes, allocated_bytes, link_count,
            modified_at, metadata_changed_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(run_id, target_kind, target_id, device_id, inode) DO UPDATE SET
            kind = excluded.kind,
            logical_bytes = excluded.logical_bytes,
            allocated_bytes = excluded.allocated_bytes,
            link_count = excluded.link_count,
            modified_at = excluded.modified_at,
            metadata_changed_at = excluded.metadata_changed_at
        """

    fileprivate static let stageMutationSQL = """
        INSERT INTO run_mutations(
            run_id, target_kind, target_id, volume_id, path, operation,
            parent_path, device_id, inode, kind, logical_bytes, allocated_bytes,
            link_count, modified_at, metadata_changed_at, classification
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(run_id, target_kind, target_id, path) DO UPDATE SET
            operation = excluded.operation,
            parent_path = excluded.parent_path,
            device_id = excluded.device_id,
            inode = excluded.inode,
            kind = excluded.kind,
            logical_bytes = excluded.logical_bytes,
            allocated_bytes = excluded.allocated_bytes,
            link_count = excluded.link_count,
            modified_at = excluded.modified_at,
            metadata_changed_at = excluded.metadata_changed_at,
            classification = excluded.classification
        """

    fileprivate func upsert(scope: StorageDomainScope) throws {
        let domain = try database.prepare(
            """
            INSERT INTO storage_domains(id, container_identifier, display_name, is_internal)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                container_identifier = excluded.container_identifier,
                display_name = excluded.display_name,
                is_internal = excluded.is_internal
            """
        )
        try domain.bind(scope.domain.id.rawValue, at: 1)
        try domain.bind(scope.domain.containerIdentifier, at: 2)
        try domain.bind(scope.domain.displayName, at: 3)
        try domain.bind(scope.domain.isInternal, at: 4)
        _ = try domain.step()

        let existingVolumes = try database.prepare(
            "SELECT id FROM volumes WHERE storage_domain_id = ?"
        )
        try existingVolumes.bind(scope.domain.id.rawValue, at: 1)
        let currentIDs = scope.volumeIDs
        var staleIDs: [String] = []
        while try existingVolumes.step() {
            if let id = existingVolumes.columnText(0), !currentIDs.contains(MonitoredVolume.ID(id)) {
                staleIDs.append(id)
            }
        }
        let demote = try database.prepare(
            """
            UPDATE volumes
            SET inventory_mode = 'metricsOnly', supports_persistent_events = 0,
                event_store_uuid = NULL, mount_path = NULL
            WHERE id = ?
            """
        )
        for id in staleIDs {
            try demote.reset()
            try demote.bind(id, at: 1)
            _ = try demote.step()
        }

        let clearFullSelection = try database.prepare(
            """
            UPDATE volumes SET inventory_mode = 'metricsOnly'
            WHERE storage_domain_id = ? AND inventory_mode = 'full'
            """
        )
        try clearFullSelection.bind(scope.domain.id.rawValue, at: 1)
        _ = try clearFullSelection.step()

        let volume = try database.prepare(
            """
            INSERT INTO volumes(
                id, storage_domain_id, filesystem_uuid, volume_group_uuid,
                event_store_uuid, device_id, mount_path, display_name, role,
                is_internal, is_removable, is_read_only,
                supports_persistent_events, topology_fingerprint, inventory_mode
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                storage_domain_id = excluded.storage_domain_id,
                filesystem_uuid = excluded.filesystem_uuid,
                volume_group_uuid = excluded.volume_group_uuid,
                event_store_uuid = excluded.event_store_uuid,
                device_id = excluded.device_id,
                mount_path = excluded.mount_path,
                display_name = excluded.display_name,
                role = excluded.role,
                is_internal = excluded.is_internal,
                is_removable = excluded.is_removable,
                is_read_only = excluded.is_read_only,
                supports_persistent_events = excluded.supports_persistent_events,
                topology_fingerprint = excluded.topology_fingerprint,
                inventory_mode = excluded.inventory_mode
            """
        )
        for value in scope.volumes {
            try volume.reset()
            try volume.bind(value.id.rawValue, at: 1)
            try volume.bind(value.storageDomainID.rawValue, at: 2)
            try volume.bind(value.filesystemUUID?.uuidString, at: 3)
            try volume.bind(value.volumeGroupUUID?.uuidString, at: 4)
            try volume.bind(value.eventStoreUUID?.uuidString, at: 5)
            try volume.bind(sqliteInteger(value.deviceID), at: 6)
            try volume.bind(value.mountPath, at: 7)
            try volume.bind(value.displayName, at: 8)
            try volume.bind(value.role.rawValue, at: 9)
            try volume.bind(value.isInternal, at: 10)
            try volume.bind(value.isRemovable, at: 11)
            try volume.bind(value.isReadOnly, at: 12)
            try volume.bind(value.supportsPersistentEvents, at: 13)
            try volume.bind(value.topologyFingerprint, at: 14)
            try volume.bind(value.inventoryMode.rawValue, at: 15)
            _ = try volume.step()
        }
    }

    fileprivate func decodeScanRun(_ statement: SQLiteStatement) throws -> ScanRun {
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

    fileprivate func loadRunKind(_ runID: ScanRun.ID) throws -> ScanRun.Kind? {
        let statement = try database.prepare("SELECT kind FROM scan_runs WHERE id = ? AND status = 'running'")
        try statement.bind(runID.rawValue.uuidString, at: 1)
        guard try statement.step(), let value = statement.columnText(0) else { return nil }
        return ScanRun.Kind(rawValue: value)
    }

    fileprivate func generationOwnership(
        for generationID: InventoryGeneration.ID,
        requiredState: InventoryGeneration.State
    ) throws -> (volumeID: MonitoredVolume.ID, runID: ScanRun.ID) {
        let statement = try database.prepare(
            "SELECT volume_id, created_by_run_id, state FROM inventory_generations WHERE id = ?"
        )
        try statement.bind(generationID.rawValue.uuidString, at: 1)
        guard try statement.step(),
            statement.columnText(2) == requiredState.rawValue,
            let volume = statement.columnText(0),
            let runString = statement.columnText(1),
            let runUUID = UUID(uuidString: runString)
        else {
            throw StoreInvariantError.generationOwnershipMismatch
        }
        return (MonitoredVolume.ID(volume), ScanRun.ID(runUUID))
    }

    fileprivate func markTargetDirty(runID: ScanRun.ID, kind: String, id: String) throws {
        let statement = try database.prepare(
            """
            UPDATE run_targets
            SET revision = revision + 1, sealed_revision = NULL
            WHERE run_id = ? AND target_kind = ? AND target_id = ?
            """
        )
        try statement.bind(runID.rawValue.uuidString, at: 1)
        try statement.bind(kind, at: 2)
        try statement.bind(id, at: 3)
        _ = try statement.step()
        guard database.changes == 1 else {
            throw StoreInvariantError.targetRevisionMismatch
        }
    }

    fileprivate func verifyTargetSealed(_ descriptor: TargetDescriptor, runID: ScanRun.ID) throws {
        let statement = try database.prepare(
            """
            SELECT revision, sealed_revision FROM run_targets
            WHERE run_id = ? AND target_kind = ? AND target_id = ?
            """
        )
        try statement.bind(runID.rawValue.uuidString, at: 1)
        try statement.bind(descriptor.kind, at: 2)
        try statement.bind(descriptor.id, at: 3)
        guard try statement.step(),
            statement.columnInt64(0) == descriptor.revision,
            !statement.columnIsNull(1),
            statement.columnInt64(1) == descriptor.revision
        else {
            throw StoreInvariantError.targetRevisionMismatch
        }
    }

    fileprivate func requireRegisteredVolume(_ volumeID: MonitoredVolume.ID) throws {
        let statement = try database.prepare("SELECT 1 FROM volumes WHERE id = ?")
        try statement.bind(volumeID.rawValue, at: 1)
        guard try statement.step() else { throw StoreInvariantError.unregisteredVolume }
    }

    fileprivate func requireRunningRun(_ runID: ScanRun.ID, kind: ScanRun.Kind? = nil) throws {
        let statement = try database.prepare("SELECT kind, status FROM scan_runs WHERE id = ?")
        try statement.bind(runID.rawValue.uuidString, at: 1)
        guard try statement.step(), statement.columnText(1) == ScanRun.Status.running.rawValue else {
            throw StoreInvariantError.invalidRunState
        }
        if let kind, statement.columnText(0) != kind.rawValue {
            throw StoreInvariantError.invalidRunState
        }
    }

    fileprivate func requireSucceededRun(_ runID: ScanRun.ID) throws {
        let statement = try database.prepare("SELECT status FROM scan_runs WHERE id = ?")
        try statement.bind(runID.rawValue.uuidString, at: 1)
        guard try statement.step(), statement.columnText(0) == ScanRun.Status.succeeded.rawValue else {
            throw StoreInvariantError.invalidRunState
        }
    }

    fileprivate func volumeID(
        for generationID: InventoryGeneration.ID,
        requiredState: InventoryGeneration.State? = nil
    ) throws -> MonitoredVolume.ID {
        let statement = try database.prepare(
            "SELECT volume_id, state FROM inventory_generations WHERE id = ?"
        )
        try statement.bind(generationID.rawValue.uuidString, at: 1)
        guard try statement.step(), let volume = statement.columnText(0) else {
            throw StoreInvariantError.generationNotFound
        }
        if let requiredState, statement.columnText(1) != requiredState.rawValue {
            throw StoreInvariantError.generationStateMismatch
        }
        return MonitoredVolume.ID(volume)
    }

    fileprivate func resolve(
        target: InventoryMutationTarget,
        runID: ScanRun.ID,
        createIfNeeded: Bool = true
    ) throws -> TargetDescriptor {
        let kind: String
        let id: String
        let volumeID: MonitoredVolume.ID
        let baseGenerationID: InventoryGeneration.ID

        switch target {
        case .expectedActive(let targetVolumeID):
            guard let state = try loadState(for: targetVolumeID) else {
                throw StoreInvariantError.checkpointMismatch
            }
            kind = "active"
            id = targetVolumeID.rawValue
            volumeID = targetVolumeID
            baseGenerationID = state.activeGeneration.id
        case .stagingGeneration(let generationID):
            let generation = try database.prepare(
                """
                SELECT volume_id, created_by_run_id, state
                FROM inventory_generations WHERE id = ?
                """
            )
            try generation.bind(generationID.rawValue.uuidString, at: 1)
            guard try generation.step(),
                let volumeString = generation.columnText(0),
                generation.columnText(1) == runID.rawValue.uuidString,
                generation.columnText(2) == InventoryGeneration.State.staging.rawValue
            else {
                throw StoreInvariantError.generationOwnershipMismatch
            }
            kind = "generation"
            id = generationID.rawValue.uuidString
            volumeID = MonitoredVolume.ID(volumeString)
            baseGenerationID = generationID
        }

        let existing = try database.prepare(
            """
            SELECT volume_id, base_generation_id, revision, sealed_revision
            FROM run_targets
            WHERE run_id = ? AND target_kind = ? AND target_id = ?
            """
        )
        try existing.bind(runID.rawValue.uuidString, at: 1)
        try existing.bind(kind, at: 2)
        try existing.bind(id, at: 3)
        if try existing.step() {
            guard existing.columnText(0) == volumeID.rawValue,
                existing.columnText(1) == baseGenerationID.rawValue.uuidString
            else {
                throw StoreInvariantError.targetRevisionMismatch
            }
            return TargetDescriptor(
                kind: kind,
                id: id,
                volumeID: volumeID,
                baseGenerationID: baseGenerationID,
                revision: existing.columnInt64(2),
                sealedRevision: optionalInt64(existing, column: 3)
            )
        }

        guard createIfNeeded else {
            throw StoreInvariantError.targetRevisionMismatch
        }
        let insert = try database.prepare(
            """
            INSERT INTO run_targets(
                run_id, target_kind, target_id, volume_id,
                base_generation_id, revision, sealed_revision
            ) VALUES (?, ?, ?, ?, ?, 0, NULL)
            """
        )
        try insert.bind(runID.rawValue.uuidString, at: 1)
        try insert.bind(kind, at: 2)
        try insert.bind(id, at: 3)
        try insert.bind(volumeID.rawValue, at: 4)
        try insert.bind(baseGenerationID.rawValue.uuidString, at: 5)
        _ = try insert.step()
        return TargetDescriptor(
            kind: kind,
            id: id,
            volumeID: volumeID,
            baseGenerationID: baseGenerationID,
            revision: 0,
            sealedRevision: nil
        )
    }

    fileprivate func loadState(for volumeID: MonitoredVolume.ID) throws -> InventoryState? {
        let statement = try database.prepare(
            """
            SELECT c.event_store_uuid, c.last_committed_event_id,
                   c.active_generation_id, c.topology_fingerprint,
                   c.last_successful_incremental_at, c.last_successful_full_scan_at,
                   g.volume_id, g.created_by_run_id, g.state, g.created_at
            FROM checkpoints c
            JOIN inventory_generations g ON g.id = c.active_generation_id
            WHERE c.volume_id = ?
            """
        )
        try statement.bind(volumeID.rawValue, at: 1)
        guard try statement.step() else { return nil }
        guard let generationString = statement.columnText(2),
            let generationUUID = UUID(uuidString: generationString),
            let generationVolume = statement.columnText(6),
            let runString = statement.columnText(7),
            let runUUID = UUID(uuidString: runString),
            let stateString = statement.columnText(8),
            let generationState = InventoryGeneration.State(rawValue: stateString)
        else {
            throw StoreInvariantError.corruptStoredValue("checkpoint/generation")
        }

        let generationID = InventoryGeneration.ID(generationUUID)
        let checkpoint = Checkpoint(
            volumeID: volumeID,
            eventStoreUUID: try optionalUUID(statement.columnText(0), field: "event_store_uuid"),
            lastCommittedEventID: statement.columnIsNull(1) ? nil : unsignedInteger(statement.columnInt64(1)),
            activeGenerationID: generationID,
            topologyFingerprint: statement.columnText(3) ?? "",
            lastSuccessfulIncrementalAt: optionalDate(statement, column: 4),
            lastSuccessfulFullScanAt: Date(timeIntervalSince1970: statement.columnDouble(5))
        )
        let generation = InventoryGeneration(
            id: generationID,
            volumeID: MonitoredVolume.ID(generationVolume),
            createdByRunID: ScanRun.ID(runUUID),
            state: generationState,
            createdAt: Date(timeIntervalSince1970: statement.columnDouble(9))
        )
        return try InventoryState(checkpoint: checkpoint, activeGeneration: generation)
    }

    fileprivate func upsert(record: InventoryRecord, generationID: InventoryGeneration.ID) throws {
        try upsert(
            record: record,
            generationID: generationID,
            objectStatement: database.prepare(Self.upsertObjectSQL),
            pathStatement: database.prepare(Self.upsertPathSQL)
        )
    }

    fileprivate func upsert(
        record: InventoryRecord,
        generationID: InventoryGeneration.ID,
        objectStatement: SQLiteStatement,
        pathStatement: SQLiteStatement
    ) throws {
        try objectStatement.bind(generationID.rawValue.uuidString, at: 1)
        try objectStatement.bind(record.object.identity.volumeID.rawValue, at: 2)
        try objectStatement.bind(sqliteInteger(record.object.identity.deviceID), at: 3)
        try objectStatement.bind(sqliteInteger(record.object.identity.inode), at: 4)
        try objectStatement.bind(record.object.kind.rawValue, at: 5)
        try objectStatement.bind(record.object.footprint.logicalBytes, at: 6)
        try objectStatement.bind(record.object.footprint.allocatedBytes, at: 7)
        try objectStatement.bind(sqliteInteger(record.object.linkCount), at: 8)
        try objectStatement.bind(record.object.modifiedAt?.timeIntervalSince1970, at: 9)
        try objectStatement.bind(record.object.metadataChangedAt?.timeIntervalSince1970, at: 10)
        _ = try objectStatement.step()

        try pathStatement.bind(generationID.rawValue.uuidString, at: 1)
        try pathStatement.bind(record.path.volumeID.rawValue, at: 2)
        try pathStatement.bind(record.path.relativePath.bytes, at: 3)
        try pathStatement.bind(record.path.parentPath?.bytes, at: 4)
        try pathStatement.bind(sqliteInteger(record.path.objectIdentity.deviceID), at: 5)
        try pathStatement.bind(sqliteInteger(record.path.objectIdentity.inode), at: 6)
        try pathStatement.bind(record.path.classification.rawValue, at: 7)
        _ = try pathStatement.step()
    }

    fileprivate func remove(path: RelativePath, generationID: InventoryGeneration.ID) throws {
        let statement = try database.prepare(
            "DELETE FROM inventory_paths WHERE generation_id = ? AND path = ?"
        )
        try statement.bind(generationID.rawValue.uuidString, at: 1)
        try statement.bind(path.bytes, at: 2)
        _ = try statement.step()
    }

    fileprivate func removeOrphanObjects(
        generationID: InventoryGeneration.ID, identities: Set<FileIdentity>? = nil
    ) throws {
        // Foreign-key cascade planning can prefer the generation-only path
        // primary key without cardinality statistics, even with the matching
        // composite index present. Bounded analysis keeps each orphan removal
        // indexed instead of rescanning every path in a large generation.
        // Reuse full-scan statistics for incremental cleanup. ANALYZE may
        // count the WITHOUT ROWID table even with a bounded index sample.
        if identities == nil { try database.execute("ANALYZE inventory_paths") }
        let statement = try database.prepare(
            """
            DELETE FROM inventory_objects
            WHERE generation_id = ?
              \(identities == nil ? "" : "AND device_id = ? AND inode = ?")
              AND NOT EXISTS (
                  SELECT 1 FROM inventory_paths p
                  WHERE p.generation_id = inventory_objects.generation_id
                    AND p.device_id = inventory_objects.device_id
                    AND p.inode = inventory_objects.inode
              )
            """
        )
        if let identities {
            for identity in identities {
                try statement.reset()
                try statement.bind(generationID.rawValue.uuidString, at: 1)
                try statement.bind(sqliteInteger(identity.deviceID), at: 2)
                try statement.bind(sqliteInteger(identity.inode), at: 3)
                _ = try statement.step()
            }
        } else {
            try statement.bind(generationID.rawValue.uuidString, at: 1)
            _ = try statement.step()
        }
    }

    fileprivate func bindMutation(
        _ statement: SQLiteStatement,
        runID: ScanRun.ID,
        descriptor: TargetDescriptor,
        operation: String,
        record: InventoryRecord?,
        removedPath: RelativePath?
    ) throws {
        let path = record?.path.relativePath ?? removedPath!
        try statement.bind(runID.rawValue.uuidString, at: 1)
        try statement.bind(descriptor.kind, at: 2)
        try statement.bind(descriptor.id, at: 3)
        try statement.bind(descriptor.volumeID.rawValue, at: 4)
        try statement.bind(path.bytes, at: 5)
        try statement.bind(operation, at: 6)
        try statement.bind(record?.path.parentPath?.bytes, at: 7)
        try statement.bind(record.map { sqliteInteger($0.object.identity.deviceID) }, at: 8)
        try statement.bind(record.map { sqliteInteger($0.object.identity.inode) }, at: 9)
        try statement.bind(record?.object.kind.rawValue, at: 10)
        try statement.bind(record?.object.footprint.logicalBytes, at: 11)
        try statement.bind(record?.object.footprint.allocatedBytes, at: 12)
        try statement.bind(record.map { sqliteInteger($0.object.linkCount) }, at: 13)
        try statement.bind(record?.object.modifiedAt?.timeIntervalSince1970, at: 14)
        try statement.bind(record?.object.metadataChangedAt?.timeIntervalSince1970, at: 15)
        try statement.bind(record?.path.classification.rawValue, at: 16)
    }

    fileprivate func bindObjectMutation(
        _ statement: SQLiteStatement,
        runID: ScanRun.ID,
        descriptor: TargetDescriptor,
        object: InventoryObject
    ) throws {
        try statement.bind(runID.rawValue.uuidString, at: 1)
        try statement.bind(descriptor.kind, at: 2)
        try statement.bind(descriptor.id, at: 3)
        try statement.bind(descriptor.volumeID.rawValue, at: 4)
        try statement.bind(sqliteInteger(object.identity.deviceID), at: 5)
        try statement.bind(sqliteInteger(object.identity.inode), at: 6)
        try statement.bind(object.kind.rawValue, at: 7)
        try statement.bind(object.footprint.logicalBytes, at: 8)
        try statement.bind(object.footprint.allocatedBytes, at: 9)
        try statement.bind(sqliteInteger(object.linkCount), at: 10)
        try statement.bind(object.modifiedAt?.timeIntervalSince1970, at: 11)
        try statement.bind(object.metadataChangedAt?.timeIntervalSince1970, at: 12)
    }

    fileprivate func loadMutation(
        runID: ScanRun.ID,
        descriptor: TargetDescriptor,
        path: RelativePath
    ) throws -> InventoryMutation? {
        let statement = try database.prepare(
            """
            SELECT operation, volume_id, path, parent_path, device_id, inode,
                   kind, logical_bytes, allocated_bytes, link_count,
                   modified_at, metadata_changed_at, classification
            FROM run_mutations
            WHERE run_id = ? AND target_kind = ? AND target_id = ? AND path = ?
            """
        )
        try statement.bind(runID.rawValue.uuidString, at: 1)
        try statement.bind(descriptor.kind, at: 2)
        try statement.bind(descriptor.id, at: 3)
        try statement.bind(path.bytes, at: 4)
        guard try statement.step(), let operation = statement.columnText(0) else { return nil }
        if operation == "remove" {
            return .remove(volumeID: descriptor.volumeID, path: path)
        }
        return .upsert(try decodeInventoryRecord(from: statement, startingAt: 1))
    }

    fileprivate func loadRecord(
        generationID: InventoryGeneration.ID,
        path: RelativePath
    ) throws -> InventoryRecord? {
        let statement = try database.prepare(
            """
            SELECT p.volume_id, p.path, p.parent_path, p.device_id, p.inode,
                   o.kind, o.logical_bytes, o.allocated_bytes, o.link_count,
                   o.modified_at, o.metadata_changed_at, p.classification
            FROM inventory_paths p
            JOIN inventory_objects o
              ON o.generation_id = p.generation_id
             AND o.device_id = p.device_id AND o.inode = p.inode
            WHERE p.generation_id = ? AND p.path = ?
            """
        )
        try statement.bind(generationID.rawValue.uuidString, at: 1)
        try statement.bind(path.bytes, at: 2)
        guard try statement.step() else { return nil }
        return try decodeInventoryRecord(from: statement, startingAt: 0)
    }

    fileprivate func insertRunCanonical(
        _ path: InventoryPath,
        statement: SQLiteStatement,
        descriptor: TargetDescriptor,
        runID: ScanRun.ID
    ) throws {
        try statement.reset()
        try statement.bind(runID.rawValue.uuidString, at: 1)
        try statement.bind(descriptor.kind, at: 2)
        try statement.bind(descriptor.id, at: 3)
        try statement.bind(path.volumeID.rawValue, at: 4)
        try statement.bind(sqliteInteger(path.objectIdentity.deviceID), at: 5)
        try statement.bind(sqliteInteger(path.objectIdentity.inode), at: 6)
        try statement.bind(path.relativePath.bytes, at: 7)
        try statement.bind(path.classification.rawValue, at: 8)
        _ = try statement.step()
    }

    fileprivate func canonicalOverlayPath(
        identity: FileIdentity,
        descriptor: TargetDescriptor,
        runID: ScanRun.ID
    ) throws -> InventoryPath? {
        let statement = try database.prepare(
            """
            WITH merged AS (
                SELECT p.volume_id, p.path, p.parent_path, p.device_id, p.inode, p.classification
                FROM inventory_paths p
                WHERE p.generation_id = ?
                  AND NOT EXISTS (
                      SELECT 1 FROM run_mutations m
                      WHERE m.run_id = ? AND m.target_kind = ? AND m.target_id = ?
                        AND m.path = p.path
                  )
                UNION ALL
                SELECT m.volume_id, m.path, m.parent_path, m.device_id, m.inode, m.classification
                FROM run_mutations m
                WHERE m.run_id = ? AND m.target_kind = ? AND m.target_id = ?
                  AND m.operation = 'upsert'
            )
            SELECT volume_id, path, parent_path, device_id, inode, classification
            FROM merged
            WHERE device_id = ? AND inode = ?
            ORDER BY path
            LIMIT 1
            """
        )
        try statement.bind(descriptor.baseGenerationID.rawValue.uuidString, at: 1)
        try statement.bind(runID.rawValue.uuidString, at: 2)
        try statement.bind(descriptor.kind, at: 3)
        try statement.bind(descriptor.id, at: 4)
        try statement.bind(runID.rawValue.uuidString, at: 5)
        try statement.bind(descriptor.kind, at: 6)
        try statement.bind(descriptor.id, at: 7)
        try statement.bind(sqliteInteger(identity.deviceID), at: 8)
        try statement.bind(sqliteInteger(identity.inode), at: 9)
        guard try statement.step() else { return nil }
        return try decodeInventoryPath(from: statement, startingAt: 0)
    }

    fileprivate func overlayPathStatement(
        descriptor: TargetDescriptor,
        runID: ScanRun.ID
    ) throws -> SQLiteStatement {
        let statement = try database.prepare(
            """
            WITH merged AS (
                SELECT p.volume_id, p.path, p.parent_path, p.device_id, p.inode, p.classification
                FROM inventory_paths p
                WHERE p.generation_id = ?
                  AND NOT EXISTS (
                      SELECT 1 FROM run_mutations m
                      WHERE m.run_id = ? AND m.target_kind = ? AND m.target_id = ?
                        AND m.path = p.path
                  )
                UNION ALL
                SELECT m.volume_id, m.path, m.parent_path, m.device_id, m.inode, m.classification
                FROM run_mutations m
                WHERE m.run_id = ? AND m.target_kind = ? AND m.target_id = ?
                  AND m.operation = 'upsert'
            )
            SELECT volume_id, path, parent_path, device_id, inode, classification
            FROM merged
            ORDER BY device_id, inode, path
            """
        )
        try statement.bind(descriptor.baseGenerationID.rawValue.uuidString, at: 1)
        try statement.bind(runID.rawValue.uuidString, at: 2)
        try statement.bind(descriptor.kind, at: 3)
        try statement.bind(descriptor.id, at: 4)
        try statement.bind(runID.rawValue.uuidString, at: 5)
        try statement.bind(descriptor.kind, at: 6)
        try statement.bind(descriptor.id, at: 7)
        return statement
    }

    fileprivate func loadCanonicalPage(
        runID: ScanRun.ID,
        descriptor: TargetDescriptor,
        after: (deviceID: Int64, inode: Int64)?,
        limit: Int
    ) throws -> [CanonicalAttribution] {
        let comparison =
            after == nil
            ? ""
            : "AND (device_id, inode) > (?, ?)"
        let statement = try database.prepare(
            """
            SELECT volume_id, device_id, inode, path, classification
            FROM run_canonical_attributions
            WHERE run_id = ? AND target_kind = ? AND target_id = ?
            \(comparison)
            ORDER BY device_id, inode
            LIMIT ?
            """
        )
        try statement.bind(runID.rawValue.uuidString, at: 1)
        try statement.bind(descriptor.kind, at: 2)
        try statement.bind(descriptor.id, at: 3)
        var limitIndex: Int32 = 4
        if let after {
            try statement.bind(after.deviceID, at: 4)
            try statement.bind(after.inode, at: 5)
            limitIndex = 6
        }
        try statement.bind(Int64(limit), at: limitIndex)

        var result: [CanonicalAttribution] = []
        while try statement.step() {
            guard let volume = statement.columnText(0),
                let pathData = statement.columnData(3),
                let classificationString = statement.columnText(4),
                let classification = InventoryClassification(rawValue: classificationString)
            else {
                throw StoreInvariantError.corruptStoredValue("canonical attribution")
            }
            let identity = FileIdentity(
                volumeID: MonitoredVolume.ID(volume),
                deviceID: unsignedInteger(statement.columnInt64(1)),
                inode: unsignedInteger(statement.columnInt64(2))
            )
            result.append(
                CanonicalAttribution(
                    objectIdentity: identity,
                    path: try RelativePath(validating: pathData),
                    classification: classification
                )
            )
        }
        return result
    }

    fileprivate func nextRecord(using pager: inout OverlayPager) throws -> InventoryRecord? {
        if pager.index < pager.page.count {
            defer { pager.index += 1 }
            return pager.page[pager.index]
        }
        guard !pager.exhausted else { return nil }
        pager.page = try loadOverlayPage(
            descriptor: pager.descriptor,
            runID: pager.runID,
            after: pager.lastPath,
            limit: InventoryDiffBatch.maximumDifferenceCount
        )
        pager.index = 0
        if let last = pager.page.last {
            pager.lastPath = last.path.relativePath
        } else {
            pager.exhausted = true
            return nil
        }
        return try nextRecord(using: &pager)
    }

    fileprivate func loadOverlayRecord(
        descriptor: TargetDescriptor,
        runID: ScanRun.ID,
        path: RelativePath
    ) throws -> InventoryRecord? {
        let statement = try database.prepare(
            """
            WITH merged AS (
                SELECT p.volume_id, p.path, p.parent_path, p.device_id, p.inode,
                       COALESCE(om.kind, o.kind) AS kind,
                       COALESCE(om.logical_bytes, o.logical_bytes) AS logical_bytes,
                       COALESCE(om.allocated_bytes, o.allocated_bytes) AS allocated_bytes,
                       COALESCE(om.link_count, o.link_count) AS link_count,
                       CASE WHEN om.kind IS NOT NULL THEN om.modified_at ELSE o.modified_at END AS modified_at,
                       CASE WHEN om.kind IS NOT NULL THEN om.metadata_changed_at ELSE o.metadata_changed_at END AS metadata_changed_at,
                       p.classification
                FROM inventory_paths p
                CROSS JOIN inventory_objects o
                  ON o.generation_id = p.generation_id
                 AND o.device_id = p.device_id AND o.inode = p.inode
                LEFT JOIN run_object_mutations om
                  ON om.run_id = ? AND om.target_kind = ? AND om.target_id = ?
                 AND om.device_id = p.device_id AND om.inode = p.inode
                WHERE p.generation_id = ?
                  AND NOT EXISTS (
                      SELECT 1 FROM run_mutations m
                      WHERE m.run_id = ? AND m.target_kind = ? AND m.target_id = ?
                        AND m.path = p.path
                  )
                UNION ALL
                SELECT m.volume_id, m.path, m.parent_path, m.device_id, m.inode,
                       om.kind, om.logical_bytes, om.allocated_bytes, om.link_count,
                       om.modified_at, om.metadata_changed_at, m.classification
                FROM run_mutations m
                JOIN run_object_mutations om
                  ON om.run_id = m.run_id AND om.target_kind = m.target_kind
                 AND om.target_id = m.target_id
                 AND om.device_id = m.device_id AND om.inode = m.inode
                WHERE m.run_id = ? AND m.target_kind = ? AND m.target_id = ?
                  AND m.operation = 'upsert'
            )
            SELECT volume_id, path, parent_path, device_id, inode, kind,
                   logical_bytes, allocated_bytes, link_count,
                   modified_at, metadata_changed_at, classification
            FROM merged WHERE path = ?
            """
        )
        try bindOverlayIdentity(statement, descriptor: descriptor, runID: runID)
        try statement.bind(path.bytes, at: 11)
        guard try statement.step() else { return nil }
        return try decodeInventoryRecord(from: statement, startingAt: 0)
    }

    fileprivate func bindOverlayIdentity(
        _ statement: SQLiteStatement,
        descriptor: TargetDescriptor,
        runID: ScanRun.ID
    ) throws {
        try statement.bind(runID.rawValue.uuidString, at: 1)
        try statement.bind(descriptor.kind, at: 2)
        try statement.bind(descriptor.id, at: 3)
        try statement.bind(descriptor.baseGenerationID.rawValue.uuidString, at: 4)
        try statement.bind(runID.rawValue.uuidString, at: 5)
        try statement.bind(descriptor.kind, at: 6)
        try statement.bind(descriptor.id, at: 7)
        try statement.bind(runID.rawValue.uuidString, at: 8)
        try statement.bind(descriptor.kind, at: 9)
        try statement.bind(descriptor.id, at: 10)
    }

    fileprivate func loadOverlayPage(
        descriptor: TargetDescriptor,
        runID: ScanRun.ID,
        after: RelativePath?,
        limit: Int,
        within root: RelativePath? = nil
    ) throws -> [InventoryRecord] {
        var conditions: [String] = []
        var parameter = 11
        if let root, root != .root {
            // CROSS JOIN keeps paths as the driving table: partial ANALYZE
            // statistics must not turn a narrow subtree into an object scan.
            // Bound each ordered branch before merging: an outer LIMIT over
            // an unbounded UNION can re-sort the remaining inventory per page.
            conditions.append(
                "(path >= ?\(parameter) AND path < ?\(parameter + 1) AND (path = ?\(parameter + 2) OR path >= ?\(parameter + 3)))"
            )
            parameter += 4
        }
        if after != nil {
            conditions.append("path > ?\(parameter)")
            parameter += 1
        }
        let comparison = conditions.isEmpty ? "" : " AND " + conditions.joined(separator: " AND ")
        let baseBounds = comparison.replacingOccurrences(of: "path", with: "p.path")
        let mutationBounds = comparison.replacingOccurrences(of: "path", with: "m.path")
        let statement = try database.prepare(
            """
            WITH base_page AS (
                SELECT p.volume_id, p.path, p.parent_path, p.device_id, p.inode,
                       COALESCE(om.kind, o.kind) AS kind,
                       COALESCE(om.logical_bytes, o.logical_bytes) AS logical_bytes,
                       COALESCE(om.allocated_bytes, o.allocated_bytes) AS allocated_bytes,
                       COALESCE(om.link_count, o.link_count) AS link_count,
                       CASE WHEN om.kind IS NOT NULL THEN om.modified_at ELSE o.modified_at END AS modified_at,
                       CASE WHEN om.kind IS NOT NULL THEN om.metadata_changed_at ELSE o.metadata_changed_at END AS metadata_changed_at,
                       p.classification
                FROM inventory_paths p
                CROSS JOIN inventory_objects o
                  ON o.generation_id = p.generation_id
                 AND o.device_id = p.device_id AND o.inode = p.inode
                LEFT JOIN run_object_mutations om
                  ON om.run_id = ?1 AND om.target_kind = ?2 AND om.target_id = ?3
                 AND om.device_id = p.device_id AND om.inode = p.inode
                WHERE p.generation_id = ?4
                  AND NOT EXISTS (
                      SELECT 1 FROM run_mutations m
                      WHERE m.run_id = ?5 AND m.target_kind = ?6 AND m.target_id = ?7
                        AND m.path = p.path
                  )
                  \(baseBounds)
                ORDER BY p.path
                LIMIT ?\(parameter)
            ), mutation_page AS (
                SELECT m.volume_id, m.path, m.parent_path, m.device_id, m.inode,
                       om.kind, om.logical_bytes, om.allocated_bytes, om.link_count,
                       om.modified_at, om.metadata_changed_at, m.classification
                FROM run_mutations m
                CROSS JOIN run_object_mutations om
                  ON om.run_id = m.run_id AND om.target_kind = m.target_kind
                 AND om.target_id = m.target_id
                 AND om.device_id = m.device_id AND om.inode = m.inode
                WHERE m.run_id = ?8 AND m.target_kind = ?9 AND m.target_id = ?10
                  AND m.operation = 'upsert'
                  \(mutationBounds)
                ORDER BY m.path
                LIMIT ?\(parameter)
            )
            SELECT * FROM base_page
            UNION ALL
            SELECT * FROM mutation_page
            ORDER BY path
            LIMIT ?\(parameter)
            """
        )
        try bindOverlayIdentity(statement, descriptor: descriptor, runID: runID)
        var bindingIndex: Int32 = 11
        if let root, root != .root {
            var lower = root.bytes
            lower.append(UInt8(ascii: "/"))
            var upper = root.bytes
            upper.append(UInt8(ascii: "0"))
            try statement.bind(root.bytes, at: bindingIndex)
            try statement.bind(upper, at: bindingIndex + 1)
            try statement.bind(root.bytes, at: bindingIndex + 2)
            try statement.bind(lower, at: bindingIndex + 3)
            bindingIndex += 4
        }
        if let after {
            try statement.bind(after.bytes, at: bindingIndex)
            bindingIndex += 1
        }
        try statement.bind(Int64(limit), at: bindingIndex)

        var result: [InventoryRecord] = []
        while try statement.step() {
            result.append(try decodeInventoryRecord(from: statement, startingAt: 0))
        }
        return result
    }

    fileprivate func validateLedger(
        commit: ScanCommit,
        authoritative: TargetDescriptor
    ) throws {
        try database.execute(
            """
            CREATE TEMP TABLE IF NOT EXISTS ledger_validation_balance (
                semantic BLOB PRIMARY KEY NOT NULL,
                multiplicity INTEGER NOT NULL CHECK (multiplicity >= 0)
            ) STRICT, WITHOUT ROWID;
            DELETE FROM ledger_validation_balance;
            """
        )
        defer { try? database.execute("DELETE FROM ledger_validation_balance") }
        for change in commit.changes {
            try addActualSemantic(semantic(change))
        }

        switch commit.runKind {
        case .incremental:
            for change in try deriveIncrementalChanges(
                descriptor: authoritative,
                runID: commit.runID,
                allowCancellation: false
            ) {
                try consumeExpected(change)
            }
        case .full, .recovery:
            if let previous = commit.previousCheckpoint {
                let base = ValidationState.generation(previous.activeGenerationID)
                let expected: ValidationState
                if try hasRunTarget(
                    runID: commit.runID,
                    kind: "active",
                    id: commit.volumeID.rawValue
                ) {
                    let descriptor = try resolve(
                        target: .expectedActive(volumeID: commit.volumeID),
                        runID: commit.runID,
                        createIfNeeded: false
                    )
                    guard descriptor.isSealed else { throw StoreInvariantError.targetNotSealed }
                    expected = .overlay(descriptor, commit.runID)
                    try validateTransition(
                        from: base,
                        to: expected,
                        source: .fsevents,
                        runID: commit.runID,
                        pathMutationTarget: descriptor,
                        allowCancellation: false
                    )
                } else {
                    expected = base
                }
                try validateTransition(
                    from: expected,
                    to: .overlay(authoritative, commit.runID),
                    source: .reconciliation,
                    runID: commit.runID,
                    pathMutationTarget: nil,
                    allowCancellation: false
                )
            }
        // A first full scan establishes an opening balance. With no prior
        // inventory or physical sample, synthesizing millions of positive
        // baseline changes would be both misleading and unbounded.
        }

        let unmatched =
            try database.scalarInt64(
                "SELECT COUNT(*) FROM ledger_validation_balance WHERE multiplicity <> 0"
            ) ?? 0
        guard unmatched == 0 else { throw StoreInvariantError.ledgerMismatch }
    }

    fileprivate func collectTransitionChanges(
        from beforeState: ValidationState,
        to afterState: ValidationState,
        source: ChangeSource,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws -> [ChangeRecord] {
        let beforeStatement = try attributedStatement(for: beforeState)
        let afterStatement = try attributedStatement(for: afterState)
        var before = try nextAttributedFact(from: beforeStatement)
        var after = try nextAttributedFact(from: afterStatement)
        var result: [ChangeRecord] = []
        var comparedCount = 0
        while before != nil || after != nil {
            comparedCount += 1
            if comparedCount.isMultiple(of: 256) {
                try await observer.checkpoint()
            }
            switch (before, after) {
            case (.some(let old), .some(let new)):
                let comparison = compare(old.identity, new.identity)
                if comparison == .orderedSame {
                    result += try objectTransitionRecords(old: old, new: new, source: source, runID: runID)
                    before = try nextAttributedFact(from: beforeStatement)
                    after = try nextAttributedFact(from: afterStatement)
                } else if comparison == .orderedAscending {
                    result += try objectTransitionRecords(old: old, new: nil, source: source, runID: runID)
                    before = try nextAttributedFact(from: beforeStatement)
                } else {
                    result += try objectTransitionRecords(old: nil, new: new, source: source, runID: runID)
                    after = try nextAttributedFact(from: afterStatement)
                }
            case (.some(let old), .none):
                result += try objectTransitionRecords(old: old, new: nil, source: source, runID: runID)
                before = try nextAttributedFact(from: beforeStatement)
            case (.none, .some(let new)):
                result += try objectTransitionRecords(old: nil, new: new, source: source, runID: runID)
                after = try nextAttributedFact(from: afterStatement)
            case (.none, .none):
                break
            }
        }
        try ChangeSetValidator.validateAttributionTransfers(in: result)
        return result
    }

    fileprivate func validateTransition(
        from beforeState: ValidationState,
        to afterState: ValidationState,
        source: ChangeSource,
        runID: ScanRun.ID,
        pathMutationTarget: TargetDescriptor?,
        allowCancellation: Bool
    ) throws {
        let beforeStatement = try attributedStatement(for: beforeState)
        let afterStatement = try attributedStatement(for: afterState)
        var before = try nextAttributedFact(from: beforeStatement)
        var after = try nextAttributedFact(from: afterStatement)

        while before != nil || after != nil {
            switch (before, after) {
            case (.some(let old), .some(let new)):
                let comparison = compare(old.identity, new.identity)
                if comparison == .orderedSame {
                    try consumeObjectTransition(old: old, new: new, source: source, runID: runID)
                    before = try nextAttributedFact(from: beforeStatement)
                    after = try nextAttributedFact(from: afterStatement)
                } else if comparison == .orderedAscending {
                    try consumeObjectTransition(old: old, new: nil, source: source, runID: runID)
                    before = try nextAttributedFact(from: beforeStatement)
                } else {
                    try consumeObjectTransition(old: nil, new: new, source: source, runID: runID)
                    after = try nextAttributedFact(from: afterStatement)
                }
            case (.some(let old), .none):
                try consumeObjectTransition(old: old, new: nil, source: source, runID: runID)
                before = try nextAttributedFact(from: beforeStatement)
            case (.none, .some(let new)):
                try consumeObjectTransition(old: nil, new: new, source: source, runID: runID)
                after = try nextAttributedFact(from: afterStatement)
            case (.none, .none):
                break
            }
        }

        if source == .fsevents, let pathMutationTarget {
            for change in try pathMutationRecords(
                descriptor: pathMutationTarget,
                beforeState: beforeState,
                afterState: afterState,
                runID: runID,
                allowCancellation: allowCancellation
            ) {
                try consumeExpected(change)
            }
        }
    }

    fileprivate func consumeObjectTransition(
        old: AttributedFact?,
        new: AttributedFact?,
        source: ChangeSource,
        runID: ScanRun.ID
    ) throws {
        for change in try objectTransitionRecords(old: old, new: new, source: source, runID: runID) {
            try consumeExpected(change)
        }
    }

    fileprivate func objectTransitionRecords(
        old: AttributedFact?,
        new: AttributedFact?,
        source: ChangeSource,
        runID: ScanRun.ID
    ) throws -> [ChangeRecord] {
        // A file created and removed within the same replay has no endpoint.
        guard let identity = old?.identity ?? new?.identity else { return [] }
        switch (old, new) {
        case (.none, .some(let new)):
            let kind: ChangeKind = source == .reconciliation ? .reconciliationAddition : .eventCreated
            return [
                try ChangeRecord(
                    runID: runID,
                    volumeID: identity.volumeID,
                    objectIdentity: identity,
                    kind: kind,
                    pathBefore: nil,
                    pathAfter: new.path,
                    effect: .objectTransition(before: nil, after: new.footprint),
                    classification: new.classification
                )
            ]
        case (.some(let old), .none):
            let kind: ChangeKind = source == .reconciliation ? .reconciliationRemoval : .eventRemoved
            return [
                try ChangeRecord(
                    runID: runID,
                    volumeID: identity.volumeID,
                    objectIdentity: identity,
                    kind: kind,
                    pathBefore: old.path,
                    pathAfter: nil,
                    effect: .objectTransition(before: old.footprint, after: nil),
                    classification: old.classification
                )
            ]
        case (.some(let old), .some(let new)):
            var result: [ChangeRecord] = []
            if old.footprint != new.footprint {
                let kind: ChangeKind = source == .reconciliation ? .reconciliationCorrection : .eventModified
                result.append(
                    try ChangeRecord(
                        runID: runID,
                        volumeID: identity.volumeID,
                        objectIdentity: identity,
                        kind: kind,
                        pathBefore: old.path,
                        pathAfter: old.classification == new.classification ? new.path : old.path,
                        effect: .objectTransition(before: old.footprint, after: new.footprint),
                        classification: old.classification
                    )
                )
            }
            if old.classification != new.classification {
                result += try HardLinkCanonicalizer.attributionTransferRecords(
                    runID: runID,
                    source: source,
                    objectIdentity: identity,
                    footprint: new.footprint,
                    from: CanonicalAttribution(
                        objectIdentity: identity,
                        path: old.path,
                        classification: old.classification
                    ),
                    to: CanonicalAttribution(
                        objectIdentity: identity,
                        path: new.path,
                        classification: new.classification
                    )
                )
            }
            return result
        case (.none, .none):
            return []
        }
    }

    fileprivate func pathMutationRecords(
        descriptor: TargetDescriptor,
        beforeState: ValidationState,
        afterState: ValidationState,
        runID: ScanRun.ID,
        allowCancellation: Bool = true
    ) throws -> [ChangeRecord] {
        let statement = try database.prepare(
            """
            SELECT m.path, p.volume_id, p.device_id, p.inode,
                   m.operation, m.volume_id, m.device_id, m.inode
            FROM run_mutations m
            LEFT JOIN inventory_paths p
              ON p.generation_id = ? AND p.path = m.path
            WHERE m.run_id = ? AND m.target_kind = ? AND m.target_id = ?
            ORDER BY m.path
            """
        )
        try statement.bind(descriptor.baseGenerationID.rawValue.uuidString, at: 1)
        try statement.bind(runID.rawValue.uuidString, at: 2)
        try statement.bind(descriptor.kind, at: 3)
        try statement.bind(descriptor.id, at: 4)

        var removed: [FileIdentity: Set<RelativePath>] = [:]
        var added: [FileIdentity: Set<RelativePath>] = [:]
        var result: [ChangeRecord] = []
        var mutationCount = 0
        while try statement.step() {
            mutationCount += 1
            if allowCancellation, mutationCount.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            guard let pathData = statement.columnData(0),
                let operation = statement.columnText(4)
            else { throw StoreInvariantError.corruptStoredValue("path mutation") }
            let path = try RelativePath(validating: pathData)
            let oldIdentity: FileIdentity?
            if let volume = statement.columnText(1), !statement.columnIsNull(2), !statement.columnIsNull(3) {
                oldIdentity = FileIdentity(
                    volumeID: MonitoredVolume.ID(volume),
                    deviceID: unsignedInteger(statement.columnInt64(2)),
                    inode: unsignedInteger(statement.columnInt64(3))
                )
            } else {
                oldIdentity = nil
            }
            let newIdentity: FileIdentity?
            if operation == "upsert", let volume = statement.columnText(5),
                !statement.columnIsNull(6), !statement.columnIsNull(7)
            {
                newIdentity = FileIdentity(
                    volumeID: MonitoredVolume.ID(volume),
                    deviceID: unsignedInteger(statement.columnInt64(6)),
                    inode: unsignedInteger(statement.columnInt64(7))
                )
            } else {
                newIdentity = nil
            }
            if oldIdentity != newIdentity {
                if let oldIdentity { removed[oldIdentity, default: []].insert(path) }
                if let newIdentity { added[newIdentity, default: []].insert(path) }
            }
        }

        let identities = Set(removed.keys).union(added.keys)
        for identity in identities {
            let old = try attributedFact(in: beforeState, identity: identity)
            let new = try attributedFact(in: afterState, identity: identity)
            var removedPaths = removed[identity, default: []]
            var addedPaths = added[identity, default: []]
            if old == nil, let new { addedPaths.remove(new.path) }
            if new == nil, let old { removedPaths.remove(old.path) }
            let classification = new?.classification ?? old?.classification ?? .ordinary
            var sortedRemoved = sortedPaths(removedPaths)
            var sortedAdded = sortedPaths(addedPaths)
            while !sortedRemoved.isEmpty && !sortedAdded.isEmpty {
                result.append(
                    try ChangeRecord(
                        runID: runID,
                        volumeID: identity.volumeID,
                        objectIdentity: identity,
                        kind: .eventMoved,
                        pathBefore: sortedRemoved.removeFirst(),
                        pathAfter: sortedAdded.removeFirst(),
                        effect: .pathOnly,
                        classification: classification
                    )
                )
            }
            for path in sortedRemoved {
                result.append(
                    try ChangeRecord(
                        runID: runID,
                        volumeID: identity.volumeID,
                        objectIdentity: identity,
                        kind: .eventLinkRemoved,
                        pathBefore: path,
                        pathAfter: nil,
                        effect: .pathOnly,
                        classification: classification
                    )
                )
            }
            for path in sortedAdded {
                result.append(
                    try ChangeRecord(
                        runID: runID,
                        volumeID: identity.volumeID,
                        objectIdentity: identity,
                        kind: .eventLinkAdded,
                        pathBefore: nil,
                        pathAfter: path,
                        effect: .pathOnly,
                        classification: classification
                    )
                )
            }
        }
        return result
    }

    fileprivate func deriveIncrementalChanges(
        descriptor: TargetDescriptor,
        runID: ScanRun.ID,
        allowCancellation: Bool = true
    ) throws -> [ChangeRecord] {
        if allowCancellation {
            return try database.withTaskCancellationProgressHandler {
                try deriveIncrementalChangesBody(
                    descriptor: descriptor,
                    runID: runID,
                    allowCancellation: true
                )
            }
        }
        return try deriveIncrementalChangesBody(
            descriptor: descriptor,
            runID: runID,
            allowCancellation: false
        )
    }

    fileprivate func deriveIncrementalChangesBody(
        descriptor: TargetDescriptor,
        runID: ScanRun.ID,
        allowCancellation: Bool
    ) throws -> [ChangeRecord] {
        let beforeState = ValidationState.generation(descriptor.baseGenerationID)
        let afterState = ValidationState.overlay(descriptor, runID)
        let candidates = try incrementalCandidateIdentities(
            descriptor: descriptor,
            runID: runID,
            allowCancellation: allowCancellation
        )
        var result: [ChangeRecord] = []
        for (index, identity) in candidates.sorted(by: { compare($0, $1) == .orderedAscending }).enumerated() {
            if allowCancellation, index.isMultiple(of: 256) { try Task.checkCancellation() }
            result += try objectTransitionRecords(
                old: attributedFact(in: beforeState, identity: identity),
                new: attributedFact(in: afterState, identity: identity),
                source: .fsevents,
                runID: runID
            )
        }
        result += try pathMutationRecords(
            descriptor: descriptor,
            beforeState: beforeState,
            afterState: afterState,
            runID: runID,
            allowCancellation: allowCancellation
        )
        try ChangeSetValidator.validateAttributionTransfers(in: result)
        return result
    }

    fileprivate func incrementalCandidateIdentities(
        descriptor: TargetDescriptor,
        runID: ScanRun.ID,
        allowCancellation: Bool = true
    ) throws -> Set<FileIdentity> {
        let statement = try database.prepare(
            """
            SELECT volume_id, device_id, inode
            FROM run_object_mutations
            WHERE run_id = ? AND target_kind = ? AND target_id = ?
            UNION
            SELECT p.volume_id, p.device_id, p.inode
            FROM run_mutations m
            JOIN inventory_paths p
              ON p.generation_id = ? AND p.path = m.path
            WHERE m.run_id = ? AND m.target_kind = ? AND m.target_id = ?
            """
        )
        try statement.bind(runID.rawValue.uuidString, at: 1)
        try statement.bind(descriptor.kind, at: 2)
        try statement.bind(descriptor.id, at: 3)
        try statement.bind(descriptor.baseGenerationID.rawValue.uuidString, at: 4)
        try statement.bind(runID.rawValue.uuidString, at: 5)
        try statement.bind(descriptor.kind, at: 6)
        try statement.bind(descriptor.id, at: 7)
        var result: Set<FileIdentity> = []
        var candidateCount = 0
        while try statement.step() {
            candidateCount += 1
            if allowCancellation, candidateCount.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            guard let volume = statement.columnText(0) else {
                throw StoreInvariantError.corruptStoredValue("incremental candidate")
            }
            result.insert(
                FileIdentity(
                    volumeID: MonitoredVolume.ID(volume),
                    deviceID: unsignedInteger(statement.columnInt64(1)),
                    inode: unsignedInteger(statement.columnInt64(2))
                )
            )
        }
        return result
    }

    fileprivate func attributedStatement(for state: ValidationState) throws -> SQLiteStatement {
        switch state {
        case .generation(let generationID):
            let statement = try database.prepare(
                """
                SELECT c.volume_id, c.device_id, c.inode,
                       o.logical_bytes, o.allocated_bytes, c.path, c.classification
                FROM canonical_attributions c
                JOIN inventory_objects o
                  ON o.generation_id = c.generation_id
                 AND o.device_id = c.device_id AND o.inode = c.inode
                WHERE c.generation_id = ?
                ORDER BY c.device_id, c.inode
                """
            )
            try statement.bind(generationID.rawValue.uuidString, at: 1)
            return statement
        case .overlay(let descriptor, let runID):
            let statement = try database.prepare(
                """
                SELECT c.volume_id, c.device_id, c.inode,
                       CASE WHEN om.device_id IS NOT NULL THEN om.logical_bytes ELSE o.logical_bytes END,
                       CASE WHEN om.device_id IS NOT NULL THEN om.allocated_bytes ELSE o.allocated_bytes END,
                       c.path, c.classification
                FROM run_canonical_attributions c
                LEFT JOIN inventory_objects o
                  ON o.generation_id = ?
                 AND o.device_id = c.device_id AND o.inode = c.inode
                LEFT JOIN run_object_mutations om
                  ON om.run_id = c.run_id AND om.target_kind = c.target_kind
                 AND om.target_id = c.target_id
                 AND om.device_id = c.device_id AND om.inode = c.inode
                WHERE c.run_id = ? AND c.target_kind = ? AND c.target_id = ?
                ORDER BY c.device_id, c.inode
                """
            )
            try statement.bind(descriptor.baseGenerationID.rawValue.uuidString, at: 1)
            try statement.bind(runID.rawValue.uuidString, at: 2)
            try statement.bind(descriptor.kind, at: 3)
            try statement.bind(descriptor.id, at: 4)
            return statement
        }
    }

    fileprivate func nextAttributedFact(from statement: SQLiteStatement) throws -> AttributedFact? {
        guard try statement.step() else { return nil }
        return try decodeAttributedFact(from: statement)
    }

    fileprivate func attributedFact(
        in state: ValidationState,
        identity: FileIdentity
    ) throws -> AttributedFact? {
        let statement: SQLiteStatement
        switch state {
        case .generation(let generationID):
            statement = try database.prepare(
                """
                SELECT c.volume_id, c.device_id, c.inode,
                       o.logical_bytes, o.allocated_bytes, c.path, c.classification
                FROM canonical_attributions c
                JOIN inventory_objects o
                  ON o.generation_id = c.generation_id
                 AND o.device_id = c.device_id AND o.inode = c.inode
                WHERE c.generation_id = ? AND c.device_id = ? AND c.inode = ?
                """
            )
            try statement.bind(generationID.rawValue.uuidString, at: 1)
            try statement.bind(sqliteInteger(identity.deviceID), at: 2)
            try statement.bind(sqliteInteger(identity.inode), at: 3)
        case .overlay(let descriptor, let runID):
            statement = try database.prepare(
                """
                SELECT c.volume_id, c.device_id, c.inode,
                       CASE WHEN om.device_id IS NOT NULL THEN om.logical_bytes ELSE o.logical_bytes END,
                       CASE WHEN om.device_id IS NOT NULL THEN om.allocated_bytes ELSE o.allocated_bytes END,
                       c.path, c.classification
                FROM run_canonical_attributions c
                LEFT JOIN inventory_objects o
                  ON o.generation_id = ?
                 AND o.device_id = c.device_id AND o.inode = c.inode
                LEFT JOIN run_object_mutations om
                  ON om.run_id = c.run_id AND om.target_kind = c.target_kind
                 AND om.target_id = c.target_id
                 AND om.device_id = c.device_id AND om.inode = c.inode
                WHERE c.run_id = ? AND c.target_kind = ? AND c.target_id = ?
                  AND c.device_id = ? AND c.inode = ?
                """
            )
            try statement.bind(descriptor.baseGenerationID.rawValue.uuidString, at: 1)
            try statement.bind(runID.rawValue.uuidString, at: 2)
            try statement.bind(descriptor.kind, at: 3)
            try statement.bind(descriptor.id, at: 4)
            try statement.bind(sqliteInteger(identity.deviceID), at: 5)
            try statement.bind(sqliteInteger(identity.inode), at: 6)
        }
        guard try statement.step() else { return nil }
        return try decodeAttributedFact(from: statement)
    }

    fileprivate func decodeAttributedFact(from statement: SQLiteStatement) throws -> AttributedFact {
        guard let volume = statement.columnText(0),
            let pathData = statement.columnData(5),
            let classificationString = statement.columnText(6),
            let classification = InventoryClassification(rawValue: classificationString),
            !statement.columnIsNull(3), !statement.columnIsNull(4)
        else { throw StoreInvariantError.corruptStoredValue("attributed fact") }
        return AttributedFact(
            identity: FileIdentity(
                volumeID: MonitoredVolume.ID(volume),
                deviceID: unsignedInteger(statement.columnInt64(1)),
                inode: unsignedInteger(statement.columnInt64(2))
            ),
            footprint: try FileFootprint(
                logicalBytes: statement.columnInt64(3),
                allocatedBytes: statement.columnInt64(4)
            ),
            path: try RelativePath(validating: pathData),
            classification: classification
        )
    }

    fileprivate func compare(_ lhs: FileIdentity, _ rhs: FileIdentity) -> ComparisonResult {
        let lhsKey = (sqliteInteger(lhs.deviceID), sqliteInteger(lhs.inode))
        let rhsKey = (sqliteInteger(rhs.deviceID), sqliteInteger(rhs.inode))
        if lhsKey == rhsKey { return .orderedSame }
        return lhsKey < rhsKey ? .orderedAscending : .orderedDescending
    }

    fileprivate func addActualSemantic(_ semantic: LedgerSemantic) throws {
        let statement = try database.prepare(
            """
            INSERT INTO ledger_validation_balance(semantic, multiplicity)
            VALUES (?, 1)
            ON CONFLICT(semantic) DO UPDATE SET multiplicity = multiplicity + 1
            """
        )
        try statement.bind(semanticKey(semantic), at: 1)
        _ = try statement.step()
    }

    fileprivate func consumeExpected(_ change: ChangeRecord) throws {
        let statement = try database.prepare(
            """
            UPDATE ledger_validation_balance SET multiplicity = multiplicity - 1
            WHERE semantic = ? AND multiplicity > 0
            """
        )
        try statement.bind(semanticKey(semantic(change)), at: 1)
        _ = try statement.step()
        guard database.changes == 1 else { throw StoreInvariantError.ledgerMismatch }
    }

    fileprivate func semantic(_ change: ChangeRecord) -> LedgerSemantic {
        let effect: String
        var before: FileFootprint?
        var after: FileFootprint?
        var transfer: FileFootprint?
        var direction: AttributionTransferDirection?
        switch change.effect {
        case .objectTransition(let old, let new):
            effect = "object"
            before = old
            after = new
        case .attributionTransfer(let footprint, let value):
            effect = "transfer"
            transfer = footprint
            direction = value
        case .pathOnly:
            effect = "path"
        }
        return LedgerSemantic(
            identity: change.objectIdentity,
            kind: change.kind.rawValue,
            classification: change.classification.rawValue,
            pathBefore: change.pathBefore,
            pathAfter: change.pathAfter,
            effect: effect,
            beforeLogical: before?.logicalBytes,
            beforeAllocated: before?.allocatedBytes,
            afterLogical: after?.logicalBytes,
            afterAllocated: after?.allocatedBytes,
            transferLogical: transfer?.logicalBytes,
            transferAllocated: transfer?.allocatedBytes,
            transferDirection: direction?.rawValue
        )
    }

    fileprivate func sortedPaths(_ paths: Set<RelativePath>) -> [RelativePath] {
        paths.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
    }

    fileprivate func semanticKey(_ value: LedgerSemantic) -> Data {
        var data = Data()
        append(value.identity.volumeID.rawValue, to: &data)
        append(Int64(bitPattern: value.identity.deviceID), to: &data)
        append(Int64(bitPattern: value.identity.inode), to: &data)
        append(value.kind, to: &data)
        append(value.classification, to: &data)
        append(value.pathBefore?.bytes, to: &data)
        append(value.pathAfter?.bytes, to: &data)
        append(value.effect, to: &data)
        append(value.beforeLogical, to: &data)
        append(value.beforeAllocated, to: &data)
        append(value.afterLogical, to: &data)
        append(value.afterAllocated, to: &data)
        append(value.transferLogical, to: &data)
        append(value.transferAllocated, to: &data)
        append(value.transferDirection, to: &data)
        return data
    }

    fileprivate func append(_ value: String?, to data: inout Data) {
        append(value.map { Data($0.utf8) }, to: &data)
    }

    fileprivate func append(_ value: Data?, to data: inout Data) {
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }

    fileprivate func append(_ value: Int64?, to data: inout Data) {
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        var bits = UInt64(bitPattern: value).bigEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    fileprivate func hasRunTarget(runID: ScanRun.ID, kind: String, id: String) throws -> Bool {
        let statement = try database.prepare(
            "SELECT 1 FROM run_targets WHERE run_id = ? AND target_kind = ? AND target_id = ?"
        )
        try statement.bind(runID.rawValue.uuidString, at: 1)
        try statement.bind(kind, at: 2)
        try statement.bind(id, at: 3)
        return try statement.step()
    }

    fileprivate func applyMutations(
        runID: ScanRun.ID, descriptor: TargetDescriptor, orphanCandidates: Set<FileIdentity>? = nil
    ) throws {
        let statement = try database.prepare(
            """
            SELECT m.operation, m.volume_id, m.path, m.parent_path, m.device_id, m.inode,
                   om.kind, om.logical_bytes, om.allocated_bytes, om.link_count,
                   om.modified_at, om.metadata_changed_at, m.classification
            FROM run_mutations m
            LEFT JOIN run_object_mutations om
              ON om.run_id = m.run_id AND om.target_kind = m.target_kind
             AND om.target_id = m.target_id
             AND om.device_id = m.device_id AND om.inode = m.inode
            WHERE m.run_id = ? AND m.target_kind = ? AND m.target_id = ?
            ORDER BY m.path
            """
        )
        try statement.bind(runID.rawValue.uuidString, at: 1)
        try statement.bind(descriptor.kind, at: 2)
        try statement.bind(descriptor.id, at: 3)
        while try statement.step() {
            guard let operation = statement.columnText(0),
                let pathData = statement.columnData(2)
            else {
                throw StoreInvariantError.corruptStoredValue("mutation")
            }
            if operation == "remove" {
                try remove(
                    path: RelativePath(validating: pathData),
                    generationID: descriptor.baseGenerationID
                )
            } else {
                try upsert(
                    record: decodeInventoryRecord(from: statement, startingAt: 1),
                    generationID: descriptor.baseGenerationID
                )
            }
        }
        try removeOrphanObjects(generationID: descriptor.baseGenerationID, identities: orphanCandidates)
    }

    fileprivate func clearCanonicalAttributions(
        generationID: InventoryGeneration.ID,
        identities: Set<FileIdentity>
    ) throws {
        let statement = try database.prepare(
            """
            DELETE FROM canonical_attributions
            WHERE generation_id = ? AND device_id = ? AND inode = ?
            """
        )
        for identity in identities {
            try statement.reset()
            try statement.bind(generationID.rawValue.uuidString, at: 1)
            try statement.bind(sqliteInteger(identity.deviceID), at: 2)
            try statement.bind(sqliteInteger(identity.inode), at: 3)
            _ = try statement.step()
        }
    }

    fileprivate func applyIncrementalCanonicalAttributions(
        runID: ScanRun.ID,
        descriptor: TargetDescriptor,
        generationID: InventoryGeneration.ID,
        candidates: Set<FileIdentity>
    ) throws {
        let insert = try database.prepare(
            """
            INSERT INTO canonical_attributions(
                generation_id, volume_id, device_id, inode, path, classification
            )
            SELECT ?, volume_id, device_id, inode, path, classification
            FROM run_canonical_attributions
            WHERE run_id = ? AND target_kind = ? AND target_id = ?
            """
        )
        try insert.bind(generationID.rawValue.uuidString, at: 1)
        try insert.bind(runID.rawValue.uuidString, at: 2)
        try insert.bind(descriptor.kind, at: 3)
        try insert.bind(descriptor.id, at: 4)
        _ = try insert.step()

        let verify = try database.prepare(
            """
            SELECT
              EXISTS(SELECT 1 FROM inventory_objects
                     WHERE generation_id = ? AND device_id = ? AND inode = ?),
              EXISTS(SELECT 1 FROM canonical_attributions
                     WHERE generation_id = ? AND device_id = ? AND inode = ?)
            """
        )
        for identity in candidates {
            try verify.reset()
            try verify.bind(generationID.rawValue.uuidString, at: 1)
            try verify.bind(sqliteInteger(identity.deviceID), at: 2)
            try verify.bind(sqliteInteger(identity.inode), at: 3)
            try verify.bind(generationID.rawValue.uuidString, at: 4)
            try verify.bind(sqliteInteger(identity.deviceID), at: 5)
            try verify.bind(sqliteInteger(identity.inode), at: 6)
            guard try verify.step(), verify.columnInt64(0) == verify.columnInt64(1) else {
                throw StoreInvariantError.missingCanonicalAttribution
            }
        }
    }

    fileprivate func clearCanonicalAttributions(
        generationID: InventoryGeneration.ID
    ) throws {
        let statement = try database.prepare(
            "DELETE FROM canonical_attributions WHERE generation_id = ?"
        )
        try statement.bind(generationID.rawValue.uuidString, at: 1)
        _ = try statement.step()
    }

    fileprivate func applyCanonicalAttributions(
        runID: ScanRun.ID,
        descriptor: TargetDescriptor,
        generationID: InventoryGeneration.ID
    ) throws {
        let delete = try database.prepare(
            "DELETE FROM canonical_attributions WHERE generation_id = ?"
        )
        try delete.bind(generationID.rawValue.uuidString, at: 1)
        _ = try delete.step()

        let insert = try database.prepare(
            """
            INSERT INTO canonical_attributions(
                generation_id, volume_id, device_id, inode, path, classification
            )
            SELECT ?, volume_id, device_id, inode, path, classification
            FROM run_canonical_attributions
            WHERE run_id = ? AND target_kind = ? AND target_id = ?
            """
        )
        try insert.bind(generationID.rawValue.uuidString, at: 1)
        try insert.bind(runID.rawValue.uuidString, at: 2)
        try insert.bind(descriptor.kind, at: 3)
        try insert.bind(descriptor.id, at: 4)
        _ = try insert.step()

        let counts = try database.prepare(
            """
            SELECT
              (SELECT COUNT(*) FROM inventory_objects WHERE generation_id = ?),
              (SELECT COUNT(*) FROM canonical_attributions WHERE generation_id = ?)
            """
        )
        try counts.bind(generationID.rawValue.uuidString, at: 1)
        try counts.bind(generationID.rawValue.uuidString, at: 2)
        guard try counts.step(), counts.columnInt64(0) == counts.columnInt64(1) else {
            throw StoreInvariantError.missingCanonicalAttribution
        }
    }

    fileprivate func activate(
        generationID: InventoryGeneration.ID,
        volumeID: MonitoredVolume.ID
    ) throws {
        let retire = try database.prepare(
            "UPDATE inventory_generations SET state = 'retired' WHERE volume_id = ? AND state = 'active'"
        )
        try retire.bind(volumeID.rawValue, at: 1)
        _ = try retire.step()

        let activate = try database.prepare(
            """
            UPDATE inventory_generations SET state = 'active'
            WHERE id = ? AND volume_id = ? AND state = 'staging'
            """
        )
        try activate.bind(generationID.rawValue.uuidString, at: 1)
        try activate.bind(volumeID.rawValue, at: 2)
        _ = try activate.step()
        guard database.changes == 1 else {
            throw StoreInvariantError.generationStateMismatch
        }
    }

    fileprivate func verifyPreviousCheckpoint(
        _ expected: Checkpoint?,
        volumeID: MonitoredVolume.ID
    ) throws {
        let actual = try loadState(for: volumeID)?.checkpoint
        guard actual == expected else {
            throw StoreInvariantError.checkpointMismatch
        }
    }

    fileprivate func upsert(checkpoint: Checkpoint) throws {
        let statement = try database.prepare(
            """
            INSERT INTO checkpoints(
                volume_id, event_store_uuid, last_committed_event_id,
                active_generation_id, topology_fingerprint,
                last_successful_incremental_at, last_successful_full_scan_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(volume_id) DO UPDATE SET
                event_store_uuid = excluded.event_store_uuid,
                last_committed_event_id = excluded.last_committed_event_id,
                active_generation_id = excluded.active_generation_id,
                topology_fingerprint = excluded.topology_fingerprint,
                last_successful_incremental_at = excluded.last_successful_incremental_at,
                last_successful_full_scan_at = excluded.last_successful_full_scan_at
            """
        )
        try statement.bind(checkpoint.volumeID.rawValue, at: 1)
        try statement.bind(checkpoint.eventStoreUUID?.uuidString, at: 2)
        try statement.bind(checkpoint.lastCommittedEventID.map(sqliteInteger), at: 3)
        try statement.bind(checkpoint.activeGenerationID.rawValue.uuidString, at: 4)
        try statement.bind(checkpoint.topologyFingerprint, at: 5)
        try statement.bind(checkpoint.lastSuccessfulIncrementalAt?.timeIntervalSince1970, at: 6)
        try statement.bind(checkpoint.lastSuccessfulFullScanAt.timeIntervalSince1970, at: 7)
        _ = try statement.step()
    }

    fileprivate func write(changes: [ChangeRecord]) throws {
        guard !changes.isEmpty else { return }
        let statement = try database.prepare(
            """
            INSERT INTO change_ledger(
                run_id, volume_id, kind, source, transfer_id,
                path_before, path_after, logical_delta, allocated_delta,
                classification, payload_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        for change in changes {
            try statement.reset()
            try statement.bind(change.runID.rawValue.uuidString, at: 1)
            try statement.bind(change.volumeID.rawValue, at: 2)
            try statement.bind(change.kind.rawValue, at: 3)
            try statement.bind(change.source.rawValue, at: 4)
            try statement.bind(change.transferID?.uuidString, at: 5)
            try statement.bind(change.pathBefore?.bytes, at: 6)
            try statement.bind(change.pathAfter?.bytes, at: 7)
            try statement.bind(change.logicalDelta, at: 8)
            try statement.bind(change.allocatedDelta, at: 9)
            try statement.bind(change.classification.rawValue, at: 10)
            try statement.bind(encoder.encode(change), at: 11)
            _ = try statement.step()
        }
    }

    fileprivate func write(samples: [StorageSample], runID: ScanRun.ID) throws {
        guard !samples.isEmpty else { return }
        let statement = try database.prepare(
            """
            INSERT INTO storage_samples(
                run_id, storage_domain_id, sampled_at, capacity_bytes,
                used_bytes, available_bytes, important_available_bytes,
                opportunistic_available_bytes
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        for sample in samples {
            try statement.reset()
            try statement.bind(runID.rawValue.uuidString, at: 1)
            try statement.bind(sample.storageDomainID.rawValue, at: 2)
            try statement.bind(sample.sampledAt.timeIntervalSince1970, at: 3)
            try statement.bind(sample.capacityBytes, at: 4)
            try statement.bind(sample.usedBytes, at: 5)
            try statement.bind(sample.availableBytes, at: 6)
            try statement.bind(sample.importantUsageAvailableBytes, at: 7)
            try statement.bind(sample.opportunisticUsageAvailableBytes, at: 8)
            _ = try statement.step()
        }
    }

    fileprivate func write(coverage: ScanCoverage, runID: ScanRun.ID) throws {
        let statement = try database.prepare(
            """
            INSERT INTO scan_summaries(
                run_id, visited_path_count, indexed_object_count,
                unreadable_path_count, transient_error_count
            ) VALUES (?, ?, ?, ?, ?)
            """
        )
        try statement.bind(runID.rawValue.uuidString, at: 1)
        try statement.bind(Int64(bitPattern: coverage.visitedPathCount), at: 2)
        try statement.bind(Int64(bitPattern: coverage.indexedObjectCount), at: 3)
        try statement.bind(Int64(bitPattern: coverage.unreadablePathCount), at: 4)
        try statement.bind(Int64(bitPattern: coverage.transientErrorCount), at: 5)
        _ = try statement.step()
    }

    fileprivate func writeSnapshotObservations(
        volumeIDs: Set<MonitoredVolume.ID>,
        runID: ScanRun.ID,
        observedAt: Date
    ) throws {
        let statement = try database.prepare(
            """
            INSERT INTO snapshot_observations(run_id, volume_id, observed_at)
            VALUES (?, ?, ?)
            """
        )
        for volumeID in volumeIDs {
            try statement.reset()
            try statement.bind(runID.rawValue.uuidString, at: 1)
            try statement.bind(volumeID.rawValue, at: 2)
            try statement.bind(observedAt.timeIntervalSince1970, at: 3)
            _ = try statement.step()
        }
    }

    fileprivate func write(overhead: DailyDiskOverheadSample?, runID: ScanRun.ID) throws {
        guard let overhead else { return }
        let statement = try database.prepare(
            """
            INSERT INTO overhead_samples(run_id, storage_domain_id, sampled_at, allocated_bytes)
            VALUES (?, ?, ?, ?)
            """
        )
        try statement.bind(runID.rawValue.uuidString, at: 1)
        try statement.bind(overhead.storageDomainID.rawValue, at: 2)
        try statement.bind(overhead.sampledAt.timeIntervalSince1970, at: 3)
        try statement.bind(overhead.allocatedBytes, at: 4)
        _ = try statement.step()
    }

    fileprivate func write(snapshots: [SnapshotSample], runID: ScanRun.ID) throws {
        guard !snapshots.isEmpty else { return }
        let statement = try database.prepare(
            """
            INSERT INTO snapshot_samples(
                run_id, volume_id, sampled_at, snapshot_uuid, name,
                created_at, is_purgeable, allocated_bytes_estimate
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        for snapshot in snapshots {
            try statement.reset()
            try statement.bind(runID.rawValue.uuidString, at: 1)
            try statement.bind(snapshot.volumeID.rawValue, at: 2)
            try statement.bind(snapshot.sampledAt.timeIntervalSince1970, at: 3)
            try statement.bind(snapshot.snapshotUUID?.uuidString, at: 4)
            try statement.bind(snapshot.name, at: 5)
            try statement.bind(snapshot.createdAt?.timeIntervalSince1970, at: 6)
            if let purgeable = snapshot.isPurgeable {
                try statement.bind(purgeable, at: 7)
            } else {
                try statement.bindNull(7)
            }
            try statement.bind(snapshot.allocatedBytesEstimate, at: 8)
            _ = try statement.step()
        }
    }

    fileprivate func write(errors: [ScanErrorRecord]) throws {
        guard !errors.isEmpty else { return }
        let statement = try database.prepare(
            """
            INSERT INTO scan_errors(
                run_id, volume_id, kind, path, error_code, message
            ) VALUES (?, ?, ?, ?, ?, ?)
            """
        )
        for error in errors {
            try statement.reset()
            try statement.bind(error.runID.rawValue.uuidString, at: 1)
            try statement.bind(error.volumeID?.rawValue, at: 2)
            try statement.bind(error.kind.rawValue, at: 3)
            try statement.bind(error.path?.bytes, at: 4)
            try statement.bind(error.errorCode.map(Int64.init), at: 5)
            try statement.bind(error.message, at: 6)
            _ = try statement.step()
        }
    }

    fileprivate func cleanupStagingState(runID: ScanRun.ID) throws {
        let statement = try database.prepare("DELETE FROM run_targets WHERE run_id = ?")
        try statement.bind(runID.rawValue.uuidString, at: 1)
        _ = try statement.step()
    }

    fileprivate func pruneGenerations(volumeID: MonitoredVolume.ID, runID: ScanRun.ID) throws {
        let staging = try database.prepare(
            "DELETE FROM inventory_generations WHERE state = 'staging' AND created_by_run_id = ?"
        )
        try staging.bind(runID.rawValue.uuidString, at: 1)
        _ = try staging.step()

        let retired = try database.prepare(
            """
            DELETE FROM inventory_generations
            WHERE volume_id = ? AND state = 'retired'
              AND id NOT IN (
                  SELECT id FROM inventory_generations
                  WHERE volume_id = ? AND state = 'retired'
                  ORDER BY created_at DESC, id DESC
                  LIMIT 1
              )
            """
        )
        try retired.bind(volumeID.rawValue, at: 1)
        try retired.bind(volumeID.rawValue, at: 2)
        _ = try retired.step()
    }

    fileprivate func loadErrors(runID: ScanRun.ID) throws -> [ScanErrorRecord] {
        let statement = try database.prepare(
            """
            SELECT volume_id, kind, path, error_code, message
            FROM scan_errors WHERE run_id = ? ORDER BY id
            """
        )
        try statement.bind(runID.rawValue.uuidString, at: 1)
        var result: [ScanErrorRecord] = []
        while try statement.step() {
            guard let kindString = statement.columnText(1),
                let kind = ScanErrorRecord.Kind(rawValue: kindString),
                let message = statement.columnText(4)
            else { throw StoreInvariantError.corruptStoredValue("scan error") }
            result.append(
                ScanErrorRecord(
                    runID: runID,
                    volumeID: statement.columnText(0).map(MonitoredVolume.ID.init),
                    kind: kind,
                    path: try statement.columnData(2).map { try RelativePath(validating: $0) },
                    errorCode: statement.columnIsNull(3) ? nil : Int32(statement.columnInt64(3)),
                    message: message
                )
            )
        }
        return result
    }

    fileprivate func loadChanges(runID: ScanRun.ID) throws -> [ChangeRecord] {
        let statement = try database.prepare(
            "SELECT payload_json FROM change_ledger WHERE run_id = ? ORDER BY sequence"
        )
        try statement.bind(runID.rawValue.uuidString, at: 1)
        var result: [ChangeRecord] = []
        while try statement.step() {
            guard let data = statement.columnData(0) else {
                throw StoreInvariantError.corruptStoredValue("change payload")
            }
            result.append(try decoder.decode(ChangeRecord.self, from: data))
        }
        return result
    }

    fileprivate func contains(overhead: DailyDiskOverheadSample, runID: ScanRun.ID) throws -> Bool {
        let statement = try database.prepare(
            """
            SELECT 1 FROM overhead_samples
            WHERE run_id = ? AND storage_domain_id = ?
              AND sampled_at = ? AND allocated_bytes = ?
            """
        )
        try statement.bind(runID.rawValue.uuidString, at: 1)
        try statement.bind(overhead.storageDomainID.rawValue, at: 2)
        try statement.bind(overhead.sampledAt.timeIntervalSince1970, at: 3)
        try statement.bind(overhead.allocatedBytes, at: 4)
        return try statement.step()
    }

    fileprivate func containsOverhead(runID: ScanRun.ID) throws -> Bool {
        let statement = try database.prepare("SELECT 1 FROM overhead_samples WHERE run_id = ?")
        try statement.bind(runID.rawValue.uuidString, at: 1)
        return try statement.step()
    }

    fileprivate func latestOverhead(
        storageDomainID: StorageDomain.ID,
        before date: Date
    ) throws -> DailyDiskOverheadSample? {
        let statement = try database.prepare(
            """
            SELECT sampled_at, allocated_bytes FROM overhead_samples
            WHERE storage_domain_id = ? AND sampled_at < ?
            ORDER BY sampled_at DESC, run_id DESC LIMIT 1
            """
        )
        try statement.bind(storageDomainID.rawValue, at: 1)
        try statement.bind(date.timeIntervalSince1970, at: 2)
        guard try statement.step() else { return nil }
        return try DailyDiskOverheadSample(
            storageDomainID: storageDomainID,
            sampledAt: Date(timeIntervalSince1970: statement.columnDouble(0)),
            allocatedBytes: statement.columnInt64(1)
        )
    }

    fileprivate func contains(sample: StorageSample, runID: ScanRun.ID) throws -> Bool {
        let statement = try database.prepare(
            """
            SELECT capacity_bytes, used_bytes, available_bytes,
                   important_available_bytes, opportunistic_available_bytes
            FROM storage_samples
            WHERE run_id = ? AND storage_domain_id = ? AND sampled_at = ?
            """
        )
        try statement.bind(runID.rawValue.uuidString, at: 1)
        try statement.bind(sample.storageDomainID.rawValue, at: 2)
        try statement.bind(sample.sampledAt.timeIntervalSince1970, at: 3)
        guard try statement.step() else { return false }
        let importantAvailable = optionalInt64(statement, column: 3)
        let opportunisticAvailable = optionalInt64(statement, column: 4)
        return statement.columnInt64(0) == sample.capacityBytes
            && statement.columnInt64(1) == sample.usedBytes
            && statement.columnInt64(2) == sample.availableBytes
            && importantAvailable == sample.importantUsageAvailableBytes
            && opportunisticAvailable == sample.opportunisticUsageAvailableBytes
    }

    fileprivate func latestSample(
        before date: Date,
        storageDomainID: StorageDomain.ID
    ) throws -> StorageSample? {
        let statement = try database.prepare(
            """
            SELECT sampled_at, capacity_bytes, used_bytes, available_bytes,
                   important_available_bytes, opportunistic_available_bytes
            FROM storage_samples
            WHERE storage_domain_id = ? AND sampled_at < ?
            ORDER BY sampled_at DESC, id DESC
            LIMIT 1
            """
        )
        try statement.bind(storageDomainID.rawValue, at: 1)
        try statement.bind(date.timeIntervalSince1970, at: 2)
        guard try statement.step() else { return nil }
        return try StorageSample(
            storageDomainID: storageDomainID,
            sampledAt: Date(timeIntervalSince1970: statement.columnDouble(0)),
            capacityBytes: statement.columnInt64(1),
            usedBytes: statement.columnInt64(2),
            availableBytes: statement.columnInt64(3),
            importantUsageAvailableBytes: optionalInt64(statement, column: 4),
            opportunisticUsageAvailableBytes: optionalInt64(statement, column: 5)
        )
    }

    fileprivate func decodeInventoryPath(
        from statement: SQLiteStatement,
        startingAt offset: Int32
    ) throws -> InventoryPath {
        guard let volumeString = statement.columnText(offset),
            let pathData = statement.columnData(offset + 1),
            let classificationString = statement.columnText(offset + 5),
            let classification = InventoryClassification(rawValue: classificationString)
        else {
            throw StoreInvariantError.corruptStoredValue("inventory path")
        }
        let volumeID = MonitoredVolume.ID(volumeString)
        let path = try RelativePath(validating: pathData)
        let parentData = statement.columnData(offset + 2)
        let identity = FileIdentity(
            volumeID: volumeID,
            deviceID: unsignedInteger(statement.columnInt64(offset + 3)),
            inode: unsignedInteger(statement.columnInt64(offset + 4))
        )
        return try InventoryPath(
            volumeID: volumeID,
            relativePath: path,
            parentPath: try parentData.map { try RelativePath(validating: $0) },
            objectIdentity: identity,
            classification: classification
        )
    }

    fileprivate func decodeInventoryRecord(
        from statement: SQLiteStatement,
        startingAt offset: Int32
    ) throws -> InventoryRecord {
        guard let volumeString = statement.columnText(offset),
            let pathData = statement.columnData(offset + 1),
            let kindString = statement.columnText(offset + 5),
            let kind = FileKind(rawValue: kindString),
            let classificationString = statement.columnText(offset + 11),
            let classification = InventoryClassification(rawValue: classificationString)
        else {
            throw StoreInvariantError.corruptStoredValue("inventory record")
        }
        let volumeID = MonitoredVolume.ID(volumeString)
        let identity = FileIdentity(
            volumeID: volumeID,
            deviceID: unsignedInteger(statement.columnInt64(offset + 3)),
            inode: unsignedInteger(statement.columnInt64(offset + 4))
        )
        let object = InventoryObject(
            identity: identity,
            kind: kind,
            footprint: try FileFootprint(
                logicalBytes: statement.columnInt64(offset + 6),
                allocatedBytes: statement.columnInt64(offset + 7)
            ),
            linkCount: unsignedInteger(statement.columnInt64(offset + 8)),
            modifiedAt: optionalDate(statement, column: offset + 9),
            metadataChangedAt: optionalDate(statement, column: offset + 10)
        )
        let path = try InventoryPath(
            volumeID: volumeID,
            relativePath: RelativePath(validating: pathData),
            parentPath: try statement.columnData(offset + 2).map { try RelativePath(validating: $0) },
            objectIdentity: identity,
            classification: classification
        )
        return try InventoryRecord(object: object, path: path)
    }

    fileprivate func optionalDate(_ statement: SQLiteStatement, column: Int32) -> Date? {
        statement.columnIsNull(column) ? nil : Date(timeIntervalSince1970: statement.columnDouble(column))
    }

    fileprivate func optionalInt64(_ statement: SQLiteStatement, column: Int32) -> Int64? {
        statement.columnIsNull(column) ? nil : statement.columnInt64(column)
    }

    fileprivate func optionalUUID(_ value: String?, field: String) throws -> UUID? {
        guard let value else { return nil }
        guard let uuid = UUID(uuidString: value) else {
            throw StoreInvariantError.corruptStoredValue(field)
        }
        return uuid
    }

    fileprivate func sqliteInteger(_ value: UInt64) -> Int64 {
        Int64(bitPattern: value)
    }

    fileprivate func unsignedInteger(_ value: Int64) -> UInt64 {
        UInt64(bitPattern: value)
    }
}
