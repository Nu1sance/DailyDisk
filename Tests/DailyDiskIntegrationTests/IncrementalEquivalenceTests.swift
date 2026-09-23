import DailyDiskCore
import DailyDiskPlatform
import DailyDiskStore
import Darwin
import Foundation
import Testing

private actor RecordingProgressTracker: ScanProgressTracking {
    private let cancelAtPhase: ScanProgressPhase?
    private(set) var phases: [ScanProgressPhase] = []
    private(set) var counters = ScanProgressCounters()

    init(cancelAtPhase: ScanProgressPhase? = nil) {
        self.cancelAtPhase = cancelAtPhase
    }

    func transition(to phase: ScanProgressPhase, mode: ScanExecutionMode?) async throws {
        phases.append(phase)
        if phase == cancelAtPhase { throw ScanProgressError.cancelled }
    }

    func checkpoint(_ delta: ScanProgressDelta) async throws {
        counters = try counters.applying(delta)
    }

    func currentSnapshot() async throws -> ScanProgressSnapshot {
        let now = Date()
        return try ScanProgressSnapshot(
            requestID: UUID(),
            trigger: .manual,
            mode: .incremental,
            phase: phases.last ?? .queued,
            startedAt: now,
            updatedAt: now,
            counters: counters
        )
    }
}

