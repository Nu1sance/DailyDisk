import Foundation
import Testing

@testable import DailyDiskCore

private func policyDate(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
private func policyCalendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}
private func policyCheckpoint(at date: Date) -> Checkpoint {
    Checkpoint(
        volumeID: MonitoredVolume.ID("data"), eventStoreUUID: UUID(), lastCommittedEventID: 1,
        activeGenerationID: InventoryGeneration.ID(), topologyFingerprint: "topology",
        lastSuccessfulIncrementalAt: date, lastSuccessfulFullScanAt: date)
}

@Test("Daily policy requires a published full today, not a proposed checkpoint or recent incremental")
func dailyFullScanPolicy() {
    let policy = ScanPolicy()
    let now = policyDate("2026-10-01T05:00:00Z")
    let calendar = policyCalendar("UTC")
    let checkpoint = policyCheckpoint(at: now)
    #expect(policy.decision(checkpoint: nil, now: now) == .initialFull)
    #expect(policy.decision(checkpoint: checkpoint, now: now, calendar: calendar) == .scheduledFull)
    #expect(
        policy.decision(
            checkpoint: checkpoint, now: now,
            lastPublishedFullAt: policyDate("2026-09-30T05:22:00Z"), calendar: calendar) == .scheduledFull)
    #expect(
        policy.decision(
            checkpoint: checkpoint, now: now,
            lastPublishedFullAt: policyDate("2026-10-01T00:01:00Z"), calendar: calendar) == .incremental)
    #expect(
        policy.decision(
            checkpoint: checkpoint, now: now,
            lastPublishedFullAt: now.addingTimeInterval(60), calendar: calendar) == .scheduledFull)
    #expect(
        policy.decision(
            checkpoint: checkpoint, now: now,
            lastPublishedFullAt: now, calendar: calendar, recoveryTrigger: .eventStoreChanged)
            == .recovery(.eventStoreChanged))
}

@Test("Daily policy follows calendar boundaries across midnight, DST and timezone changes")
func dailyPolicyCalendarBoundaries() {
    let cases = [
        ("America/Los_Angeles", "2026-03-08T07:59:00Z", "2026-03-08T13:00:00Z", false),
        ("America/Los_Angeles", "2026-03-08T08:01:00Z", "2026-03-08T13:00:00Z", true),
        ("America/Los_Angeles", "2026-11-01T08:30:00Z", "2026-11-01T09:30:00Z", true),
        ("Asia/Shanghai", "2026-09-30T23:30:00Z", "2026-10-01T01:00:00Z", true),
        ("UTC", "2026-09-30T23:30:00Z", "2026-10-01T01:00:00Z", false),
    ]
    for (zone, published, now, sameDay) in cases {
        let date = policyDate(now)
        #expect(
            ScanPolicy().decision(
                checkpoint: policyCheckpoint(at: date), now: date,
                lastPublishedFullAt: policyDate(published), calendar: policyCalendar(zone))
                == (sameDay ? .incremental : .scheduledFull))
    }
}
