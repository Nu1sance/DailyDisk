import Foundation

public enum DailyDiskRunTrigger: String, Codable, CaseIterable, Sendable {
    case scheduled
    case manual
}

public enum DailyDiskRequestedScanMode: String, Codable, CaseIterable, Sendable {
    case automatic
    case fullReconciliation
}

public enum ScanExecutionMode: String, Codable, CaseIterable, Sendable {
    case initialFull
    case incremental
    case scheduledFull
    case recoveryFull
}

public enum ScanProgressPhase: String, Codable, CaseIterable, Sendable {
    case queued
    case waitingForWriter
    case preparing
    case discoveringStorage
    case recoveringInterruptedRun
    case replayingEvents
    case scanningFiles
    case preservingOpaqueInventory
    case catchingUpEvents
    case sealingInventory
    case reconciling
    case collectingDiagnostics
    case committing
    case publishingReport
    case notifying
    case applyingRetention
    case cleaningRetiredInventory
    case reclaimingSpace
    case verifyingMaintenance
    case cleaningUpFailedRun
    case cancelling
    case completed
    case cancelled
    case failed

    public var isSpaceMaintenance: Bool {
        self == .cleaningRetiredInventory || self == .reclaimingSpace || self == .verifyingMaintenance
    }

    public var isTerminal: Bool {
        self == .completed || self == .cancelled || self == .failed
    }

    public var allowsCancellation: Bool {
        switch self {
        case .queued, .waitingForWriter, .preparing, .discoveringStorage,
            .recoveringInterruptedRun, .replayingEvents, .scanningFiles, .preservingOpaqueInventory,
            .catchingUpEvents, .sealingInventory, .reconciling,
            .collectingDiagnostics:
            true
        case .cleaningRetiredInventory, .reclaimingSpace, .verifyingMaintenance,
            .committing, .publishingReport, .notifying, .applyingRetention,
            .cleaningUpFailedRun, .cancelling, .completed, .cancelled, .failed:
            false
        }
    }

    public var sequenceRank: Int {
        switch self {
        case .queued: 0
        case .waitingForWriter: 1
        case .preparing, .cleaningRetiredInventory, .reclaimingSpace, .verifyingMaintenance: 2
        case .recoveringInterruptedRun: 3
        case .discoveringStorage: 4
        case .replayingEvents: 5
        case .scanningFiles, .preservingOpaqueInventory: 6
        case .catchingUpEvents: 7
        case .sealingInventory: 8
        case .reconciling: 9
        case .collectingDiagnostics: 10
        case .committing: 11
        case .publishingReport: 12
        case .notifying: 13
        case .applyingRetention: 14
        case .cleaningUpFailedRun, .cancelling: 15
        case .completed, .cancelled, .failed: 16
        }
    }
}

public enum ScanProgressErrorCategory: String, Codable, CaseIterable, Sendable {
    case insufficientSpace
    case maintenanceRecovery
    case maintenanceInterrupted
    case permission
    case eventHistory
    case storageTopology
    case database
    case report
    case notification
    case writerBusy
    case cancellation
    case unknown
}

public struct ScanProgressCounters: Codable, Equatable, Sendable {
    public let processedEvents: UInt64
    public let affectedPaths: UInt64
    public let visitedPaths: UInt64
    public let indexedObjects: UInt64
    public let unreadablePaths: UInt64
    public let transientErrors: UInt64
    public let preservedPaths: UInt64
    public let processedOpaqueRoots: UInt64

    public init(
        processedEvents: UInt64 = 0,
        affectedPaths: UInt64 = 0,
        visitedPaths: UInt64 = 0,
        indexedObjects: UInt64 = 0,
        unreadablePaths: UInt64 = 0,
        transientErrors: UInt64 = 0,
        preservedPaths: UInt64 = 0,
        processedOpaqueRoots: UInt64 = 0
    ) {
        self.processedEvents = processedEvents
        self.affectedPaths = affectedPaths
        self.visitedPaths = visitedPaths
        self.indexedObjects = indexedObjects
        self.unreadablePaths = unreadablePaths
        self.transientErrors = transientErrors
        self.preservedPaths = preservedPaths
        self.processedOpaqueRoots = processedOpaqueRoots
    }