private actor FakeEventSession: EventHistorySession {
    let historical: [EventBatch]
    let live: [EventBatch]
    let historyFence: EventCursorFence
    let liveFence: EventCursorFence

    init(
        historical: [EventBatch],
        live: [EventBatch],
        historyFence: EventCursorFence,
        liveFence: EventCursorFence
    ) {
        self.historical = historical
        self.live = live
        self.historyFence = historyFence
        self.liveFence = liveFence
    }

    func replayHistoricalEvents(
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws -> EventCursorFence {
        for batch in historical { try await consume(batch) }
        return historyFence
    }

    func flushLiveEvents(
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws -> EventCursorFence {
        for batch in live { try await consume(batch) }
        return liveFence
    }

    private(set) var stopCount = 0
    func stop() async { stopCount += 1 }
}

private actor QueuedEventReader: EventHistoryReading {
    private var sessions: [FakeEventSession]

    init(_ sessions: [FakeEventSession]) {
        self.sessions = sessions
    }

    func openSession(
        volume: MonitoredVolume,
        checkpoint: EventStreamCheckpoint?
    ) async throws -> any EventHistorySession {
        guard !sessions.isEmpty else { throw IncrementalScanError.missingCheckpoint }
        return sessions.removeFirst()
    }
}

private struct StaticVolumeDiscovery: VolumeDiscovering {
    let topology: VolumeTopology

    func discoverInternalAPFSVolumes() async throws -> VolumeTopology { topology }
}

private struct FakeEventReader: EventHistoryReading {
    let session: FakeEventSession

    func openSession(
        volume: MonitoredVolume,
        checkpoint: EventStreamCheckpoint?
    ) async throws -> any EventHistorySession {
        session
    }
}

private struct EmptyDeletedOpenProbe: DeletedOpenFileProbing {
    func deletedOpenFiles() async throws -> [DeletedOpenFile] { [] }
}

private struct FakeDiskSampler: DiskUsageSampling {
    let sampleValue: StorageSample

    func sample(storageDomain: StorageDomain) async throws -> StorageSample { sampleValue }
    func snapshots(volume: MonitoredVolume) async throws -> [SnapshotSample] { [] }
}

private actor AdvancingClock: Clock {
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() async -> Date {
        defer { value = value.addingTimeInterval(1) }
        return value
    }
}

private struct IncrementalMountProvider: DiskArbitrationProviding {
    let volume: MonitoredVolume

    func describeDisk(bsdName: String) async throws -> DiskHardwareDescription? { nil }

    func mountedVolumes() async throws -> [MountedVolumeDescription] {
        [
            MountedVolumeDescription(
                bsdName: "disk-test",
                mountPath: volume.mountPath!,
                filesystemKind: "apfs",
                volumeUUID: volume.filesystemUUID,
                deviceID: volume.deviceID,
                isInternal: true,
                isRemovable: false,
                isReadOnly: false
            )
        ]
    }
}

private struct RacingFileScanner: FileInventoryScanning {
    let base: FileInventoryScanner
    let afterFullScan: @Sendable () async throws -> Void

    func scan(
        volume: MonitoredVolume,
        runID: ScanRun.ID,
        consume: @escaping @Sendable (InventoryRecordBatch) async throws -> Void
    ) async throws -> InventoryScanResult {
        let result = try await base.scan(volume: volume, runID: runID, consume: consume)
        try await afterFullScan()
        return result
    }

    func scanSubtree(
        volume: MonitoredVolume,
        root: RelativePath,
        runID: ScanRun.ID,
        consume: @escaping @Sendable (InventoryRecordBatch) async throws -> Void
    ) async throws -> InventoryScanResult {
        try await base.scanSubtree(volume: volume, root: root, runID: runID, consume: consume)
    }
}

private actor IncrementalDiffCollector {
    private(set) var differences: [InventoryDiff] = []
    func append(_ batch: InventoryDiffBatch) { differences.append(contentsOf: batch.differences) }
}

private actor IncrementalRecordCollector {
    private(set) var records: [InventoryRecord] = []

    func append(_ batch: InventoryRecordBatch) {
        records.append(contentsOf: batch.records)
    }
}

private struct IncrementalFixture {
    let root: URL
    let databaseRoot: URL
    let store: SQLiteInventoryStore
    let volume: MonitoredVolume
    let scope: StorageDomainScope
    let eventStoreUUID: UUID
    let baselineCheckpoint: Checkpoint
    let baselineSample: StorageSample

    static func make() async throws -> IncrementalFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyDiskIncremental", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyDiskIncrementalDB", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        var status = Darwin.stat()
        guard lstat(root.path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let domain = StorageDomain(
            id: StorageDomain.ID("incremental-domain"),
            containerIdentifier: "disk-test",
            displayName: "Incremental Test",
            isInternal: true
        )
        let eventStoreUUID = UUID()
        let volume = MonitoredVolume(
            id: MonitoredVolume.ID("incremental-volume"),
            storageDomainID: domain.id,
            filesystemUUID: UUID(),
            eventStoreUUID: eventStoreUUID,
            deviceID: UInt64(status.st_dev),
            mountPath: root.path,
            displayName: "Data",
            role: .data,
            isInternal: true,
            isRemovable: false,
            isReadOnly: false,
            supportsPersistentEvents: true,
            topologyFingerprint: "incremental-topology",
            inventoryMode: .full
        )
        let scope = try StorageDomainScope(domain: domain, volumes: [volume])
        let store = try SQLiteInventoryStore(
            databaseURL: databaseRoot.appendingPathComponent("DailyDisk.sqlite")
        )
        try await store.prepare()
        try await store.register(scope: scope)

        for (name, contents) in [
            ("a", "old-a"),
            ("b", "old-b"),
            ("c-old", "old-c"),
        ] {
            try Data(contents.utf8).write(to: root.appendingPathComponent(name))
        }
        try FileManager.default.linkItem(
            at: root.appendingPathComponent("a"),
            to: root.appendingPathComponent("a-baseline-link")
        )
        let subtree = root.appendingPathComponent("directory/subdirectory", isDirectory: true)
        try FileManager.default.createDirectory(at: subtree, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: subtree.appendingPathComponent("nested-file"))

        let run = ScanRun(
            kind: .full,
            reason: .initialBaseline,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        try await store.begin(run: run)
        let generation = try await store.createStagingGeneration(
            volumeID: volume.id,
            runID: run.id,
            at: run.startedAt
        )
        let scanner = FileInventoryScanner(
            configuration: try FileInventoryScannerConfiguration(
                managedAbsolutePaths: [],
                validateMountIdentity: false
            )
        )
        _ = try await scanner.scan(volume: volume, runID: run.id) { batch in
            try await store.append(records: batch.records, to: generation.id)
        }
        try await store.finalizeCanonicalAttribution(
            target: .stagingGeneration(generation.id),
            runID: run.id,
            consume: { _ in }
        )
        let checkpoint = Checkpoint(
            volumeID: volume.id,
            eventStoreUUID: eventStoreUUID,
            lastCommittedEventID: 10,
            activeGenerationID: generation.id,
            topologyFingerprint: volume.topologyFingerprint,
            lastSuccessfulIncrementalAt: nil,
            lastSuccessfulFullScanAt: Date(timeIntervalSince1970: 2)
        )
        let sample = try StorageSample(
            storageDomainID: domain.id,
            sampledAt: Date(timeIntervalSince1970: 2),
            capacityBytes: 1_000_000,
            usedBytes: 100_000,
            availableBytes: 900_000
        )
        let commit = try ScanCommit(
            runID: run.id,
            runKind: .full,
            scope: scope,
            volumeID: volume.id,
            activatedGenerationID: generation.id,
            previousCheckpoint: nil,
            checkpoint: checkpoint,
            eventFence: EventCursorFence(
                volumeID: volume.id,
                eventStoreUUID: eventStoreUUID,
                highestFullyDeliveredEventID: 10,
                phase: .liveFlush,
                trust: .trusted
            ),
            changes: [],
            storageSamples: [sample],
            snapshotSamples: []
        )
        try await store.commit(commit, finishedAt: Date(timeIntervalSince1970: 2))
        return IncrementalFixture(
            root: root,
            databaseRoot: databaseRoot,
            store: store,
            volume: volume,
            scope: scope,
            eventStoreUUID: eventStoreUUID,
            baselineCheckpoint: checkpoint,
            baselineSample: sample
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: databaseRoot)
    }
}

@Test("Incremental FSEvents inventory equals a fresh full inventory")
func incrementalInventoryEqualsFullInventory() async throws {
    let fixture = try await IncrementalFixture.make()
    defer { fixture.remove() }

    try Data("new-and-larger-a".utf8).write(to: fixture.root.appendingPathComponent("a"))
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("b"))
    try FileManager.default.moveItem(
        at: fixture.root.appendingPathComponent("c-old"),
        to: fixture.root.appendingPathComponent("c-new")
    )
    try Data("new-d".utf8).write(to: fixture.root.appendingPathComponent("d"))
    try FileManager.default.linkItem(
        at: fixture.root.appendingPathComponent("a"),
        to: fixture.root.appendingPathComponent("a-link")
    )

    let pathsAndFlags: [(String, FileSystemEventFlags)] = [
        ("", [.modified, .isDirectory]),
        ("a", [.modified, .inodeMetadataModified, .isFile]),
        ("a-link", [.created, .isFile, .isHardLink]),
        ("b", [.removed, .isFile]),
        ("c-old", [.renamed, .isFile]),
        ("c-new", [.renamed, .isFile]),
        ("d", [.created, .isFile]),
    ]
    let events = try pathsAndFlags.enumerated().map { index, value in
        FileSystemEvent(
            id: UInt64(11 + index),
            volumeID: fixture.volume.id,
            path: try RelativePath(validating: value.0),
            flags: value.1
        )
    }
    let historyFence = EventCursorFence(
        volumeID: fixture.volume.id,
        eventStoreUUID: fixture.eventStoreUUID,
        highestFullyDeliveredEventID: 17,
        phase: .historyDone,
        trust: .trusted
    )
    let liveFence = EventCursorFence(
        volumeID: fixture.volume.id,
        eventStoreUUID: fixture.eventStoreUUID,
        highestFullyDeliveredEventID: 17,
        phase: .liveFlush,
        trust: .trusted
    )
    let session = FakeEventSession(
        historical: [try EventBatch(events: events)],
        live: [],
        historyFence: historyFence,
        liveFence: liveFence
    )
    let currentSample = try StorageSample(
        storageDomainID: fixture.scope.domain.id,
        sampledAt: Date(timeIntervalSince1970: 20),
        capacityBytes: 1_000_000,
        usedBytes: 100_100,
        availableBytes: 899_900
    )
    let incremental = IncrementalScanner(
        store: fixture.store,
        eventReader: FakeEventReader(session: session),
        metadataReader: POSIXFileMetadataReader(
            diskArbitration: IncrementalMountProvider(volume: fixture.volume),
            managedAbsolutePaths: []
        ),
        subtreeScanner: FileInventoryScanner(
            configuration: try FileInventoryScannerConfiguration(
                managedAbsolutePaths: [],
                validateMountIdentity: false
            )
        ),
        diskUsageSampler: FakeDiskSampler(sampleValue: currentSample),
        clock: AdvancingClock(Date(timeIntervalSince1970: 20))
    )
    let outcome = try await incremental.run(volume: fixture.volume, scope: fixture.scope)

    let expectedKinds = Set([
        ChangeKind.eventCreated,
        .eventRemoved,
        .eventModified,
        .eventMoved,
        .eventLinkAdded,
    ])
    #expect(Set(outcome.changes.map(\.kind)) == expectedKinds)
    #expect(outcome.checkpoint.lastCommittedEventID == 17)

    let freshCollector = IncrementalRecordCollector()
    let freshScanner = FileInventoryScanner(
        configuration: try FileInventoryScannerConfiguration(
            managedAbsolutePaths: [],
            validateMountIdentity: false
        )
    )
    _ = try await freshScanner.scan(volume: fixture.volume, runID: ScanRun.ID()) { batch in
        await freshCollector.append(batch)
    }
    let freshFiles = await freshCollector.records.filter { $0.object.kind == .regular }
    let expectedByPath = Dictionary(uniqueKeysWithValues: freshFiles.map { ($0.path.relativePath, $0.object) })

    let inspectionRun = ScanRun(
        kind: .incremental,
        reason: .manual,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 30)
    )
    try await fixture.store.begin(run: inspectionRun)
    let stored = try await fixture.store.records(
        target: .expectedActive(volumeID: fixture.volume.id),
        runID: inspectionRun.id,
        paths: Array(expectedByPath.keys) + [try RelativePath(validating: "b"), try RelativePath(validating: "c-old")]
    )
    let storedByPath = Dictionary(uniqueKeysWithValues: stored.map { ($0.path.relativePath, $0.object) })
    #expect(storedByPath == expectedByPath)
    try await fixture.store.fail(runID: inspectionRun.id, errors: [], finishedAt: Date(timeIntervalSince1970: 31))

    let verificationRun = ScanRun(
        kind: .full,
        reason: .manual,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 32)
    )
    try await fixture.store.begin(run: verificationRun)
    let freshGeneration = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id,
        runID: verificationRun.id,
        at: verificationRun.startedAt
    )
    let allFreshRecords = await freshCollector.records
    for start in stride(from: 0, to: allFreshRecords.count, by: 1_024) {
        let end = min(start + 1_024, allFreshRecords.count)
        try await fixture.store.append(
            records: Array(allFreshRecords[start..<end]),
            to: freshGeneration.id
        )
    }
    let activeTarget = InventoryMutationTarget.expectedActive(volumeID: fixture.volume.id)
    let freshTarget = InventoryMutationTarget.stagingGeneration(freshGeneration.id)
    try await fixture.store.finalizeCanonicalAttribution(
        target: activeTarget,
        runID: verificationRun.id,
        consume: { _ in }
    )
    try await fixture.store.finalizeCanonicalAttribution(
        target: freshTarget,
        runID: verificationRun.id,
        consume: { _ in }
    )
    let diff = IncrementalDiffCollector()
    try await fixture.store.diff(
        expected: activeTarget,
        authoritative: freshTarget,
        runID: verificationRun.id,
        consume: { batch in await diff.append(batch) }
    )
    let completeDifferences = await diff.differences
    #expect(completeDifferences.isEmpty)
    try await fixture.store.fail(
        runID: verificationRun.id,
        errors: [],
        finishedAt: Date(timeIntervalSince1970: 33)
    )
}

