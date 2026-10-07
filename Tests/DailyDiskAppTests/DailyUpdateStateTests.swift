import Foundation
import Testing

@testable import DailyDiskApp

@MainActor
private func withUpdateDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let name = "DailyDiskTests.Updates.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
}

private func updateCalendar(_ zone: String = "Asia/Shanghai") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private func updateDate(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

@Test @MainActor
func automaticUpdateAttemptsSurviveOfflineRestartAndResetAtLocalMidnight() {
    withUpdateDefaults { defaults in
        let now = updateDate("2026-10-07T15:59:00Z")
        let calendar = updateCalendar()
        let state = DailyUpdateState(defaults: defaults, context: "build20-feedA", currentBuild: "20")
        #expect(state.beginProbe(now: now, calendar: calendar, ready: true))
        #expect(!state.beginProbe(now: now, calendar: calendar, ready: true))
        #expect(!state.beginManual(ready: true))
        // Network failure: no presentation/installation cleanup, no same-day retry.
        #expect(!state.finish(.probe, noUpdate: false))
        let reopened = DailyUpdateState(defaults: defaults, context: "build20-feedA", currentBuild: "20")
        #expect(!reopened.beginProbe(now: now.addingTimeInterval(30), calendar: calendar, ready: true))
        #expect(reopened.beginProbe(now: now.addingTimeInterval(60), calendar: calendar, ready: true))
    }
}

@Test @MainActor
func updateScheduleRespectsDisabledBusyAndManualBypass() {
    withUpdateDefaults { defaults in
        let now = Date()
        let state = DailyUpdateState(defaults: defaults, context: "20", currentBuild: "20")
        state.automaticallyChecks = false
        #expect(!state.beginProbe(now: now, ready: true))
        #expect(state.beginManual(ready: true))
        #expect(!state.beginProbe(now: now, ready: true))
        // A late callback of the wrong type cannot close a manual check.
        #expect(!state.finish(.probe, noUpdate: true))
        #expect(state.cycle == .manual)
        #expect(state.finish(.manual, noUpdate: false))
        state.automaticallyChecks = true
        #expect(!state.beginProbe(now: now, ready: false))
        #expect(state.beginProbe(now: now, ready: true))
        state.finish(.probe, noUpdate: true)
        #expect(state.beginManual(ready: true))
        state.finish(.manual, noUpdate: true)
        #expect(!state.beginProbe(now: now, ready: true))
        state.automaticallyChecks = false
        let reopened = DailyUpdateState(defaults: defaults, context: "21", currentBuild: "21")
        #expect(!reopened.automaticallyChecks)
    }
}

@Test @MainActor
func updateHintPersistsThroughFailuresButClearsOnSuccessOrInstallation() {
    withUpdateDefaults { defaults in
        let now = Date()
        let state = DailyUpdateState(defaults: defaults, context: "20-feedA", currentBuild: "20")
        #expect(state.beginProbe(now: now, ready: true))
        state.found(build: "21", version: "0.2.6")
        state.finish(.probe, noUpdate: false)
        let reopened = DailyUpdateState(defaults: defaults, context: "20-feedA", currentBuild: "20")
        #expect(reopened.available?.build == "21")
        #expect(reopened.beginManual(ready: true))
        reopened.finish(.manual, noUpdate: false)
        #expect(reopened.available?.version == "0.2.6")
        #expect(reopened.beginManual(ready: true))
        reopened.finish(.manual, noUpdate: true)
        #expect(reopened.available == nil)
        #expect(reopened.beginManual(ready: true))
        reopened.found(build: "21", version: "0.2.6")
        reopened.finish(.manual, noUpdate: false)
        let installed = DailyUpdateState(defaults: defaults, context: "21-feedA", currentBuild: "21")
        #expect(installed.available == nil)
        #expect(installed.beginProbe(now: now, ready: true))
    }
}

@Test @MainActor
func updateHintsRejectInvalidVersionsAndChangedFeed() {
    withUpdateDefaults { defaults in
        let state = DailyUpdateState(defaults: defaults, context: "20-feedA", currentBuild: "20")
        state.found(build: "21", version: "0.2.6")
        #expect(state.available == nil)  // Unsolicited callback outside a cycle.
        #expect(state.beginManual(ready: true))
        for build in ["19", "20", "021", "-1", "1000000000", "not-a-build"] {
            state.found(build: build, version: "0.2.6")
            #expect(state.available == nil)
        }
        for version in ["", "bad\nversion", String(repeating: "x", count: 129)] {
            state.found(build: "21", version: version)
            #expect(state.available == nil)
        }
        state.found(build: "21", version: "0.2.6")
        state.finish(.manual, noUpdate: false)
        let changedFeed = DailyUpdateState(defaults: defaults, context: "20-feedB", currentBuild: "20")
        #expect(changedFeed.available == nil)
    }
}

@Test @MainActor
func automaticUpdateClockRollbackDoesNotBlockIndefinitely() {
    withUpdateDefaults { defaults in
        let state = DailyUpdateState(defaults: defaults, context: "20", currentBuild: "20")
        let future = updateDate("2036-10-07T01:00:00Z")
        let now = updateDate("2026-10-07T01:00:00Z")
        #expect(state.beginProbe(now: future, ready: true))
        state.finish(.probe, noUpdate: false)
        #expect(state.beginProbe(now: now, ready: true))
        state.finish(.probe, noUpdate: false)
        #expect(!state.beginProbe(now: now, ready: true))
    }
}
