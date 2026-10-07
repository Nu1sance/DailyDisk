import Combine
import Foundation

/// Local hints only. Sparkle must revalidate the feed before any download/install.
@MainActor
final class DailyUpdateState: ObservableObject {
    struct AvailableUpdate: Codable, Equatable {
        let build: String
        let version: String
    }

    enum Cycle { case probe, manual }
    @Published private(set) var available: AvailableUpdate?
    @Published private(set) var cycle: Cycle?
    @Published var automaticallyChecks: Bool {
        didSet { defaults.set(automaticallyChecks, forKey: Self.enabledKey) }
    }
    private let defaults: UserDefaults
    private let currentBuild: String
    private var lastAttempt: Date?
    private static let enabledKey = "DailyDisk.dailyUpdateCheckEnabled"
    private static let contextKey = "DailyDisk.updateHintContext"
    private static let hintKey = "DailyDisk.availableUpdateHint"
    private static let attemptKey = "DailyDisk.lastAutomaticUpdateAttempt"

    init(defaults: UserDefaults, context: String, currentBuild: String) {
        self.defaults = defaults
        self.currentBuild = currentBuild
        automaticallyChecks = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        if defaults.string(forKey: Self.contextKey) != context {
            defaults.removeObject(forKey: Self.hintKey)
            defaults.removeObject(forKey: Self.attemptKey)
            defaults.set(context, forKey: Self.contextKey)
        }
        lastAttempt = defaults.object(forKey: Self.attemptKey) as? Date
        if let data = defaults.data(forKey: Self.hintKey), data.count <= 4096,
            let hint = try? JSONDecoder().decode(AvailableUpdate.self, from: data),
            Self.valid(hint, currentBuild: currentBuild)
        {
            available = hint
        }
    }

    func beginProbe(now: Date, calendar: Calendar = .autoupdatingCurrent, ready: Bool) -> Bool {
        guard ready, automaticallyChecks, cycle == nil else { return false }
        if let lastAttempt, calendar.isDate(lastAttempt, inSameDayAs: now) { return false }
        // Record the attempt before networking, including failures. A clock rollback
        // to a different day permits one fresh attempt, rather than blocking for years.
        lastAttempt = now
        defaults.set(now, forKey: Self.attemptKey)
        cycle = .probe
        return true
    }

    func beginManual(ready: Bool) -> Bool {
        guard ready, cycle == nil else { return false }
        cycle = .manual
        return true
    }

    func found(build: String, version: String) {
        let hint = AvailableUpdate(build: build, version: version)
        guard cycle != nil, Self.valid(hint, currentBuild: currentBuild) else { return }
        available = hint
        defaults.set(try? JSONEncoder().encode(hint), forKey: Self.hintKey)
    }

    /// Returns true only for a manual cycle, whose presentation/installer needs cleanup.
    @discardableResult
    func finish(_ completed: Cycle, noUpdate: Bool) -> Bool {
        guard cycle == completed else { return false }
        if noUpdate {
            available = nil
            defaults.removeObject(forKey: Self.hintKey)
        }
        cycle = nil
        return completed == .manual
    }

    private static func valid(_ hint: AvailableUpdate, currentBuild: String) -> Bool {
        guard let current = Int(currentBuild), let target = Int(hint.build),
            target > current, target <= 999_999_999, String(target) == hint.build,
            !hint.version.isEmpty, hint.version.utf8.count <= 128,
            !hint.version.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }
        return true
    }
}