    public func applying(_ delta: ScanProgressDelta) throws -> ScanProgressCounters {
        try ScanProgressCounters(
            processedEvents: checkedAdd(processedEvents, delta.processedEvents),
            affectedPaths: checkedAdd(affectedPaths, delta.affectedPaths),
            visitedPaths: checkedAdd(visitedPaths, delta.visitedPaths),
            indexedObjects: checkedAdd(indexedObjects, delta.indexedObjects),
            unreadablePaths: checkedAdd(unreadablePaths, delta.unreadablePaths),
            transientErrors: checkedAdd(transientErrors, delta.transientErrors),
            preservedPaths: checkedAdd(preservedPaths, delta.preservedPaths),
            processedOpaqueRoots: checkedAdd(processedOpaqueRoots, delta.processedOpaqueRoots)
        )
    }

    private func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw ScanProgressError.counterOverflow }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case processedEvents, affectedPaths, visitedPaths, indexedObjects, unreadablePaths, transientErrors
        case preservedPaths, processedOpaqueRoots
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            processedEvents: try values.decode(UInt64.self, forKey: .processedEvents),
            affectedPaths: try values.decode(UInt64.self, forKey: .affectedPaths),
            visitedPaths: try values.decode(UInt64.self, forKey: .visitedPaths),
            indexedObjects: try values.decode(UInt64.self, forKey: .indexedObjects),
            unreadablePaths: try values.decode(UInt64.self, forKey: .unreadablePaths),
            transientErrors: try values.decode(UInt64.self, forKey: .transientErrors),
            preservedPaths: try values.decodeIfPresent(UInt64.self, forKey: .preservedPaths) ?? 0,
            processedOpaqueRoots: try values.decodeIfPresent(UInt64.self, forKey: .processedOpaqueRoots) ?? 0
        )
    }
}

public struct ScanProgressDelta: Codable, Equatable, Sendable {
    public let processedEvents: UInt64
    public let affectedPaths: UInt64
    public let visitedPaths: UInt64
    public let indexedObjects: UInt64
    public let unreadablePaths: UInt64
    public let transientErrors: UInt64
    public let preservedPaths: UInt64
    public let processedOpaqueRoots: UInt64

    public init(
        processedEvents: UInt64 = 0,
        affectedPaths: UInt64 = 0,
        visitedPaths: UInt64 = 0,
        indexedObjects: UInt64 = 0,
        unreadablePaths: UInt64 = 0,
        transientErrors: UInt64 = 0,
        preservedPaths: UInt64 = 0,
        processedOpaqueRoots: UInt64 = 0
    ) {
        self.processedEvents = processedEvents
        self.affectedPaths = affectedPaths
        self.visitedPaths = visitedPaths
        self.indexedObjects = indexedObjects
        self.unreadablePaths = unreadablePaths
        self.transientErrors = transientErrors
        self.preservedPaths = preservedPaths
        self.processedOpaqueRoots = processedOpaqueRoots
    }

    private enum CodingKeys: String, CodingKey {
        case processedEvents, affectedPaths, visitedPaths, indexedObjects, unreadablePaths, transientErrors
        case preservedPaths, processedOpaqueRoots
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            processedEvents: try values.decode(UInt64.self, forKey: .processedEvents),
            affectedPaths: try values.decode(UInt64.self, forKey: .affectedPaths),
            visitedPaths: try values.decode(UInt64.self, forKey: .visitedPaths),
            indexedObjects: try values.decode(UInt64.self, forKey: .indexedObjects),
            unreadablePaths: try values.decode(UInt64.self, forKey: .unreadablePaths),
            transientErrors: try values.decode(UInt64.self, forKey: .transientErrors),
            preservedPaths: try values.decodeIfPresent(UInt64.self, forKey: .preservedPaths) ?? 0,
            processedOpaqueRoots: try values.decodeIfPresent(UInt64.self, forKey: .processedOpaqueRoots) ?? 0
        )
    }
}

