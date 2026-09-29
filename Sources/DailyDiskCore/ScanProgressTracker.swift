import Foundation

public func isScanCancellation(_ error: any Error) -> Bool {
    error is CancellationError || (error as? ScanProgressError) == .cancelled
}

public struct ScanProgressContext: Sendable {
    public let requestID: UUID
    public let trigger: DailyDiskRunTrigger
    public let mode: ScanExecutionMode?
    public let startedAt: Date
    public let domainOrdinal: Int?
    public let domainCount: Int?

    public init(
        requestID: UUID,
        trigger: DailyDiskRunTrigger,
        mode: ScanExecutionMode? = nil,
        startedAt: Date,
        domainOrdinal: Int? = nil,
        domainCount: Int? = nil
    ) {
        self.requestID = requestID
        self.trigger = trigger
        self.mode = mode
        self.startedAt = startedAt
        self.domainOrdinal = domainOrdinal
        self.domainCount = domainCount
    }
}

public protocol ScanProgressTracking: ScanWorkObserving {
    func bindRun(_ runID: ScanRun.ID) async throws
    func beginDomain(ordinal: Int, count: Int) async throws
    func transition(to phase: ScanProgressPhase, mode: ScanExecutionMode?) async throws
    func currentSnapshot() async throws -> ScanProgressSnapshot
}

extension ScanProgressTracking {
    public func bindRun(_ runID: ScanRun.ID) async throws {}
    public func beginDomain(ordinal: Int, count: Int) async throws {}
}

public protocol ScanRunBindingRecording: Sendable {
    func recordRunBinding(_ binding: DailyDiskRunBinding) async throws
}

public protocol ScanCommitBoundaryEntering: Sendable {
    func enterCommitBoundary(_ snapshot: ScanProgressSnapshot) async throws
}

