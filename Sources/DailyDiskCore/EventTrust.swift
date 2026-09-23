import Foundation

public struct EventTrustAssessment: Equatable, Sendable {
    public let trust: EventHistoryTrust
    public let reasons: [String]

    public init(trust: EventHistoryTrust, reasons: [String] = []) {
        self.trust = trust
        self.reasons = reasons
    }

    public func merging(_ other: EventTrustAssessment) -> EventTrustAssessment {
        let mergedTrust: EventHistoryTrust
        if trust == .fullScanRequired || other.trust == .fullScanRequired {
            mergedTrust = .fullScanRequired
        } else if trust == .subtreeRescanRequired || other.trust == .subtreeRescanRequired {
            mergedTrust = .subtreeRescanRequired
        } else {
            mergedTrust = .trusted
        }
        return EventTrustAssessment(
            trust: mergedTrust,
            reasons: Array(Set(reasons + other.reasons)).sorted()
        )
    }
}

public enum EventTrustEvaluator {
    public static func assess(flags: FileSystemEventFlags) -> EventTrustAssessment {
        var reasons: [String] = []
        if flags.contains(.userDropped) { reasons.append("FSEvents user-space events dropped") }
        if flags.contains(.kernelDropped) { reasons.append("FSEvents kernel events dropped") }
        if flags.contains(.eventIDsWrapped) { reasons.append("FSEvents event IDs wrapped") }
        if flags.contains(.rootChanged) { reasons.append("FSEvents watched root changed") }
        if flags.contains(.mounted) { reasons.append("FSEvents nested volume mounted") }
        if flags.contains(.unmounted) { reasons.append("FSEvents volume unmounted") }
        if !reasons.isEmpty {
            return EventTrustAssessment(trust: .fullScanRequired, reasons: reasons)
        }
        if flags.contains(.mustScanSubdirectories) {
            return EventTrustAssessment(
                trust: .subtreeRescanRequired,
                reasons: ["FSEvents requires recursive subtree scan"]
            )
        }
        return EventTrustAssessment(trust: .trusted)
    }

    public static func assessJournal(
        expectedUUID: UUID?,
        observedUUID: UUID?,
        previousEventID: UInt64?,
        observedEventID: UInt64?
    ) -> EventTrustAssessment {
        guard let observedUUID else {
            return EventTrustAssessment(
                trust: .fullScanRequired,
                reasons: ["Persistent FSEvents history is unavailable"]
            )
        }
        if let expectedUUID, expectedUUID != observedUUID {
            return EventTrustAssessment(
                trust: .fullScanRequired,
                reasons: ["FSEvents journal UUID changed"]
            )
        }
        if let previousEventID, let observedEventID, observedEventID < previousEventID {
            return EventTrustAssessment(
                trust: .fullScanRequired,
                reasons: ["FSEvents event cursor regressed"]
            )
        }
        return EventTrustAssessment(trust: .trusted)
    }
}