@Test("MustScanSubDirs is discharged by authoritative subtree replacement")
func mustScanSubdirectoriesIsRepaired() async throws {
    let fixture = try await IncrementalFixture.make()
    defer { fixture.remove() }
    try FileManager.default.removeItem(
        at: fixture.root.appendingPathComponent("directory/subdirectory/nested-file")
    )
    let event = FileSystemEvent(
        id: 11,
        volumeID: fixture.volume.id,
        path: try RelativePath(validating: "directory"),
        flags: [.mustScanSubdirectories, .isDirectory]
    )
    let session = FakeEventSession(
        historical: [try EventBatch(events: [event])],
        live: [],
        historyFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: fixture.eventStoreUUID,
            highestFullyDeliveredEventID: 11,
            phase: .historyDone,
            trust: .subtreeRescanRequired,
            diagnostic: "FSEvents requires recursive subtree scan"
        ),
        liveFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: fixture.eventStoreUUID,
            highestFullyDeliveredEventID: 11,
            phase: .liveFlush,
            trust: .trusted
        )
    )
    let sample = try StorageSample(
        storageDomainID: fixture.scope.domain.id,
        sampledAt: Date(timeIntervalSince1970: 20),
        capacityBytes: 1_000_000,
        usedBytes: 100_000,
        availableBytes: 900_000
    )
    let scanner = IncrementalScanner(
        store: fixture.store,
        eventReader: FakeEventReader(session: session),
        metadataReader: POSIXFileMetadataReader(
            diskArbitration: IncrementalMountProvider(volume: fixture.volume),
            managedAbsolutePaths: []
        ),
        subtreeScanner: FileInventoryScanner(
            configuration: try FileInventoryScannerConfiguration(
                managedAbsolutePaths: [],
                validateMountIdentity: false
            )
        ),
        diskUsageSampler: FakeDiskSampler(sampleValue: sample),
        clock: AdvancingClock(Date(timeIntervalSince1970: 20))
    )
    let outcome = try await scanner.run(volume: fixture.volume, scope: fixture.scope)

    #expect(outcome.changes.contains { $0.kind == .eventRemoved })
    #expect(outcome.checkpoint.lastCommittedEventID == 11)
}