public struct ScanProgressSnapshot: Codable, Equatable, Sendable {
    public static let protocolVersion = 1

    public let version: Int
    public let requestID: UUID
    public let trigger: DailyDiskRunTrigger
    public let mode: ScanExecutionMode?
    public let phase: ScanProgressPhase
    public let startedAt: Date
    public let updatedAt: Date
    public let domainOrdinal: Int?
    public let domainCount: Int?
    public let counters: ScanProgressCounters
    public let errorCategory: ScanProgressErrorCategory?

    public init(
        version: Int = ScanProgressSnapshot.protocolVersion,
        requestID: UUID,
        trigger: DailyDiskRunTrigger,
        mode: ScanExecutionMode?,
        phase: ScanProgressPhase,
        startedAt: Date,
        updatedAt: Date,
        domainOrdinal: Int? = nil,
        domainCount: Int? = nil,
        counters: ScanProgressCounters = ScanProgressCounters(),
        errorCategory: ScanProgressErrorCategory? = nil
    ) throws {
        guard version == Self.protocolVersion,
            startedAt <= updatedAt,
            domainOrdinal.map({ $0 > 0 }) ?? true,
            domainCount.map({ $0 > 0 }) ?? true,
            domainOrdinal.map({ ordinal in domainCount.map({ ordinal <= $0 }) ?? false }) ?? true,
            phase == .failed || errorCategory == nil
        else {
            throw ScanProgressError.invalidSnapshot
        }
        self.version = version
        self.requestID = requestID
        self.trigger = trigger
        self.mode = mode
        self.phase = phase
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.domainOrdinal = domainOrdinal
        self.domainCount = domainCount
        self.counters = counters
        self.errorCategory = errorCategory
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID
        case trigger
        case mode
        case phase
        case startedAt
        case updatedAt
        case domainOrdinal
        case domainCount
        case counters
        case errorCategory
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            requestID: container.decode(UUID.self, forKey: .requestID),
            trigger: container.decode(DailyDiskRunTrigger.self, forKey: .trigger),
            mode: container.decodeIfPresent(ScanExecutionMode.self, forKey: .mode),
            phase: container.decode(ScanProgressPhase.self, forKey: .phase),
            startedAt: container.decode(Date.self, forKey: .startedAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            domainOrdinal: container.decodeIfPresent(Int.self, forKey: .domainOrdinal),
            domainCount: container.decodeIfPresent(Int.self, forKey: .domainCount),
            counters: container.decode(ScanProgressCounters.self, forKey: .counters),
            errorCategory: container.decodeIfPresent(ScanProgressErrorCategory.self, forKey: .errorCategory)
        )
    }
}

public enum DailyDiskRunRequestAction: String, Codable, CaseIterable, Sendable {
    case scanNow
    case reclaimSpace
}

public struct DailyDiskRunRequest: Codable, Equatable, Sendable {
    public static let protocolVersion = 1

    public let version: Int
    public let requestID: UUID
    public let action: DailyDiskRunRequestAction
    public let requestedMode: DailyDiskRequestedScanMode
    public let createdAt: Date

    public init(
        version: Int = DailyDiskRunRequest.protocolVersion,
        requestID: UUID = UUID(),
        action: DailyDiskRunRequestAction = .scanNow,
        requestedMode: DailyDiskRequestedScanMode = .automatic,
        createdAt: Date = Date()
    ) throws {
        guard version == Self.protocolVersion else { throw ScanProgressError.unsupportedProtocolVersion }
        self.version = version
        self.requestID = requestID
        self.action = action
        self.requestedMode = requestedMode
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID
        case action
        case requestedMode
        case createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            requestID: container.decode(UUID.self, forKey: .requestID),
            action: container.decode(DailyDiskRunRequestAction.self, forKey: .action),
            requestedMode: container.decode(DailyDiskRequestedScanMode.self, forKey: .requestedMode),
            createdAt: container.decode(Date.self, forKey: .createdAt)
        )
    }
}

