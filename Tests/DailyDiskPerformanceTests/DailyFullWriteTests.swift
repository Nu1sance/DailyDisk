import DailyDiskCore
import DailyDiskStore
import Darwin
import Foundation
import Testing

private func dailyUsage() throws -> rusage_info_v2 {
    var info = rusage_info_v2()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
        }
    }
    guard status == 0 else { throw POSIXError(.EIO) }
    return info
}

private actor DailyWritePeaks {
    var wal: Int64 = 0
    var resident: UInt64 = 0
    func sample(_ url: URL) {
        var info = stat()
        if lstat(url.path + "-wal", &info) == 0 { wal = max(wal, Int64(info.st_size)) }
        resident = max(resident, (try? dailyUsage().ri_resident_size) ?? 0)
    }
}

@Test(
    "Daily snapshot replacement write budget",
    .enabled(if: ProcessInfo.processInfo.environment["DAILYDISK_DAILY_WRITE_TEST"] == "1"))
func dailyFullWriteBudget() async throws {
    let env = ProcessInfo.processInfo.environment
    let count = Int(env["DAILYDISK_WRITE_ROWS"] ?? "100000")!
    let batchSize = Int(env["DAILYDISK_WRITE_BATCH"] ?? "512")!
    let bounded = env["DAILYDISK_WRITE_WAL"] == "bounded"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DailyFullWrite-\(UUID())")
    let url = root.appendingPathComponent("DailyDisk.sqlite")
    defer { try? FileManager.default.removeItem(at: root) }
    let peaks = DailyWritePeaks()
    let monitor = Task {
        while !Task.isCancelled {
            await peaks.sample(url)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    defer { monitor.cancel() }
    let store = try SQLiteInventoryStore(databaseURL: url, checkpointPolicy: bounded ? .bounded() : .everyTransaction)
    try await store.prepare()
    let domain = StorageDomain(
        id: StorageDomain.ID("budget"), containerIdentifier: "disk-test", displayName: "Test", isInternal: true)
    let volume = MonitoredVolume(
        id: MonitoredVolume.ID("data"), storageDomainID: domain.id,
        filesystemUUID: UUID(), eventStoreUUID: UUID(), deviceID: 1, mountPath: "/synthetic", displayName: "Test",
        role: .data, isInternal: true, isRemovable: false, isReadOnly: false, supportsPersistentEvents: true,
        topologyFingerprint: "budget", inventoryMode: .full)
    let scope = try StorageDomainScope(domain: domain, volumes: [volume])
    try await store.register(scope: scope)
    let reader = try SQLiteReportStore(databaseURL: url)
    var previousCheckpoint: Checkpoint?
    var previousSample: StorageSample?
    let parent = try RelativePath(validating: "synthetic/Library/Application Support/Repeated/Cache")
    let epoch = Date().timeIntervalSince1970.rounded(.down)
    for cycle in 0..<3 {
        let start = Date()
        let io = try dailyUsage().ri_diskio_byteswritten
        let run = ScanRun(kind: .full, reason: .dailySchedule, status: .running, startedAt: start)
        try await store.begin(run: run)
        let generation = try await store.createStagingGeneration(volumeID: volume.id, runID: run.id, at: start)
        let target = InventoryMutationTarget.stagingGeneration(generation.id)
        for offset in stride(from: 0, to: count, by: batchSize) {
            var records: [InventoryRecord] = []
            for i in offset..<min(offset + batchSize, count) {
                let identity = FileIdentity(volumeID: volume.id, deviceID: 1, inode: UInt64(i + 1))
                let path = try RelativePath(validating: parent.displayString + String(format: "/%08d", i))
                records.append(
                    try InventoryRecord(
                        object: InventoryObject(
                            identity: identity, kind: .regular,
                            footprint: FileFootprint(logicalBytes: 4096, allocatedBytes: 4096), linkCount: 1,
                            modifiedAt: nil, metadataChangedAt: nil),
                        path: InventoryPath(
                            volumeID: volume.id, relativePath: path, parentPath: parent, objectIdentity: identity)))
            }
            try await store.append(records: records, to: generation.id)
        }
        try await store.finalizeCanonicalAttribution(target: target, runID: run.id, consume: { _ in })
        let changes = try await store.deriveSnapshotChanges(
            authoritative: target, runID: run.id, observer: TaskOnlyScanWorkObserver())
        #expect(changes.isEmpty)
        let date = Date(timeIntervalSince1970: epoch + Double(cycle))
        let sample = try StorageSample(
            storageDomainID: domain.id, sampledAt: date,
            capacityBytes: 10_000_000_000, usedBytes: 1_000_000_000, availableBytes: 9_000_000_000)
        let checkpoint = Checkpoint(
            volumeID: volume.id, eventStoreUUID: volume.eventStoreUUID,
            lastCommittedEventID: UInt64(cycle + 1), activeGenerationID: generation.id,
            topologyFingerprint: volume.topologyFingerprint, lastSuccessfulIncrementalAt: nil,
            lastSuccessfulFullScanAt: date)
        try await store.commit(
            ScanCommit(
                runID: run.id, runKind: .full, scope: scope, volumeID: volume.id,
                activatedGenerationID: generation.id, previousCheckpoint: previousCheckpoint, checkpoint: checkpoint,
                eventFence: EventCursorFence(
                    volumeID: volume.id, eventStoreUUID: volume.eventStoreUUID,
                    highestFullyDeliveredEventID: UInt64(cycle + 1), phase: .liveFlush, trust: .trusted),
                changes: changes, storageSamples: [sample], snapshotSamples: [], comparesSnapshots: true),
            finishedAt: date)
        let report = try DailyReport(
            runID: run.id, generatedAt: date, storageDomainID: domain.id,
            accounting: SpaceAccounting.summarize(
                changes: [], scope: scope, previousSample: previousSample, currentSample: sample),
            reconciliation: nil,
            coverage: ScanCoverage(
                visitedPathCount: UInt64(count), indexedObjectCount: UInt64(count),
                unreadablePathCount: 0, transientErrorCount: 0), largestGrowth: [], largestShrinkage: [],
            diagnostics: [])
        try await store.commitReport(
            ReportCommit(
                runID: run.id, scope: scope, changes: [], previousStorageSample: previousSample,
                currentStorageSample: sample, previousOverheadSample: nil, currentOverheadSample: nil, report: report))
        print(
            "DAILY_WRITE wal=\(bounded) batch=\(batchSize) rows=\(count) cycle=\(cycle) phase=scan bytes=\(try dailyUsage().ri_diskio_byteswritten - io) seconds=\(Date().timeIntervalSince(start))"
        )
        let deleteStart = Date()
        let deleteIO = try dailyUsage().ri_diskio_byteswritten
        try await store.pruneRetiredGenerations(at: Date().addingTimeInterval(86410))
        let usage = try await reader.spaceUsage()
        print(
            "DAILY_WRITE cycle=\(cycle) phase=delete bytes=\(try dailyUsage().ri_diskio_byteswritten - deleteIO) seconds=\(Date().timeIntervalSince(deleteStart)) db=\(usage.databaseBytes) free=\(usage.reusableBytes)"
        )
        #expect(try await store.state(for: volume.id)?.checkpoint == checkpoint)
        #expect(try await reader.diagnostics().tableCounts["inventory_generations"] == 1)
        previousCheckpoint = checkpoint
        previousSample = sample
    }
    let compactIO = try dailyUsage().ri_diskio_byteswritten
    let compactStart = Date()
    try await store.maintainSpace(force: true, availableBytes: { Int64.max })
    print(
        "DAILY_WRITE phase=compact bytes=\(try dailyUsage().ri_diskio_byteswritten - compactIO) seconds=\(Date().timeIntervalSince(compactStart)) allocated=\(try await reader.spaceUsage().allocatedBytes)"
    )
    #expect(try await store.state(for: volume.id)?.checkpoint == previousCheckpoint)
    #expect(try await reader.verify().isHealthy)
    print("DAILY_WRITE peakWAL=\(await peaks.wal) peakResident=\(await peaks.resident)")
}