@Test("Removing a non-final hard link refreshes surviving object metadata")
func incrementalHardLinkRemovalRefreshesIdentity() async throws {
    let fixture = try await IncrementalFixture.make()
    defer { fixture.remove() }
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("a-baseline-link"))

    let event = FileSystemEvent(
        id: 11,
        volumeID: fixture.volume.id,
        path: try RelativePath(validating: "a-baseline-link"),
        flags: [.removed, .isFile, .isHardLink]
    )
    let session = FakeEventSession(
        historical: [try EventBatch(events: [event])],
        live: [],
        historyFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: fixture.eventStoreUUID,
            highestFullyDeliveredEventID: 11,
            phase: .historyDone,
            trust: .trusted
        ),
        liveFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: fixture.eventStoreUUID,
            highestFullyDeliveredEventID: 11,
            phase: .liveFlush,
            trust: .trusted
        )
    )
    let sample = try StorageSample(
        storageDomainID: fixture.scope.domain.id,
        sampledAt: Date(timeIntervalSince1970: 20),
        capacityBytes: 1_000_000,
        usedBytes: 100_000,
        availableBytes: 900_000
    )
    let scanner = IncrementalScanner(
        store: fixture.store,
        eventReader: FakeEventReader(session: session),
        metadataReader: POSIXFileMetadataReader(
            diskArbitration: IncrementalMountProvider(volume: fixture.volume),
            managedAbsolutePaths: []
        ),
        subtreeScanner: FileInventoryScanner(
            configuration: try FileInventoryScannerConfiguration(
                managedAbsolutePaths: [],
                validateMountIdentity: false
            )
        ),
        diskUsageSampler: FakeDiskSampler(sampleValue: sample),
        clock: AdvancingClock(Date(timeIntervalSince1970: 20))
    )
    let outcome = try await scanner.run(volume: fixture.volume, scope: fixture.scope)
    #expect(outcome.changes.map(\.kind) == [.eventLinkRemoved])

    let inspection = ScanRun(
        kind: .incremental,
        reason: .manual,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 30)
    )
    try await fixture.store.begin(run: inspection)
    let surviving = try await fixture.store.records(
        target: .expectedActive(volumeID: fixture.volume.id),
        runID: inspection.id,
        paths: [try RelativePath(validating: "a")]
    )
    #expect(surviving.first?.object.linkCount == 1)
    try await fixture.store.fail(runID: inspection.id, errors: [], finishedAt: Date(timeIntervalSince1970: 31))
}

@Test("Directory replacement removes every stale descendant before upserting the new file")
func incrementalDirectoryReplacementRemovesSubtree() async throws {
    let fixture = try await IncrementalFixture.make()
    defer { fixture.remove() }
    let directory = fixture.root.appendingPathComponent("directory")
    try FileManager.default.removeItem(at: directory)
    try Data("replacement".utf8).write(to: directory)

    let event = FileSystemEvent(
        id: 11,
        volumeID: fixture.volume.id,
        path: try RelativePath(validating: "directory"),
        flags: [.created, .isFile]
    )
    let session = FakeEventSession(
        historical: [try EventBatch(events: [event])],
        live: [],
        historyFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: fixture.eventStoreUUID,
            highestFullyDeliveredEventID: 11,
            phase: .historyDone,
            trust: .trusted
        ),
        liveFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: fixture.eventStoreUUID,
            highestFullyDeliveredEventID: 11,
            phase: .liveFlush,
            trust: .trusted
        )
    )
    let sample = try StorageSample(
        storageDomainID: fixture.scope.domain.id,
        sampledAt: Date(timeIntervalSince1970: 20),
        capacityBytes: 1_000_000,
        usedBytes: 100_000,
        availableBytes: 900_000
    )
    let scanner = IncrementalScanner(
        store: fixture.store,
        eventReader: FakeEventReader(session: session),
        metadataReader: POSIXFileMetadataReader(
            diskArbitration: IncrementalMountProvider(volume: fixture.volume),
            managedAbsolutePaths: []
        ),
        subtreeScanner: FileInventoryScanner(
            configuration: try FileInventoryScannerConfiguration(
                managedAbsolutePaths: [],
                validateMountIdentity: false
            )
        ),
        diskUsageSampler: FakeDiskSampler(sampleValue: sample),
        clock: AdvancingClock(Date(timeIntervalSince1970: 20))
    )
    let outcome = try await scanner.run(volume: fixture.volume, scope: fixture.scope)

    #expect(outcome.changes.filter { $0.kind == .eventRemoved }.count == 3)
    #expect(outcome.changes.filter { $0.kind == .eventCreated }.count == 1)

    let inspection = ScanRun(
        kind: .incremental,
        reason: .manual,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 30)
    )
    try await fixture.store.begin(run: inspection)
    let paths = [
        try RelativePath(validating: "directory"),
        try RelativePath(validating: "directory/subdirectory"),
        try RelativePath(validating: "directory/subdirectory/nested-file"),
    ]
    let stored = try await fixture.store.records(
        target: .expectedActive(volumeID: fixture.volume.id),
        runID: inspection.id,
        paths: paths
    )
    #expect(stored.count == 1)
    #expect(stored[0].object.kind == .regular)
    try await fixture.store.fail(runID: inspection.id, errors: [], finishedAt: Date(timeIntervalSince1970: 31))
}

