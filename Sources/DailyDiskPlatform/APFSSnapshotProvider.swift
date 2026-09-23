import DailyDiskCore
import Foundation

struct APFSSnapshotRecord: Equatable, Sendable {
    let uuid: UUID?
    let name: String
    let createdAt: Date?
    let isPurgeable: Bool?
    let allocatedBytesEstimate: Int64?
}

enum DiskutilSnapshotParser {
    static func parse(_ data: Data) throws -> [APFSSnapshotRecord] {
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let root = propertyList as? [String: Any],
            let values = root["Snapshots"] as? [[String: Any]]
        else {
            throw APFSSnapshotError.invalidPropertyList
        }
        var identities: Set<String> = []
        return try values.map { value in
            guard let name = value["SnapshotName"] as? String, !name.isEmpty else {
                throw APFSSnapshotError.invalidPropertyList
            }
            let uuid = (value["SnapshotUUID"] as? String).flatMap(UUID.init(uuidString:))
            let identity = uuid?.uuidString ?? name
            guard identities.insert(identity).inserted else {
                throw APFSSnapshotError.duplicateSnapshot(identity)
            }
            let estimate = try estimatedBytes(value)
            return APFSSnapshotRecord(
                uuid: uuid,
                name: name,
                createdAt: dateFromSnapshotName(name),
                isPurgeable: (value["Purgeable"] as? NSNumber)?.boolValue,
                allocatedBytesEstimate: estimate
            )
        }
    }

    private static func estimatedBytes(_ value: [String: Any]) throws -> Int64? {
        for key in ["SnapshotSize", "BytesUsed", "Size"] {
            guard let raw = value[key] else { continue }
            guard let number = raw as? NSNumber,
                String(cString: number.objCType) != "c",
                number.decimalValue == Decimal(number.int64Value),
                number.int64Value >= 0
            else {
                throw APFSSnapshotError.invalidPropertyList
            }
            return number.int64Value
        }
        return nil
    }

    private static func dateFromSnapshotName(_ name: String) -> Date? {
        let prefix = "com.apple.TimeMachine."
        guard name.hasPrefix(prefix) else { return nil }
        var value = String(name.dropFirst(prefix.count))
        if value.hasSuffix(".local") { value.removeLast(".local".count) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: value)
    }
}

public struct APFSSnapshotProvider: SnapshotProviding {
    private let processRunner: any ProcessRunning
    private let diskutilURL: URL
    private let now: @Sendable () -> Date

    public init(
        processRunner: any ProcessRunning = SystemProcessRunner(),
        diskutilURL: URL = URL(fileURLWithPath: "/usr/sbin/diskutil"),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.processRunner = processRunner
        self.diskutilURL = diskutilURL
        self.now = now
    }

    public func snapshots(volume: MonitoredVolume) async throws -> [SnapshotSample] {
        guard let mountPath = volume.mountPath else {
            throw APFSSnapshotError.volumeNotMounted(volume.id)
        }
        let result = try await processRunner.run(
            ProcessRequest(
                executableURL: diskutilURL,
                arguments: ["apfs", "listSnapshots", "-plist", mountPath]
            )
        )
        let data = try result.requireSuccess(executable: diskutilURL.path)
        let sampledAt = now()
        return try DiskutilSnapshotParser.parse(data).map { record in
            try SnapshotSample(
                volumeID: volume.id,
                sampledAt: sampledAt,
                snapshotUUID: record.uuid,
                name: record.name,
                createdAt: record.createdAt,
                isPurgeable: record.isPurgeable,
                allocatedBytesEstimate: record.allocatedBytesEstimate
            )
        }
    }
}

public enum APFSSnapshotError: Error, Equatable, Sendable {
    case invalidPropertyList
    case duplicateSnapshot(String)
    case volumeNotMounted(MonitoredVolume.ID)
}
