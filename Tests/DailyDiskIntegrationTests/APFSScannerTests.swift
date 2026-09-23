import DailyDiskCore
import DailyDiskPlatform
import DailyDiskStore
import Darwin
import Foundation
import Testing

private struct ScannerFixture {
    let root: URL
    let volume: MonitoredVolume

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyDiskScannerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var status = Darwin.stat()
        guard lstat(root.path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        volume = MonitoredVolume(
            id: MonitoredVolume.ID("scanner-volume"),
            storageDomainID: StorageDomain.ID("scanner-domain"),
            filesystemUUID: UUID(),
            eventStoreUUID: UUID(),
            deviceID: UInt64(UInt32(bitPattern: status.st_dev)),
            mountPath: root.path,
            displayName: "Scanner Fixture",
            role: .data,
            isInternal: true,
            isRemovable: false,
            isReadOnly: false,
            supportsPersistentEvents: true,
            topologyFingerprint: "scanner-fixture",
            inventoryMode: .full
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor WorkObserverProbe: ScanWorkObserving {
    private let cancelAfterCheckpoint: Int?
    private(set) var checkpointCount = 0
    private(set) var counters = ScanProgressCounters()

    init(cancelAfterCheckpoint: Int? = nil) {
        self.cancelAfterCheckpoint = cancelAfterCheckpoint
    }

    func checkpoint(_ delta: ScanProgressDelta) async throws {
        checkpointCount += 1
        if let cancelAfterCheckpoint, checkpointCount >= cancelAfterCheckpoint {
            throw CancellationError()
        }
        counters = try counters.applying(delta)
    }
}

private actor RecordCollector {
    private(set) var records: [InventoryRecord] = []
    private(set) var batchSizes: [Int] = []

    func append(_ batch: InventoryRecordBatch) {
        records.append(contentsOf: batch.records)
        batchSizes.append(batch.records.count)
    }
}

private actor CanonicalBatchCollector {
    private(set) var count = 0

    func append(_ batch: CanonicalAttributionBatch) {
        count += batch.attributions.count
    }
}

private actor DeleteOnFirstBatch {
    private var deleted = false
    private let target: URL
    private(set) var records: [InventoryRecord] = []

    init(target: URL) {
        self.target = target
    }

    func consume(_ batch: InventoryRecordBatch) {
        records.append(contentsOf: batch.records)
        if !deleted {
            deleted = true
            try? FileManager.default.removeItem(at: target)
        }
    }
}

@Test("Scanner inventories metadata without following symlinks and deduplicates hard-link objects")
func scannerInventoriesFilesystemMetadata() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let regular = fixture.root.appendingPathComponent("regular.dat")
    try Data(repeating: 0x41, count: 8_192).write(to: regular)
    let hardLink = fixture.root.appendingPathComponent("regular-hardlink.dat")
    try FileManager.default.linkItem(at: regular, to: hardLink)

    let sparse = fixture.root.appendingPathComponent("sparse.dat")
    let sparseFD = open(sparse.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    #expect(sparseFD >= 0)
    #expect(ftruncate(sparseFD, 8 * 1_024 * 1_024) == 0)
    close(sparseFD)

    let package = fixture.root.appendingPathComponent("Example.app/Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data("package".utf8).write(to: package.appendingPathComponent("payload"))

    let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    try Data("must not be scanned".utf8).write(to: outside.appendingPathComponent("secret"))
    try FileManager.default.createSymbolicLink(
        at: fixture.root.appendingPathComponent("outside-link"),
        withDestinationURL: outside
    )

    let managed = fixture.root.appendingPathComponent("DailyDiskInternal", isDirectory: true)
    try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
    try Data("index".utf8).write(to: managed.appendingPathComponent("index.sqlite"))

    let rawName = Data("原始名".utf8)
    let rootFD = open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    #expect(rootFD >= 0)
    var terminatedName = [UInt8](rawName)
    terminatedName.append(0)
    let rawFD = terminatedName.withUnsafeBufferPointer { buffer in
        buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
            openat(rootFD, $0, O_CREAT | O_WRONLY | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
    }
    #expect(rawFD >= 0)
    close(rawFD)
    close(rootFD)

    let configuration = try FileInventoryScannerConfiguration(
        batchSize: 2,
        managedAbsolutePaths: [managed.path],
        validateMountIdentity: false
    )
    let collector = RecordCollector()
    let result = try await FileInventoryScanner(configuration: configuration).scan(
        volume: fixture.volume,
        runID: ScanRun.ID(),
        consume: { batch in await collector.append(batch) }
    )
    let records = await collector.records
    let batchSizes = await collector.batchSizes
    let byPath = Dictionary(uniqueKeysWithValues: records.map { ($0.path.relativePath.bytes, $0) })

    #expect(!records.isEmpty)
    #expect(batchSizes.allSatisfy { $0 > 0 && $0 <= 2 })
    #expect(result.errors.isEmpty)
    #expect(result.coverage.visitedPathCount > UInt64(records.count))
    #expect(result.coverage.indexedObjectCount == UInt64(Set(records.map(\.object.identity)).count))

    let regularRecord = try #require(byPath[Data("regular.dat".utf8)])
    let hardLinkRecord = try #require(byPath[Data("regular-hardlink.dat".utf8)])
    #expect(regularRecord.object.identity == hardLinkRecord.object.identity)
    #expect(regularRecord.object.linkCount == 2)

    let sparseRecord = try #require(byPath[Data("sparse.dat".utf8)])
    #expect(sparseRecord.object.footprint.logicalBytes == 8 * 1_024 * 1_024)
    #expect(sparseRecord.object.footprint.allocatedBytes <= sparseRecord.object.footprint.logicalBytes)

    let symlink = try #require(byPath[Data("outside-link".utf8)])
    #expect(symlink.object.kind == .symbolicLink)
    #expect(!records.contains { $0.path.relativePath.displayString.contains("secret") })
    #expect(byPath[rawName] != nil)
    #expect(byPath[Data("DailyDiskInternal".utf8)] == nil)
    #expect(byPath[Data("DailyDiskInternal/index.sqlite".utf8)] == nil)
    #expect(byPath[Data("Example.app/Contents/payload".utf8)] != nil)
}

@Test("Scanner reports path-free counters with exact hard-link object totals")
func scannerReportsProgressCounters() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }
    let original = fixture.root.appendingPathComponent("original")
    try Data("payload".utf8).write(to: original)
    try FileManager.default.linkItem(
        at: original,
        to: fixture.root.appendingPathComponent("linked")
    )
    let observer = WorkObserverProbe()
    let result = try await FileInventoryScanner(
        configuration: try FileInventoryScannerConfiguration(
            batchSize: 1,
            managedAbsolutePaths: [],
            validateMountIdentity: false
        )
    ).scan(
        volume: fixture.volume,
        runID: ScanRun.ID(),
        observer: observer,
        consume: { _ in }
    )
    let counters = await observer.counters
    #expect(counters.visitedPaths == result.coverage.visitedPathCount)
    #expect(counters.indexedObjects == result.coverage.indexedObjectCount)
    #expect(counters.unreadablePaths == result.coverage.unreadablePathCount)
    #expect(counters.transientErrors == result.coverage.transientErrorCount)
    #expect(counters.indexedObjects < counters.visitedPaths)
}

@Test("Scanner cancellation is observed within a bounded directory chunk")
func scannerCancellationIsBounded() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }
    for index in 0..<300 {
        try Data().write(to: fixture.root.appendingPathComponent("item-\(index)"))
    }
    let observer = WorkObserverProbe(cancelAfterCheckpoint: 4)
    let scanner = FileInventoryScanner(
        configuration: try FileInventoryScannerConfiguration(
            batchSize: 1_024,
            managedAbsolutePaths: [],
            validateMountIdentity: false
        )
    )
    await #expect(throws: CancellationError.self) {
        _ = try await scanner.scan(
            volume: fixture.volume,
            runID: ScanRun.ID(),
            observer: observer,
            consume: { _ in }
        )
    }
    #expect(await observer.checkpointCount == 4)
}

