import Foundation

/// Closed diagnostic vocabulary. Never log event paths or human error strings.
public enum ScanProbeName: String, Codable, Sendable {
    case helperStarted, helperFinished, diagnosticSummary, phaseChanged, requestStarted, requestFinished,
        recoveryResume, policyDecision,
        checkpointRead
    case attemptStarted, attemptFailed, recoverySelected, commitProposed, commitSucceeded
    case volumeDiscovered, journalRead, cursorQuery, sessionOpened, sessionStopped
    case historyDone, liveFlush, rejection, callbackSummary, consumeSummary, identityAmbiguity
}
public enum ScanProbeReasonCode: String, Codable, Sendable {
    case journalUnavailable, journalUUIDChanged, cursorRegressed, cursorUnavailable
    case eventBelowCommittedCursor, userEventsDropped, kernelEventsDropped, eventIDsWrapped
    case watchedRootChanged, nestedVolumeMounted, volumeUnmounted, invalidRelativePath
    case mailboxOverflow, historyTimeout, operationInterrupted, topologyChanged, missingCheckpoint
    case hardLinkRecreated, inodeReuse, unknown
}
public struct ScanProbeEvent: Codable, Sendable {
    public let name: ScanProbeName
    public let wallTime: Date
    public let monotonicNanoseconds: UInt64
    public let requestID: UUID?
    public let runID: UUID?
    public let attemptID: UUID?
    public let sessionID: UUID?
    public let role: String
    public let reason: ScanProbeReasonCode?
    public let fields: [String: String]
    public var critical: Bool { reason != nil || name == .attemptFailed || name == .recoverySelected }
}
public protocol ScanProbeRecording: Sendable {
    /// Nonthrowing, bounded enqueue only. Implementations must not perform I/O here.
    func record(_ event: ScanProbeEvent)
    func flush() async
}
extension ScanProbeRecording {
    public func flush() async {}
}
public struct ScanProbeContext: Sendable {
    public var trace: ScanProbeTrace?
    public var recorder: (any ScanProbeRecording)?
    public var requestID: UUID?
    public var runID: UUID?
    public var attemptID: UUID?
    public var sessionID: UUID?
    public var role: String
    public var detailed: Bool

    public init(recorder: (any ScanProbeRecording)? = nil, requestID: UUID? = nil, detailed: Bool = false) {
        trace = nil
        self.recorder = recorder
        self.requestID = requestID
        role = "request"
        self.detailed = detailed
    }
    public func attempt(_ run: ScanRun.ID, role: String) -> Self {
        var copy = self
        copy.runID = run.rawValue
        copy.attemptID = UUID()
        copy.sessionID = nil
        copy.role = role
        copy.trace?.begin(attempt: copy.attemptID, run: copy.runID)
        return copy
    }
    public func session() -> Self {
        var copy = self
        copy.sessionID = UUID()
        return copy
    }
    public func emit(_ name: ScanProbeName, reason: ScanProbeReasonCode? = nil, fields: [String: String] = [:]) {
        if let reason { trace?.record(reason, attempt: attemptID, run: runID) }
        recorder?.record(
            ScanProbeEvent(
                name: name, wallTime: Date(), monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
                requestID: requestID, runID: runID, attemptID: attemptID, sessionID: sessionID,
                role: role, reason: reason, fields: fields))
    }
}
public enum ScanProbe {
    @TaskLocal public static var context = ScanProbeContext()
    public static func emit(
        _ name: ScanProbeName, reason: ScanProbeReasonCode? = nil,
        fields: @autoclosure () -> [String: String] = [:]
    ) {
        guard context.recorder != nil else {
            if let reason { context.trace?.record(reason, attempt: context.attemptID, run: context.runID) }
            return
        }
        context.emit(name, reason: reason, fields: fields())
    }
    public static func checkpoint(_ name: ScanProbeName, _ checkpoint: Checkpoint?) {
        emit(
            name,
            fields: [
                "present": String(checkpoint != nil),
                "volume": checkpoint?.volumeID.rawValue ?? "nil",
                "journalUUID": checkpoint?.eventStoreUUID?.uuidString ?? "nil",
                "cursor": checkpoint?.lastCommittedEventID.map { String($0) } ?? "nil",
                "topology": checkpoint?.topologyFingerprint ?? "nil",
                "generation": checkpoint?.activeGenerationID.rawValue.uuidString ?? "nil",
                "lastFullUnix": checkpoint.map { String($0.lastSuccessfulFullScanAt.timeIntervalSince1970) } ?? "nil",
            ])
    }
}

/// Small ordered cause ledger independent of log delivery. Never sorts causes.
public final class ScanProbeTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [ScanProbeReasonCode] = []
    private var attempt: UUID?
    private var run: UUID?
    public init() {}
    public func begin(attempt: UUID?, run: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        codes.removeAll(keepingCapacity: true)
        self.attempt = attempt
        self.run = run
    }
    public func record(_ code: ScanProbeReasonCode, attempt: UUID?, run: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        // Late callbacks from an earlier stopped attempt may still be logged,
        // but cannot replace the active attempt's first cause.
        guard self.attempt == attempt else { return }
        self.run = run
        if codes.count < 24, !codes.contains(code) { codes.append(code) }
    }
    public var snapshot: (codes: [ScanProbeReasonCode], attempt: UUID?, run: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        return (codes, attempt, run)
    }
}
