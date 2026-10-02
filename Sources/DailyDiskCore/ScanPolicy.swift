import Foundation

public enum RecoveryTrigger: String, Codable, CaseIterable, Sendable {
    case eventHistoryLost
    case eventStoreChanged
    case topologyChanged
    case inventoryDrift
    case interruptedFullScan
}

public enum ScanDecision: Equatable, Sendable {
    case initialFull
    case incremental
    case scheduledFull
    case recovery(RecoveryTrigger)
}

public struct ScanPolicy: Sendable {
    public init() {}
    public static let `default` = ScanPolicy()

    public func decision(
        checkpoint: Checkpoint?, now: Date,
        lastPublishedFullAt: Date? = nil, calendar: Calendar = .current,
        recoveryTrigger: RecoveryTrigger? = nil
    ) -> ScanDecision {
        if let recoveryTrigger { return .recovery(recoveryTrigger) }
        guard checkpoint != nil else { return .initialFull }
        if let lastPublishedFullAt, lastPublishedFullAt <= now,
            calendar.isDate(lastPublishedFullAt, inSameDayAs: now)
        {
            return .incremental
        }
        return .scheduledFull
    }
}
