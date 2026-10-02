import CSQLite
import Darwin
import Foundation

final class StableDataLease {
    private var fileDescriptor: Int32 = -1

    init(databaseURL: URL, exclusive: Bool, create: Bool) throws {
        let root = databaseURL.deletingLastPathComponent()
        let parent = root.deletingLastPathComponent()
        if create {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let lockURL = parent.appendingPathComponent(".DailyDisk.reset.lock")
        let flags = O_RDWR | O_CLOEXEC | (create ? O_CREAT : 0)
        fileDescriptor = open(lockURL.path, flags, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw SQLiteStoreError(code: errno, message: "Stable data lease is unavailable")
        }
        guard flock(fileDescriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            let code = errno
            close(fileDescriptor)
            fileDescriptor = -1
            throw SQLiteStoreError(code: code, message: "DailyDisk data is currently in use")
        }
    }

    deinit {
        if fileDescriptor >= 0 {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
    }
}

final class ProcessLease {
    private var fileDescriptor: Int32 = -1
    private let stableLease: StableDataLease

    init(databaseURL: URL) throws {
        stableLease = try StableDataLease(databaseURL: databaseURL, exclusive: false, create: true)
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockURL = databaseURL.appendingPathExtension("lock")
        fileDescriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw SQLiteStoreError(code: errno, message: "Unable to open writer lease at \(lockURL.path)")
        }
        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fileDescriptor)
            fileDescriptor = -1
            if code == EWOULDBLOCK || code == EAGAIN {
                throw WriterLeaseError.alreadyHeld
            }
            throw SQLiteStoreError(code: code, message: "Unable to acquire the DailyDisk writer lease")
        }
    }

    static func isWriterActive(databaseURL: URL) -> Bool {
        guard let probe = try? ProcessWriterProbe(databaseURL: databaseURL) else {
            return true
        }
        return probe.writerIsActive
    }

    deinit {
        if fileDescriptor >= 0 {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
    }
}

final class ProcessWriterProbe {
    private var fileDescriptor: Int32 = -1
    let writerIsActive: Bool

    init(databaseURL: URL) throws {
        let lockURL = databaseURL.appendingPathExtension("lock")
        guard FileManager.default.fileExists(atPath: lockURL.path) else {
            writerIsActive = false
            return
        }
        fileDescriptor = open(lockURL.path, O_RDONLY | O_CLOEXEC)
        guard fileDescriptor >= 0 else {
            throw SQLiteStoreError(code: errno, message: "Writer state is unavailable")
        }
        if flock(fileDescriptor, LOCK_SH | LOCK_NB) == 0 {
            writerIsActive = false
        } else if errno == EWOULDBLOCK || errno == EAGAIN {
            close(fileDescriptor)
            fileDescriptor = -1
            writerIsActive = true
        } else {
            let code = errno
            close(fileDescriptor)
            fileDescriptor = -1
            throw SQLiteStoreError(code: code, message: "Writer state is unavailable")
        }
    }

    deinit {
        if fileDescriptor >= 0 {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
    }
}

public enum WriterLeaseError: Error, Equatable, Sendable {
    case alreadyHeld
}

public struct SQLiteStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public let sql: String?

    public init(code: Int32, message: String, sql: String? = nil) {
        self.code = code
        self.message = message
        self.sql = sql
    }

    public var description: String {
        if let sql {
            return "SQLite error \(code): \(message) [\(sql)]"
        }
        return "SQLite error \(code): \(message)"
    }
}

final class ProcessReadLease {
    private var fileDescriptor: Int32 = -1
    private let stableLease: StableDataLease

    init(databaseURL: URL) throws {
        stableLease = try StableDataLease(databaseURL: databaseURL, exclusive: false, create: false)
        let lockURL = databaseURL.appendingPathExtension("lock")
        fileDescriptor = open(lockURL.path, O_RDONLY | O_CLOEXEC)
        guard fileDescriptor >= 0 else {
            throw SQLiteStoreError(code: errno, message: "Read-only lease is unavailable")
        }
        guard flock(fileDescriptor, LOCK_SH | LOCK_NB) == 0 else {
            let code = errno
            close(fileDescriptor)
            fileDescriptor = -1
            throw SQLiteStoreError(code: code, message: "DailyDisk database is currently being written")
        }
    }

