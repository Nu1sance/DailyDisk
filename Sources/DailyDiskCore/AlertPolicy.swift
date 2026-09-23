import Foundation

public enum AlertReason: String, Codable, CaseIterable, Sendable {
    case physicalGrowth
    case lowAvailableBytes
    case lowAvailableFraction
    case largePathGrowth
    case largeReconciliation
    case largeUnattributedChange
    case deletedOpenFiles
    case scanErrors
}

public struct AlertThresholds: Codable, Equatable, Sendable {
    public let physicalGrowthBytes: Int64
    public let minimumAvailableBytes: Int64
    public let minimumAvailableFraction: Double
    public let largePathGrowthBytes: Int64
    public let reconciliationBytes: Int64
    public let unattributedBytes: Int64

    public init(
        physicalGrowthBytes: Int64 = 5 * 1_024 * 1_024 * 1_024,
        minimumAvailableBytes: Int64 = 20 * 1_024 * 1_024 * 1_024,
        minimumAvailableFraction: Double = 0.10,
        largePathGrowthBytes: Int64 = 3 * 1_024 * 1_024 * 1_024,
        reconciliationBytes: Int64 = 1 * 1_024 * 1_024 * 1_024,
        unattributedBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    ) throws {
        guard physicalGrowthBytes > 0,
            minimumAvailableBytes >= 0,
            minimumAvailableFraction.isFinite,
            minimumAvailableFraction >= 0,
            minimumAvailableFraction <= 1,
            largePathGrowthBytes > 0,
            reconciliationBytes > 0,
            unattributedBytes > 0
        else {
            throw AlertPolicyError.invalidThreshold
        }
        self.physicalGrowthBytes = physicalGrowthBytes
        self.minimumAvailableBytes = minimumAvailableBytes
        self.minimumAvailableFraction = minimumAvailableFraction
        self.largePathGrowthBytes = largePathGrowthBytes
        self.reconciliationBytes = reconciliationBytes
        self.unattributedBytes = unattributedBytes
    }

    public static let `default` = try! AlertThresholds()
}

public struct AlertState: Codable, Equatable, Sendable {
    public let notifiedAt: Date
    public let reasons: [AlertReason]

    public init(notifiedAt: Date, reasons: [AlertReason]) {
        self.notifiedAt = notifiedAt
        self.reasons = reasons
    }
}

public struct AlertDecision: Codable, Equatable, Sendable {
    public let reasons: [AlertReason]
    public let severity: NotificationMessage.Severity
    public let title: String
    public let body: String

    public init(
        reasons: [AlertReason],
        severity: NotificationMessage.Severity,
        title: String,
        body: String
    ) {
        self.reasons = reasons
        self.severity = severity
        self.title = title
        self.body = body
    }
}

public protocol AlertStatePersisting: Sendable {
    func state(storageDomainID: StorageDomain.ID) async throws -> AlertState?
    func save(_ state: AlertState, storageDomainID: StorageDomain.ID) async throws
}

public struct AlertPolicy: Sendable {
    public let thresholds: AlertThresholds

    public init(thresholds: AlertThresholds = .default) {
        self.thresholds = thresholds
    }

