import DailyDiskCore
import Foundation

/// Exact raw-byte membership. A root itself is separate from its descendant range:
/// `cache-neighbor` sorts between `cache` and `cache/child` and must not hide the latter.
struct OpaquePathIndex {
    private struct Range {
        let lower: Data
        var upper: Data
    }
    private let coversAll: Bool
    private let exact: Set<Data>
    private let ranges: [Range]

    init(_ roots: [RelativePath]) {
        coversAll = roots.contains { $0.bytes.isEmpty }
        if coversAll {
            exact = []
            ranges = []
            return
        }
        exact = Set(roots.map(\.bytes))
        let sorted = exact.map { Range(lower: $0 + Data([47]), upper: $0 + Data([48])) }
            .sorted { $0.lower.lexicographicallyPrecedes($1.lower) }
        var merged: [Range] = []
        for range in sorted {
            if let last = merged.last, !last.upper.lexicographicallyPrecedes(range.lower) {
                if last.upper.lexicographicallyPrecedes(range.upper) {
                    merged[merged.count - 1].upper = range.upper
                }
            } else {
                merged.append(range)
            }
        }
        ranges = merged
    }

    func contains(_ path: Data) -> Bool {
        if coversAll || exact.contains(path) { return true }
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = low + (high - low) / 2
            if path.lexicographicallyPrecedes(ranges[mid].lower) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low > 0 && path.lexicographicallyPrecedes(ranges[low - 1].upper)
    }
}
