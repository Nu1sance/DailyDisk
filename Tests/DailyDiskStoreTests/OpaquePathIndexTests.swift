import DailyDiskCore
import Foundation
import Testing

@testable import DailyDiskStore

@Test("Opaque index matches raw prefix semantics for nested, adjacent and non-UTF8 paths")
func opaqueIndexMatchesOracle() throws {
    let names = ["cache", "cache-neighbor", "cache.more", "cache0", "cache/child", "cache/child/deep"]
    var roots = names.map { Data($0.utf8) }
    roots += [Data([0xFF]), Data([0xFF, 47, 0xFE]), Data("cache".utf8)]
    let candidates =
        roots.flatMap { [$0, $0 + Data([47, 120]), $0 + Data([48]), $0 + Data([46, 120])] }
        + [Data(), Data("other".utf8), Data("cache/another".utf8)]
    for bytes in [roots, Array(roots.reversed()), [], [Data()]] {
        let index = OpaquePathIndex(try bytes.map { try RelativePath(validating: $0) })
        for path in candidates {
            let expected = bytes.contains { $0.isEmpty || path == $0 || path.starts(with: $0 + Data([47])) }
            #expect(index.contains(path) == expected)
        }
    }
}

@Test("Opaque index retains coverage across thousands of disjoint directory ranges")
func opaqueIndexWideRoots() throws {
    let roots = try (0..<4096).map { try RelativePath(validating: "dir-\($0)") }
    let index = OpaquePathIndex(roots)
    for root in roots {
        #expect(index.contains(root.bytes))
        #expect(index.contains(root.bytes + Data("/nested/file".utf8)))
        #expect(!index.contains(root.bytes + Data(".neighbor/file".utf8)))
    }
}
