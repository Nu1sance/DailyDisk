import DailyDiskCore
import DailyDiskStore
import Foundation
import Testing

@testable import DailyDiskApp

private func inspectionDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("DailyDiskInspectionTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("DailyDisk.sqlite")
}

@Test("Missing database is represented as first-use state")
func missingInspectionDatabase() async throws {
    let url = inspectionDatabaseURL()
    let snapshot = try await RuntimeInspectionService(databaseURL: url).loadSnapshot()
    #expect(snapshot.health == .notInitialized)
    #expect(snapshot.reports.isEmpty)
    #expect(snapshot.volumes.isEmpty)
}

@Test("Active writer defers immutable verification without hiding runtime data")
func activeWriterInspection() async throws {
    let url = inspectionDatabaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try SQLiteInventoryStore(databaseURL: url)
    try await store.prepare()
    let run = ScanRun(
        kind: .incremental,
        reason: .manual,
        status: .running,
        startedAt: Date()
    )
    try await store.begin(run: run)

    let snapshot = try await RuntimeInspectionService(databaseURL: url).loadSnapshot()
    #expect(snapshot.health == .waitingForWriter)
    #expect(snapshot.writerState?.leaseIsHeld == true)
    #expect(snapshot.writerState?.activeRuns.map(\.id) == [run.id])
    #expect(snapshot.recentRuns.map(\.id) == [run.id])
    #expect(snapshot.diagnostics != nil)
}

@Test("Released database receives strict verification and diagnostics stay path-free")
func healthyInspectionAndSanitization() async throws {
    let url = inspectionDatabaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var store: SQLiteInventoryStore? = try SQLiteInventoryStore(databaseURL: url)
    try await store?.prepare()
    store = nil

    let service = RuntimeInspectionService(databaseURL: url)
    let snapshot = try await service.loadSnapshot()
    guard case .verified(let verification) = snapshot.health else {
        Issue.record("Expected strict verification")
        return
    }
    #expect(verification.isHealthy)
    let diagnostics = try await service.sanitizedDiagnostics()
    #expect(!diagnostics.contains(url.deletingLastPathComponent().path))
    #expect(diagnostics.contains("database healthy: true"))
}

@Test("Mount paths require explicit disclosure")
func inspectionMountPathDisclosure() async throws {
    let url = inspectionDatabaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var store: SQLiteInventoryStore? = try SQLiteInventoryStore(databaseURL: url)
    try await store?.prepare()
    let domain = StorageDomain(
        id: StorageDomain.ID("inspection-domain"),
        containerIdentifier: "disk-test",
        displayName: "Inspection",
        isInternal: true
    )
    let volume = MonitoredVolume(
        id: MonitoredVolume.ID("inspection-volume"),
        storageDomainID: domain.id,
        filesystemUUID: UUID(),
        eventStoreUUID: UUID(),
        deviceID: 1,
        mountPath: "/private/example",
        displayName: "Data",
        role: .data,
        isInternal: true,
        isRemovable: false,
        isReadOnly: false,
        supportsPersistentEvents: true,
        topologyFingerprint: "inspection",
        inventoryMode: .full
    )
    try await store?.register(scope: StorageDomainScope(domain: domain, volumes: [volume]))
    store = nil

    let service = RuntimeInspectionService(databaseURL: url)
    let hidden = try await service.loadSnapshot(discloseMountPaths: false)
    #expect(hidden.volumes.first?.mountPath == nil)
    let disclosed = try await service.loadSnapshot(discloseMountPaths: true)
    #expect(disclosed.volumes.first?.mountPath == "/private/example")
}

@Test("Overview reads a live WAL without running whole-database verification")
func lightweightOverviewInspection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("DailyDisk.sqlite")
    var store: SQLiteInventoryStore? = try SQLiteInventoryStore(databaseURL: url)
    try await store?.prepare()
    let service = RuntimeInspectionService(databaseURL: url)
    let live = try await service.loadSnapshot(verify: false)
    #expect(live.health == .waitingForWriter)
    #expect(live.diagnostics == nil)
    store = nil
    let idle = try await service.loadSnapshot(verify: false)
    #expect(idle.health == .notChecked)
    #expect(idle.diagnostics == nil)
}
