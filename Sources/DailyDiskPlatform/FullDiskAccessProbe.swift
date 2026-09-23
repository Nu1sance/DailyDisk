import AppKit
import Darwin
import Foundation

public enum FullDiskAccessStatus: String, Codable, Sendable {
    case likelyGranted
    case likelyDenied
    case inconclusive
}

public struct FullDiskAccessProbeResult: Equatable, Sendable {
    public let status: FullDiskAccessStatus
    public let accessiblePaths: [String]
    public let deniedPaths: [String]
    public let missingPaths: [String]
    public let errorPaths: [String]

    public init(
        status: FullDiskAccessStatus,
        accessiblePaths: [String],
        deniedPaths: [String],
        missingPaths: [String],
        errorPaths: [String] = []
    ) {
        self.status = status
        self.accessiblePaths = accessiblePaths
        self.deniedPaths = deniedPaths
        self.missingPaths = missingPaths
        self.errorPaths = errorPaths
    }
}

public protocol FullDiskAccessProbing: Sendable {
    func probe() async -> FullDiskAccessProbeResult
}

public struct FullDiskAccessProbe: FullDiskAccessProbing {
    private let protectedPaths: [String]

    public init(
        protectedPaths: [String] = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari").path,
        ]
    ) {
        self.protectedPaths = protectedPaths
    }

    public func probe() async -> FullDiskAccessProbeResult {
        var accessible: [String] = []
        var denied: [String] = []
        var missing: [String] = []
        var failures: [String] = []
        for path in protectedPaths {
            var status = Darwin.stat()
            if lstat(path, &status) != 0 {
                if errno == EACCES || errno == EPERM {
                    denied.append(path)
                } else if errno == ENOENT {
                    missing.append(path)
                } else {
                    failures.append(path)
                }
                continue
            }
            let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            if descriptor >= 0 {
                let duplicate = dup(descriptor)
                if duplicate >= 0, let directory = fdopendir(duplicate) {
                    errno = 0
                    _ = readdir(directory)
                    let enumerationError = errno
                    closedir(directory)
                    close(descriptor)
                    if enumerationError == 0 {
                        accessible.append(path)
                    } else if enumerationError == EACCES || enumerationError == EPERM {
                        denied.append(path)
                    } else {
                        failures.append(path)
                    }
                } else {
                    let code = errno
                    if duplicate >= 0 { close(duplicate) }
                    close(descriptor)
                    if code == EACCES || code == EPERM {
                        denied.append(path)
                    } else {
                        failures.append(path)
                    }
                }
            } else if errno == EACCES || errno == EPERM {
                denied.append(path)
            } else if errno == ENOENT {
                missing.append(path)
            } else {
                failures.append(path)
            }
        }
        let result: FullDiskAccessStatus
        if !denied.isEmpty {
            result = .likelyDenied
        } else if !accessible.isEmpty, failures.isEmpty {
            result = .likelyGranted
        } else {
            result = .inconclusive
        }
        return FullDiskAccessProbeResult(
            status: result,
            accessiblePaths: accessible,
            deniedPaths: denied,
            missingPaths: missing,
            errorPaths: failures
        )
    }

    @MainActor
    public static func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
        ]
        for value in urls {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return }
        }
    }
}
