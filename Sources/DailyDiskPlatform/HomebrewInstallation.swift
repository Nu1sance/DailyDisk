import Darwin
import Foundation
import Security

/// A headless mode of the signed GUI executable; never an inventory writer.
public enum HomebrewInstallation {
    public static let installCommand = "--homebrew-install"
    public static let uninstallCommand = "--homebrew-uninstall"

    public static func run(arguments: [String]) async -> Int32 {
        do {
            guard arguments.count == 2, getuid() != 0,
                arguments[0] == installCommand || arguments[0] == uninstallCommand
            else { throw UpdatePreparationError.invalidState }
            let invocation = try HomebrewInvocation.current()
            let removing = arguments[0] == uninstallCommand
            // Homebrew removes old artifacts before installing replacements and
            // invokes them again on rollback. Our artifact owns no app move here.
            if removing, invocation != .uninstall { return 0 }
            guard removing || invocation != .uninstall else { throw UpdatePreparationError.invalidState }
            let directory = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
            let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
            let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Applications", isDirectory: true)
            guard directory == system || directory == user else { throw UpdatePreparationError.invalidState }
            let files = FileManager.default
            if directory == user, !files.fileExists(atPath: directory.path) {
                try files.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            guard directory.resolvingSymlinksInPath() == directory, files.isWritableFile(atPath: directory.path) else {
                throw HomebrewInstallationError.unwritableDestination
            }
            let alternate = (directory == system ? user : system).appendingPathComponent("DailyDisk.app")
            var info = stat()
            guard lstat(alternate.path, &info) != 0, errno == ENOENT else {
                throw HomebrewInstallationError.duplicateInstallation
            }
            let candidate = Bundle.main.bundleURL
            let verifier = try HomebrewBundleVerifier(reference: candidate)
            let control = try RunControlStore()
            let transaction = ExternalAppTransaction(
                control: control, directory: directory, candidate: candidate,
                validate: { try verifier.validate($0) }, requireIdle: requireIdle)
            let outcome = try await transaction.run(removing: removing)
            switch outcome {
            case .installed:
                print("DailyDisk installed. Open DailyDisk and choose Resume if installation preparation is shown.")
            case .preservedNewer:
                print("DailyDisk already has this or a newer signed build; the existing app was preserved.")
            case .removed:
                print("DailyDisk removed. Your database and reports were retained.")
            }
            return 0
        } catch {
            fputs("DailyDisk installation stopped: \(error.localizedDescription)\n", stderr)
            fputs(
                "For an existing app: pause for manual replacement in Settings > General > Advanced, then quit. "
                    + "After an interrupted installation, retry the same brew command; do not delete Control files.\n",
                stderr)
            return 1
        }
    }

    private static func requireIdle() throws {
        try UpdateSessionGuard.requireSingleUser()
        // Conservative process-name rejection also covers read-only CLI handles.
        // Ignore only this headless installer, not another copy of DailyDisk.
        var pids = [pid_t](repeating: 0, count: 65_536)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0, count < pids.count else { throw UpdatePreparationError.busy }
        for pid in pids.prefix(Int(count)) where pid > 0 && pid != getpid() {
            var name = [CChar](repeating: 0, count: 1024)
            let length = proc_name(pid, &name, UInt32(name.count))
            let processName = String(
                decoding: name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if length > 0, ["DailyDisk", "DailyDiskAgent", "dailydiskctl"].contains(processName) {
                throw UpdatePreparationError.busy
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(LaunchAgentManager.label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 113 else { throw UpdatePreparationError.unsupportedRegistration }
    }
}

private enum HomebrewInstallationError: LocalizedError {
    case unwritableDestination, duplicateInstallation, invalidSignature
    var errorDescription: String? {
        switch self {
        case .unwritableDestination:
            "Destination is not writable. Use --appdir=\"$HOME/Applications\" for a user installation; do not run brew with sudo."
        case .duplicateInstallation:
            "DailyDisk exists in the other Applications directory. Keep one production installation."
        case .invalidSignature:
            "The app signature, identity or build number could not be verified."
        }
    }
}

/// Verify the Developer ID identity and all three executable requirements before
/// accepting either the installed build, copied candidate, or recovery backup.
struct HomebrewBundleVerifier: Sendable {
    private static let parts = ["", "Contents/Helpers/DailyDiskAgent", "Contents/Helpers/dailydiskctl"]
    private let requirements: [String]

    init(reference: URL) throws {
        let code = try Self.code(reference)
        var requirement: SecRequirement?
        let identity =
            "anchor apple generic and identifier \"io.github.xiuyuwu.DailyDisk\" "
            + "and certificate leaf[subject.OU] = \"C78GVUBYS3\" "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        guard SecRequirementCreateWithString(identity as CFString, [], &requirement) == errSecSuccess,
            SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
        else { throw HomebrewInstallationError.invalidSignature }
        requirements = try Self.parts.map { try Self.requirement(reference.appendingPathComponent($0)) }
        _ = try validate(reference)
    }

    func validate(_ url: URL) throws -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw HomebrewInstallationError.invalidSignature
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        let code = try Self.code(url)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess,
            try Self.parts.map({ try Self.requirement(url.appendingPathComponent($0)) }) == requirements,
            let metadata = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")), format: nil)
                as? [String: Any],
            let raw = metadata["CFBundleVersion"] as? String,
            let build = Int(raw), build > 0, build <= 999_999_999, String(build) == raw
        else { throw HomebrewInstallationError.invalidSignature }
        return build
    }

    private static func code(_ url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw HomebrewInstallationError.invalidSignature
        }
        return code
    }

    private static func requirement(_ url: URL) throws -> String {
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopyDesignatedRequirement(try code(url), [], &requirement) == errSecSuccess,
            let requirement, SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text
        else { throw HomebrewInstallationError.invalidSignature }
        return text as String
    }
}
