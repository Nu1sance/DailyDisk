import Foundation
import Testing

@testable import DailyDiskCore

private func alertReport(
    physical: Int64?,
    unattributed: Int64?,
    correction: Int64 = 0,
    growth: Int64 = 0
) throws -> DailyReport {
    let reconciled = correction
    let overhead: Int64 = 0
    let accounting = try AccountingSummary(
        eventAttributedDelta: 0,
        reconciliationCorrection: correction,
        reconciledIndexedDelta: reconciled,
        dailyDiskOverheadDelta: overhead,
        physicalUsedDelta: physical,
        physicalUnattributedDelta: unattributed
    )
    return try DailyReport(
        runID: ScanRun.ID(),
        generatedAt: Date(),
        storageDomainID: StorageDomain.ID("domain"),
        accounting: accounting,
        reconciliation: correction == 0
            ? nil
            : ReconciliationBreakdown(
                missedAdditions: 0,
                staleRemovals: 0,
                sizeCorrections: correction,
                attributionTransfers: 0,
                affectedRecords: 1
            ),
        coverage: ScanCoverage(
            visitedPathCount: 1,
            indexedObjectCount: 1,
            unreadablePathCount: 0,
            transientErrorCount: 0
        ),
        largestGrowth: growth == 0
            ? []
            : [
                RankedPathChange(
                    path: RelativePath(validating: "Users/alice/cache"),
                    allocatedDelta: growth,
                    logicalDelta: growth
                )
            ],
        largestShrinkage: [],
        diagnostics: []
    )
}

@Test("Alert policy stays silent for ordinary growth")
func alertPolicyStaysSilent() throws {
    let report = try alertReport(physical: 1_000, unattributed: 1_000)
    let sample = try StorageSample(
        storageDomainID: report.storageDomainID,
        sampledAt: Date(),
        capacityBytes: 1_000_000,
        usedBytes: 500_000,
        availableBytes: 500_000
    )
    let policy = AlertPolicy(
        thresholds: try AlertThresholds(
            physicalGrowthBytes: 10_000,
            minimumAvailableBytes: 1_000,
            minimumAvailableFraction: 0.01,
            largePathGrowthBytes: 10_000,
            reconciliationBytes: 10_000,
            unattributedBytes: 10_000
        )
    )
    #expect(try policy.evaluate(report: report, currentSample: sample) == nil)
}

private actor MemoryAlertStateStore: AlertStatePersisting {
    private var value: AlertState?
    func state(storageDomainID: StorageDomain.ID) async throws -> AlertState? { value }
    func save(_ state: AlertState, storageDomainID: StorageDomain.ID) async throws { value = state }
}

private actor NotificationRecorder: NotificationSending {
    private(set) var messages: [NotificationMessage] = []
    func send(_ message: NotificationMessage) async throws { messages.append(message) }
}

@Test("Alert coordinator persists cooldown and omits paths from notification text")
func alertCoordinatorCooldown() async throws {
    let report = try alertReport(physical: 20_000, unattributed: 20_000, growth: 8_000)
    let sample = try StorageSample(
        storageDomainID: report.storageDomainID,
        sampledAt: Date(),
        capacityBytes: 100_000,
        usedBytes: 50_000,
        availableBytes: 50_000
    )
    let state = MemoryAlertStateStore()
    let notifications = NotificationRecorder()
    let coordinator = AlertCoordinator(
        policy: AlertPolicy(
            thresholds: try AlertThresholds(
                physicalGrowthBytes: 10_000,
                minimumAvailableBytes: 1,
                minimumAvailableFraction: 0,
                largePathGrowthBytes: 7_000,
                reconciliationBytes: 10_000,
                unattributedBytes: 10_000
            )
        ),
        stateStore: state,
        notifier: notifications,
        cooldown: 3_600,
        clock: AdvancingTestClock(Date(timeIntervalSince1970: 100))
    )
    #expect(try await coordinator.evaluateAndNotify(report: report, currentSample: sample) != nil)
    #expect(try await coordinator.evaluateAndNotify(report: report, currentSample: sample) == nil)
    let messages = await notifications.messages
    #expect(messages.count == 1)
    #expect(!messages[0].body.contains("Users/alice"))
}

private actor AdvancingTestClock: Clock {
    var date: Date
    init(_ date: Date) { self.date = date }
    func now() async -> Date {
        defer { date = date.addingTimeInterval(1) }
        return date
    }
}

@Test("Alert policy reports physical, correction, path, residual, and low-space conditions")
func alertPolicyDetectsThresholds() throws {
    let report = try alertReport(physical: 20_000, unattributed: 15_000, correction: 5_000, growth: 8_000)
    let sample = try StorageSample(
        storageDomainID: report.storageDomainID,
        sampledAt: Date(),
        capacityBytes: 100_000,
        usedBytes: 95_000,
        availableBytes: 5_000
    )
    let policy = AlertPolicy(
        thresholds: try AlertThresholds(
            physicalGrowthBytes: 10_000,
            minimumAvailableBytes: 6_000,
            minimumAvailableFraction: 0.10,
            largePathGrowthBytes: 7_000,
            reconciliationBytes: 4_000,
            unattributedBytes: 10_000
        )
    )
    let decision = try #require(try policy.evaluate(report: report, currentSample: sample))

    #expect(decision.severity == .critical)
    #expect(decision.reasons.contains(.physicalGrowth))
    #expect(decision.reasons.contains(.largeReconciliation))
    #expect(decision.reasons.contains(.largePathGrowth))
    #expect(decision.reasons.contains(.largeUnattributedChange))
    #expect(decision.reasons.contains(.lowAvailableBytes))
    #expect(decision.reasons.contains(.lowAvailableFraction))
}

@Test("Directory aggregate alerts survive separating direct-path rankings")
func directoryAggregateAlert() throws {
    let path = try RelativePath(validating: "folder")
    let ranking = ReportPathRanking(
        growth: [
            RankedPathChange(path: try RelativePath(validating: "folder/file"), allocatedDelta: 100, logicalDelta: 100)
        ],
        release: [], directoryGrowth: [RankedPathChange(path: path, allocatedDelta: 20_000, logicalDelta: 20_000)],
        directoryRelease: [], growthPathCount: 200, releasePathCount: 0, logicalOnlyPathCount: 0)
    let report = try alertReport(physical: 0, unattributed: 0).replacingPathRanking(ranking)
    let sample = try StorageSample(
        storageDomainID: report.storageDomainID, sampledAt: Date(),
        capacityBytes: 1_000_000, usedBytes: 500_000, availableBytes: 500_000)
    let policy = AlertPolicy(
        thresholds: try AlertThresholds(
            physicalGrowthBytes: 10_000,
            minimumAvailableBytes: 1_000, minimumAvailableFraction: 0.01, largePathGrowthBytes: 10_000,
            reconciliationBytes: 10_000, unattributedBytes: 10_000))
    let decision = try #require(try policy.evaluate(report: report, currentSample: sample))
    #expect(decision.reasons.contains(.largePathGrowth))
}
