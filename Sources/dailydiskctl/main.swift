import DailyDiskCore
import DailyDiskStore
import Darwin
import Foundation

@main
struct DailyDiskCLI {
    static func main() async {
        do {
            let invocation = try Invocation(arguments: Array(CommandLine.arguments.dropFirst()))
            if invocation.command == "version" {
                print(DailyDiskProduct.version)
                return
            }
            if invocation.command == "build-number" {
                print(DailyDiskProduct.installedBuildNumber)
                return
            }
            if invocation.command == "minimum-system-version" {
                print(DailyDiskProduct.minimumMacOSVersion)
                return
            }
            if invocation.command == "sqlite-version" {
                print(DailyDiskStoreModule.sqliteVersion)
                return
            }
            if invocation.command == "help" {
                print(Invocation.help)
                return
            }

            let store = try SQLiteReportStore(
                databaseURL: invocation.databaseURL,
                strictReadOnly: true
            )
            switch invocation.command {
            case "status":
                let values = try await store.volumeStatuses()
                if values.isEmpty {
                    print("No monitored volumes have been registered.")
                }
                for value in values {
                    print("\(value.name) [\(value.role), \(value.inventoryMode)]")
                    if invocation.includePaths {
                        print("  mount: \(value.mountPath ?? "unmounted")")
                    }
                    print("  objects: \(value.indexedObjectCount)")
                    print("  event ID: \(value.lastEventID.map(String.init) ?? "none")")
                    print("  last full: \(value.lastFullAt?.formatted(.iso8601) ?? "never")")
                    print("  last incremental: \(value.lastIncrementalAt?.formatted(.iso8601) ?? "never")")
                }
            case "history":
                let reports = try await store.recentReports(limit: invocation.limit)
                if reports.isEmpty { print("No reports are available.") }
                for report in reports {
                    print(
                        "\(report.generatedAt.formatted(.iso8601))  "
                            + "run=\(report.runID.rawValue.uuidString)  "
                            + "domain=\(report.storageDomainID.rawValue)  "
                            + "physical=\(DiagnosticFormatter.optionalBytes(report.accounting.physicalUsedDelta))  "
                            + "correction=\(DiagnosticFormatter.bytes(report.accounting.reconciliationCorrection))"
                    )
                }
            case "report":
                let report: DailyReport?
                if let runID = invocation.runID, let domainID = invocation.domainID {
                    report = try await store.report(runID: runID, storageDomainID: domainID)
                } else if let domainID = invocation.domainID {
                    report = try await store.reportHistory(for: domainID, limit: 1).first
                } else if let runID = invocation.runID {
                    report = try await store.report(runID: runID)
                } else {
                    report = try await store.recentReports(limit: 1).first
                }
                guard let report else { throw CLIError.noReports }
                if invocation.json {
                    print(String(decoding: try jsonEncoder.encode(report), as: UTF8.self))
                } else {
                    print(DiagnosticFormatter.reportSummary(report))
                    if invocation.includePaths {
                        print("Largest growth paths:")
                        for value in report.largestGrowth {
                            print("  \(value.path.displayString)  \(DiagnosticFormatter.bytes(value.allocatedDelta))")
                        }
                        print("Largest shrinkage paths:")
                        for value in report.largestShrinkage {
                            print("  \(value.path.displayString)  \(DiagnosticFormatter.bytes(value.allocatedDelta))")
                        }
                    }
                }
            case "verify":
                let verification = try await store.verify()
                print(String(decoding: try jsonEncoder.encode(verification), as: UTF8.self))
                print("healthy: \(verification.isHealthy)")
                if !verification.isHealthy { exit(2) }
            case "diagnostics":
                let diagnostics = try await store.diagnostics()
                print(String(decoding: try jsonEncoder.encode(diagnostics), as: UTF8.self))
            default:
                throw CLIError.unknownCommand(invocation.command)
            }
        } catch {
            FileHandle.standardError.write(Data("dailydiskctl: \(error)\n".utf8))
            if case CLIError.noReports = error { exit(66) }
            if error is CLIError { exit(64) }
            if let sqlite = error as? SQLiteStoreError, sqlite.code == 14 { exit(66) }
            exit(65)
        }
    }

