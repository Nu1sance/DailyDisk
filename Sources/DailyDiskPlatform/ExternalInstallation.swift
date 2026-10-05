import Foundation

/// Fixed-schema metadata only. No paths, commands, process names or credentials.
/// Admission is not completion: a Cask postflight is not a terminal transaction fence.
public enum ExternalInstallationOperation: String, Codable, Sendable, CaseIterable {
    case install, upgrade, reinstall, uninstall
}

struct ExternalInstallationIntent: Equatable, Sendable {
    let operation: ExternalInstallationOperation
    let sourceBuild: String?
    let targetBuild: String?

    init(operation: ExternalInstallationOperation, sourceBuild: String?, targetBuild: String?) throws {
        func number(_ value: String?) -> Int? {
            guard let value, let parsed = Int(value), parsed > 0, parsed <= 999_999_999,
                String(parsed) == value
            else { return nil }
            return parsed
        }
        let source = number(sourceBuild)
        let target = number(targetBuild)
        let valid: Bool
        switch operation {
        case .install:
            valid = sourceBuild == nil && target != nil
        case .upgrade:
            if let source, let target { valid = target > source } else { valid = false }
        case .reinstall:
            if let source, let target { valid = target >= source } else { valid = false }
        case .uninstall:
            valid = source != nil && targetBuild == nil
        }
        guard valid else { throw UpdatePreparationError.invalidState }
        self.operation = operation
        self.sourceBuild = sourceBuild
        self.targetBuild = targetBuild
    }
}
