public struct ReconciliationResult: Sendable {
    public let snapshotChanges: [ChangeRecord]
    public let eventChanges: [ChangeRecord]
    public let reconciliationChanges: [ChangeRecord]
    public let allChanges: [ChangeRecord]
    public let breakdown: ReconciliationBreakdown?

    public init(
        snapshotChanges: [ChangeRecord] = [],
        eventChanges: [ChangeRecord],
        reconciliationChanges: [ChangeRecord]
    ) throws {
        guard snapshotChanges.allSatisfy({ $0.source == .snapshotComparison }),
            eventChanges.allSatisfy({ $0.source == .fsevents }),
            reconciliationChanges.allSatisfy({ $0.source == .reconciliation })
        else {
            throw ReconciliationError.invalidChangeSource
        }
        let all = snapshotChanges + eventChanges + reconciliationChanges
        let runIDs = Set(all.map(\.runID))
        let volumeIDs = Set(all.map(\.volumeID))
        guard runIDs.count <= 1, volumeIDs.count <= 1 else {
            throw ReconciliationError.mixedTransitionScope
        }
        try ChangeSetValidator.validateAttributionTransfers(in: all)
        self.snapshotChanges = snapshotChanges
        self.eventChanges = eventChanges
        self.reconciliationChanges = reconciliationChanges
        allChanges = all
        breakdown = try SpaceAccounting.reconciliationBreakdown(from: all)
    }
}

public enum ReconciliationError: Error, Equatable, Sendable {
    case invalidChangeSource
    case mixedTransitionScope
}
