import DailyDiskCore
import Foundation
import Testing

@testable import DailyDiskPlatform

@Test("Mailbox separates historical and live events at HistoryDone")
func mailboxSeparatesPhases() throws {
    let volumeID = MonitoredVolume.ID("mailbox")
    let mailbox = FSEventMailbox(volumeID: volumeID, previousEventID: 10, maximumBufferedEvents: 16)
    mailbox.append(
        pathBytes: Data("/before".utf8),
        flagsRawValue: FileSystemEventFlags.created.rawValue,
        eventID: 11
    )
    mailbox.append(
        pathBytes: Data("/".utf8),
        flagsRawValue: FileSystemEventFlags.historyDone.rawValue,
        eventID: 0
    )
    mailbox.append(
        pathBytes: Data("/after".utf8),
        flagsRawValue: FileSystemEventFlags.modified.rawValue,
        eventID: 12
    )

    let boundary = try #require(mailbox.historyBoundarySequence)
    #expect(mailbox.drainHistorical(maximumCount: 10).map(\.path.displayString) == ["before"])
    #expect(mailbox.drainLive(throughSequence: boundary, maximumCount: 10).isEmpty)
    #expect(
        mailbox.drainLive(throughSequence: mailbox.latestSequence, maximumCount: 10).map(\.path.displayString) == [
            "after"
        ])
}

@Test("Synthetic SinceNow boundary routes the first callback to live events")
func mailboxSinceNowBoundary() {
    let mailbox = FSEventMailbox(
        volumeID: MonitoredVolume.ID("mailbox"),
        previousEventID: nil,
        maximumBufferedEvents: 10,
        historyStartsComplete: true
    )
    mailbox.append(
        pathBytes: Data("/live".utf8),
        flagsRawValue: FileSystemEventFlags.created.rawValue,
        eventID: 1
    )

    #expect(mailbox.historyBoundarySequence == 0)
    #expect(mailbox.drainHistorical(maximumCount: 10).isEmpty)
    #expect(mailbox.drainLive(throughSequence: mailbox.latestSequence, maximumCount: 10).count == 1)
}

@Test("Historical trust does not poison a later live-flush phase")
func mailboxAssessmentsArePhaseScoped() throws {
    let mailbox = FSEventMailbox(
        volumeID: MonitoredVolume.ID("mailbox"),
        previousEventID: 10,
        maximumBufferedEvents: 10
    )
    mailbox.append(
        pathBytes: Data("/lost".utf8),
        flagsRawValue: FileSystemEventFlags.mustScanSubdirectories.rawValue,
        eventID: 11
    )
    mailbox.append(
        pathBytes: Data("/".utf8),
        flagsRawValue: FileSystemEventFlags.historyDone.rawValue,
        eventID: 0
    )
    let boundary = try #require(mailbox.historyBoundarySequence)
    mailbox.append(
        pathBytes: Data("/clean".utf8),
        flagsRawValue: FileSystemEventFlags.modified.rawValue,
        eventID: 12
    )

    #expect(mailbox.assessment(throughSequence: boundary).trust == .subtreeRescanRequired)
    #expect(
        mailbox.assessment(afterSequence: boundary, throughSequence: mailbox.latestSequence).trust == .trusted
    )
}

@Test("Mailbox escalates native loss flags and its own bounded-buffer overflow")
func mailboxEscalatesLoss() {
    let mailbox = FSEventMailbox(
        volumeID: MonitoredVolume.ID("mailbox"),
        previousEventID: 100,
        maximumBufferedEvents: 1
    )
    mailbox.append(
        pathBytes: Data("/first".utf8),
        flagsRawValue: FileSystemEventFlags.modified.rawValue,
        eventID: 101
    )
    mailbox.append(
        pathBytes: Data("/second".utf8),
        flagsRawValue: FileSystemEventFlags.modified.rawValue,
        eventID: 102
    )
    #expect(mailbox.assessment(throughSequence: mailbox.latestSequence).trust == .fullScanRequired)

    let dropped = FSEventMailbox(
        volumeID: MonitoredVolume.ID("mailbox"),
        previousEventID: 100,
        maximumBufferedEvents: 10
    )
    dropped.append(
        pathBytes: Data("/".utf8),
        flagsRawValue: FileSystemEventFlags.kernelDropped.rawValue,
        eventID: 101
    )
    #expect(dropped.assessment(throughSequence: dropped.latestSequence).trust == .fullScanRequired)
}

@Test("Mailbox rejects paths that are not safe volume-relative paths")
func mailboxRejectsUnsafePaths() {
    let mailbox = FSEventMailbox(
        volumeID: MonitoredVolume.ID("mailbox"),
        previousEventID: nil,
        maximumBufferedEvents: 10
    )
    mailbox.append(
        pathBytes: Data("/a/../escape".utf8),
        flagsRawValue: FileSystemEventFlags.modified.rawValue,
        eventID: 1
    )

    #expect(mailbox.drainHistorical(maximumCount: 10).isEmpty)
    #expect(mailbox.assessment(throughSequence: mailbox.latestSequence).trust == .fullScanRequired)
}

@Test("HistoryDone sentinel IDs do not advance or regress the item cursor")
func historySentinelIsNotAnItemCursor() {
    for sentinelID: UInt64 in [1, 9999] {
        let mailbox = FSEventMailbox(
            volumeID: MonitoredVolume.ID("mailbox"), previousEventID: 10, maximumBufferedEvents: 10)
        mailbox.append(
            pathBytes: Data("/before".utf8), flagsRawValue: FileSystemEventFlags.modified.rawValue, eventID: 11)
        mailbox.append(
            pathBytes: Data("/".utf8), flagsRawValue: FileSystemEventFlags.historyDone.rawValue, eventID: sentinelID)
        mailbox.append(
            pathBytes: Data("/after".utf8), flagsRawValue: FileSystemEventFlags.modified.rawValue, eventID: 12)
        #expect(mailbox.latestObservedEventID == 12)
        #expect(mailbox.assessment(throughSequence: mailbox.latestSequence).trust == .trusted)
    }
}

@Test("Unsorted callback batches retain every event; committed cursor regressions remain unsafe")
func unsortedCallbackIsFullyRetained() {
    let mailbox = FSEventMailbox(
        volumeID: MonitoredVolume.ID("mailbox"), previousEventID: 10, maximumBufferedEvents: 20)
    for ids: [UInt64] in [[18, 11, 14], [17, 12]] {
        mailbox.appendBatch(count: ids.count) { i in
            (Data("/item-\(ids[i])".utf8), FileSystemEventFlags.modified.rawValue, ids[i])
        }
    }
    #expect(mailbox.latestSequence == 5)
    #expect(mailbox.latestObservedEventID == 18)
    #expect(mailbox.assessment(throughSequence: mailbox.latestSequence).trust == .trusted)
    #expect(mailbox.drainHistorical(maximumCount: 20).map(\.id) == [18, 11, 14, 17, 12])
    mailbox.append(pathBytes: Data("/stale".utf8), flagsRawValue: FileSystemEventFlags.modified.rawValue, eventID: 9)
    #expect(mailbox.assessment(throughSequence: mailbox.latestSequence).trust == .fullScanRequired)
}
