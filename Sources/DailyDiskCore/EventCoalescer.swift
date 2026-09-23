import Foundation

public enum EventCoalescer {
    /// Coalesces repeated notifications for the same volume-relative path.
    /// FSEvents is already coalescing and is not an audit log, so callers must
    /// inspect current metadata; merged flags describe every reason observed.
    public static func coalesce(_ events: [FileSystemEvent]) -> [FileSystemEvent] {
        struct Key: Hashable {
            let volumeID: MonitoredVolume.ID
            let path: RelativePath
        }

        var values: [Key: FileSystemEvent] = [:]
        for event in events {
            let key = Key(volumeID: event.volumeID, path: event.path)
            if let existing = values[key] {
                values[key] = FileSystemEvent(
                    id: max(existing.id, event.id),
                    volumeID: event.volumeID,
                    path: event.path,
                    flags: existing.flags.union(event.flags)
                )
            } else {
                values[key] = event
            }
        }
        return values.values.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            if lhs.volumeID != rhs.volumeID {
                return lhs.volumeID.rawValue < rhs.volumeID.rawValue
            }
            return lhs.path.bytes.lexicographicallyPrecedes(rhs.path.bytes)
        }
    }

    public static func batches(
        _ events: [FileSystemEvent],
        maximumCount: Int = EventBatch.maximumEventCount
    ) throws -> [EventBatch] {
        guard maximumCount > 0, maximumCount <= EventBatch.maximumEventCount else {
            throw ModelValidationError.eventBatchTooLarge
        }
        let coalesced = coalesce(events)
        var result: [EventBatch] = []
        result.reserveCapacity((coalesced.count + maximumCount - 1) / maximumCount)
        var index = 0
        while index < coalesced.count {
            let end = min(index + maximumCount, coalesced.count)
            result.append(try EventBatch(events: Array(coalesced[index..<end])))
            index = end
        }
        return result
    }
}