@Test("Scheduled full scan separates historical event growth from reconciliation correction")
func scheduledFullScanSeparatesCorrection() async throws {
    let fixture = try await IncrementalFixture.make()
    defer { fixture.remove() }
    try Data(repeating: 0x41, count: 16_384).write(to: fixture.root.appendingPathComponent("a"))
    try Data(repeating: 0x42, count: 24_576).write(to: fixture.root.appendingPathComponent("b"))

    let historyEvent = FileSystemEvent(
        id: 11,
        volumeID: fixture.volume.id,
        path: try RelativePath(validating: "a"),
        flags: [.modified, .isFile]
    )
    let session = FakeEventSession(
        historical: [try EventBatch(events: [historyEvent])],
        live: [],
        historyFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: fixture.eventStoreUUID,
            highestFullyDeliveredEventID: 11,
            phase: .historyDone,
            trust: .trusted
        ),
        liveFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: fixture.eventStoreUUID,
            highestFullyDeliveredEventID: 11,
            phase: .liveFlush,
            trust: .trusted
        )
    )
    let sample = try StorageSample(
        storageDomainID: fixture.scope.domain.id,
        sampledAt: Date(timeIntervalSince1970: 20),
        capacityBytes: 1_000_000,
        usedBytes: 140_000,
        availableBytes: 860_000
    )
    let fullScanner = FileInventoryScanner(
        configuration: try FileInventoryScannerConfiguration(
            managedAbsolutePaths: [],
            validateMountIdentity: false
        )
    )
    let coordinator = FullScanCoordinator(
        store: fixture.store,
        eventReader: FakeEventReader(session: session),
        metadataReader: POSIXFileMetadataReader(
            diskArbitration: IncrementalMountProvider(volume: fixture.volume),
            managedAbsolutePaths: []
        ),
        fullScanner: fullScanner,
        diskUsageSampler: FakeDiskSampler(sampleValue: sample),
        volumeDiscovery: StaticVolumeDiscovery(
            topology: VolumeTopology(
                domains: [fixture.scope.domain],
                volumes: [fixture.volume],
                discoveredAt: Date(timeIntervalSince1970: 20)
            )
        ),
        clock: AdvancingClock(Date(timeIntervalSince1970: 20))
    )
    let outcome = try await coordinator.run(
        volume: fixture.volume,
        scope: fixture.scope,
        mode: .scheduled
    )

    #expect(outcome.reconciliation.eventChanges.contains { $0.pathAfter?.displayString == "a" })
    #expect(
        outcome.reconciliation.reconciliationChanges.contains {
            $0.pathAfter?.displayString == "b" && $0.allocatedDelta > 0
        }
    )
    #expect((outcome.reconciliation.breakdown?.sizeCorrections ?? 0) > 0)
    #expect(outcome.checkpoint.activeGenerationID != fixture.baselineCheckpoint.activeGenerationID)

    let reportDirectory = fixture.databaseRoot.appendingPathComponent("Reports", isDirectory: true)
    let generated = try await DailyReportCoordinator(
        store: fixture.store,
        diagnosticsCoordinator: PhysicalDiagnosticsCoordinator(
            deletedOpenFileProbe: EmptyDeletedOpenProbe()
        ),
        reportWriter: LocalReportWriter(directory: reportDirectory),
        clock: AdvancingClock(Date(timeIntervalSince1970: 30))
    ).generate(outcome: outcome, scope: fixture.scope)
    #expect(generated.report.accounting.reconciliationCorrection > 0)
    #expect(FileManager.default.fileExists(atPath: generated.artifacts.jsonURL.path))
    let retried = try await DailyReportCoordinator(
        store: fixture.store,
        diagnosticsCoordinator: PhysicalDiagnosticsCoordinator(
            deletedOpenFileProbe: EmptyDeletedOpenProbe()
        ),
        reportWriter: LocalReportWriter(directory: reportDirectory),
        clock: AdvancingClock(Date(timeIntervalSince1970: 999))
    ).generate(outcome: outcome, scope: fixture.scope)
    #expect(retried.report == generated.report)
    #expect(retried.artifacts == generated.artifacts)
}

@Test("Full scan replays a file created after traversal into both expected and staging views")
func fullScanReplaysLiveRace() async throws {
    let fixture = try await IncrementalFixture.make()
    defer { fixture.remove() }
    let livePath = try RelativePath(validating: "live-created")
    let liveEvent = FileSystemEvent(
        id: 11,
        volumeID: fixture.volume.id,
        path: livePath,
        flags: [.created, .isFile]
    )
    let session = FakeEventSession(
        historical: [],
        live: [try EventBatch(events: [liveEvent])],
        historyFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: fixture.eventStoreUUID,
            highestFullyDeliveredEventID: 10,
            phase: .historyDone,
            trust: .trusted
        ),
        liveFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: fixture.eventStoreUUID,
            highestFullyDeliveredEventID: 11,
            phase: .liveFlush,
            trust: .trusted
        )
    )
    let baseScanner = FileInventoryScanner(
        configuration: try FileInventoryScannerConfiguration(
            managedAbsolutePaths: [],
            validateMountIdentity: false
        )
    )
    let racingScanner = RacingFileScanner(base: baseScanner) {
        #expect(await session.stopCount == 1)
        try Data("created after traversal".utf8).write(
            to: fixture.root.appendingPathComponent("live-created")
        )
    }
    let sample = try StorageSample(
        storageDomainID: fixture.scope.domain.id,
        sampledAt: Date(timeIntervalSince1970: 20),
        capacityBytes: 1_000_000,
        usedBytes: 100_100,
        availableBytes: 899_900
    )
    let coordinator = FullScanCoordinator(
        store: fixture.store,
        eventReader: FakeEventReader(session: session),
        metadataReader: POSIXFileMetadataReader(
            diskArbitration: IncrementalMountProvider(volume: fixture.volume),
            managedAbsolutePaths: []
        ),
        fullScanner: racingScanner,
        diskUsageSampler: FakeDiskSampler(sampleValue: sample),
        volumeDiscovery: StaticVolumeDiscovery(
            topology: VolumeTopology(
                domains: [fixture.scope.domain],
                volumes: [fixture.volume],
                discoveredAt: Date(timeIntervalSince1970: 20)
            )
        ),
        clock: AdvancingClock(Date(timeIntervalSince1970: 20))
    )
    let outcome = try await coordinator.run(
        volume: fixture.volume,
        scope: fixture.scope,
        mode: .scheduled
    )

    #expect(outcome.reconciliation.eventChanges.map(\.kind).contains(.eventCreated))
    #expect(outcome.reconciliation.reconciliationChanges.isEmpty)
}

