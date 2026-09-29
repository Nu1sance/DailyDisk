import DailyDiskCore
import DailyDiskPlatform
import Foundation
import Testing

private struct CancellingEventObserver: ScanWorkObserving {
    func checkpoint(_ delta: ScanProgressDelta) async throws {
        throw CancellationError()
    }
}

private actor EventCollector {
    private(set) var events: [FileSystemEvent] = []

    func append(_ batch: EventBatch) {
        events.append(contentsOf: batch.events)
    }
}

private struct FixedEventStoreUUIDProvider: EventStoreUUIDIdentifying {
    let value: UUID?

    func eventStoreUUID(deviceID: UInt64) -> UUID? {
        value
    }
}

private final class EventStoreProbe: EventStoreUUIDIdentifying, @unchecked Sendable {
    private let provider = SystemEventStoreUUIDProvider()
    private let lock = NSLock()
    private var observations: [String] = []

    var diagnostic: String { lock.withLock { observations.joined(separator: "; ") } }

    func eventStoreUUID(deviceID: UInt64) -> UUID? {
        let value = provider.eventStoreUUID(deviceID: deviceID)
        lock.withLock { observations.append("journalAvailable=\(value != nil)") }
        return value
    }

    func latestEventID(deviceID: UInt64) -> UInt64? {
        let value = provider.latestEventID(deviceID: deviceID)
        lock.withLock { observations.append("deviceCursor=\(value.map(String.init) ?? "nil")") }
        return value
    }
}

@Test("Unsupported volumes return an explicit untrusted fence")
func unsupportedVolumeFence() async throws {
    let volume = MonitoredVolume(
        id: MonitoredVolume.ID("metrics"),
        storageDomainID: StorageDomain.ID("domain"),
        filesystemUUID: UUID(),
        eventStoreUUID: nil,
        deviceID: 0,
        mountPath: nil,
        displayName: "Metrics only",
        role: .system,
        isInternal: true,
        isRemovable: false,
        isReadOnly: true,
        supportsPersistentEvents: false,
        topologyFingerprint: "metrics",
        inventoryMode: .metricsOnly
    )
    let session = try await FSEventHistoryReader().openSession(volume: volume, checkpoint: nil)
    let fence = try await session.replayHistoricalEvents(consume: { _ in
        Issue.record("Unavailable session must not deliver events")
    })

    #expect(fence.trust == .fullScanRequired)
    #expect(fence.phase == .historyDone)
    #expect(fence.diagnostic?.contains("does not support") == true)
}

@Test("Unavailable event sessions still honor observer cancellation")
func unavailableSessionCancellation() async throws {
    let volume = MonitoredVolume(
        id: MonitoredVolume.ID("metrics-cancel"),
        storageDomainID: StorageDomain.ID("domain"),
        filesystemUUID: UUID(),
        eventStoreUUID: nil,
        deviceID: 0,
        mountPath: nil,
        displayName: "Metrics only",
        role: .system,
        isInternal: true,
        isRemovable: false,
        isReadOnly: true,
        supportsPersistentEvents: false,
        topologyFingerprint: "metrics",
        inventoryMode: .metricsOnly
    )
    let session = try await FSEventHistoryReader().openSession(volume: volume, checkpoint: nil)
    await #expect(throws: CancellationError.self) {
        _ = try await session.replayHistoricalEvents(
            observer: CancellingEventObserver(),
            consume: { _ in }
        )
    }
}

@Test("A changed journal UUID returns an explicit recovery fence")
func changedJournalFence() async throws {
    let expected = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let replacement = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    let volume = MonitoredVolume(
        id: MonitoredVolume.ID("data"),
        storageDomainID: StorageDomain.ID("domain"),
        filesystemUUID: UUID(),
        eventStoreUUID: expected,
        deviceID: 1,
        mountPath: "/",
        displayName: "Data",
        role: .data,
        isInternal: true,
        isRemovable: false,
        isReadOnly: false,
        supportsPersistentEvents: true,
        topologyFingerprint: "data",
        inventoryMode: .full
    )
    let reader = FSEventHistoryReader(
        eventStoreUUIDProvider: FixedEventStoreUUIDProvider(value: replacement)
    )
    let session = try await reader.openSession(
        volume: volume,
        checkpoint: EventStreamCheckpoint(eventStoreUUID: expected, lastEventID: 10)
    )
    let fence = try await session.replayHistoricalEvents(consume: { _ in })

    #expect(fence.trust == .fullScanRequired)
    #expect(fence.eventStoreUUID == replacement)
    #expect(fence.diagnostic?.contains("UUID changed") == true)
}