@Test("Scanner batches stream directly into a SQLite staging generation")
func scannerStreamsIntoSQLiteStaging() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }
    try Data("payload".utf8).write(to: fixture.root.appendingPathComponent("payload"))

    let databaseRoot = fixture.root.appendingPathComponent("DailyDiskInternal", isDirectory: true)
    let store = try SQLiteInventoryStore(
        databaseURL: databaseRoot.appendingPathComponent("DailyDisk.sqlite")
    )
    try await store.prepare()
    let domain = StorageDomain(
        id: fixture.volume.storageDomainID,
        containerIdentifier: "scanner-container",
        displayName: "Scanner Container",
        isInternal: true
    )
    try await store.register(scope: StorageDomainScope(domain: domain, volumes: [fixture.volume]))
    let run = ScanRun(
        kind: .full,
        reason: .manual,
        status: .running,
        startedAt: Date()
    )
    try await store.begin(run: run)
    let generation = try await store.createStagingGeneration(
        volumeID: fixture.volume.id,
        runID: run.id,
        at: run.startedAt
    )

    let scanner = FileInventoryScanner(
        configuration: try FileInventoryScannerConfiguration(
            managedAbsolutePaths: [databaseRoot.path],
            validateMountIdentity: false
        )
    )
    let result = try await scanner.scan(
        volume: fixture.volume,
        runID: run.id,
        consume: { batch in
            try await store.append(records: batch.records, to: generation.id)
        }
    )
    let canonical = CanonicalBatchCollector()
    try await store.finalizeCanonicalAttribution(
        target: .stagingGeneration(generation.id),
        runID: run.id,
        consume: { batch in await canonical.append(batch) }
    )
    let records = try await store.records(
        target: .stagingGeneration(generation.id),
        runID: run.id,
        paths: [
            .root,
            RelativePath(validating: "payload"),
            RelativePath(validating: "DailyDiskInternal"),
            RelativePath(validating: "DailyDiskInternal/DailyDisk.sqlite"),
        ]
    )

    let canonicalCount = await canonical.count
    #expect(records.count == 2)
    #expect(canonicalCount == Int(result.coverage.indexedObjectCount))
}

