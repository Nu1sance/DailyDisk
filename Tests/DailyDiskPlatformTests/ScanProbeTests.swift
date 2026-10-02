import DailyDiskCore
import Darwin
import Foundation
import Testing

@testable import DailyDiskPlatform

final class ProbeCollector: ScanProbeRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ScanProbeEvent] = []
    func record(_ event: ScanProbeEvent) { lock.withLock { storage.append(event) } }
    var events: [ScanProbeEvent] { lock.withLock { storage } }
}

private func probeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("DailyDiskProbes-" + UUID().uuidString)
}
private func probeLines(_ directory: URL) throws -> [[String: Any]] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "jsonl" }
        .flatMap { url in
            try Data(contentsOf: url).split(separator: 10).map {
                try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
            }
        }.sorted { ($0["sequence"] as! NSNumber).uint64Value < ($1["sequence"] as! NSNumber).uint64Value }
}

@Test(
    "Probe callback context preserves first cause, ordering and real mailbox semantics",
    arguments: [false, true])
func probeMailboxSemantics(enabled: Bool) throws {
    let sink = ProbeCollector()
    var context = ScanProbeContext(recorder: enabled ? sink : nil, requestID: UUID(), detailed: true)
    context.trace = ScanProbeTrace()
    context = context.attempt(ScanRun.ID(UUID()), role: "incremental").session()
    let mailbox = ScanProbe.$context.withValue(context) {
        FSEventMailbox(volumeID: .init("synthetic"), previousEventID: 10, maximumBufferedEvents: 1)
    }
    // Invocation outside TaskLocal simulates a native callback thread.
    mailbox.appendBatch(count: 3) { index in
        (Data("/secret-name".utf8), FileSystemEventFlags.modified.rawValue, UInt64(11 + index))
    }
    ScanProbe.$context.withValue(context) {
        _ = EventTrustEvaluator.assessJournal(
            expectedUUID: UUID(), observedUUID: UUID(),
            previousEventID: 10, observedEventID: 13)
    }
    #expect(mailbox.assessment(throughSequence: mailbox.latestSequence).trust == .fullScanRequired)
    #expect(mailbox.drainHistorical(maximumCount: 10).map(\.id) == [11])
    #expect(mailbox.probeSummary["peak"] == "1")
    #expect(mailbox.probeSummary["received"] == "3")
    #expect(context.trace?.snapshot.codes == [.mailboxOverflow, .journalUUIDChanged])
    if enabled {
        #expect(sink.events.first { $0.reason != nil }?.reason == .mailboxOverflow)
        #expect(sink.events.allSatisfy { $0.sessionID == context.sessionID && $0.requestID == context.requestID })
        #expect(!sink.events.flatMap { $0.fields.values }.contains { $0.contains("secret-name") })
    } else {
        #expect(sink.events.isEmpty)
    }
}

@Test("Probe files have bounded rotation, ordered sequence and private permissions")
func probeRotationAndPrivacy() async throws {
    let root = probeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = ScanProbeLogger(directory: root, capacity: 64, fileLimit: 2048, fileCount: 3)
    let context = ScanProbeContext(recorder: logger, requestID: UUID())
    for index in 0..<40 {
        context.emit(.policyDecision, fields: ["index": String(index), "selection": "incremental"])
        await logger.flush()
    }
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    #expect(files.count <= 3)
    var total = 0
    for file in files {
        var info = stat()
        #expect(lstat(file.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        total += Int(info.st_size)
    }
    #expect(total <= 6144)
    let lines = try probeLines(root)
    let sequence = lines.map { ($0["sequence"] as! NSNumber).uint64Value }
    #expect(sequence == sequence.sorted() && Set(sequence).count == sequence.count)
    context.emit(.identityAmbiguity, fields: ["path": "/not-allowed"])
    await logger.flush()
    #expect(logger.statistics.dropped == 1)
    #expect(!String(decoding: try Data(contentsOf: files[0]), as: UTF8.self).contains("/not-allowed"))
}

@Test("Probe saturation drops diagnostics only and preserves first critical cause")
func probeSaturation() async throws {
    let root = probeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = ScanProbeLogger(directory: root, capacity: 8, fileLimit: 1_048_576, fileCount: 2)
    let context = ScanProbeContext(recorder: logger, requestID: UUID())
    context.emit(.rejection, reason: .journalUUIDChanged)
    for index in 0..<20_000 { context.emit(.callbackSummary, fields: ["count": String(index)]) }
    #expect(logger.statistics.queued <= 8)
    await logger.flush()
    #expect(logger.statistics.dropped > 0)
    let lines = try probeLines(root)
    #expect(lines.contains { ($0["event"] as? [String: Any])?["reason"] as? String == "journalUUIDChanged" })
    #expect(lines.last?["droppedDiagnostics"] as? Int == Int(logger.statistics.dropped))
}

