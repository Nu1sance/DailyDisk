import Foundation
import Testing

@testable import DailyDiskCore

@Test("Scan policy uses a rolling seven-day full-scan deadline")
func rollingFullScanPolicy() throws {
    let policy = try ScanPolicy()
    let now = Date(timeIntervalSince1970: 10 * 24 * 60 * 60)
    #expect(policy.decision(checkpoint: nil, now: now) == .initialFull)

    let checkpoint = Checkpoint(
        volumeID: MonitoredVolume.ID("data"),
        eventStoreUUID: UUID(),
        lastCommittedEventID: 1,
        activeGenerationID: InventoryGeneration.ID(),
        topologyFingerprint: "topology",
        lastSuccessfulIncrementalAt: nil,
        lastSuccessfulFullScanAt: now.addingTimeInterval(-7 * 24 * 60 * 60)
    )
    #expect(policy.decision(checkpoint: checkpoint, now: now) == .scheduledFull)
    #expect(
        policy.decision(
            checkpoint: Checkpoint(
                volumeID: checkpoint.volumeID,
                eventStoreUUID: checkpoint.eventStoreUUID,
                lastCommittedEventID: checkpoint.lastCommittedEventID,
                activeGenerationID: checkpoint.activeGenerationID,
                topologyFingerprint: checkpoint.topologyFingerprint,
                lastSuccessfulIncrementalAt: nil,
                lastSuccessfulFullScanAt: now.addingTimeInterval(-6 * 24 * 60 * 60)
            ),
            now: now
        ) == .incremental
    )
}

@Test("Recovery trigger takes precedence over the weekly schedule")
func recoveryPrecedesSchedule() throws {
    let policy = try ScanPolicy()
    let now = Date()
    let checkpoint = Checkpoint(
        volumeID: MonitoredVolume.ID("data"),
        eventStoreUUID: UUID(),
        lastCommittedEventID: 1,
        activeGenerationID: InventoryGeneration.ID(),
        topologyFingerprint: "topology",
        lastSuccessfulIncrementalAt: nil,
        lastSuccessfulFullScanAt: now
    )

    #expect(
        policy.decision(
            checkpoint: checkpoint,
            now: now,
            recoveryTrigger: .eventStoreChanged
        ) == .recovery(.eventStoreChanged)
    )
}