@Test("Subtree scans include the directory and descendants but not siblings")
func scannerScansOneSubtree() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }
    let subtree = fixture.root.appendingPathComponent("subtree/child", isDirectory: true)
    try FileManager.default.createDirectory(at: subtree, withIntermediateDirectories: true)
    try Data("inside".utf8).write(to: subtree.appendingPathComponent("file"))
    try Data("outside".utf8).write(to: fixture.root.appendingPathComponent("sibling"))

    let collector = RecordCollector()
    let scanner = FileInventoryScanner(
        configuration: try FileInventoryScannerConfiguration(validateMountIdentity: false)
    )
    let result = try await scanner.scanSubtree(
        volume: fixture.volume,
        root: RelativePath(validating: "subtree"),
        runID: ScanRun.ID(),
        consume: { batch in await collector.append(batch) }
    )
    let paths = Set(await collector.records.map(\.path.relativePath.displayString))

    #expect(paths == ["subtree", "subtree/child", "subtree/child/file"])
    #expect(result.coverage.visitedPathCount == 3)
}

@Test("A file disappearing after directory enumeration is reported as transient")
func scannerReportsDisappearingFile() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }
    try Data("trigger".utf8).write(to: fixture.root.appendingPathComponent("a-trigger"))
    let vanishing = fixture.root.appendingPathComponent("z-vanishing")
    try Data("temporary".utf8).write(to: vanishing)

    let consumer = DeleteOnFirstBatch(target: vanishing)
    // Root + a-trigger fills the first batch after the directory entries were
    // copied. The callback then removes z-vanishing before its fstatat call.
    let configuration = try FileInventoryScannerConfiguration(
        batchSize: 2,
        validateMountIdentity: false
    )
    let result = try await FileInventoryScanner(configuration: configuration).scan(
        volume: fixture.volume,
        runID: ScanRun.ID(),
        consume: { batch in await consumer.consume(batch) }
    )

    #expect(result.coverage.transientErrorCount == 1)
    #expect(result.errors.contains { $0.kind == .disappearedDuringScan })
}

