import DailyDiskCore
import Foundation

struct ReportIdentity: Hashable, Sendable {
    let runID: ScanRun.ID
    let storageDomainID: StorageDomain.ID
}

extension DailyReport {
    var reportIdentity: ReportIdentity {
        ReportIdentity(runID: runID, storageDomainID: storageDomainID)
    }
}

func reversibleDisplayPath(_ path: RelativePath) -> String {
    let bytes = [UInt8](path.bytes)
    if let utf8 = String(bytes: bytes, encoding: .utf8) {
        return utf8.unicodeScalars.map { scalar in
            if scalar == "%" { return "%25" }
            if CharacterSet.controlCharacters.contains(scalar) {
                return String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
            }
            return String(scalar)
        }.joined()
    }
    return bytes.map { byte in
        if (0x20...0x7E).contains(byte), byte != UInt8(ascii: "%") {
            return String(UnicodeScalar(byte))
        }
        return String(format: "%%%02X", byte)
    }.joined()
}

enum AppScanFailure: String, Equatable, Sendable {
    case launchAgentUnavailable
    case writerBusy
    case controlChannel
    case scanFailed
    case helperStopped
}

enum AppScanState: Equatable, Sendable {
    case idle
    case requesting
    case running(ScanProgressSnapshot)
    case cancellationRequested(ScanProgressSnapshot)
    case finishing(ScanProgressSnapshot)
    case succeeded(DailyDiskRunSummary)
    case cancelled(DailyDiskRunSummary?)
    case externalWriter
    case failed(AppScanFailure)

    var isActive: Bool {
        switch self {
        case .requesting, .running, .cancellationRequested, .finishing, .externalWriter:
            true
        case .idle, .succeeded, .cancelled, .failed:
            false
        }
    }

    var progress: ScanProgressSnapshot? {
        switch self {
        case .running(let value), .cancellationRequested(let value), .finishing(let value):
            value
        default:
            nil
        }
    }
}
