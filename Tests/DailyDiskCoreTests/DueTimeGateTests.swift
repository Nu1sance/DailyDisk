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

    let due = try gate.decision(now: now, lastSuccessfulAt: today.addingTimeInterval(-86400))
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
        lastSuccessfulAt: yesterday.addingTimeInterval(-86400)
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

@Test("A manual full published before 05:00 satisfies that day, including DST days")
func dueGatePublishedFullBeforeSchedule() throws {
    for zone in ["UTC", "Asia/Shanghai", "America/Los_Angeles"] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        for components in [DateComponents(year: 2026, month: 3, day: 8), DateComponents(year: 2026, month: 11, day: 1)]
        {
            let day = try #require(calendar.date(from: components))
            let published = try #require(calendar.date(bySettingHour: 0, minute: 30, second: 0, of: day))
            let now = try #require(calendar.date(bySettingHour: 5, minute: 0, second: 0, of: day))
            let gate = try DueTimeGate(calendar: calendar)
            #expect(gate.hour == 5)
            if case .due = try gate.decision(now: now, lastSuccessfulAt: published) {
                Issue.record("Pre-schedule manual full must satisfy today's work")
            }
            let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: now))
            #expect(
                try gate.decision(now: tomorrow, lastSuccessfulAt: now.addingTimeInterval(22 * 60))
                    == .due(scheduledFor: tomorrow))
        }
    }
}