public struct DailyDiskRunBinding: Codable, Equatable, Sendable {
    public static let protocolVersion = 1

    public let version: Int
    public let requestID: UUID
    public let runID: ScanRun.ID
    public let createdAt: Date

    public init(
        version: Int = DailyDiskRunBinding.protocolVersion,
        requestID: UUID,
        runID: ScanRun.ID,
        createdAt: Date = Date()
    ) throws {
        guard version == Self.protocolVersion else {
            throw ScanProgressError.unsupportedProtocolVersion
        }
        self.version = version
        self.requestID = requestID
        self.runID = runID
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case version, requestID, runID, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            requestID: container.decode(UUID.self, forKey: .requestID),
            runID: ScanRun.ID(container.decode(UUID.self, forKey: .runID)),
            createdAt: container.decode(Date.self, forKey: .createdAt)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(runID.rawValue, forKey: .runID)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

public struct DailyDiskCancelRequest: Codable, Equatable, Sendable {
    public static let protocolVersion = 1

    public let version: Int
    public let requestID: UUID
    public let createdAt: Date

    public init(
        version: Int = DailyDiskCancelRequest.protocolVersion,
        requestID: UUID,
        createdAt: Date = Date()
    ) throws {
        guard version == Self.protocolVersion else { throw ScanProgressError.unsupportedProtocolVersion }
        self.version = version
        self.requestID = requestID
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID
        case createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            requestID: container.decode(UUID.self, forKey: .requestID),
            createdAt: container.decode(Date.self, forKey: .createdAt)
        )
    }
}

public enum DailyDiskRunTerminalState: String, Codable, CaseIterable, Sendable {
    case maintenanceCompleted
    case succeeded
    case cancelled
    case failed
    case skippedNotDue
    case blockedByWriter
}

public struct DailyDiskRunSummary: Codable, Equatable, Sendable {
    public static let protocolVersion = 1

    public let version: Int
    public let requestID: UUID
    public let trigger: DailyDiskRunTrigger
    public let terminalState: DailyDiskRunTerminalState
    public let startedAt: Date
    public let finishedAt: Date
    public let completedDomainCount: Int
    public let failedDomainCount: Int
    public let reportRunIDs: [UUID]
    public let errorCategory: ScanProgressErrorCategory?

    public init(
        version: Int = DailyDiskRunSummary.protocolVersion,
        requestID: UUID,
        trigger: DailyDiskRunTrigger,
        terminalState: DailyDiskRunTerminalState,
        startedAt: Date,
        finishedAt: Date,
        completedDomainCount: Int,
        failedDomainCount: Int,
        reportRunIDs: [UUID],
        errorCategory: ScanProgressErrorCategory? = nil
    ) throws {
        guard version == Self.protocolVersion,
            startedAt <= finishedAt,
            completedDomainCount >= 0,
            failedDomainCount >= 0,
            reportRunIDs.count <= completedDomainCount
        else {
            throw ScanProgressError.invalidSummary
        }
        let terminalIsValid: Bool =
            switch terminalState {
            case .succeeded:
                completedDomainCount > 0 && failedDomainCount == 0 && errorCategory == nil
            case .cancelled:
                failedDomainCount == 0 && errorCategory == nil
            case .failed:
                failedDomainCount > 0 && errorCategory != nil
            case .maintenanceCompleted, .skippedNotDue, .blockedByWriter:
                completedDomainCount == 0
                    && failedDomainCount == 0
                    && reportRunIDs.isEmpty
                    && errorCategory == nil
            }
        guard terminalIsValid else { throw ScanProgressError.invalidSummary }
        self.version = version
        self.requestID = requestID
        self.trigger = trigger
        self.terminalState = terminalState
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.completedDomainCount = completedDomainCount
        self.failedDomainCount = failedDomainCount
        self.reportRunIDs = reportRunIDs
        self.errorCategory = errorCategory
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID
        case trigger
        case terminalState
        case startedAt
        case finishedAt
        case completedDomainCount
        case failedDomainCount
        case reportRunIDs
        case errorCategory
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            requestID: container.decode(UUID.self, forKey: .requestID),
            trigger: container.decode(DailyDiskRunTrigger.self, forKey: .trigger),
            terminalState: container.decode(DailyDiskRunTerminalState.self, forKey: .terminalState),
            startedAt: container.decode(Date.self, forKey: .startedAt),
            finishedAt: container.decode(Date.self, forKey: .finishedAt),
            completedDomainCount: container.decode(Int.self, forKey: .completedDomainCount),
            failedDomainCount: container.decode(Int.self, forKey: .failedDomainCount),
            reportRunIDs: container.decode([UUID].self, forKey: .reportRunIDs),
            errorCategory: container.decodeIfPresent(ScanProgressErrorCategory.self, forKey: .errorCategory)
        )
    }
}

