import CoreServices
import DailyDiskCore
import Darwin
import Foundation

public struct FSEventReaderConfiguration: Sendable {
    public let latency: TimeInterval
    public let historyTimeoutSeconds: TimeInterval
    public let pollingInterval: Duration
    public let maximumBufferedEvents: Int
    public let watchRoots: [RelativePath]

    public init(
        latency: TimeInterval = 0.25,
        historyTimeoutSeconds: TimeInterval = 30,
        pollingInterval: Duration = .milliseconds(10),
        maximumBufferedEvents: Int = 100_000,
        watchRoots: [RelativePath] = [.root]
    ) throws {
        guard latency >= 0,
            historyTimeoutSeconds > 0,
            maximumBufferedEvents >= EventBatch.maximumEventCount,
            !watchRoots.isEmpty
        else {
            throw FSEventReaderError.invalidConfiguration
        }
        self.latency = latency
        self.historyTimeoutSeconds = historyTimeoutSeconds
        self.pollingInterval = pollingInterval
        self.maximumBufferedEvents = maximumBufferedEvents
        self.watchRoots = watchRoots
    }

    public static let `default` = try! FSEventReaderConfiguration()
}

public struct FSEventHistoryReader: EventHistoryReading {
    private let configuration: FSEventReaderConfiguration
    private let eventStoreUUIDProvider: any EventStoreUUIDIdentifying

    public init(
        configuration: FSEventReaderConfiguration = .default,
        eventStoreUUIDProvider: any EventStoreUUIDIdentifying = SystemEventStoreUUIDProvider()
    ) {
        self.configuration = configuration
        self.eventStoreUUIDProvider = eventStoreUUIDProvider
    }

    public func openSession(
        volume: MonitoredVolume,
        checkpoint: EventStreamCheckpoint?
    ) async throws -> any EventHistorySession {
        return try await ScanProbe.$context.withValue(ScanProbe.context.session()) {
            ScanProbe.emit(
                .sessionOpened,
                fields: [
                    "volume": volume.id.rawValue, "device": String(volume.deviceID),
                    "expectedUUID": checkpoint?.eventStoreUUID.uuidString ?? volume.eventStoreUUID?.uuidString ?? "nil",
                    "since": checkpoint?.lastEventID.map { String($0) } ?? "sinceNow",
                ])
            let eventID = checkpoint?.lastEventID
            guard volume.inventoryMode == .full,
                volume.supportsPersistentEvents,
                volume.deviceID != 0,
                let nativeDeviceID = nativeDeviceID(from: volume.deviceID)
            else {
                ScanProbe.emit(.rejection, reason: .journalUnavailable)
                return UnavailableEventHistorySession(
                    volumeID: volume.id,
                    eventStoreUUID: volume.eventStoreUUID,
                    eventID: eventID,
                    reason: "Volume does not support persistent FSEvents"
                )
            }

            let observedUUID = eventStoreUUIDProvider.eventStoreUUID(deviceID: volume.deviceID)
            let journalAssessment = EventTrustEvaluator.assessJournal(
                expectedUUID: checkpoint?.eventStoreUUID ?? volume.eventStoreUUID,
                observedUUID: observedUUID,
                previousEventID: eventID,
                observedEventID: eventID
            )
            guard journalAssessment.trust == .trusted, let observedUUID else {
                return UnavailableEventHistorySession(
                    volumeID: volume.id,
                    eventStoreUUID: observedUUID,
                    eventID: eventID,
                    reason: journalAssessment.reasons.joined(separator: "; ")
                )
            }

            let watchPaths = try configuration.watchRoots.map { path -> String in
                if path == .root { return "/" }
                guard let value = String(data: path.bytes, encoding: .utf8) else {
                    throw FSEventReaderError.watchPathIsNotUTF8(path)
                }
                return "/" + value
            }
            let mailbox = FSEventMailbox(
                volumeID: volume.id,
                previousEventID: eventID,
                maximumBufferedEvents: configuration.maximumBufferedEvents,
                historyStartsComplete: eventID == nil
            )
            let callbackBox = FSEventCallbackBox(mailbox: mailbox)
            let sinceWhen = eventID ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
            let handle = try FSEventStreamHandle(
                nativeDeviceID: nativeDeviceID,
                watchPaths: watchPaths,
                sinceWhen: sinceWhen,
                latency: configuration.latency,
                callbackBox: callbackBox
            )
            return ActiveEventHistorySession(
                volumeID: volume.id,
                deviceID: volume.deviceID,
                initialEventStoreUUID: observedUUID,
                initialEventID: eventID,
                configuration: configuration,
                eventStoreUUIDProvider: eventStoreUUIDProvider,
                mailbox: mailbox,
                handle: handle
            )
        }
    }

}