    deinit {
        if fileDescriptor >= 0 {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
    }
}

/// Bounded mode checkpoints between transactions. A single atomic transaction
/// may exceed the limits; pinned readers prevent any further write transaction
/// once the hard limit is reached. No durability setting is relaxed.
public enum WALCheckpointPolicy: Sendable {
    case everyTransaction
    case bounded(softLimitBytes: Int64 = 32 * 1_024 * 1_024, hardLimitBytes: Int64 = 128 * 1_024 * 1_024)
}

final class SQLiteDatabase {
    private let checkpointPolicy: WALCheckpointPolicy
    private var handle: OpaquePointer?
    let url: URL
    let isReadOnly: Bool

    init(
        url: URL, readOnly: Bool = false, immutable: Bool = false,
        checkpointPolicy: WALCheckpointPolicy = .everyTransaction
    ) throws {
        if case .bounded(let soft, let hard) = checkpointPolicy, soft <= 0 || hard < soft {
            throw SQLiteStoreError(code: -2, message: "Invalid WAL limits")
        }
        self.checkpointPolicy = checkpointPolicy
        self.url = url
        self.isReadOnly = readOnly

        if immutable {
            let walURL = URL(fileURLWithPath: url.path + "-wal")
            let walBytes = (try? walURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard walBytes == 0 else {
                throw SQLiteStoreError(
                    code: -3,
                    message: "Read-only snapshot unavailable while WAL contains uncheckpointed data"
                )
            }
        }

        if !readOnly {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        let flags =
            readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | (immutable ? SQLITE_OPEN_URI : 0)
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let openPath = immutable ? url.absoluteString + "?immutable=1" : url.path
        let result = sqlite3_open_v2(openPath, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let error = makeError(code: result)
            sqlite3_close_v2(handle)
            handle = nil
            throw error
        }

        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA foreign_keys = ON")
        if !readOnly {
            _ = try scalarText("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            if case .bounded = checkpointPolicy { try execute("PRAGMA wal_autocheckpoint = 0") }
            // Bound the writer cache while avoiding repeated disk reads across
            // the large path/object indexes during staging and cleanup.
            try execute("PRAGMA cache_size = -65536")
            try execute("PRAGMA analysis_limit = 1000")
            try execute("PRAGMA temp_store = FILE")
            try execute("PRAGMA temp.cache_size = -8192")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    deinit {
        // SQLiteStatement holds an unowned database reference. Do not create
        // a Swift statement while this object is already deinitializing.
        if !isReadOnly {
            sqlite3_busy_timeout(handle, 0)
            _ = sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        }
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? currentMessage
            sqlite3_free(errorMessage)
            throw SQLiteStoreError(code: result, message: message, sql: sql)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw makeError(code: result, sql: sql)
        }
        return SQLiteStatement(database: self, handle: statement, sql: sql)
    }

    func withTaskCancellationProgressHandler<T>(
        instructionInterval: Int32 = 1_000,
        _ body: () throws -> T
    ) throws -> T {
        sqlite3_progress_handler(
            handle,
            instructionInterval,
            { _ in Task<Never, Never>.isCancelled ? 1 : 0 },
            nil
        )
        defer { sqlite3_progress_handler(handle, 0, nil, nil) }
        do {
            return try body()
        } catch let error as SQLiteStoreError
            where error.code == SQLITE_INTERRUPT && Task<Never, Never>.isCancelled
        {
            throw CancellationError()
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        if !isReadOnly, case .bounded(_, let hard) = checkpointPolicy, walBytes >= hard {
            // Fail BEFORE BEGIN if a reader pins a large WAL. Never report a
            // successfully committed inventory transaction as rolled back.
            try checkpointWAL()
        }
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            if !isReadOnly {
                // The transaction is already committed. Checkpoint maintenance
                // must never be reported as a rollback-capable commit failure;
                // immutable readers refuse a nonempty WAL instead.
                try? checkpointAfterTransaction()
            }
            return value
        } catch {
            try? execute("ROLLBACK")
            if !isReadOnly { try? checkpointAfterTransaction() }
            throw error
        }
    }

    var walBytes: Int64 {
        var info = stat()
        guard lstat(url.path + "-wal", &info) == 0 else { return 0 }
        return Int64(info.st_size)
    }

    private func checkpointAfterTransaction() throws {
        switch checkpointPolicy {
        case .everyTransaction:
            try checkpointWAL()
        case .bounded(let soft, _):
            guard walBytes >= soft else { return }
            var frames: Int32 = 0
            var copied: Int32 = 0
            let result = sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_PASSIVE, &frames, &copied)
            guard result == SQLITE_OK else { throw makeError(code: result) }
            if frames == copied { try checkpointWAL(waitForReaders: false) }
        }
    }

    func checkpointWAL(waitForReaders: Bool = true) throws {
        if !waitForReaders { sqlite3_busy_timeout(handle, 0) }
        defer { if !waitForReaders { sqlite3_busy_timeout(handle, 5_000) } }
        let statement = try prepare("PRAGMA wal_checkpoint(TRUNCATE)")
        guard try statement.step() else {
            throw SQLiteStoreError(code: -2, message: "WAL checkpoint returned no status")
        }
        let busy = statement.columnInt64(0)
        let logFrames = statement.columnInt64(1)
        let checkpointedFrames = statement.columnInt64(2)
        guard busy == 0, logFrames == checkpointedFrames else {
            throw SQLiteStoreError(
                code: -2,
                message: "WAL checkpoint incomplete: busy=\(busy), log=\(logFrames), checkpointed=\(checkpointedFrames)"
            )
        }
    }

    func scalarInt64(_ sql: String) throws -> Int64? {
        let statement = try prepare(sql)
        guard try statement.step() else { return nil }
        return statement.columnIsNull(0) ? nil : statement.columnInt64(0)
    }

    func scalarText(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        guard try statement.step() else { return nil }
        return statement.columnText(0)
    }

    var changes: Int { Int(sqlite3_changes(handle)) }
    var lastInsertedRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    fileprivate var currentMessage: String {
        guard let message = sqlite3_errmsg(handle) else { return "Unknown SQLite error" }
        return String(cString: message)
    }

    fileprivate func makeError(code: Int32, sql: String? = nil) -> SQLiteStoreError {
        SQLiteStoreError(code: code, message: currentMessage, sql: sql)
    }
}

final class SQLiteStatement {
    private unowned let database: SQLiteDatabase
    private var handle: OpaquePointer?
    let sql: String

    fileprivate init(database: SQLiteDatabase, handle: OpaquePointer, sql: String) {
        self.database = database
        self.handle = handle
        self.sql = sql
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func bindNull(_ index: Int32) throws {
        try check(sqlite3_bind_null(handle, index))
    }

    func bind(_ value: Int64, at index: Int32) throws {
        try check(sqlite3_bind_int64(handle, index, value))
    }

    func bind(_ value: Int32, at index: Int32) throws {
        try bind(Int64(value), at: index)
    }

    func bind(_ value: Bool, at index: Int32) throws {
        try bind(Int64(value ? 1 : 0), at: index)
    }

    func bind(_ value: Double, at index: Int32) throws {
        try check(sqlite3_bind_double(handle, index, value))
    }

    func bind(_ value: String, at index: Int32) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(handle, index, pointer, -1, sqliteTransient)
        }
        try check(result)
    }

    func bind(_ value: Data, at index: Int32) throws {
        if value.isEmpty {
            try check(sqlite3_bind_zeroblob(handle, index, 0))
            return
        }
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(handle, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
        try check(result)
    }

    func bind(_ value: String?, at index: Int32) throws {
        if let value { try bind(value, at: index) } else { try bindNull(index) }
    }

    func bind(_ value: Int64?, at index: Int32) throws {
        if let value { try bind(value, at: index) } else { try bindNull(index) }
    }

    func bind(_ value: Double?, at index: Int32) throws {
        if let value { try bind(value, at: index) } else { try bindNull(index) }
    }

    func bind(_ value: Data?, at index: Int32) throws {
        if let value { try bind(value, at: index) } else { try bindNull(index) }
    }

    /// Returns true for a row and false when the statement is complete.
    func step() throws -> Bool {
        let result = sqlite3_step(handle)
        switch result {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw database.makeError(code: result, sql: sql)
        }
    }

    func reset() throws {
        try check(sqlite3_reset(handle))
        try check(sqlite3_clear_bindings(handle))
    }

    func columnIsNull(_ index: Int32) -> Bool {
        sqlite3_column_type(handle, index) == SQLITE_NULL
    }

    func columnInt64(_ index: Int32) -> Int64 {
        sqlite3_column_int64(handle, index)
    }

    func columnDouble(_ index: Int32) -> Double {
        sqlite3_column_double(handle, index)
    }

    func columnText(_ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: pointer)
    }

    func columnData(_ index: Int32) -> Data? {
        guard !columnIsNull(index) else { return nil }
        let count = Int(sqlite3_column_bytes(handle, index))
        guard count > 0 else { return Data() }
        guard let pointer = sqlite3_column_blob(handle, index) else { return nil }
        return Data(bytes: pointer, count: count)
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw database.makeError(code: result, sql: sql)
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
