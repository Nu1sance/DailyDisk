public struct ReconciliationResult: Sendable {
    public let eventChanges: [ChangeRecord]
    public let reconciliationChanges: [ChangeRecord]
    public let allChanges: [ChangeRecord]
    public let breakdown: ReconciliationBreakdown?

    public init(
        eventChanges: [ChangeRecord],
        reconciliationChanges: [ChangeRecord]
    ) throws {
        guard eventChanges.allSatisfy({ $0.source == .fsevents }),
            reconciliationChanges.allSatisfy({ $0.source == .reconciliation })
        else {
            throw ReconciliationError.invalidChangeSource
        }
        let all = eventChanges + reconciliationChanges
        let runIDs = Set(all.map(\.runID))
        let volumeIDs = Set(all.map(\.volumeID))
        guard runIDs.count <= 1, volumeIDs.count <= 1 else {
            throw ReconciliationError.mixedTransitionScope
        }
        try ChangeSetValidator.validateAttributionTransfers(in: all)
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
