import DailyDiskCore
import DailyDiskStore
import Foundation
import Testing

struct StoreFixture {
    let rootURL: URL
    let databaseURL: URL
    let store: SQLiteInventoryStore
    let scope: StorageDomainScope
    let volume: MonitoredVolume

    init() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyDiskStoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        databaseURL = rootURL.appendingPathComponent("DailyDisk.sqlite")
        let domain = StorageDomain(
            id: StorageDomain.ID("container-test"),
            containerIdentifier: "disk-test",
            displayName: "Test Internal Disk",
            isInternal: true
        )
        volume = MonitoredVolume(
            id: MonitoredVolume.ID("volume-test"),
            storageDomainID: domain.id,
            filesystemUUID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
            eventStoreUUID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"),
            deviceID: 42,
            mountPath: "/System/Volumes/Data",
            displayName: "Data",
            role: .data,
            isInternal: true,
            isRemovable: false,
            isReadOnly: false,
            supportsPersistentEvents: true,
            topologyFingerprint: "topology-v1"
        )
        scope = try StorageDomainScope(domain: domain, volumes: [volume])
        store = try SQLiteInventoryStore(databaseURL: databaseURL)
        try await store.prepare()
        try await store.register(scope: scope)
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func record(
        path pathString: String,
        inode: UInt64,
        logicalBytes: Int64,
        allocatedBytes: Int64,
        classification: InventoryClassification = .ordinary,
        linkCount: UInt64 = 1
    ) throws -> InventoryRecord {
        let relativePath = try RelativePath(validating: pathString)
        let identity = FileIdentity(volumeID: volume.id, deviceID: volume.deviceID, inode: inode)
        let object = InventoryObject(
            identity: identity,
            kind: .regular,
            footprint: try FileFootprint(logicalBytes: logicalBytes, allocatedBytes: allocatedBytes),
            linkCount: linkCount,
            modifiedAt: Date(timeIntervalSince1970: 10),
            metadataChangedAt: Date(timeIntervalSince1970: 10)
        )
        let path = try InventoryPath(
            volumeID: volume.id,
            relativePath: relativePath,
            parentPath: PathPolicy.parent(of: relativePath),
            objectIdentity: identity,
            classification: classification
        )
        return try InventoryRecord(object: object, path: path)
    }

    func sample(usedBytes: Int64, at timestamp: TimeInterval) throws -> StorageSample {
        try StorageSample(
            storageDomainID: scope.domain.id,
            sampledAt: Date(timeIntervalSince1970: timestamp),
            capacityBytes: 1_000_000,
            usedBytes: usedBytes,
            availableBytes: 1_000_000 - usedBytes
        )
    }
}

struct BaselineResult {
    let run: ScanRun
    let generation: InventoryGeneration
    let checkpoint: Checkpoint
    let records: [InventoryRecord]
    let changes: [ChangeRecord]
    let sample: StorageSample
}

func establishBaseline(
    in fixture: StoreFixture,
    records: [InventoryRecord]? = nil
) async throws -> BaselineResult {
    let baselineRecords =
        try records ?? [
            fixture.record(path: "Users/alice/file.dat", inode: 1, logicalBytes: 100, allocatedBytes: 128)
        ]
    let run = ScanRun(
        kind: .full,
        reason: .initialBaseline,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 10)
    )
    try await fixture.store.begin(run: run)
    let generation = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id,
        runID: run.id,
        at: run.startedAt
    )
    try await fixture.store.append(records: baselineRecords, to: generation.id)
    try await fixture.store.finalizeCanonicalAttribution(
        target: .stagingGeneration(generation.id),
        runID: run.id,
        consume: { _ in }
    )

    // The first full scan is an opening balance, not interval growth. It does
    // not synthesize one positive ledger row per existing object.
    let changes: [ChangeRecord] = []
    let checkpoint = Checkpoint(
        volumeID: fixture.volume.id,
        eventStoreUUID: fixture.volume.eventStoreUUID,
        lastCommittedEventID: 10,
        activeGenerationID: generation.id,
        topologyFingerprint: fixture.volume.topologyFingerprint,
        lastSuccessfulIncrementalAt: nil,
        lastSuccessfulFullScanAt: Date(timeIntervalSince1970: 20)
    )
    let fence = EventCursorFence(
        volumeID: fixture.volume.id,
        eventStoreUUID: fixture.volume.eventStoreUUID,
        highestFullyDeliveredEventID: 10,
        phase: .liveFlush,
        trust: .trusted
    )
    let sample = try fixture.sample(usedBytes: 500_000, at: 20)
    let commit = try ScanCommit(
        runID: run.id,
        runKind: .full,
        scope: fixture.scope,
        volumeID: fixture.volume.id,
        activatedGenerationID: generation.id,
        previousCheckpoint: nil,
        checkpoint: checkpoint,
        eventFence: fence,
        changes: changes,
        storageSamples: [sample],
        snapshotSamples: []
    )
    try await fixture.store.commit(commit, finishedAt: Date(timeIntervalSince1970: 20))
    return BaselineResult(
        run: run,
        generation: generation,
        checkpoint: checkpoint,
        records: baselineRecords,
        changes: changes,
        sample: sample
    )
}

actor CanonicalCollector {
    private(set) var values: [CanonicalAttribution] = []

    func append(_ batch: CanonicalAttributionBatch) {
        values.append(contentsOf: batch.attributions)
    }
}

actor DiffCollector {
    private(set) var values: [InventoryDiff] = []

    func append(_ batch: InventoryDiffBatch) {
        values.append(contentsOf: batch.differences)
    }
}
