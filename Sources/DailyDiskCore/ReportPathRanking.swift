import Foundation

/// Direct path deltas never compete with their synthetic ancestor rollups.
/// A direct path can represent directory metadata; the ledger is not a file-I/O audit log.
public struct ReportPathRanking: Codable, Equatable, Sendable {
    public let growth: [RankedPathChange]
    public let release: [RankedPathChange]
    public let directoryGrowth: [RankedPathChange]
    public let directoryRelease: [RankedPathChange]
    public let growthPathCount: Int
    public let releasePathCount: Int
    public let logicalOnlyPathCount: Int
}

extension ChangeRecord {
    public var attributionPath: RelativePath? {
        if case .attributionTransfer(_, .debit) = effect { return pathBefore }
        return pathAfter ?? pathBefore
    }
}

public struct ReportPathRankingBuilder: Sendable {
    private struct Delta: Sendable {
        var logical: Int64 = 0
        var allocated: Int64 = 0
    }
    private var paths: [RelativePath: Delta] = [:]

    public init() {}

    public mutating func append(_ change: ChangeRecord) throws {
        guard change.classification == .ordinary, change.kind != .baseline, let path = change.attributionPath else {
            return
        }
        var delta = paths[path, default: Delta()]
        delta.logical = try AccountingMath.add(delta.logical, change.logicalDelta)
        delta.allocated = try AccountingMath.add(delta.allocated, change.allocatedDelta)
        paths[path] = delta
    }

    public func finish() throws -> ReportPathRanking {
        var directories: [RelativePath: Delta] = [:]
        for (path, value) in paths {
            try Task.checkCancellation()
            for ancestor in PathPolicy.ancestors(of: path) {
                var delta = directories[ancestor, default: Delta()]
                delta.logical = try AccountingMath.add(delta.logical, value.logical)
                delta.allocated = try AccountingMath.add(delta.allocated, value.allocated)
                directories[ancestor] = delta
            }
        }
        func ranked(_ values: [RelativePath: Delta], positive: Bool) -> [RankedPathChange] {
            values.filter { positive ? $0.value.allocated > 0 : $0.value.allocated < 0 }
                .map {
                    RankedPathChange(path: $0.key, allocatedDelta: $0.value.allocated, logicalDelta: $0.value.logical)
                }
                .sorted {
                    if $0.allocatedDelta != $1.allocatedDelta {
                        return positive ? $0.allocatedDelta > $1.allocatedDelta : $0.allocatedDelta < $1.allocatedDelta
                    }
                    return $0.path.bytes.lexicographicallyPrecedes($1.path.bytes)
                }.prefix(10).map { $0 }
        }
        return ReportPathRanking(
            growth: ranked(paths, positive: true), release: ranked(paths, positive: false),
            directoryGrowth: ranked(directories, positive: true),
            directoryRelease: ranked(directories, positive: false),
            growthPathCount: paths.values.filter { $0.allocated > 0 }.count,
            releasePathCount: paths.values.filter { $0.allocated < 0 }.count,
            logicalOnlyPathCount: paths.values.filter { $0.allocated == 0 && $0.logical != 0 }.count)
    }
}

extension DailyReport {
    public func replacingPathRanking(_ ranking: ReportPathRanking) throws -> DailyReport {
        try DailyReport(
            runID: runID, generatedAt: generatedAt, storageDomainID: storageDomainID,
            accounting: accounting, reconciliation: reconciliation, coverage: coverage,
            largestGrowth: ranking.growth, largestShrinkage: ranking.release,
            physicalDiagnosis: physicalDiagnosis, diagnostics: diagnostics, pathRanking: ranking)
    }
}
