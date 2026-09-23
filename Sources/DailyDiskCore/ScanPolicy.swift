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
    public let fullScanInterval: TimeInterval

    public init(fullScanInterval: TimeInterval = 7 * 24 * 60 * 60) throws {
        guard fullScanInterval.isFinite, fullScanInterval > 0 else {
            throw ScanPolicyError.invalidFullScanInterval
        }
        self.fullScanInterval = fullScanInterval
    }

    public static let `default` = try! ScanPolicy()

    public func decision(
        checkpoint: Checkpoint?,
        now: Date,
        recoveryTrigger: RecoveryTrigger? = nil
    ) -> ScanDecision {
        if let recoveryTrigger { return .recovery(recoveryTrigger) }
        guard let checkpoint else { return .initialFull }
        if now.timeIntervalSince(checkpoint.lastSuccessfulFullScanAt) >= fullScanInterval {
            return .scheduledFull
        }
        return .incremental
    }
}

public enum ScanPolicyError: Error, Equatable, Sendable {
    case invalidFullScanInterval
}
