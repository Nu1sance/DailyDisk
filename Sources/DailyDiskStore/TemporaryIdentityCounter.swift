import DailyDiskCore
import Foundation

/// Disk-backed exact identity counter used by full scans so memory does not
/// grow with the number of filesystem objects.
public final class TemporaryIdentityCounter: @unchecked Sendable {
    private let directory: URL
    private var database: SQLiteDatabase?
    private var insert: SQLiteStatement?
    public private(set) var count: UInt64 = 0

    public init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyDisk.IdentityCounter.\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("identities.sqlite")
        let database = try SQLiteDatabase(url: url)
        self.database = database
        try database.execute(
            """
            CREATE TABLE identities (
                volume_id TEXT NOT NULL,
                device_id INTEGER NOT NULL,
                inode INTEGER NOT NULL,
                PRIMARY KEY (volume_id, device_id, inode)
            ) WITHOUT ROWID;
            BEGIN IMMEDIATE;
            """
        )
        insert = try database.prepare(
            "INSERT OR IGNORE INTO identities(volume_id, device_id, inode) VALUES (?, ?, ?)"
        )
    }

    deinit {
        insert = nil
        try? database?.execute("COMMIT")
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    public func register(_ identity: FileIdentity) throws {
        guard let database, let insert else { return }
        try insert.reset()
        try insert.bind(identity.volumeID.rawValue, at: 1)
        try insert.bind(Int64(bitPattern: identity.deviceID), at: 2)
        try insert.bind(Int64(bitPattern: identity.inode), at: 3)
        _ = try insert.step()
        if database.changes == 1 {
            let (next, overflow) = count.addingReportingOverflow(1)
            guard !overflow else {
                throw AccountingError.overflow(operation: "temporary identity count + 1")
            }
            count = next
        }
    }
}