@Test("Journal replacement recovery refreshes volume identity before SinceNow baseline")
func journalReplacementRefreshesTopology() async throws {
    let fixture = try await IncrementalFixture.make()
    defer { fixture.remove() }
    let replacementUUID = UUID()
    let refreshedVolume = MonitoredVolume(
        id: fixture.volume.id,
        storageDomainID: fixture.volume.storageDomainID,
        filesystemUUID: fixture.volume.filesystemUUID,
        volumeGroupUUID: fixture.volume.volumeGroupUUID,
        eventStoreUUID: replacementUUID,
        deviceID: fixture.volume.deviceID,
        mountPath: fixture.volume.mountPath,
        displayName: fixture.volume.displayName,
        role: fixture.volume.role,
        isInternal: true,
        isRemovable: false,
        isReadOnly: false,
        supportsPersistentEvents: true,
        topologyFingerprint: fixture.volume.topologyFingerprint,
        inventoryMode: .full
    )
    let lostSession = FakeEventSession(
        historical: [],
        live: [],
        historyFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: replacementUUID,
            highestFullyDeliveredEventID: nil,
            phase: .historyDone,
            trust: .fullScanRequired,
            diagnostic: "FSEvents journal UUID changed"
        ),
        liveFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: replacementUUID,
            highestFullyDeliveredEventID: nil,
            phase: .liveFlush,
            trust: .fullScanRequired
        )
    )
    let recoverySession = FakeEventSession(
        historical: [],
        live: [],
        historyFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: replacementUUID,
            highestFullyDeliveredEventID: nil,
            phase: .historyDone,
            trust: .trusted
        ),
        liveFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: replacementUUID,
            highestFullyDeliveredEventID: 1,
            phase: .liveFlush,
            trust: .trusted
        )
    )
    let catchupSession = FakeEventSession(
        historical: [],
        live: [],
        historyFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: replacementUUID,
            highestFullyDeliveredEventID: 1,
            phase: .historyDone,
            trust: .trusted
        ),
        liveFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: replacementUUID,
            highestFullyDeliveredEventID: 1,
            phase: .liveFlush,
            trust: .trusted
        )
    )
    let eventReader = QueuedEventReader([lostSession, recoverySession, catchupSession])
    let sample = try StorageSample(
        storageDomainID: fixture.scope.domain.id,
        sampledAt: Date(timeIntervalSince1970: 20),
        capacityBytes: 1_000_000,
        usedBytes: 100_000,
        availableBytes: 900_000
    )
    let scanner = FileInventoryScanner(
        configuration: try FileInventoryScannerConfiguration(
            managedAbsolutePaths: [],
            validateMountIdentity: false
        )
    )
    let coordinator = FullScanCoordinator(
        store: fixture.store,
        eventReader: eventReader,
        metadataReader: POSIXFileMetadataReader(
            diskArbitration: IncrementalMountProvider(volume: refreshedVolume),
            managedAbsolutePaths: []
        ),
        fullScanner: scanner,
        diskUsageSampler: FakeDiskSampler(sampleValue: sample),
        volumeDiscovery: StaticVolumeDiscovery(
            topology: VolumeTopology(
                domains: [fixture.scope.domain],
                volumes: [refreshedVolume],
                discoveredAt: Date(timeIntervalSince1970: 20)
            )
        ),
        clock: AdvancingClock(Date(timeIntervalSince1970: 20))
    )
    let outcome = try await coordinator.run(
        volume: fixture.volume,
        scope: fixture.scope,
        mode: .scheduled
    )

    #expect(outcome.checkpoint.eventStoreUUID == replacementUUID)
    #expect(outcome.checkpoint.lastCommittedEventID == 1)
    #expect(outcome.reconciliation.eventChanges.isEmpty)
}

@Test("Manual incremental runs publish ordered phases and persist manual reason")
func manualIncrementalProgressPhases() async throws {
    let fixture = try await IncrementalFixture.make()
    defer { fixture.remove() }
    let session = FakeEventSession(
        historical: [],
        live: [],
        historyFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: fixture.eventStoreUUID,
            highestFullyDeliveredEventID: 10,
            phase: .historyDone,
            trust: .trusted
        ),
        liveFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: fixture.eventStoreUUID,
            highestFullyDeliveredEventID: 10,
            phase: .liveFlush,
            trust: .trusted
        )
    )
    let tracker = RecordingProgressTracker()
    let scanner = IncrementalScanner(
        store: fixture.store,
        eventReader: FakeEventReader(session: session),
        metadataReader: POSIXFileMetadataReader(
            diskArbitration: IncrementalMountProvider(volume: fixture.volume),
            managedAbsolutePaths: []
        ),
        subtreeScanner: FileInventoryScanner(
            configuration: try FileInventoryScannerConfiguration(
                managedAbsolutePaths: [],
                validateMountIdentity: false
            )
        ),
        diskUsageSampler: FakeDiskSampler(sampleValue: fixture.baselineSample),
        clock: AdvancingClock(Date(timeIntervalSince1970: 30))
    )
    _ = try await scanner.run(
        volume: fixture.volume,
        scope: fixture.scope,
        trigger: .manual,
        progressTracker: tracker
    )
    #expect(
        await tracker.phases == [
            .preparing, .discoveringStorage, .replayingEvents,
            .catchingUpEvents, .sealingInventory, .collectingDiagnostics,
            .committing,
        ]
    )
    let reports = try SQLiteReportStore(
        databaseURL: fixture.databaseRoot.appendingPathComponent("DailyDisk.sqlite")
    )
    let run = try #require(try await reports.recentRuns().first)
    #expect(run.reason == .manual)
    #expect(run.status == .succeeded)
}

