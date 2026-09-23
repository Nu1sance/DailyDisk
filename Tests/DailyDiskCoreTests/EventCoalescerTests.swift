import Foundation
import Testing

@testable import DailyDiskCore

private let eventVolume = MonitoredVolume.ID("event-volume")

private func event(_ id: UInt64, _ path: String, _ flags: FileSystemEventFlags) throws -> FileSystemEvent {
    FileSystemEvent(
        id: id,
        volumeID: eventVolume,
        path: try RelativePath(validating: path),
        flags: flags
    )
}

@Test("Repeated path events merge flags and retain the highest event ID")
func repeatedEventsCoalesce() throws {
    let values = [
        try event(10, "Users/alice/file", [.created, .isFile]),
        try event(12, "Users/alice/file", [.modified, .isFile]),
        try event(11, "Users/alice/other", [.removed, .isFile]),
    ]

    let coalesced = EventCoalescer.coalesce(values)
    #expect(coalesced.count == 2)
    let file = try #require(coalesced.first { $0.path.displayString == "Users/alice/file" })
    #expect(file.id == 12)
    #expect(file.flags.contains(.created))
    #expect(file.flags.contains(.modified))
    #expect(file.flags.contains(.isFile))
}

@Test("Rename endpoints remain separate paths")
func renameEndpointsRemainSeparate() throws {
    let values = [
        try event(20, "old", [.renamed, .isFile]),
        try event(21, "new", [.renamed, .isFile]),
    ]
    #expect(EventCoalescer.coalesce(values).count == 2)
}

@Test("Coalesced output is split into validated bounded batches")
func eventBatchesAreBounded() throws {
    let values = try (0..<11).map {
        try event(UInt64($0 + 1), "path-\($0)", [.modified, .isFile])
    }
    let batches = try EventCoalescer.batches(values, maximumCount: 4)

    #expect(batches.map { $0.events.count } == [4, 4, 3])
    #expect(batches.flatMap(\.events).count == 11)
}

@Test("Item-event helpers distinguish stream-control flags")
func itemEventHelpers() throws {
    #expect(try event(1, "file", [.created, .isFile]).isItemEvent)
    #expect(try !event(0, "", .historyDone).isItemEvent)
    #expect(try event(2, "directory", .mustScanSubdirectories).requiresSubtreeScan)
    #expect(try event(3, "", .kernelDropped).requiresFullScan)
}