@Test("A quiet SinceNow flush still returns a concrete per-device cursor")
func quietSinceNowCursor() async throws {
    guard ProcessInfo.processInfo.environment["CI"] == nil else { return }
    let topology = try await APFSVolumeProvider().discoverInternalAPFSVolumes()
    let volume = try #require(
        topology.volumes.first { $0.role == .data && $0.supportsPersistentEvents }
    )
    let probe = EventStoreProbe()
    let session = try await FSEventHistoryReader(eventStoreUUIDProvider: probe)
        .openSession(volume: volume, checkpoint: nil)
    let history = try await session.replayHistoricalEvents(consume: { _ in })
    let fence = try await session.flushLiveEvents(consume: { _ in })
    let diagnostic =
        "history=\(history.diagnostic ?? "none"); flush=\(fence.diagnostic ?? "none"); \(probe.diagnostic)"

    #expect(history.trust == .trusted, "Quiet history diagnostic: \(diagnostic)")
    #expect(fence.trust == .trusted, "Quiet flush diagnostic: \(diagnostic)")
    #expect(
        fence.highestFullyDeliveredEventID != nil,
        "Quiet flush diagnostic: \(diagnostic)"
    )
}

@Test("Real FSEvents session flushes live events and replays events after restart")
func realFSEventsReplay() async throws {
    guard ProcessInfo.processInfo.environment["CI"] == nil else { return }
    let topology = try await APFSVolumeProvider().discoverInternalAPFSVolumes()
    let volume = try #require(
        topology.volumes.first {
            $0.role == .data
                && $0.mountPath == "/System/Volumes/Data"
                && $0.supportsPersistentEvents
        }
    )

    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/DailyDiskFSEvents", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let relativeRoot = try RelativePath(validating: String(directory.path.dropFirst()))
    let configuration = try FSEventReaderConfiguration(
        latency: 0.05,
        historyTimeoutSeconds: 5,
        pollingInterval: .milliseconds(5),
        maximumBufferedEvents: 10_000,
        watchRoots: [relativeRoot]
    )
    let reader = FSEventHistoryReader(configuration: configuration)

    let firstSession = try await reader.openSession(volume: volume, checkpoint: nil)
    let initialFence = try await firstSession.replayHistoricalEvents(consume: { _ in })
    #expect(initialFence.trust == .trusted)

    let firstFile = directory.appendingPathComponent("first-event")
    _ = try await SystemProcessRunner().run(
        ProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
            arguments: [firstFile.path]
        )
    )
    let burstNames = (0..<64).map { "burst-\($0)" }
    for name in burstNames { try Data(name.utf8).write(to: directory.appendingPathComponent(name)) }
    let liveCollector = EventCollector()
    let liveFence = try await firstSession.flushLiveEvents { batch in
        await liveCollector.append(batch)
    }
    let liveEvents = await liveCollector.events
    #expect(liveFence.trust == .trusted)
    #expect(liveFence.highestFullyDeliveredEventID != nil)
    let expectedFirstPath = try PathPolicy.appending(
        componentBytes: Data("first-event".utf8),
        to: relativeRoot
    )
    #expect(liveEvents.contains { $0.path == expectedFirstPath })
    let expectedBurst = try Set(
        burstNames.map { try PathPolicy.appending(componentBytes: Data($0.utf8), to: relativeRoot) })

    let secondFile = directory.appendingPathComponent("second-event")
    _ = try await SystemProcessRunner().run(
        ProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
            arguments: [secondFile.path]
        )
    )
    try await Task.sleep(for: .milliseconds(150))

    let secondSession = try await reader.openSession(
        volume: volume,
        checkpoint: EventStreamCheckpoint(
            eventStoreUUID: try #require(liveFence.eventStoreUUID),
            lastEventID: liveFence.highestFullyDeliveredEventID
        )
    )
    let historicalCollector = EventCollector()
    let replayFence = try await secondSession.replayHistoricalEvents { batch in
        await historicalCollector.append(batch)
    }
    let historicalEvents = await historicalCollector.events
    await secondSession.stop()

    #expect(replayFence.trust == .trusted)
    let expectedSecondPath = try PathPolicy.appending(
        componentBytes: Data("second-event".utf8),
        to: relativeRoot
    )
    #expect(historicalEvents.contains { $0.path == expectedSecondPath })
    // Kernel-to-daemon delivery may straddle the flush; the next replay must
    // recover every remaining event rather than skip it past the saved cursor.
    #expect(expectedBurst.isSubset(of: Set((liveEvents + historicalEvents).map(\.path))))
    #expect(
        (replayFence.highestFullyDeliveredEventID ?? 0)
            >= (liveFence.highestFullyDeliveredEventID ?? 0)
    )
}