@Test("Coordinator cancellation interrupts and cleans the active run")
func coordinatorCancellationInterruptsRun() async throws {
    let fixture = try await IncrementalFixture.make()
    defer { fixture.remove() }
    let tracker = RecordingProgressTracker(cancelAtPhase: .replayingEvents)
    let scanner = IncrementalScanner(
        store: fixture.store,
        eventReader: FakeEventReader(
            session: FakeEventSession(
                historical: [],
                live: [],
                historyFence: EventCursorFence(
                    volumeID: fixture.volume.id,
                    eventStoreUUID: fixture.eventStoreUUID,
                    highestFullyDeliveredEventID: 10,
                    phase: .historyDone,
                    trust: .trusted
                ),
                liveFence: EventCursorFence(
                    volumeID: fixture.volume.id,
                    eventStoreUUID: fixture.eventStoreUUID,
                    highestFullyDeliveredEventID: 10,
                    phase: .liveFlush,
                    trust: .trusted
                )
            )
        ),
        metadataReader: POSIXFileMetadataReader(
            diskArbitration: IncrementalMountProvider(volume: fixture.volume),
            managedAbsolutePaths: []
        ),
        subtreeScanner: FileInventoryScanner(
            configuration: try FileInventoryScannerConfiguration(
                managedAbsolutePaths: [],
                validateMountIdentity: false
            )
        ),
        diskUsageSampler: FakeDiskSampler(sampleValue: fixture.baselineSample),
        clock: AdvancingClock(Date(timeIntervalSince1970: 30))
    )
    await #expect(throws: ScanProgressError.cancelled) {
        _ = try await scanner.run(
            volume: fixture.volume,
            scope: fixture.scope,
            trigger: .manual,
            progressTracker: tracker
        )
    }
    let reports = try SQLiteReportStore(
        databaseURL: fixture.databaseRoot.appendingPathComponent("DailyDisk.sqlite")
    )
    #expect(try await reports.recentRuns().first?.status == .interrupted)
    #expect(await tracker.phases.suffix(2) == [.cancelling, .cancelled])
    #expect(try await fixture.store.activeRuns().isEmpty)
}

@Test("FSEvents trust loss preserves the previous checkpoint and requests recovery")
func incrementalTrustLossRequestsRecovery() async throws {
    let fixture = try await IncrementalFixture.make()
    defer { fixture.remove() }
    let session = FakeEventSession(
        historical: [],
        live: [],
        historyFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: fixture.eventStoreUUID,
            highestFullyDeliveredEventID: 10,
            phase: .historyDone,
            trust: .fullScanRequired,
            diagnostic: "Kernel events dropped"
        ),
        liveFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: fixture.eventStoreUUID,
            highestFullyDeliveredEventID: 10,
            phase: .liveFlush,
            trust: .trusted
        )
    )
    let scanner = IncrementalScanner(
        store: fixture.store,
        eventReader: FakeEventReader(session: session),
        metadataReader: POSIXFileMetadataReader(
            diskArbitration: IncrementalMountProvider(volume: fixture.volume),
            managedAbsolutePaths: []
        ),
        subtreeScanner: FileInventoryScanner(
            configuration: try FileInventoryScannerConfiguration(
                managedAbsolutePaths: [],
                validateMountIdentity: false
            )
        ),
        diskUsageSampler: FakeDiskSampler(sampleValue: fixture.baselineSample),
        clock: AdvancingClock(Date(timeIntervalSince1970: 20))
    )

    await #expect(throws: IncrementalScanError.self) {
        _ = try await scanner.run(volume: fixture.volume, scope: fixture.scope)
    }
    let state = try #require(try await fixture.store.state(for: fixture.volume.id))
    #expect(state.checkpoint == fixture.baselineCheckpoint)
    let reports = try SQLiteReportStore(databaseURL: fixture.databaseRoot.appendingPathComponent("DailyDisk.sqlite"))
    #expect(try await reports.recentRuns().contains { $0.status == .failed })
}

private struct UnavailableContentScanner: FileInventoryScanning {
    func scanSubtree(
        volume: MonitoredVolume, root: RelativePath, runID: ScanRun.ID,
        consume: @escaping @Sendable (InventoryRecordBatch) async throws -> Void
    ) async throws -> InventoryScanResult {
        try await scan(volume: volume, runID: runID, consume: consume)
    }

    func scan(
        volume: MonitoredVolume, runID: ScanRun.ID,
        consume: @escaping @Sendable (InventoryRecordBatch) async throws -> Void
    ) async throws -> InventoryScanResult {
        InventoryScanResult(
            coverage: ScanCoverage(
                visitedPathCount: 1, indexedObjectCount: 0,
                unreadablePathCount: 1, transientErrorCount: 0),
            errors: [
                ScanErrorRecord(
                    runID: runID, volumeID: volume.id,
                    kind: .contentUnavailable, path: .root, errorCode: EDEADLK,
                    message: "Synthetic unavailable provider directory")
            ])
    }
}

@Test("Unavailable provider content preserves the baseline rather than reporting deletions")
func unavailableContentPreservesFullScanBaseline() async throws {
    let fixture = try await IncrementalFixture.make()
    defer { fixture.remove() }
    let session = FakeEventSession(
        historical: [], live: [],
        historyFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: fixture.eventStoreUUID, highestFullyDeliveredEventID: 10,
            phase: .historyDone, trust: .trusted),
        liveFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: fixture.eventStoreUUID, highestFullyDeliveredEventID: 10,
            phase: .liveFlush, trust: .trusted))
    let coordinator = FullScanCoordinator(
        store: fixture.store, eventReader: FakeEventReader(session: session),
        metadataReader: POSIXFileMetadataReader(
            diskArbitration: IncrementalMountProvider(volume: fixture.volume), managedAbsolutePaths: []),
        fullScanner: UnavailableContentScanner(),
        diskUsageSampler: FakeDiskSampler(sampleValue: fixture.baselineSample),
        volumeDiscovery: StaticVolumeDiscovery(
            topology: VolumeTopology(
                domains: [fixture.scope.domain], volumes: [fixture.volume],
                discoveredAt: Date(timeIntervalSince1970: 20))),
        clock: AdvancingClock(Date(timeIntervalSince1970: 20)))
    let outcome = try await coordinator.run(volume: fixture.volume, scope: fixture.scope, mode: .scheduled)
    #expect(outcome.reconciliation.reconciliationChanges.isEmpty)
    #expect(outcome.scanErrors.contains { $0.kind == .contentUnavailable })
    let inspection = ScanRun(
        kind: .incremental, reason: .manual, status: .running,
        startedAt: Date(timeIntervalSince1970: 30))
    try await fixture.store.begin(run: inspection)
    let preserved = try await fixture.store.records(
        target: .expectedActive(volumeID: fixture.volume.id), runID: inspection.id,
        paths: [try RelativePath(validating: "a")])
    #expect(preserved.count == 1)
    try await fixture.store.interrupt(runID: inspection.id, finishedAt: Date(timeIntervalSince1970: 31))
}

