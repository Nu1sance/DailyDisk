import Foundation

/// Bounded recent-report inbox. No paths, commands or user-controlled messages.
public struct CompletionNotificationState: Codable, Equatable, Sendable {
    public static let capacity = 1024
    public internal(set) var version = 1
    public var enabled = true
    public var sound = false
    public var badges = true
    public internal(set) var known: [UUID] = []
    public internal(set) var unread: [UUID] = []
    public internal(set) var read: [UUID] = []
    public internal(set) var pending: [UUID] = []
    public internal(set) var lastDelivery: NotificationDeliveryStatus = .none
    public var badgeCount: Int { badges ? unread.count : 0 }

    public init() {}

    mutating func enqueue(_ ids: [UUID]) {
        for id in ids where !known.contains(id) {
            known.append(id)
            pending.append(id)
            if !read.contains(id) { unread.append(id) }
        }
        known = Array(known.suffix(Self.capacity))
        let retained = Set(known)
        pending = Array(pending.filter { retained.contains($0) }.suffix(1))
        unread = unread.filter { retained.contains($0) }
    }

    mutating func markRead(_ id: UUID) {
        unread.removeAll { $0 == id }
        if !read.contains(id) { read.append(id) }
        read = Array(read.suffix(Self.capacity))
    }

    func validate() throws {
        guard version == 1 else { throw RunControlStoreError.unexpectedJSONShape }
        for values in [known, unread, read, pending] {
            guard values.count <= Self.capacity, Set(values).count == values.count else {
                throw RunControlStoreError.unexpectedJSONShape
            }
        }
        guard Set(unread).isSubset(of: Set(known)), Set(pending).isSubset(of: Set(known)),
            Set(unread).isDisjoint(with: Set(read))
        else {
            throw RunControlStoreError.unexpectedJSONShape
        }
    }
}

public enum NotificationDeliveryStatus: String, Codable, Sendable {
    case none, submitted, unavailable, disabled
}