public enum FSEventReaderError: Error, Equatable, Sendable {
    case invalidConfiguration
    case watchPathIsNotUTF8(RelativePath)
    case streamCreationFailed
    case streamStartFailed
    case historyAlreadyConsumed
    case historyMustBeConsumedBeforeFlush
    case operationAlreadyInProgress
    case operationInterrupted
}

private actor UnavailableEventHistorySession: EventHistorySession {
    let probe = ScanProbe.context
    let volumeID: MonitoredVolume.ID
    let eventStoreUUID: UUID?
    let eventID: UInt64?
    let reason: String

    init(volumeID: MonitoredVolume.ID, eventStoreUUID: UUID?, eventID: UInt64?, reason: String) {
        self.volumeID = volumeID
        self.eventStoreUUID = eventStoreUUID
        self.eventID = eventID
        self.reason = reason
    }

    func replayHistoricalEvents(
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws -> EventCursorFence {
        try await replayHistoricalEvents(
            observer: TaskOnlyScanWorkObserver(),
            consume: consume
        )
    }

    func replayHistoricalEvents(
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws -> EventCursorFence {
        try await observer.checkpoint()
        return fence(phase: .historyDone)
    }

    func flushLiveEvents(
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws -> EventCursorFence {
        try await flushLiveEvents(
            observer: TaskOnlyScanWorkObserver(),
            consume: consume
        )
    }

    func flushLiveEvents(
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws -> EventCursorFence {
        try await observer.checkpoint()
        return fence(phase: .liveFlush)
    }

    func stop() async {}

    private func fence(phase: EventCursorFence.Phase) -> EventCursorFence {
        probe.emit(phase == .historyDone ? .historyDone : .liveFlush, fields: ["trust": "fullScanRequired"])
        return EventCursorFence(
            volumeID: volumeID,
            eventStoreUUID: eventStoreUUID,
            highestFullyDeliveredEventID: eventID,
            phase: phase,
            trust: .fullScanRequired,
            diagnostic: reason
        )
    }
}

private actor ActiveEventHistorySession: EventHistorySession {
    let probe = ScanProbe.context
    enum State: Equatable {
        case idle
        case replaying
        case historyReady
        case flushing
        case finished
        case failed
        case stopped
    }

    let volumeID: MonitoredVolume.ID
    let deviceID: UInt64
    let initialEventStoreUUID: UUID
    let initialEventID: UInt64?
    let configuration: FSEventReaderConfiguration
    let eventStoreUUIDProvider: any EventStoreUUIDIdentifying
    let mailbox: FSEventMailbox
    let handle: FSEventStreamHandle

    var state: State = .idle
    var highestDeliveredEventID: UInt64?
    var lastConsumeSample: UInt64 = 0
    var consumedBatches: UInt64 = 0
    var consumptionNanoseconds: UInt64 = 0

    init(
        volumeID: MonitoredVolume.ID,
        deviceID: UInt64,
        initialEventStoreUUID: UUID,
        initialEventID: UInt64?,
        configuration: FSEventReaderConfiguration,
        eventStoreUUIDProvider: any EventStoreUUIDIdentifying,
        mailbox: FSEventMailbox,
        handle: FSEventStreamHandle
    ) {
        self.volumeID = volumeID
        self.deviceID = deviceID
        self.initialEventStoreUUID = initialEventStoreUUID
        self.initialEventID = initialEventID
        self.configuration = configuration
        self.eventStoreUUIDProvider = eventStoreUUIDProvider
        self.mailbox = mailbox
        self.handle = handle
        highestDeliveredEventID = initialEventID
    }

    func replayHistoricalEvents(
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws -> EventCursorFence {
        try await replayHistoricalEvents(
            observer: TaskOnlyScanWorkObserver(),
            consume: consume
        )
    }

    func replayHistoricalEvents(
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws -> EventCursorFence {
        guard state == .idle else { throw FSEventReaderError.operationAlreadyInProgress }
        state = .replaying
        do {
            let deadline = Date().addingTimeInterval(configuration.historyTimeoutSeconds)
            while true {
                try await observer.checkpoint()
                guard state == .replaying else {
                    probe.emit(.rejection, reason: .operationInterrupted)
                    throw FSEventReaderError.operationInterrupted
                }
                try mailbox.checkReplayTrust()
                let events = mailbox.drainHistorical(maximumCount: EventBatch.maximumEventCount)
                if !events.isEmpty {
                    try await deliver(
                        events,
                        expectedState: .replaying,
                        observer: observer,
                        consume: consume
                    )
                    continue
                }
                if let boundary = mailbox.historyBoundarySequence {
                    let fence = makeFence(phase: .historyDone, boundarySequence: boundary)
                    mailbox.discardAssessments(throughSequence: boundary)
                    if fence.trust == .fullScanRequired {
                        state = .failed
                        handle.stop()
                    } else {
                        state = .historyReady
                    }
                    return fence
                }
                if Date() >= deadline {
                    probe.emit(.rejection, reason: .historyTimeout)
                    let boundary = mailbox.latestSequence
                    let fence = makeFence(
                        phase: .historyDone,
                        boundarySequence: boundary,
                        additionalAssessment: EventTrustAssessment(
                            trust: .fullScanRequired,
                            reasons: ["Timed out waiting for FSEvents HistoryDone"]
                        )
                    )
                    state = .failed
                    handle.stop()
                    return fence
                }
                try await Task.sleep(for: configuration.pollingInterval)
            }
        } catch {
            state = .failed
            handle.stop()
            throw error
        }
    }

    func flushLiveEvents(
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws -> EventCursorFence {
        try await flushLiveEvents(
            observer: TaskOnlyScanWorkObserver(),
            consume: consume
        )
    }

    func flushLiveEvents(
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws -> EventCursorFence {
        guard state == .historyReady else {
            throw FSEventReaderError.historyMustBeConsumedBeforeFlush
        }
        state = .flushing
        do {
            try await observer.checkpoint()
            try mailbox.checkReplayTrust()
            let preFlushEventID = ScanProbe.$context.withValue(probe) {
                eventStoreUUIDProvider.latestEventID(deviceID: deviceID)
            }
            guard await handle.flushSynchronously() else {
                probe.emit(.rejection, reason: .operationInterrupted)
                throw FSEventReaderError.operationInterrupted
            }
            try await observer.checkpoint()
            guard state == .flushing else {
                probe.emit(.rejection, reason: .operationInterrupted)
                throw FSEventReaderError.operationInterrupted
            }
            if let preFlushEventID {
                highestDeliveredEventID = max(highestDeliveredEventID ?? 0, preFlushEventID)
            }
            let boundary = mailbox.latestSequence
            while true {
                try mailbox.checkReplayTrust()
                let events = mailbox.drainLive(
                    throughSequence: boundary,
                    maximumCount: EventBatch.maximumEventCount
                )
                guard !events.isEmpty else { break }
                try await deliver(
                    events,
                    expectedState: .flushing,
                    observer: observer,
                    consume: consume
                )
            }
            guard state == .flushing else {
                probe.emit(.rejection, reason: .operationInterrupted)
                throw FSEventReaderError.operationInterrupted
            }
            let fence = makeFence(phase: .liveFlush, boundarySequence: boundary)
            mailbox.discardAssessments(throughSequence: boundary)
            handle.stop()
            state = .finished
            return fence
        } catch {
            state = .failed
            handle.stop()
            throw error
        }
    }

    func stop() async {
        guard state != .finished, state != .stopped else { return }
        state = .stopped
        handle.stop()
    }

    private func deliver(
        _ events: [FileSystemEvent],
        expectedState: State,
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws {
        for batch in try EventCoalescer.batches(events) {
            try await observer.checkpoint()
            try mailbox.checkReplayTrust()
            let consumptionStart = DispatchTime.now().uptimeNanoseconds
            let verify: @Sendable () throws -> Void = { [mailbox] in try mailbox.checkReplayTrust() }
            do {
                try await EventReplayGuard.$check.withValue(verify) {
                    try await ScanProbe.$context.withValue(probe) { try await consume(batch) }
                }
                try mailbox.checkReplayTrust()
            } catch {
                probe.emit(
                    .consumeSummary,
                    fields: [
                        "count": String(batch.events.count), "failed": "true",
                        "elapsedNanoseconds": String(DispatchTime.now().uptimeNanoseconds - consumptionStart),
                    ])
                throw error
            }
            consumedBatches &+= 1
            consumptionNanoseconds &+= DispatchTime.now().uptimeNanoseconds - consumptionStart
            if probe.detailed && consumptionStart - lastConsumeSample >= 1_000_000_000 {
                lastConsumeSample = consumptionStart
                probe.emit(
                    .consumeSummary,
                    fields: [
                        "count": String(batch.events.count), "failed": "false",
                        "elapsedNanoseconds": String(DispatchTime.now().uptimeNanoseconds - consumptionStart),
                    ])
            }
            try await observer.checkpoint(
                ScanProgressDelta(processedEvents: UInt64(batch.events.count))
            )
            guard state == expectedState else {
                probe.emit(.rejection, reason: .operationInterrupted)
                throw FSEventReaderError.operationInterrupted
            }
            if let maximum = batch.events.map(\.id).filter({ $0 != 0 }).max() {
                highestDeliveredEventID = max(highestDeliveredEventID ?? 0, maximum)
            }
        }
    }

    private func makeFence(
        phase: EventCursorFence.Phase,
        boundarySequence: UInt64,
        additionalAssessment: EventTrustAssessment = EventTrustAssessment(trust: .trusted)
    ) -> EventCursorFence {
        return ScanProbe.$context.withValue(probe) {
            let observedUUID = eventStoreUUIDProvider.eventStoreUUID(deviceID: deviceID)
            let journal = EventTrustEvaluator.assessJournal(
                expectedUUID: initialEventStoreUUID,
                observedUUID: observedUUID,
                previousEventID: initialEventID,
                observedEventID: highestDeliveredEventID
            )
            let afterSequence: UInt64 =
                phase == .liveFlush
                ? mailbox.historyBoundarySequence ?? 0
                : 0
            var assessment = mailbox.assessment(
                afterSequence: afterSequence,
                throughSequence: boundarySequence
            )
            .merging(journal)
            .merging(additionalAssessment)
            if phase == .liveFlush, highestDeliveredEventID == nil {
                assessment = assessment.merging(
                    EventTrustAssessment(
                        trust: .fullScanRequired,
                        reasons: ["FSEvents could not establish a durable event cursor"],
                        probeReason: .cursorUnavailable
                    )
                )
            }
            var fields = mailbox.probeSummary
            fields["trust"] = String(describing: assessment.trust)
            fields["journalUUID"] = observedUUID?.uuidString ?? "nil"
            fields["expectedUUID"] = initialEventStoreUUID.uuidString
            fields["delivered"] = highestDeliveredEventID.map { String($0) } ?? "nil"
            fields["boundary"] = String(boundarySequence)
            fields["consumedBatches"] = String(consumedBatches)
            fields["consumptionNanoseconds"] = String(consumptionNanoseconds)
            probe.emit(phase == .historyDone ? .historyDone : .liveFlush, fields: fields)
            return EventCursorFence(
                volumeID: volumeID,
                eventStoreUUID: observedUUID,
                highestFullyDeliveredEventID: highestDeliveredEventID,
                phase: phase,
                trust: assessment.trust,
                diagnostic: assessment.reasons.isEmpty ? nil : assessment.reasons.joined(separator: "; ")
            )
        }
    }
}

private struct QueuedEvent {
    let sequence: UInt64
    let event: FileSystemEvent
}

final class FSEventMailbox: @unchecked Sendable {
    let probe = ScanProbe.context
    private var callbacks: UInt64 = 0
    private var lastSample: UInt64 = 0
    private var received: UInt64 = 0
    private var consumed: UInt64 = 0
    private var peak = 0
    private var observedFlags: UInt32 = 0
    private var firstOverflow: UInt64?
    var probeSummary: [String: String] {
        lock.withLock { summaryLocked() }
    }
    private func summaryLocked() -> [String: String] {
        [
            "callbacks": String(callbacks), "received": String(received), "consumed": String(consumed),
            "buffered": String(historical.count - historicalIndex + live.count - liveIndex),
            "peak": String(peak), "flags": String(observedFlags),
            "firstOverflowNanoseconds": firstOverflow.map { String($0) } ?? "nil",
        ]
    }

    let volumeID: MonitoredVolume.ID
    let previousEventID: UInt64?
    let maximumBufferedEvents: Int

    private let lock = NSLock()
    private var historical: [QueuedEvent] = []
    private var historicalIndex = 0
    private var live: [QueuedEvent] = []
    private var liveIndex = 0
    private var historicalAssessment = EventTrustAssessment(trust: .trusted)
    private var liveAssessment = EventTrustAssessment(trust: .trusted)
    private var sequence: UInt64 = 0
    private var historyBoundary: UInt64?
    private var lastObservedEventID: UInt64?
    private var overflowRecorded = false

    init(
        volumeID: MonitoredVolume.ID,
        previousEventID: UInt64?,
        maximumBufferedEvents: Int,
        historyStartsComplete: Bool = false
    ) {
        self.volumeID = volumeID
        self.previousEventID = previousEventID
        self.maximumBufferedEvents = maximumBufferedEvents
        historyBoundary = historyStartsComplete ? 0 : nil
    }

    /// Any observed fatal loss invalidates this attempt, including live overflow
    /// while history is still being consumed. Never treat subtree repair as fatal.
    func checkReplayTrust() throws {
        let evidence = lock.withLock { historicalAssessment.merging(liveAssessment) }
        if evidence.trust == .fullScanRequired {
            throw EventReplayInvalidated(reasons: evidence.reasons)
        }
    }

    var historyBoundarySequence: UInt64? {
        lock.withLock { historyBoundary }
    }

    var latestSequence: UInt64 {
        lock.withLock { sequence }
    }

    var latestObservedEventID: UInt64? {
        lock.withLock { lastObservedEventID }
    }

    func append(pathBytes: Data, flagsRawValue: UInt32, eventID: UInt64) {
        appendBatch(count: 1) { _ in (pathBytes, flagsRawValue, eventID) }
    }

    // Publish callback receipt atomically: no fence may observe half a callback.
    func appendBatch(count: Int, eventAt: (Int) -> (Data, UInt32, UInt64)?) {
        ScanProbe.$context.withValue(probe) {
            lock.withLock {
                callbacks &+= 1
                for index in 0..<count {
                    guard let (path, flags, id) = eventAt(index) else { continue }
                    received &+= 1
                    observedFlags |= flags
                    appendLocked(pathBytes: path, flagsRawValue: flags, eventID: id)
                    peak = max(peak, historical.count - historicalIndex + live.count - liveIndex)
                }
                let now = DispatchTime.now().uptimeNanoseconds
                if (probe.detailed && now - lastSample >= 1_000_000_000) || callbacks % 1024 == 0 {
                    lastSample = now
                    probe.emit(.callbackSummary, fields: summaryLocked())
                }
            }
        }
    }

    private func appendLocked(pathBytes: Data, flagsRawValue: UInt32, eventID: UInt64) {
        sequence &+= 1
        let currentSequence = sequence
        let flags = FileSystemEventFlags(rawValue: flagsRawValue)
        var assessment = EventTrustEvaluator.assess(flags: flags)
        // HistoryDone is a control sentinel, not a delivered filesystem change.
        // Its ID must not move the observed cursor or poison item ordering.
        if flags.contains(.historyDone) {
            if assessment.trust != .trusted { recordAssessment(assessment, sequence: currentSequence) }
            historyBoundary = currentSequence
            return
        }
        if let previousEventID, eventID != 0, eventID < previousEventID {
            assessment = assessment.merging(
                EventTrustAssessment(
                    trust: .fullScanRequired,
                    reasons: ["FSEvents delivered an event below the committed cursor"],
                    probeReason: .eventBelowCommittedCursor
                )
            )
        }
        if eventID != 0 {
            lastObservedEventID = max(lastObservedEventID ?? 0, eventID)
        }
        if assessment.trust != .trusted {
            recordAssessment(assessment, sequence: currentSequence)
        }
        let relativeBytes = Data(pathBytes.drop(while: { $0 == UInt8(ascii: "/") }))
        let path: RelativePath
        do {
            path = try RelativePath(validating: relativeBytes)
        } catch {
            recordAssessment(
                EventTrustAssessment(
                    trust: .fullScanRequired,
                    reasons: ["FSEvents delivered an invalid relative path"], probeReason: .invalidRelativePath
                ),
                sequence: currentSequence
            )
            return
        }

        let bufferedCount = (historical.count - historicalIndex) + (live.count - liveIndex)
        guard bufferedCount < maximumBufferedEvents else {
            if !overflowRecorded {
                overflowRecorded = true
                firstOverflow = DispatchTime.now().uptimeNanoseconds
                probe.emit(.callbackSummary, fields: summaryLocked())
                recordAssessment(
                    EventTrustAssessment(
                        trust: .fullScanRequired,
                        reasons: ["DailyDisk FSEvents buffer overflowed"], probeReason: .mailboxOverflow
                    ),
                    sequence: currentSequence
                )
            }
            return
        }
        let queued = QueuedEvent(
            sequence: currentSequence,
            event: FileSystemEvent(id: eventID, volumeID: volumeID, path: path, flags: flags)
        )
        if historyBoundary == nil {
            historical.append(queued)
        } else {
            live.append(queued)
        }
    }

    func drainHistorical(maximumCount: Int) -> [FileSystemEvent] {
        lock.withLock {
            let end = min(historicalIndex + maximumCount, historical.count)
            guard historicalIndex < end else { return [] }
            let result = historical[historicalIndex..<end].map(\.event)
            consumed &+= UInt64(result.count)
            historicalIndex = end
            compactIfNeeded(&historical, index: &historicalIndex)
            return result
        }
    }

    func drainLive(throughSequence boundary: UInt64, maximumCount: Int) -> [FileSystemEvent] {
        lock.withLock {
            var result: [FileSystemEvent] = []
            while liveIndex < live.count,
                result.count < maximumCount,
                live[liveIndex].sequence <= boundary
            {
                result.append(live[liveIndex].event)
                liveIndex += 1
            }
            consumed &+= UInt64(result.count)
            compactIfNeeded(&live, index: &liveIndex)
            return result
        }
    }

    func assessment(
        afterSequence: UInt64 = 0,
        throughSequence boundary: UInt64
    ) -> EventTrustAssessment {
        lock.withLock {
            guard let historyBoundary else { return historicalAssessment }
            if afterSequence >= historyBoundary {
                return liveAssessment
            }
            if boundary <= historyBoundary {
                return historicalAssessment
            }
            return historicalAssessment.merging(liveAssessment)
        }
    }

    func discardAssessments(throughSequence boundary: UInt64) {
        lock.withLock {
            if let historyBoundary, boundary >= historyBoundary {
                historicalAssessment = EventTrustAssessment(trust: .trusted)
            }
            if boundary >= sequence {
                liveAssessment = EventTrustAssessment(trust: .trusted)
            }
        }
    }

    private func recordAssessment(_ assessment: EventTrustAssessment, sequence _: UInt64) {
        if historyBoundary == nil {
            historicalAssessment = historicalAssessment.merging(assessment)
        } else {
            liveAssessment = liveAssessment.merging(assessment)
        }
    }

    private func compactIfNeeded(_ values: inout [QueuedEvent], index: inout Int) {
        if index >= 4_096, index * 2 >= values.count {
            values.removeFirst(index)
            index = 0
        }
    }
}

private final class FSEventCallbackBox: @unchecked Sendable {
    let mailbox: FSEventMailbox

    init(mailbox: FSEventMailbox) {
        self.mailbox = mailbox
    }
}

private final class FSEventStreamHandle: @unchecked Sendable {
    private let callbackQueue = DispatchQueue(label: "io.github.xiuyuwu.DailyDisk.fsevents")
    private let stream: FSEventStreamRef
    private let callbackBox: FSEventCallbackBox
    private let lock = NSLock()
    private var isStopped = false

    init(
        nativeDeviceID: dev_t,
        watchPaths: [String],
        sinceWhen: FSEventStreamEventId,
        latency: TimeInterval,
        callbackBox: FSEventCallbackBox
    ) throws {
        self.callbackBox = callbackBox
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard
            let stream = FSEventStreamCreateRelativeToDevice(
                kCFAllocatorDefault,
                eventCallback,
                &context,
                nativeDeviceID,
                watchPaths as CFArray,
                sinceWhen,
                latency,
                flags
            )
        else {
            throw FSEventReaderError.streamCreationFailed
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, callbackQueue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw FSEventReaderError.streamStartFailed
        }
    }

    deinit {
        stop()
    }

    func flushSynchronously() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                let completed = lock.withLock {
                    guard !isStopped else { return false }
                    FSEventStreamFlushSync(stream)
                    callbackQueue.sync {}
                    return true
                }
                continuation.resume(returning: completed)
            }
        }
    }

    func stop() {
        lock.withLock {
            guard !isStopped else { return }
            isStopped = true
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            callbackBox.mailbox.probe.emit(.sessionStopped, fields: callbackBox.mailbox.probeSummary)
        }
    }
}

private let eventCallback: FSEventStreamCallback = {
    _, clientInfo, eventCount, eventPaths, eventFlags, eventIDs in
    guard let clientInfo else { return }
    let box = Unmanaged<FSEventCallbackBox>.fromOpaque(clientInfo).takeUnretainedValue()
    let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
    box.mailbox.appendBatch(count: eventCount) { index in
        guard let path = paths[index] else { return nil }
        return (Data(bytes: path, count: strlen(path)), eventFlags[index], eventIDs[index])
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
