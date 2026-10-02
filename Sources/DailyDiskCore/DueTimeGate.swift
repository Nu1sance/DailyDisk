import Foundation

public enum DueTimeDecision: Equatable, Sendable {
    case due(scheduledFor: Date)
    case notDue(nextScheduledAt: Date)
}

public struct DueTimeGate: Sendable {
    public let hour: Int
    public let minute: Int
    public let calendar: Calendar

    public init(hour: Int = 5, minute: Int = 0, calendar: Calendar = .current) throws {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else {
            throw DueTimeGateError.invalidTime
        }
        self.hour = hour
        self.minute = minute
        self.calendar = calendar
    }

    public static let `default` = try! DueTimeGate()

    public func decision(now: Date, lastSuccessfulAt: Date?) throws -> DueTimeDecision {
        guard
            let today = calendar.date(
                bySettingHour: hour,
                minute: minute,
                second: 0,
                of: now,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .backward
            )
        else {
            throw DueTimeGateError.cannotResolveSchedule
        }
        let todayTarget: Date
        if calendar.isDate(today, inSameDayAs: now) {
            todayTarget = today
        } else {
            guard let value = calendar.date(byAdding: .day, value: 1, to: today) else {
                throw DueTimeGateError.cannotResolveSchedule
            }
            todayTarget = value
        }

        if lastSuccessfulAt == nil {
            return .due(scheduledFor: min(now, todayTarget))
        }
        let lastSuccessfulAt = lastSuccessfulAt!
        if lastSuccessfulAt <= now, calendar.isDate(lastSuccessfulAt, inSameDayAs: now) {
            return .notDue(nextScheduledAt: try nextDay(after: todayTarget))
        }
        if now >= todayTarget {
            return lastSuccessfulAt < todayTarget
                ? .due(scheduledFor: todayTarget)
                : .notDue(nextScheduledAt: try nextDay(after: todayTarget))
        }
        guard let previousTarget = calendar.date(byAdding: .day, value: -1, to: todayTarget) else {
            throw DueTimeGateError.cannotResolveSchedule
        }
        if lastSuccessfulAt < calendar.startOfDay(for: previousTarget) {
            return .due(scheduledFor: previousTarget)
        }
        return .notDue(nextScheduledAt: todayTarget)
    }

    private func nextDay(after date: Date) throws -> Date {
        guard let value = calendar.date(byAdding: .day, value: 1, to: date) else {
            throw DueTimeGateError.cannotResolveSchedule
        }
        return value
    }
}

public enum DueTimeGateError: Error, Equatable, Sendable {
    case invalidTime
    case cannotResolveSchedule
}
