import DailyDiskCore
import Foundation
import Testing

@testable import DailyDiskApp

private func growth(_ path: String, _ bytes: Int64) throws -> RankedPathChange {
    RankedPathChange(path: try RelativePath(validating: path), allocatedDelta: bytes, logicalDelta: bytes)
}

@Test("Growth chart excludes overlapping ancestors, negative changes and duplicate paths")
func growthChartDisjointSources() throws {
    let model = GrowthBreakdown(ranking: [
        try growth("private", 100), try growth("private/var", 100),
        try growth("private/var/log", 60), try growth("private/var/log", 60),
        try growth("private/various", 40), try growth("deleted", -200), try growth("zero", 0),
    ])
    #expect(model.sources.map(\.path.displayString) == ["private/var/log", "private/various"])
    #expect(model.total == 100)
    #expect(model.fraction(at: 0) == 0.6)
    #expect(model.start(at: 1) == 0.6)
}

@Test("Growth chart denominator covers only its displayed subset and does not overflow Int64")
func growthChartSubsetAndLargeValues() throws {
    let model = GrowthBreakdown(ranking: try (0..<7).map { try growth("file-\($0)", Int64.max) })
    #expect(model.sources.count == 5)
    #expect(model.total.isFinite)
    #expect(model.fraction(at: 0) == 0.2)
    let empty = GrowthBreakdown(ranking: [])
    #expect(empty.sources.isEmpty)
    #expect(empty.total == 0)
}

@Test("System path descriptions respect path-component boundaries")
func systemSourceDescriptions() throws {
    #expect(sourceDescription(try RelativePath(validating: "private")) == "macOS 系统数据目录")
    #expect(sourceDescription(try RelativePath(validating: "private/var/db/diagnostics/Signpost")) == "系统诊断日志")
    #expect(sourceDescription(try RelativePath(validating: "private/var/db/diagnostics-other")) == nil)
}