public actor ScanProgressTracker: ScanProgressTracking {
    private let context: ScanProgressContext
    private let reporter: any ScanProgressReporting
    private let cancellationChecker: any ScanCancellationChecking
    private let commitBoundary: (any ScanCommitBoundaryEntering)?
    private let runBindingRecorder: (any ScanRunBindingRecording)?
    private let publicationInterval: TimeInterval
    private var phase: ScanProgressPhase
    private var mode: ScanExecutionMode?
    private var domainOrdinal: Int?
    private var domainCount: Int?
    private var counters = ScanProgressCounters()
    private var lastPublishedAt: Date

    public init(
        context: ScanProgressContext,
        initialPhase: ScanProgressPhase = .queued,
        reporter: any ScanProgressReporting,
        cancellationChecker: any ScanCancellationChecking,
        commitBoundary: (any ScanCommitBoundaryEntering)? = nil,
        runBindingRecorder: (any ScanRunBindingRecording)? = nil,
        publicationInterval: TimeInterval = 0.25
    ) throws {
        guard publicationInterval.isFinite, publicationInterval >= 0 else {
            throw ScanProgressError.invalidSnapshot
        }
        self.context = context
        self.reporter = reporter
        self.cancellationChecker = cancellationChecker
        self.commitBoundary = commitBoundary
        self.runBindingRecorder = runBindingRecorder
        self.publicationInterval = publicationInterval
        phase = initialPhase
        mode = context.mode
        domainOrdinal = context.domainOrdinal
        domainCount = context.domainCount
        lastPublishedAt = context.startedAt
    }

    public init(
        resuming snapshot: ScanProgressSnapshot,
        reporter: any ScanProgressReporting,
        cancellationChecker: any ScanCancellationChecking,
        commitBoundary: (any ScanCommitBoundaryEntering)? = nil,
        runBindingRecorder: (any ScanRunBindingRecording)? = nil,
        publicationInterval: TimeInterval = 0.25
    ) throws {
        guard !snapshot.phase.isTerminal,
            publicationInterval.isFinite,
            publicationInterval >= 0
        else {
            throw ScanProgressError.invalidSnapshot
        }
        context = ScanProgressContext(
            requestID: snapshot.requestID,
            trigger: snapshot.trigger,
            mode: snapshot.mode,
            startedAt: snapshot.startedAt,
            domainOrdinal: snapshot.domainOrdinal,
            domainCount: snapshot.domainCount
        )
        self.reporter = reporter
        self.cancellationChecker = cancellationChecker
        self.commitBoundary = commitBoundary
        self.runBindingRecorder = runBindingRecorder
        self.publicationInterval = publicationInterval
        phase = snapshot.phase
        mode = snapshot.mode
        domainOrdinal = snapshot.domainOrdinal
        domainCount = snapshot.domainCount
        counters = snapshot.counters
        lastPublishedAt = snapshot.updatedAt
    }

    public func bindRun(_ runID: ScanRun.ID) async throws {
        guard let runBindingRecorder else { return }
        try await runBindingRecorder.recordRunBinding(
            DailyDiskRunBinding(requestID: context.requestID, runID: runID)
        )
    }

    public func beginDomain(ordinal: Int, count: Int) async throws {
        guard ordinal > 0, count > 0, ordinal <= count,
            domainOrdinal == nil || ordinal >= domainOrdinal!
        else {
            throw ScanProgressError.invalidSnapshot
        }
        if let previous = domainOrdinal, ordinal > previous {
            mode = nil
        }
        domainOrdinal = ordinal
        domainCount = count
    }

    public func transition(to nextPhase: ScanProgressPhase, mode nextMode: ScanExecutionMode? = nil) async throws {
        if nextPhase != .cancelling, nextPhase != .cancelled, nextPhase != .cleaningUpFailedRun,
            phase.allowsCancellation
        {
            try Task.checkCancellation()
            try await cancellationChecker.checkCancellation(requestID: context.requestID)
        }
        guard ScanProgressTransitionValidator.canTransition(from: phase, to: nextPhase) else {
            throw ScanProgressError.invalidPhaseTransition(from: phase, to: nextPhase)
        }
        if let nextMode {
            let isRecoveryUpgrade = nextPhase == .preparing && nextMode == .recoveryFull
            guard mode == nil || mode == nextMode || isRecoveryUpgrade else {
                throw ScanProgressError.invalidSnapshot
            }
            mode = nextMode
        }
        let snapshot = try makeSnapshot(phase: nextPhase, at: Date())
        if nextPhase == .committing || nextPhase.isSpaceMaintenance, let commitBoundary {
            try await commitBoundary.enterCommitBoundary(snapshot)
        } else {
            await reporter.publish(snapshot)
        }
        phase = nextPhase
        lastPublishedAt = snapshot.updatedAt
    }

    public func checkpoint(_ delta: ScanProgressDelta) async throws {
        try Task.checkCancellation()
        if phase.allowsCancellation {
            try await cancellationChecker.checkCancellation(requestID: context.requestID)
        }
        counters = try counters.applying(delta)
        let now = Date()
        guard now.timeIntervalSince(lastPublishedAt) >= publicationInterval else { return }
        let snapshot = try makeSnapshot(phase: phase, at: now)
        await reporter.publish(snapshot)
        lastPublishedAt = now
    }

    public func currentSnapshot() throws -> ScanProgressSnapshot {
        try makeSnapshot(phase: phase, at: max(lastPublishedAt, Date()))
    }

    private func makeSnapshot(phase: ScanProgressPhase, at date: Date) throws -> ScanProgressSnapshot {
        try ScanProgressSnapshot(
            requestID: context.requestID,
            trigger: context.trigger,
            mode: mode,
            phase: phase,
            startedAt: context.startedAt,
            updatedAt: max(context.startedAt, date),
            domainOrdinal: domainOrdinal,
            domainCount: domainCount,
            counters: counters
        )
    }
}

public actor NoopScanProgressTracker: ScanProgressTracking {
    private var phase: ScanProgressPhase = .queued
    private var mode: ScanExecutionMode?
    private var counters = ScanProgressCounters()
    private let requestID = UUID()
    private let startedAt = Date()

    public init() {}

    public func beginDomain(ordinal: Int, count: Int) async throws {}

    public func transition(to phase: ScanProgressPhase, mode: ScanExecutionMode?) async throws {
        try Task.checkCancellation()
        self.phase = phase
        if let mode { self.mode = mode }
    }

    public func checkpoint(_ delta: ScanProgressDelta) async throws {
        try Task.checkCancellation()
        counters = try counters.applying(delta)
    }

    public func currentSnapshot() throws -> ScanProgressSnapshot {
        try ScanProgressSnapshot(
            requestID: requestID,
            trigger: .scheduled,
            mode: mode,
            phase: phase,
            startedAt: startedAt,
            updatedAt: Date(),
            counters: counters
        )
    }
}