    public func evaluate(
        report: DailyReport,
        currentSample: StorageSample,
        now: Date = Date(),
        previousState: AlertState? = nil,
        cooldown: TimeInterval = 24 * 60 * 60
    ) throws -> AlertDecision? {
        guard currentSample.storageDomainID == report.storageDomainID else {
            throw AlertPolicyError.storageDomainMismatch
        }
        guard cooldown.isFinite, cooldown >= 0 else {
            throw AlertPolicyError.invalidCooldown
        }
        var reasons: Set<AlertReason> = []
        if let physical = report.accounting.physicalUsedDelta,
            physical >= thresholds.physicalGrowthBytes
        {
            reasons.insert(.physicalGrowth)
        }
        if currentSample.availableBytes <= thresholds.minimumAvailableBytes {
            reasons.insert(.lowAvailableBytes)
        }
        if currentSample.capacityBytes > 0,
            Double(currentSample.availableBytes) / Double(currentSample.capacityBytes)
                <= thresholds.minimumAvailableFraction
        {
            reasons.insert(.lowAvailableFraction)
        }
        if report.largestGrowth.contains(where: { $0.allocatedDelta >= thresholds.largePathGrowthBytes }) {
            reasons.insert(.largePathGrowth)
        }
        if magnitude(report.accounting.reconciliationCorrection) >= thresholds.reconciliationBytes {
            reasons.insert(.largeReconciliation)
        }
        if let unattributed = report.accounting.physicalUnattributedDelta,
            magnitude(unattributed) >= thresholds.unattributedBytes
        {
            reasons.insert(.largeUnattributedChange)
        }
        if (report.physicalDiagnosis?.uniqueDeletedOpenLogicalBytes ?? 0) > 0 {
            reasons.insert(.deletedOpenFiles)
        }
        if report.coverage.unreadablePathCount > 0 || !report.diagnostics.isEmpty {
            reasons.insert(.scanErrors)
        }
        guard !reasons.isEmpty else { return nil }

        let ordered = reasons.sorted { $0.rawValue < $1.rawValue }
        if let previousState,
            previousState.reasons == ordered,
            now.timeIntervalSince(previousState.notifiedAt) >= 0,
            now.timeIntervalSince(previousState.notifiedAt) < cooldown
        {
            return nil
        }
        let severity: NotificationMessage.Severity =
            reasons.contains(.lowAvailableBytes)
                || reasons.contains(.lowAvailableFraction)
            ? .critical : .warning
        let physical = report.accounting.physicalUsedDelta.map(formatBytes) ?? "unknown"
        let top =
            report.largestGrowth.first.map {
                "Largest attributed path change: \(formatBytes($0.allocatedDelta))"
            } ?? "No path attribution"
        return AlertDecision(
            reasons: ordered,
            severity: severity,
            title: "DailyDisk detected unusual storage change",
            body: "Physical change: \(physical). \(top). \(ordered.count) alert condition(s)."
        )
    }

    private func magnitude(_ value: Int64) -> Int64 {
        value == .min ? .max : abs(value)
    }

    private func formatBytes(_ value: Int64) -> String {
        let sign = value > 0 ? "+" : ""
        return sign + ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

public struct AlertCoordinator: Sendable {
    private let policy: AlertPolicy
    private let stateStore: any AlertStatePersisting
    private let notifier: any NotificationSending
    private let cooldown: TimeInterval
    private let clock: any Clock

    public init(
        policy: AlertPolicy,
        stateStore: any AlertStatePersisting,
        notifier: any NotificationSending,
        cooldown: TimeInterval = 24 * 60 * 60,
        clock: any Clock = SystemClock()
    ) {
        self.policy = policy
        self.stateStore = stateStore
        self.notifier = notifier
        self.cooldown = cooldown
        self.clock = clock
    }

    public func evaluateAndNotify(report: DailyReport, currentSample: StorageSample) async throws -> AlertDecision? {
        let previous = try await stateStore.state(storageDomainID: report.storageDomainID)
        let now = await clock.now()
        guard
            let decision = try policy.evaluate(
                report: report,
                currentSample: currentSample,
                now: now,
                previousState: previous,
                cooldown: cooldown
            )
        else { return nil }
        try await notifier.send(
            NotificationMessage(
                identifier: "dailydisk.\(report.storageDomainID.rawValue)",
                title: decision.title,
                body: decision.body,
                severity: decision.severity
            )
        )
        try await stateStore.save(
            AlertState(notifiedAt: now, reasons: decision.reasons),
            storageDomainID: report.storageDomainID
        )
        return decision
    }
}

public enum AlertPolicyError: Error, Equatable, Sendable {
    case invalidThreshold
    case invalidCooldown
    case storageDomainMismatch
}
