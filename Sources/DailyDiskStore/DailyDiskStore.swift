import CSQLite
import DailyDiskCore

/// Namespace for the persistence layer. The concrete SQLite store is added in
/// the database implementation phase.
public enum DailyDiskStoreModule: Sendable {
    public static var sqliteVersion: String {
        String(cString: sqlite3_libversion())
    }
}
