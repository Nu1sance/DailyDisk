import DailyDiskCore
import DailyDiskStore
import Foundation

struct RuntimeVolumeStatus: Equatable, Sendable {
    let volumeID: String
    let name: String
    let role: String
    let inventoryMode: String
    let mountPath: String?
    let lastEventID: UInt64?
    let lastIncrementalAt: Date?
    let lastFullAt: Date?
    let indexedObjectCount: Int64
}

enum RuntimeDatabaseHealth: Equatable, Sendable {
    case notChecked
    case notInitialized
    case waitingForWriter
    case verified(DatabaseVerification)
}

struct RuntimeInspectionSnapshot: Equatable, Sendable {
    let health: RuntimeDatabaseHealth
    let writerState: DatabaseWriterState?
    let volumes: [RuntimeVolumeStatus]
    let reports: [DailyReport]
    let recentRuns: [ScanRun]
    let diagnostics: DatabaseDiagnostics?
    let recentErrorKinds: [String: Int]
}

struct RuntimeInspectionService: Sendable {
    private static let rankingCache = LegacyRankingCache()
    let databaseURL: URL

    init(databaseURL: URL = SQLiteInventoryStore.defaultDatabaseURL) {
        self.databaseURL = databaseURL
    }

    func loadSnapshot(
        historyLimit: Int = 30,
        discloseMountPaths: Bool = false,
        verify: Bool = true
    ) async throws -> RuntimeInspectionSnapshot {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return emptySnapshot(health: .notInitialized, writerState: nil)
        }