public enum ScanProgressTransitionValidator {
    public static func canTransition(
        from current: ScanProgressPhase,
        to next: ScanProgressPhase
    ) -> Bool {
        if current.isTerminal { return false }
        if current == next { return true }
        if current == .cancelling {
            return next == .cancelled || next == .failed
        }
        if next == .cancelling || next == .cancelled {
            return current.allowsCancellation
        }
        if next == .failed { return true }
        if next == .cleaningUpFailedRun {
            return current.allowsCancellation || current == .committing
        }
        if current == .cleaningUpFailedRun { return next == .preparing }

        switch current {
        case .queued:
            return next == .waitingForWriter || next == .preparing
        case .waitingForWriter:
            return next == .preparing
        case .cleaningRetiredInventory:
            return next == .reclaimingSpace || next == .preparing
        case .reclaimingSpace:
            return next == .verifyingMaintenance || next == .preparing
        case .verifyingMaintenance:
            return next == .preparing || next == .completed
        case .preparing:
            if next.isSpaceMaintenance || next == .completed { return true }
            return next == .recoveringInterruptedRun || next == .discoveringStorage
        case .recoveringInterruptedRun:
            return next == .discoveringStorage || next == .preparing
        case .discoveringStorage:
            return next == .replayingEvents || next == .scanningFiles
                || next == .publishingReport  // Recover an already committed scan before new work.
                || next == .applyingRetention || next == .completed
                || next == .preparing
        case .replayingEvents:
            return next == .scanningFiles || next == .catchingUpEvents
                || next == .sealingInventory || next == .preparing
        case .scanningFiles:
            return next == .preservingOpaqueInventory || next == .catchingUpEvents || next == .sealingInventory
                || next == .preparing
        case .preservingOpaqueInventory:
            return next == .catchingUpEvents || next == .sealingInventory || next == .preparing
        case .catchingUpEvents:
            return next == .sealingInventory || next == .preparing
        case .sealingInventory:
            return next == .reconciling || next == .collectingDiagnostics
                || next == .preparing
        case .reconciling:
            return next == .collectingDiagnostics || next == .preparing
        case .collectingDiagnostics:
            return next == .committing || next == .preparing
        case .committing:
            return next == .publishingReport || next == .preparing
        case .publishingReport:
            return next == .notifying || next == .applyingRetention
                || next == .completed || next == .preparing
        case .notifying:
            return next == .applyingRetention || next == .completed
                || next == .preparing
        case .applyingRetention:
            return next == .completed
        case .cleaningUpFailedRun, .cancelling, .completed, .cancelled, .failed:
            return false
        }
    }
}

public enum ScanProgressError: Error, Equatable, Sendable {
    case counterOverflow
    case invalidSnapshot
    case invalidPhaseTransition(from: ScanProgressPhase, to: ScanProgressPhase)
    case invalidSummary
    case unsupportedProtocolVersion
    case cancelled
}
