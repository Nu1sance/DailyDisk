import DailyDiskCore
import DailyDiskStore
import Darwin
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
    let peaks = SpacePeakRecorder()
    let monitor = Task.detached {
        while !Task.isCancelled {
            var bytes: Int64 = 0
            for name in ["DailyDisk.sqlite", "DailyDisk.sqlite-wal", "DailyDisk.sqlite-shm"] {
                var metadata = stat()
                if lstat(root.appendingPathComponent(name).path, &metadata) == 0 {
                    bytes += Int64(metadata.st_blocks) * 512
                }
            }
            await peaks.record(bytes)
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    defer { monitor.cancel() }
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

    let pathPrefix = "synthetic/Library/Application Support/Example/Cache/RepeatedDirectoryPrefix/files"
    let parent = try RelativePath(validating: pathPrefix)
    for batchStart in stride(from: 0, to: 1_000_000, by: 1_024) {
        let end = min(batchStart + 1_024, 1_000_000)
        var records: [InventoryRecord] = []
        records.reserveCapacity(end - batchStart)
        for index in batchStart..<end {
            let path = try RelativePath(validating: pathPrefix + String(format: "/%07d", index))
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
            path: try RelativePath(validating: pathPrefix + String(format: "/%07d", index))
        )
    }
    try await store.stage(mutations: removals, target: .stagingGeneration(generation.id), for: run.id)
    await peaks.setPhase("initial-seal")
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
    await peaks.setPhase("initial-commit")
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
    await peaks.setPhase("incremental")
    let incremental = ScanRun(kind: .incremental, reason: .manual, status: .running, startedAt: Date())
    try await store.begin(run: incremental)
    let lookupStarted = Date()
    for index in 500_000..<500_032 {
        try await store.stageRemovalSubtree(
            root: RelativePath(validating: pathPrefix + String(format: "/%07d", index)),
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

    // Exercise the pager used by opaque preservation and full reconciliation.
    // The old UNION/sort/outer-LIMIT query repeated a whole-tail scan per page.
    await peaks.setPhase("recovery-staging-and-seal")
    let recovery = ScanRun(kind: .full, reason: .manual, status: .running, startedAt: Date())
    try await store.begin(run: recovery)
    let recovered = try await store.createStagingGeneration(
        volumeID: volume.id, runID: recovery.id, at: recovery.startedAt)
    let recoveredTarget = InventoryMutationTarget.stagingGeneration(recovered.id)
    let preservation = OpaquePerformanceObserver()
    let preservationStart = Date()
    try await store.preserveOpaqueSubtrees(
        roots: [.root], from: target, to: recoveredTarget, for: recovery.id, observer: preservation
    )
    let preservationSeconds = Date().timeIntervalSince(preservationStart)
    #expect(await preservation.preserved == UInt64(count - 32))
    #expect(preservationSeconds < 120)
    for sealedTarget in [target, recoveredTarget] {
        try await store.finalizeCanonicalAttribution(target: sealedTarget, runID: recovery.id, consume: { _ in })
    }
    let diffStart = Date()
    try await store.diff(expected: target, authoritative: recoveredTarget, runID: recovery.id) { batch in
        #expect(batch.differences.isEmpty)
    }
    let diffSeconds = Date().timeIntervalSince(diffStart)
    #expect(diffSeconds < 60)
    print("Million-row opaque preservation: \(preservationSeconds)s; full diff: \(diffSeconds)s")
    #expect(try await store.state(for: volume.id)?.checkpoint == nextCheckpoint)

    let scope = try StorageDomainScope(domain: domain, volumes: [volume])
    let initialSample = try StorageSample(
        storageDomainID: domain.id, sampledAt: finishedAt,
        capacityBytes: 1_000_000, usedBytes: 0, availableBytes: 1_000_000)
    func publish(_ runID: ScanRun.ID, sample: StorageSample, previous: StorageSample?) async throws {
        let report = try DailyReport(
            runID: runID, generatedAt: sample.sampledAt, storageDomainID: domain.id,
            accounting: SpaceAccounting.summarize(
                changes: [], scope: scope, previousSample: previous, currentSample: sample),
            reconciliation: nil,
            coverage: ScanCoverage(
                visitedPathCount: UInt64(count - 32), indexedObjectCount: UInt64(count - 32),
                unreadablePathCount: 0, transientErrorCount: 0),
            largestGrowth: [], largestShrinkage: [], diagnostics: [])
        try await store.commitReport(
            ReportCommit(
                runID: runID, scope: scope, changes: [], previousStorageSample: previous,
                currentStorageSample: sample, previousOverheadSample: nil, currentOverheadSample: nil, report: report))
    }
    try await publish(run.id, sample: initialSample, previous: nil)
    var previousCheckpoint = nextCheckpoint
    var previousSample = initialSample
    // Repeat authoritative activation, retirement, expiry and native compaction.
    // Daily incremental failure is intentionally not fixed by this workload.
    for cycle in 0..<2 {
        await peaks.setPhase("cycle-\(cycle + 1)-staging-and-seal")
        let cycleRun: ScanRun
        let cycleGeneration: InventoryGeneration
        if cycle == 0 {
            cycleRun = recovery
            cycleGeneration = recovered
        } else {
            cycleRun = ScanRun(kind: .full, reason: .manual, status: .running, startedAt: Date())
            try await store.begin(run: cycleRun)
            cycleGeneration = try await store.createStagingGeneration(
                volumeID: volume.id, runID: cycleRun.id, at: Date())
            let staged = InventoryMutationTarget.stagingGeneration(cycleGeneration.id)
            try await store.preserveOpaqueSubtrees(roots: [.root], from: target, to: staged, for: cycleRun.id)
            for sealTarget in [target, staged] {
                try await store.finalizeCanonicalAttribution(target: sealTarget, runID: cycleRun.id, consume: { _ in })
            }
        }
        let stagedUsage = try await reportStore.spaceUsage()
        let sample = try StorageSample(
            storageDomainID: domain.id,
            sampledAt: finishedAt.addingTimeInterval(Double(cycle + 1)),
            capacityBytes: 1_000_000, usedBytes: 0, availableBytes: 1_000_000)
        let next = Checkpoint(
            volumeID: volume.id, eventStoreUUID: volume.eventStoreUUID,
            lastCommittedEventID: UInt64(30 + cycle), activeGenerationID: cycleGeneration.id,
            topologyFingerprint: volume.topologyFingerprint,
            lastSuccessfulIncrementalAt: finishedAt, lastSuccessfulFullScanAt: sample.sampledAt)
        await peaks.setPhase("cycle-\(cycle + 1)-activation")
        let activationStart = Date()
        try await store.commit(
            ScanCommit(
                runID: cycleRun.id, runKind: .full, scope: scope, volumeID: volume.id,
                activatedGenerationID: cycleGeneration.id, previousCheckpoint: previousCheckpoint, checkpoint: next,
                eventFence: EventCursorFence(
                    volumeID: volume.id, eventStoreUUID: volume.eventStoreUUID,
                    highestFullyDeliveredEventID: UInt64(30 + cycle), phase: .liveFlush, trust: .trusted),
                changes: [], storageSamples: [sample], snapshotSamples: []), finishedAt: sample.sampledAt)
        let activationSeconds = Date().timeIntervalSince(activationStart)
        await peaks.setPhase("cycle-\(cycle + 1)-report")
        try await publish(cycleRun.id, sample: sample, previous: previousSample)
        let retained = try await reportStore.spaceUsage()
        await peaks.setPhase("cycle-\(cycle + 1)-maintenance")
        let maintenanceStart = Date()
        try await store.maintainSpace(at: Date().addingTimeInterval(86410), force: true, availableBytes: { Int64.max })
        let maintenanceSeconds = Date().timeIntervalSince(maintenanceStart)
        let compacted = try await reportStore.spaceUsage()
        #expect(compacted.allocatedBytes < retained.allocatedBytes)
        #expect(try await store.state(for: volume.id)?.checkpoint == next)
        #expect(try await reportStore.report(runID: run.id) != nil)
        #expect(try await reportStore.report(runID: cycleRun.id) != nil)
        let counts = try await reportStore.diagnostics().tableCounts
        #expect(counts["inventory_generations"] == 1)
        #expect(counts["inventory_paths"] == Int64(count - 32))
        print(
            "Space cycle \(cycle + 1): staged=\(stagedUsage.allocatedBytes), retained=\(retained.allocatedBytes), compacted=\(compacted.allocatedBytes), activation=\(activationSeconds)s, maintenance=\(maintenanceSeconds)s"
        )
        previousCheckpoint = next
        previousSample = sample
    }
    await peaks.setPhase("post-vacuum-incremental")
    let postMaintenanceRun = ScanRun(kind: .incremental, reason: .manual, status: .running, startedAt: Date())
    try await store.begin(run: postMaintenanceRun)
    let postLookup = Date()
    for index in 600_000..<600_032 {
        try await store.stageRemovalSubtree(
            root: RelativePath(validating: pathPrefix + String(format: "/%07d", index)),
            target: target, for: postMaintenanceRun.id, observer: TaskOnlyScanWorkObserver())
    }
    let postLookupSeconds = Date().timeIntervalSince(postLookup)
    #expect(postLookupSeconds < 10)
    try await store.finalizeCanonicalAttribution(target: target, runID: postMaintenanceRun.id, consume: { _ in })
    let postChanges = try await store.deriveIncrementalChanges(target: target, runID: postMaintenanceRun.id)
    #expect(postChanges.count == 32)
    // Use an exactly representable fractional Unix timestamp. Date() may carry
    // finer reference-epoch precision than a persisted Unix-epoch Double.
    let postTimestamp = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 0.75)
    let postCheckpoint = Checkpoint(
        volumeID: volume.id, eventStoreUUID: volume.eventStoreUUID,
        lastCommittedEventID: 50, activeGenerationID: previousCheckpoint.activeGenerationID,
        topologyFingerprint: volume.topologyFingerprint, lastSuccessfulIncrementalAt: postTimestamp,
        lastSuccessfulFullScanAt: previousCheckpoint.lastSuccessfulFullScanAt)
    let postCommit = try ScanCommit(
        runID: postMaintenanceRun.id, runKind: .incremental,
        scope: scope, volumeID: volume.id, activatedGenerationID: nil,
        previousCheckpoint: previousCheckpoint, checkpoint: postCheckpoint,
        eventFence: EventCursorFence(
            volumeID: volume.id, eventStoreUUID: volume.eventStoreUUID,
            highestFullyDeliveredEventID: 50, phase: .liveFlush, trust: .trusted),
        changes: postChanges, storageSamples: [], snapshotSamples: [])
    let postCommitStart = Date()
    try await store.commit(postCommit, finishedAt: Date())
    let postCommitSeconds = Date().timeIntervalSince(postCommitStart)
    #expect(postCommitSeconds < 10)
    #expect(try await store.state(for: volume.id)?.checkpoint == postCheckpoint)
    print("Post-vacuum incremental: lookup=\(postLookupSeconds)s, commit=\(postCommitSeconds)s")
    print("Sampled database/WAL/SHM allocation peaks (bytes): \(await peaks.values)")

}

private actor OpaquePerformanceObserver: ScanWorkObserving {
    private(set) var preserved: UInt64 = 0
    func checkpoint(_ delta: ScanProgressDelta) async throws {
        try Task.checkCancellation()
        preserved += delta.preservedPaths
    }
}

private actor SpacePeakRecorder {
    private var phase = "initial-staging"
    private(set) var values: [String: Int64] = [:]
    func setPhase(_ phase: String) { self.phase = phase }
    func record(_ bytes: Int64) { values[phase] = max(values[phase, default: 0], bytes) }
}
