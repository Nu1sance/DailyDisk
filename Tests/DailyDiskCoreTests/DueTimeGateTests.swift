import Foundation
import Testing

@testable import DailyDiskCore

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

@Test("Due gate runs once after today's schedule")
func dueGateOncePerDay() throws {
    let gate = try DueTimeGate(hour: 9, minute: 0, calendar: utcCalendar)
    let now = Date(timeIntervalSince1970: 1_700_049_600)  // 2023-11-15 12:00 UTC
    let today = try #require(utcCalendar.date(bySettingHour: 9, minute: 0, second: 0, of: now))

    let due = try gate.decision(now: now, lastSuccessfulAt: today.addingTimeInterval(-1))
    #expect(due == .due(scheduledFor: today))
    if case .notDue = try gate.decision(now: now, lastSuccessfulAt: today.addingTimeInterval(1)) {
        // Expected.
    } else {
        Issue.record("Expected not due after today's successful run")
    }
}

@Test("RunAtLoad before today's time catches up only when yesterday was missed")
func dueGateCatchUp() throws {
    let gate = try DueTimeGate(hour: 9, minute: 0, calendar: utcCalendar)
    let now = Date(timeIntervalSince1970: 1_700_035_200)  // 2023-11-15 08:00 UTC
    let today = try #require(utcCalendar.date(bySettingHour: 9, minute: 0, second: 0, of: now))
    let yesterday = try #require(utcCalendar.date(byAdding: .day, value: -1, to: today))

    let catchUp = try gate.decision(
        now: now,
        lastSuccessfulAt: yesterday.addingTimeInterval(-1)
    )
    #expect(catchUp == .due(scheduledFor: yesterday))
    if case .notDue(let next) = try gate.decision(
        now: now,
        lastSuccessfulAt: yesterday.addingTimeInterval(1)
    ) {
        #expect(next == today)
    } else {
        Issue.record("Expected today's future schedule")
    }
}

@Test("A new installation is immediately due and invalid times are rejected")
func dueGateInitialAndValidation() throws {
    let gate = try DueTimeGate(calendar: utcCalendar)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    if case .due = try gate.decision(now: now, lastSuccessfulAt: nil) {
        // Expected.
    } else {
        Issue.record("Initial scan should be due")
    }
    #expect(throws: DueTimeGateError.invalidTime) {
        _ = try DueTimeGate(hour: 24)
    }
}