        if !verify {
            do {
                let store = try SQLiteReportStore(databaseURL: databaseURL)
                let writer = try await store.writerState()
                return try await loadContents(
                    store: store, health: writer.leaseIsHeld ? .waitingForWriter : .notChecked,
                    writerState: writer, historyLimit: historyLimit,
                    discloseMountPaths: discloseMountPaths, detailed: false
                )
            } catch {
                if SQLiteReportStore.writerIsActive(databaseURL: databaseURL) {
                    return emptySnapshot(
                        health: .waitingForWriter, writerState: DatabaseWriterState(leaseIsHeld: true, activeRuns: []))
                }
                throw error
            }
        }
        do {
            // The shared process lease is acquired before any query and held
            // until every value and verification result has been loaded. A
            // writer therefore cannot start midway through this snapshot.
            let store = try SQLiteReportStore(
                databaseURL: databaseURL,
                strictReadOnly: true
            )
            let verification = try await store.verify()
            return try await loadContents(
                store: store,
                health: .verified(verification),
                writerState: try await store.writerState(),
                historyLimit: historyLimit,
                discloseMountPaths: discloseMountPaths
            )
        } catch {
            guard SQLiteReportStore.writerIsActive(databaseURL: databaseURL) else {
                throw error
            }
            // Migration or the first writer transaction may not have created
            // every table yet. Waiting is a valid GUI state, not corruption.
            do {
                let store = try SQLiteReportStore(databaseURL: databaseURL)
                return try await loadContents(
                    store: store,
                    health: .waitingForWriter,
                    writerState: try await store.writerState(),
                    historyLimit: historyLimit,
                    discloseMountPaths: discloseMountPaths
                )
            } catch {
                return emptySnapshot(
                    health: .waitingForWriter,
                    writerState: DatabaseWriterState(leaseIsHeld: true, activeRuns: [])
                )
            }
        }
    }

    func spaceUsage() async throws -> DatabaseSpaceUsage? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        return try await SQLiteReportStore(databaseURL: databaseURL).spaceUsage()
    }

    func report(
        runID: ScanRun.ID,
        storageDomainID: StorageDomain.ID? = nil
    ) async throws -> DailyReport? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        let store = try SQLiteReportStore(databaseURL: databaseURL)
        if let storageDomainID {
            let report = try await store.report(
                runID: runID,
                storageDomainID: storageDomainID
            )
            return try await corrected(report, store: store)
        }
        return try await corrected(store.report(runID: runID), store: store)
    }

    func changePage(
        report: DailyReport, afterSequence: Int64, filter: ReportChangeFilter
    ) async throws -> ReportChangePage {
        let store = try SQLiteReportStore(databaseURL: databaseURL)
        return try await store.reportChangePage(
            runID: report.runID, storageDomainID: report.storageDomainID,
            afterSequence: afterSequence, filter: filter)
    }

    private func corrected(_ report: DailyReport?, store: SQLiteReportStore) async throws -> DailyReport? {
        guard let report else { return nil }
        return try await Self.rankingCache.correct(report, databaseURL: databaseURL, store: store)
    }

    func reportJSON(
        runID: ScanRun.ID,
        storageDomainID: StorageDomain.ID? = nil
    ) async throws -> Data? {
        guard
            let report = try await report(
                runID: runID,
                storageDomainID: storageDomainID
            )
        else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    func sanitizedDiagnostics() async throws -> String {
        let snapshot = try await loadSnapshot(historyLimit: 10)
        var lines: [String] = ["DailyDisk \(DailyDiskProduct.version)"]
        switch snapshot.health {
        case .notChecked:
            lines.append("database: not verified")
        case .notInitialized:
            lines.append("database: not initialized")
        case .waitingForWriter:
            lines.append("database: waiting for active writer")
        case .verified(let verification):
            lines.append("database healthy: \(verification.isHealthy)")
            lines.append("schema: \(verification.schemaVersion)/\(verification.expectedSchemaVersion)")
        }
        if let diagnostics = snapshot.diagnostics {
            lines.append("database bytes: \(diagnostics.databaseBytes)")
            lines.append("wal bytes: \(diagnostics.walBytes)")
            for key in diagnostics.tableCounts.keys.sorted() {
                lines.append("table \(key): \(diagnostics.tableCounts[key] ?? 0)")
            }
        }
        lines.append("running rows: \(snapshot.writerState?.activeRuns.count ?? 0)")
        for key in snapshot.recentErrorKinds.keys.sorted() {
            lines.append("error \(key): \(snapshot.recentErrorKinds[key] ?? 0)")
        }
        return lines.joined(separator: "\n")
    }

    private func loadContents(
        store: SQLiteReportStore,
        health: RuntimeDatabaseHealth,
        writerState: DatabaseWriterState,
        historyLimit: Int,
        discloseMountPaths: Bool,
        detailed: Bool = true
    ) async throws -> RuntimeInspectionSnapshot {
        let volumes = try await store.volumeStatuses().map { value in
            RuntimeVolumeStatus(
                volumeID: value.volumeID,
                name: value.name,
                role: value.role,
                inventoryMode: value.inventoryMode,
                mountPath: discloseMountPaths ? value.mountPath : nil,
                lastEventID: value.lastEventID,
                lastIncrementalAt: value.lastIncrementalAt,
                lastFullAt: value.lastFullAt,
                indexedObjectCount: value.indexedObjectCount
            )
        }
        var reports = try await store.recentReports(limit: historyLimit)
        // Correct only the latest report here. Older reports are rebuilt on
        // selection, never by every overview refresh across the entire history.
        if let first = reports.first, let updated = try await corrected(first, store: store) { reports[0] = updated }
        let runs = try await store.recentRuns(limit: historyLimit)
        let diagnostics = detailed ? try await store.diagnostics() : nil
        var errorKinds: [String: Int] = [:]
        for run in runs {
            for error in try await store.errors(for: run.id) {
                errorKinds[error.kind.rawValue, default: 0] += 1
            }
        }
        return RuntimeInspectionSnapshot(
            health: health,
            writerState: writerState,
            volumes: volumes,
            reports: reports,
            recentRuns: runs,
            diagnostics: diagnostics,
            recentErrorKinds: errorKinds
        )
    }

    private func emptySnapshot(
        health: RuntimeDatabaseHealth,
        writerState: DatabaseWriterState?
    ) -> RuntimeInspectionSnapshot {
        RuntimeInspectionSnapshot(
            health: health,
            writerState: writerState,
            volumes: [],
            reports: [],
            recentRuns: [],
            diagnostics: nil,
            recentErrorKinds: [:]
        )
    }
}

private actor LegacyRankingCache {
    private var reports: [String: DailyReport] = [:]
    private var order: [String] = []

    func correct(_ report: DailyReport, databaseURL: URL, store: SQLiteReportStore) async throws -> DailyReport {
        guard report.pathRanking == nil else { return report }
        let key = "\(databaseURL.path)|\(report.runID.rawValue)|\(report.storageDomainID.rawValue)"
        if let cached = reports[key] { return cached }
        let ranking = try await store.rebuiltPathRanking(runID: report.runID, storageDomainID: report.storageDomainID)
        let corrected = try report.replacingPathRanking(ranking)
        try Task.checkCancellation()
        if reports[key] == nil { order.append(key) }
        reports[key] = corrected
        while order.count > 32 { reports.removeValue(forKey: order.removeFirst()) }
        return corrected
    }
}