    private static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private struct Invocation {
    let command: String
    let databaseURL: URL
    let limit: Int
    let json: Bool
    let includePaths: Bool
    let runID: ScanRun.ID?
    let domainID: StorageDomain.ID?

    init(arguments: [String]) throws {
        var values = arguments
        var databaseURL = SQLiteInventoryStore.defaultDatabaseURL
        var limit = 30
        var json = false
        var includePaths = false
        var runID: ScanRun.ID?
        var domainID: StorageDomain.ID?
        var positionals: [String] = []
        var usedOptions: Set<String> = []

        while !values.isEmpty {
            let value = values.removeFirst()
            switch value {
            case "--database", "--limit", "--run", "--domain":
                guard !values.isEmpty, !values[0].hasPrefix("-") else {
                    throw CLIError.missingOptionValue(value)
                }
                let optionValue = values.removeFirst()
                usedOptions.insert(value)
                switch value {
                case "--database": databaseURL = URL(fileURLWithPath: optionValue)
                case "--limit":
                    guard let parsed = Int(optionValue), parsed > 0 else { throw CLIError.invalidLimit }
                    limit = parsed
                case "--run":
                    guard let uuid = UUID(uuidString: optionValue) else { throw CLIError.invalidRunID }
                    runID = ScanRun.ID(uuid)
                case "--domain": domainID = StorageDomain.ID(optionValue)
                default: break
                }
            case "--json":
                json = true
                usedOptions.insert(value)
            case "--include-paths":
                includePaths = true
                usedOptions.insert(value)
            case "--help", "-h":
                positionals = ["help"]
            default:
                if value.hasPrefix("-") { throw CLIError.unknownOption(value) }
                positionals.append(value)
            }
        }
        guard positionals.count <= 1 else { throw CLIError.tooManyArguments }
        let command = positionals.first ?? "help"
        let known = [
            "help", "version", "build-number", "minimum-system-version", "sqlite-version",
            "status", "history", "report", "verify", "diagnostics",
        ]
        guard known.contains(command) else { throw CLIError.unknownCommand(command) }
        let allowed: Set<String> =
            switch command {
            case "status": ["--database", "--include-paths"]
            case "history": ["--database", "--limit"]
            case "report": ["--database", "--json", "--include-paths", "--run", "--domain"]
            case "verify", "diagnostics": ["--database"]
            default: []
            }
        guard usedOptions.isSubset(of: allowed) else {
            throw CLIError.unsupportedOptions(command)
        }
        if json, !includePaths { throw CLIError.jsonRequiresPathConsent }
        self.command = command
        self.databaseURL = databaseURL
        self.limit = limit
        self.json = json
        self.includePaths = includePaths
        self.runID = runID
        self.domainID = domainID
    }

    static let help = """
        dailydiskctl \(DailyDiskProduct.version)

        Read-only diagnostics for DailyDisk.

        Usage:
          dailydiskctl status [--include-paths] [--database PATH]
          dailydiskctl history [--limit N] [--database PATH]
          dailydiskctl report [--run UUID] [--domain ID] [--include-paths] [--json]
          dailydiskctl verify [--database PATH]
          dailydiskctl diagnostics [--database PATH]
          dailydiskctl version
          dailydiskctl build-number
          dailydiskctl minimum-system-version
          dailydiskctl sqlite-version

        Paths are omitted by default. --json includes reversible path bytes and
        therefore requires explicit --include-paths consent.
        """
}

private enum CLIError: Error, CustomStringConvertible {
    case unknownCommand(String)
    case unknownOption(String)
    case missingOptionValue(String)
    case invalidLimit
    case invalidRunID
    case unsupportedOptions(String)
    case jsonRequiresPathConsent
    case tooManyArguments
    case noReports

    var description: String {
        switch self {
        case .unknownCommand(let value): "unknown command '\(value)'"
        case .unknownOption(let value): "unknown option '\(value)'"
        case .missingOptionValue(let value): "missing value for \(value)"
        case .invalidLimit: "--limit must be a positive integer"
        case .invalidRunID: "--run must be a UUID"
        case .unsupportedOptions(let command): "one or more options are not valid for '\(command)'"
        case .jsonRequiresPathConsent: "--json requires --include-paths because report JSON contains paths"
        case .tooManyArguments: "too many positional arguments"
        case .noReports: "no reports are available"
        }
    }
}
