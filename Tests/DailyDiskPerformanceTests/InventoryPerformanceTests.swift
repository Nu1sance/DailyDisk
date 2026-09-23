import DailyDiskCore
import DailyDiskStore
import Foundation
import Testing

private actor PerformanceCounter {
    private(set) var value = 0
    func add(_ batch: CanonicalAttributionBatch) { value += batch.attributions.count }
}

@Test(
    "One million records stream through staging, deletion, and activation",
    .enabled(if: ProcessInfo.processInfo.environment["DAILYDISK_RUN_STRESS"] == "1")
)
func millionRecordInventory() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DailyDiskMillionRow", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteInventoryStore(databaseURL: root.appendingPathComponent("DailyDisk.sqlite"))
    try await store.prepare()
    let domain = StorageDomain(
        id: StorageDomain.ID("stress-domain"),
        containerIdentifier: "disk-stress",
        displayName: "Stress",
        isInternal: true
    )
    let volume = MonitoredVolume(
        id: MonitoredVolume.ID("stress-volume"),
        storageDomainID: domain.id,
        filesystemUUID: UUID(),
        eventStoreUUID: UUID(),
        deviceID: 1,
        mountPath: "/stress",
        displayName: "Data",
        role: .data,
        isInternal: true,
        isRemovable: false,
        isReadOnly: false,
        supportsPersistentEvents: true,
        topologyFingerprint: "stress"
    )
    try await store.register(scope: StorageDomainScope(domain: domain, volumes: [volume]))
    let run = ScanRun(kind: .full, reason: .manual, status: .running, startedAt: Date())
    try await store.begin(run: run)
    let generation = try await store.createStagingGeneration(
        volumeID: volume.id,
        runID: run.id,
        at: run.startedAt
    )

    let parent = try RelativePath(validating: "files")
    for batchStart in stride(from: 0, to: 1_000_000, by: 1_024) {
        let end = min(batchStart + 1_024, 1_000_000)
        var records: [InventoryRecord] = []
        records.reserveCapacity(end - batchStart)
        for index in batchStart..<end {
            let path = try RelativePath(validating: String(format: "files/%07d", index))
            let identity = FileIdentity(volumeID: volume.id, deviceID: 1, inode: UInt64(index + 1))
            records.append(
                try InventoryRecord(
                    object: InventoryObject(
                        identity: identity,
                        kind: .regular,
                        footprint: FileFootprint.zero,
                        linkCount: 1,
                        modifiedAt: nil,
                        metadataChangedAt: nil
                    ),
                    path: InventoryPath(
                        volumeID: volume.id,
                        relativePath: path,
                        parentPath: parent,
                        objectIdentity: identity
                    )
                )
            )
        }
        try await store.append(records: records, to: generation.id)
    }

    let removedCount = 128
    let removals = try (0..<removedCount).map { index in
        InventoryMutation.remove(
            volumeID: volume.id,
            path: try RelativePath(validating: String(format: "files/%07d", index))
        )
    }
    try await store.stage(mutations: removals, target: .stagingGeneration(generation.id), for: run.id)
    let counter = PerformanceCounter()
    try await store.finalizeCanonicalAttribution(
        target: .stagingGeneration(generation.id),
        runID: run.id,
        consume: { batch in
            #expect(batch.attributions.count <= CanonicalAttributionBatch.maximumAttributionCount)
            await counter.add(batch)
        }
    )
    let count = await counter.value
    #expect(count == 1_000_000 - removedCount)

    let finishedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    let checkpoint = Checkpoint(
        volumeID: volume.id, eventStoreUUID: volume.eventStoreUUID,
        lastCommittedEventID: 10, activeGenerationID: generation.id,
        topologyFingerprint: volume.topologyFingerprint,
        lastSuccessfulIncrementalAt: nil, lastSuccessfulFullScanAt: finishedAt
    )
    let commit = try ScanCommit(
        runID: run.id, runKind: .full,
        scope: StorageDomainScope(domain: domain, volumes: [volume]),
        volumeID: volume.id, activatedGenerationID: generation.id,
        previousCheckpoint: nil, checkpoint: checkpoint,
        eventFence: EventCursorFence(
            volumeID: volume.id, eventStoreUUID: volume.eventStoreUUID,
            highestFullyDeliveredEventID: 10, phase: .liveFlush, trust: .trusted
        ),
        changes: [],
        storageSamples: [
            StorageSample(
                storageDomainID: domain.id, sampledAt: finishedAt,
                capacityBytes: 1_000_000, usedBytes: 0, availableBytes: 1_000_000
            )
        ],
        snapshotSamples: []
    )
    try await store.commit(commit, finishedAt: finishedAt)
    let state = try await store.state(for: volume.id)
    #expect(state?.checkpoint == checkpoint)
    let reportStore = try SQLiteReportStore(databaseURL: root.appendingPathComponent("DailyDisk.sqlite"))
    let diagnostics = try await reportStore.diagnostics()
    #expect(diagnostics.tableCounts["inventory_objects"] == Int64(count))
    #expect(diagnostics.tableCounts["canonical_attributions"] == Int64(count))

    // The committed inventory now has path statistics from orphan cleanup.
    // Narrow incremental removals must still seek paths first, not visit every
    // object for each changed subtree.
    let incremental = ScanRun(kind: .incremental, reason: .manual, status: .running, startedAt: Date())
    try await store.begin(run: incremental)
    let lookupStarted = Date()
    for index in 500_000..<500_032 {
        try await store.stageRemovalSubtree(
            root: RelativePath(validating: String(format: "files/%07d", index)),
            target: .expectedActive(volumeID: volume.id), for: incremental.id, observer: TaskOnlyScanWorkObserver()
        )
    }
    #expect(Date().timeIntervalSince(lookupStarted) < 10)

    let target = InventoryMutationTarget.expectedActive(volumeID: volume.id)
    try await store.finalizeCanonicalAttribution(target: target, runID: incremental.id, consume: { _ in })
    let changes = try await store.deriveIncrementalChanges(target: target, runID: incremental.id)
    #expect(changes.count == 32)
    let nextCheckpoint = Checkpoint(
        volumeID: volume.id, eventStoreUUID: volume.eventStoreUUID,
        lastCommittedEventID: 20, activeGenerationID: generation.id,
        topologyFingerprint: volume.topologyFingerprint,
        lastSuccessfulIncrementalAt: finishedAt, lastSuccessfulFullScanAt: finishedAt
    )
    let incrementalCommit = try ScanCommit(
        runID: incremental.id, runKind: .incremental,
        scope: StorageDomainScope(domain: domain, volumes: [volume]),
        volumeID: volume.id, activatedGenerationID: nil,
        previousCheckpoint: checkpoint, checkpoint: nextCheckpoint,
        eventFence: EventCursorFence(
            volumeID: volume.id, eventStoreUUID: volume.eventStoreUUID,
            highestFullyDeliveredEventID: 20, phase: .liveFlush, trust: .trusted
        ),
        changes: changes, storageSamples: [], snapshotSamples: []
    )
    let commitStarted = Date()
    try await store.commit(incrementalCommit, finishedAt: finishedAt)
    #expect(Date().timeIntervalSince(commitStarted) < 10)
    #expect(try await store.state(for: volume.id)?.checkpoint == nextCheckpoint)
    let updated = try await reportStore.diagnostics()
    #expect(updated.tableCounts["inventory_objects"] == Int64(count - 32))
    #expect(updated.tableCounts["canonical_attributions"] == Int64(count - 32))

}
