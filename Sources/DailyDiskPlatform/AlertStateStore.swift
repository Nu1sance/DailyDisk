import DailyDiskCore
import Foundation

public actor LocalAlertStateStore: AlertStatePersisting {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DailyDisk/AlertState.json")
    ) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func state(storageDomainID: StorageDomain.ID) async throws -> AlertState? {
        try load()[storageDomainID.rawValue]
    }

    public func save(_ state: AlertState, storageDomainID: StorageDomain.ID) async throws {
        var values = try load()
        values[storageDomainID.rawValue] = state
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try encoder.encode(values).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func load() throws -> [String: AlertState] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        return try decoder.decode([String: AlertState].self, from: Data(contentsOf: fileURL))
    }
}