@Test("Coalesced create/remove events reconcile known endpoints and retain genuine inode ambiguity")
func coalescedReplacementUsesObservedIdentity() async throws {
    let fixture = try await IncrementalFixture.make()
    defer { fixture.remove() }
    let replacement = fixture.root.appendingPathComponent("replacement")
    try Data("replacement contents".utf8).write(to: replacement)
    #expect(rename(replacement.path, fixture.root.appendingPathComponent("a").path) == 0)
    try Data("new contents".utf8).write(to: fixture.root.appendingPathComponent("new-file"))
    let run = ScanRun(
        kind: .incremental, reason: .manual, status: .running,
        startedAt: Date(timeIntervalSince1970: 20))
    try await fixture.store.begin(run: run)
    let mutator = IncrementalInventoryMutator(
        store: fixture.store,
        metadataReader: POSIXFileMetadataReader(
            diskArbitration: IncrementalMountProvider(volume: fixture.volume), managedAbsolutePaths: []),
        subtreeScanner: FileInventoryScanner(
            configuration: try FileInventoryScannerConfiguration(
                managedAbsolutePaths: [], validateMountIdentity: false)))
    let events = try ["a", "new-file", "already-gone", "b"].enumerated().map { index, path in
        FileSystemEvent(
            id: UInt64(11 + index), volumeID: fixture.volume.id,
            path: try RelativePath(validating: path), flags: [.created, .removed, .isFile])
    }
    let result = try await mutator.apply(
        batch: try EventBatch(events: events), volume: fixture.volume,
        target: .expectedActive(volumeID: fixture.volume.id), runID: run.id)
    #expect(result.assessment.trust == .trusted)
    let records = try await fixture.store.records(
        target: .expectedActive(volumeID: fixture.volume.id),
        runID: run.id, paths: events.map(\.path))
    #expect(Set(records.map(\.path.relativePath.displayString)) == ["a", "new-file", "b"])
    try FileManager.default.linkItem(
        at: fixture.root.appendingPathComponent("b"),
        to: fixture.root.appendingPathComponent("b-new-link"))
    let ambiguous = try await mutator.apply(
        batch: try EventBatch(events: [
            FileSystemEvent(
                id: 15, volumeID: fixture.volume.id, path: try RelativePath(validating: "b"),
                flags: [.created, .removed, .isFile])
        ]), volume: fixture.volume,
        target: .expectedActive(volumeID: fixture.volume.id), runID: run.id)
    #expect(ambiguous.assessment.trust == .fullScanRequired)
    try await fixture.store.interrupt(runID: run.id, finishedAt: Date(timeIntervalSince1970: 30))
}

private struct SyntheticMetadataReader: FileMetadataReading {
    let values: [RelativePath: FileMetadataReadResult]
    func read(volume: MonitoredVolume, path: RelativePath) async throws -> FileMetadataReadResult {
        values[path] ?? .missing
    }
}

@Test("Reused inodes are accepted only after every old indexed alias has been removed")
func inodeReuseRequiresNoSurvivingAliases() async throws {
    for oldName in ["a", "b"] {
        let fixture = try await IncrementalFixture.make()
        defer { fixture.remove() }
        let run = ScanRun(kind: .incremental, reason: .manual, status: .running, startedAt: Date())
        try await fixture.store.begin(run: run)
        let target = InventoryMutationTarget.expectedActive(volumeID: fixture.volume.id)
        let oldPath = try RelativePath(validating: oldName)
        let aliasPath = try RelativePath(validating: "a-baseline-link")
        let existing = try await fixture.store.records(target: target, runID: run.id, paths: [oldPath, aliasPath])
        let old = try #require(existing.first { $0.path.relativePath == oldPath })
        let newPath = try RelativePath(validating: "reused-inode")
        let replacement = try InventoryRecord(
            object: old.object,
            path: InventoryPath(
                volumeID: fixture.volume.id, relativePath: newPath, parentPath: .root,
                objectIdentity: old.object.identity))
        let alias = try #require(existing.first { $0.path.relativePath == aliasPath })
        let mutator = IncrementalInventoryMutator(
            store: fixture.store,
            metadataReader: SyntheticMetadataReader(values: [newPath: .record(replacement), aliasPath: .record(alias)]),
            subtreeScanner: UnavailableContentScanner())
        let result = try await mutator.apply(
            batch: EventBatch(events: [
                FileSystemEvent(id: 11, volumeID: fixture.volume.id, path: oldPath, flags: [.removed, .isFile]),
                FileSystemEvent(id: 12, volumeID: fixture.volume.id, path: newPath, flags: [.created, .isFile]),
            ]),
            volume: fixture.volume, target: target, runID: run.id)
        #expect(result.assessment.trust == (oldName == "a" ? .fullScanRequired : .trusted))
        let current = try await fixture.store.records(target: target, runID: run.id, paths: [newPath])
        #expect(current.count == (oldName == "a" ? 0 : 1))
        try await fixture.store.interrupt(runID: run.id, finishedAt: Date())
    }
}
