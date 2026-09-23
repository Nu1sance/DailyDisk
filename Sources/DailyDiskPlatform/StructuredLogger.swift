import CryptoKit
import Foundation
import OSLog

public enum StructuredLogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

public enum PublicLogValue: Sendable {
    case integer(Int64)
    case bytes(Int64)
    case boolean(Bool)
    case identifier(String)

    fileprivate var rendered: String? {
        switch self {
        case .integer(let value), .bytes(let value):
            String(value)
        case .boolean(let value):
            value ? "true" : "false"
        case .identifier(let value):
            value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:")).contains($0)
            } ? value : nil
        }
    }
}

public struct StructuredLogEntry: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let level: StructuredLogLevel
    public let event: String
    public let runID: UUID?
    public let metadata: [String: String]

    public init(
        timestamp: Date,
        level: StructuredLogLevel,
        event: String,
        runID: UUID?,
        metadata: [String: String]
    ) {
        self.timestamp = timestamp
        self.level = level
        self.event = event
        self.runID = runID
        self.metadata = metadata
    }
}

public actor StructuredLogger {
    public static var defaultLogDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DailyDisk/Logs", isDirectory: true)
    }

    private let logger = Logger(subsystem: "io.github.xiuyuwu.DailyDisk", category: "operations")
    private let directory: URL
    private let maximumBytes: Int64
    private let retainedFiles: Int
    private let encoder: JSONEncoder

    public init(
        directory: URL = StructuredLogger.defaultLogDirectory,
        maximumBytes: Int64 = 5 * 1_024 * 1_024,
        retainedFiles: Int = 5
    ) throws {
        guard maximumBytes > 0, retainedFiles > 0 else {
            throw StructuredLoggerError.invalidConfiguration
        }
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.retainedFiles = retainedFiles
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public func log(
        level: StructuredLogLevel,
        event: String,
        runID: UUID? = nil,
        publicMetadata: [String: PublicLogValue] = [:],
        sensitiveMetadata: [String: String] = [:]
    ) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !event.isEmpty, event.unicodeScalars.allSatisfy(allowed.contains) else {
            throw StructuredLoggerError.invalidEventIdentifier
        }
        var metadata: [String: String] = [:]
        for (key, value) in publicMetadata {
            guard key.unicodeScalars.allSatisfy(allowed.contains),
                let rendered = value.rendered
            else {
                throw StructuredLoggerError.invalidPublicMetadata
            }
            metadata[key] = rendered
        }
        for (key, value) in sensitiveMetadata {
            guard key.unicodeScalars.allSatisfy(allowed.contains) else {
                throw StructuredLoggerError.invalidPublicMetadata
            }
            metadata[key] = redacted(value)
        }

        let entry = StructuredLogEntry(
            timestamp: Date(),
            level: level,
            event: event,
            runID: runID,
            metadata: metadata
        )
        let data = try encoder.encode(entry) + Data([0x0A])
        guard Int64(data.count) <= maximumBytes else {
            throw StructuredLoggerError.entryTooLarge
        }
        try rotateIfNeeded(adding: Int64(data.count))
        let fileURL = directory.appendingPathComponent("operations.jsonl")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            _ = FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()

        switch level {
        case .debug: logger.debug("\(event, privacy: .public)")
        case .info: logger.info("\(event, privacy: .public)")
        case .warning: logger.warning("\(event, privacy: .public)")
        case .error: logger.error("\(event, privacy: .public)")
        }
    }

    private func redacted(_ value: String) -> String {
        "sha256:"
            + SHA256.hash(data: Data(value.utf8)).map {
                String(format: "%02x", $0)
            }.joined()
    }

    private func rotateIfNeeded(adding bytes: Int64) throws {
        let active = directory.appendingPathComponent("operations.jsonl")
        let currentSize = ((try? active.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard Int64(currentSize) + bytes > maximumBytes else { return }

        if retainedFiles > 1 {
            for index in stride(from: retainedFiles - 1, through: 1, by: -1) {
                let destination = directory.appendingPathComponent("operations.\(index).jsonl")
                let source =
                    index == 1
                    ? active
                    : directory.appendingPathComponent("operations.\(index - 1).jsonl")
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.moveItem(at: source, to: destination)
                }
            }
        } else if FileManager.default.fileExists(atPath: active.path) {
            try FileManager.default.removeItem(at: active)
        }
    }
}

public enum StructuredLoggerError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidEventIdentifier
    case entryTooLarge
    case invalidPublicMetadata
}
