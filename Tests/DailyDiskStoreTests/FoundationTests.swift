import Testing

@testable import DailyDiskStore

@Test("System SQLite is linked")
func systemSQLiteIsLinked() {
    #expect(!DailyDiskStoreModule.sqliteVersion.isEmpty)
}
