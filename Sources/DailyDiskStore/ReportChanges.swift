import DailyDiskCore

public enum ReportChangeFilter: String, CaseIterable, Sendable {
    case all, growth, release, logicalOnly
}

public struct ReportChangeEntry: Sendable, Identifiable {
    public let id: Int64
    public let change: ChangeRecord
}

public struct ReportChangePage: Sendable {
    public let entries: [ReportChangeEntry]
    public let nextSequence: Int64?

    public init(entries: [ReportChangeEntry], nextSequence: Int64?) {
        self.entries = entries
        self.nextSequence = nextSequence
    }
}
