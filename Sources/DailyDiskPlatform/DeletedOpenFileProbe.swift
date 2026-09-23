import DailyDiskCore
import Foundation

public enum LsofDeletedFileParser {
    public static func parse(_ data: Data) throws -> [DeletedOpenFile] {
        var processID: Int32?
        var command = ""
        var fileDescriptor: String?
        var device: String?
        var inode: String?
        var size: Int64?
        var linkCount: Int64?
        var fileType: String?
        var path: String?
        var result: [DeletedOpenFile] = []

        func flushFile() throws {
            guard let processID,
                let fileDescriptor,
                let device,
                let inode,
                let size,
                let linkCount,
                linkCount == 0,
                fileType == "REG",
                let path
            else { return }
            result.append(
                try DeletedOpenFile(
                    processID: processID,
                    command: command,
                    fileDescriptor: fileDescriptor,
                    device: device,
                    inode: inode,
                    logicalBytes: size,
                    path: path
                )
            )
        }

        for rawToken in data.split(separator: 0, omittingEmptySubsequences: true) {
            var token = Data(rawToken)
            while token.first == UInt8(ascii: "\n") { token.removeFirst() }
            guard let field = token.first else { continue }
            let value = String(decoding: token.dropFirst(), as: UTF8.self)
            switch field {
            case UInt8(ascii: "p"):
                try flushFile()
                fileDescriptor = nil
                device = nil
                inode = nil
                size = nil
                linkCount = nil
                fileType = nil
                path = nil
                processID = Int32(value)
            case UInt8(ascii: "c"):
                command = value
            case UInt8(ascii: "f"):
                try flushFile()
                fileDescriptor = value
                device = nil
                inode = nil
                size = nil
                linkCount = nil
                fileType = nil
                path = nil
            case UInt8(ascii: "D"):
                device = value
            case UInt8(ascii: "i"):
                inode = value
            case UInt8(ascii: "s"):
                size = Int64(value)
            case UInt8(ascii: "k"):
                linkCount = Int64(value.trimmingCharacters(in: .whitespaces))
            case UInt8(ascii: "t"):
                fileType = value
            case UInt8(ascii: "n"):
                path = value
            default:
                continue
            }
        }
        try flushFile()
        return result
    }
}

public struct DeletedOpenFileProbe: DeletedOpenFileProbing {
    private let processRunner: any ProcessRunning
    private let lsofURL: URL

    public init(
        processRunner: any ProcessRunning = SystemProcessRunner(),
        lsofURL: URL = URL(fileURLWithPath: "/usr/sbin/lsof")
    ) {
        self.processRunner = processRunner
        self.lsofURL = lsofURL
    }

    public func deletedOpenFiles() async throws -> [DeletedOpenFile] {
        let result = try await processRunner.run(
            ProcessRequest(
                executableURL: lsofURL,
                arguments: ["-nP", "+L1", "-F0pcfDikstn"],
                timeoutSeconds: 30
            )
        )
        if result.terminationStatus == 1,
            result.standardOutput.isEmpty,
            result.standardError.isEmpty
        {
            return []
        }
        let data = try result.requireSuccess(executable: lsofURL.path)
        return try LsofDeletedFileParser.parse(data)
    }
}