@Test("Unreadable traversal can invalidate a full scan by policy")
func scannerEnforcesCompletenessPolicy() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }
    let protected = fixture.root.appendingPathComponent("protected", isDirectory: true)
    try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
    try Data("hidden".utf8).write(to: protected.appendingPathComponent("file"))
    #expect(chmod(protected.path, 0) == 0)
    defer { chmod(protected.path, S_IRWXU) }

    let configuration = try FileInventoryScannerConfiguration(
        maximumUnreadablePaths: 0,
        maximumUnreadableFraction: 0,
        validateMountIdentity: false
    )
    do {
        _ = try await FileInventoryScanner(configuration: configuration).scan(
            volume: fixture.volume,
            runID: ScanRun.ID(),
            consume: { _ in }
        )
        Issue.record("Expected an incomplete scan")
    } catch FileInventoryScannerError.incomplete(let result) {
        #expect(result.coverage.unreadablePathCount == 1)
        #expect(result.errors.contains { $0.kind == .permissionDenied })
    }

    let fractionOnly = try FileInventoryScannerConfiguration(
        maximumUnreadablePaths: 100,
        maximumUnreadableFraction: 0,
        validateMountIdentity: false
    )
    await #expect(throws: FileInventoryScannerError.self) {
        _ = try await FileInventoryScanner(configuration: fractionOnly).scan(
            volume: fixture.volume,
            runID: ScanRun.ID(),
            consume: { _ in }
        )
    }

    let absoluteOnly = try FileInventoryScannerConfiguration(
        maximumUnreadablePaths: 0,
        maximumUnreadableFraction: 1,
        validateMountIdentity: false
    )
    await #expect(throws: FileInventoryScannerError.self) {
        _ = try await FileInventoryScanner(configuration: absoluteOnly).scan(
            volume: fixture.volume,
            runID: ScanRun.ID(),
            consume: { _ in }
        )
    }
}

@Test("Scanner rejects metrics-only volumes and mount-device mismatches")
func scannerRejectsInvalidRoots() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }
    let metricsOnly = MonitoredVolume(
        id: fixture.volume.id,
        storageDomainID: fixture.volume.storageDomainID,
        filesystemUUID: fixture.volume.filesystemUUID,
        volumeGroupUUID: fixture.volume.volumeGroupUUID,
        eventStoreUUID: nil,
        deviceID: fixture.volume.deviceID,
        mountPath: fixture.volume.mountPath,
        displayName: fixture.volume.displayName,
        role: .system,
        isInternal: true,
        isRemovable: false,
        isReadOnly: true,
        supportsPersistentEvents: false,
        topologyFingerprint: fixture.volume.topologyFingerprint,
        inventoryMode: .metricsOnly
    )
    await #expect(throws: FileInventoryScannerError.self) {
        _ = try await FileInventoryScanner().scan(
            volume: metricsOnly,
            runID: ScanRun.ID(),
            consume: { _ in }
        )
    }

    let wrongDevice = MonitoredVolume(
        id: fixture.volume.id,
        storageDomainID: fixture.volume.storageDomainID,
        filesystemUUID: fixture.volume.filesystemUUID,
        volumeGroupUUID: fixture.volume.volumeGroupUUID,
        eventStoreUUID: fixture.volume.eventStoreUUID,
        deviceID: fixture.volume.deviceID + 1,
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
    await #expect(throws: FileInventoryScannerError.self) {
        _ = try await FileInventoryScanner().scan(
            volume: wrongDevice,
            runID: ScanRun.ID(),
            consume: { _ in }
        )
    }
}