@Test("Probe write failures, symlinks and disabled recording cannot change trust")
func probeFailureIsolation() async throws {
    let root = probeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let blocked = root.appendingPathComponent("blocked")
    try Data("unchanged".utf8).write(to: blocked)
    let logger = ScanProbeLogger(directory: blocked)
    let uuid = UUID()
    let assessment = ScanProbe.$context.withValue(ScanProbeContext(recorder: logger)) {
        EventTrustEvaluator.assessJournal(
            expectedUUID: uuid, observedUUID: uuid,
            previousEventID: 10, observedEventID: 11)
    }
    #expect(assessment.trust == .trusted)
    ScanProbeContext(recorder: logger).emit(.rejection, reason: .cursorUnavailable)
    await logger.flush()
    #expect(logger.statistics.writeFailures > 0)
    #expect(try Data(contentsOf: blocked) == Data("unchanged".utf8))
    let off = root.appendingPathComponent("off")
    let unused = ScanProbeLogger(directory: off)
    ScanProbe.$context.withValue(ScanProbeContext()) { ScanProbe.emit(.requestStarted) }
    await unused.flush()
    #expect(!FileManager.default.fileExists(atPath: off.path))
    let directory = root.appendingPathComponent("private")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent("probe.0.jsonl"), withDestinationURL: blocked)
    let linked = ScanProbeLogger(directory: directory)
    ScanProbeContext(recorder: linked).emit(.requestStarted)
    await linked.flush()
    #expect(linked.statistics.writeFailures > 0)
    #expect(try Data(contentsOf: blocked) == Data("unchanged".utf8))
}

@Test("Probe summary throughput leaves event delivery unchanged")
func probeThroughput() async throws {
    let root = probeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for mode in ["off", "summary", "detail"] {
        let enabled = mode != "off"
        let logger = ScanProbeLogger(directory: root.appendingPathComponent(mode))
        let start = ContinuousClock.now
        let mailbox = ScanProbe.$context.withValue(
            ScanProbeContext(recorder: enabled ? logger : nil, detailed: mode == "detail")
        ) {
            FSEventMailbox(volumeID: .init("synthetic"), previousEventID: nil, maximumBufferedEvents: 1024)
        }
        var consumed = 0
        for batch in 0..<200 {
            mailbox.appendBatch(count: 512) { index in
                (Data("/synthetic".utf8), FileSystemEventFlags.modified.rawValue, UInt64(batch * 512 + index + 1))
            }
            consumed += mailbox.drainHistorical(maximumCount: 1024).count
        }
        mailbox.probe.emit(.callbackSummary, fields: mailbox.probeSummary)
        await logger.flush()
        #expect(consumed == 102400)
        #expect(mailbox.assessment(throughSequence: mailbox.latestSequence).trust == .trusted)
        print(
            "Probe mode=\(mode) duration=\(start.duration(to: .now)) dropped=\(logger.statistics.dropped)"
        )
    }
}

@Test("Cursor probes record actual Unix/CF fallback and distinguish invalid device conversion")
func probeNativeCursorInputs() {
    let sink = ProbeCollector()
    let cutoff = Date().timeIntervalSince1970 - 300_000_000
    let provider = SystemEventStoreUUIDProvider(queryBeforeTime: { _, time in
        time > cutoff ? 0 : 77
    })
    ScanProbe.$context.withValue(ScanProbeContext(recorder: sink)) {
        #expect(provider.latestEventID(deviceID: 1) == 77)
        #expect(provider.latestEventID(deviceID: UInt64.max) == nil)
    }
    let events = sink.events
    #expect(events[0].fields["unixResult"] == "0")
    #expect(events[0].fields["fallbackExecuted"] == "true")
    #expect(events[0].fields["cfResult"] == "77")
    #expect(events[0].fields["adopted"] == "77")
    #expect(events[1].fields["nativeDevice"] == "nil")
    #expect(events[1].fields["adopted"] == "nil")
    let zero = SystemEventStoreUUIDProvider(queryBeforeTime: { _, _ in 0 })
    ScanProbe.$context.withValue(ScanProbeContext(recorder: sink)) {
        #expect(zero.latestEventID(deviceID: 1) == nil)
    }
    #expect(sink.events.last?.fields["cfResult"] == "0")
    #expect(sink.events.last?.fields["adopted"] == "nil")
}

@Test("Late callbacks cannot overwrite the active attempt's ordered causes")
func probeAttemptCauseIsolation() {
    let trace = ScanProbeTrace()
    let oldAttempt = UUID()
    let currentAttempt = UUID()
    let run = UUID()
    trace.begin(attempt: oldAttempt, run: UUID())
    trace.record(.mailboxOverflow, attempt: oldAttempt, run: nil)
    trace.begin(attempt: currentAttempt, run: run)
    trace.record(.hardLinkRecreated, attempt: currentAttempt, run: run)
    trace.record(.journalUUIDChanged, attempt: oldAttempt, run: nil)
    trace.record(.mailboxOverflow, attempt: currentAttempt, run: run)
    trace.record(.hardLinkRecreated, attempt: currentAttempt, run: run)
    #expect(trace.snapshot.codes == [.hardLinkRecreated, .mailboxOverflow])
    #expect(trace.snapshot.attempt == currentAttempt)
    #expect(trace.snapshot.run == run)
}

@Test("Helper write counters are sampled at phase boundaries without dropping daily policy evidence")
func probeProcessWriteCounters() async throws {
    let root = probeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = ScanProbeLogger(directory: root)
    let context = ScanProbeContext(recorder: logger, requestID: UUID())
    context.emit(.helperStarted)
    context.emit(.policyDecision, fields: ["selection": "dailyFull", "lastPublishedFullUnix": "none"])
    context.emit(.phaseChanged, fields: ["phase": "scanningFiles"])
    context.emit(.helperFinished)
    await logger.flush()
    let lines = try probeLines(root)
    let counters = lines.compactMap { ($0["processWriteBytes"] as? NSNumber)?.uint64Value }
    #expect(counters.count == 3)
    #expect(counters == counters.sorted())
    #expect(logger.statistics.dropped == 0)
}
