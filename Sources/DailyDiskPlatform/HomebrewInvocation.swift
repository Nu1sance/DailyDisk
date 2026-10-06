import Darwin
import Foundation

/// Homebrew invokes uninstall scripts during upgrade/reinstall as well as removal.
/// Resolve that distinction from the invoking process, never from a caller-supplied
/// "skip safety" option or a mutable environment variable.
enum HomebrewInvocation: String, Sendable {
    case install, upgrade, reinstall, uninstall

    static func parse(arguments: [String]) throws -> Self? {
        let scripts = [
            "/opt/homebrew/Library/Homebrew/brew.rb",
            "/usr/local/Homebrew/Library/Homebrew/brew.rb",
        ]
        guard let index = arguments.firstIndex(where: { scripts.contains($0) }) else { return nil }
        guard arguments.indices.contains(index + 1) else { throw UpdatePreparationError.invalidState }
        switch arguments[index + 1] {
        case "install": return .install
        case "upgrade": return .upgrade
        case "reinstall": return .reinstall
        case "uninstall", "remove", "rm": return .uninstall
        default: throw UpdatePreparationError.invalidState
        }
    }

    static func current() throws -> Self {
        var pid = getppid()
        for _ in 0..<32 {
            guard pid > 1 else { break }
            var info = proc_bsdinfo()
            guard
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
                    == MemoryLayout.size(ofValue: info), info.pbi_uid == getuid()
            else { throw UpdatePreparationError.invalidState }
            if let invocation = try parse(arguments: processArguments(pid)) { return invocation }
            guard info.pbi_ppid != UInt32(pid) else { break }
            pid = pid_t(info.pbi_ppid)
        }
        throw UpdatePreparationError.invalidState
    }

    private static func processArguments(_ pid: pid_t) throws -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var bytes = [UInt8](repeating: 0, count: 1_048_576)
        var size = bytes.count
        let result = bytes.withUnsafeMutableBytes { buffer in
            sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0, size > MemoryLayout<Int32>.size else { throw UpdatePreparationError.invalidState }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count < 16_384 else { throw UpdatePreparationError.invalidState }
        var index = MemoryLayout<Int32>.size
        // Executable path, NUL padding, then exactly argc arguments (not environment).
        while index < size && bytes[index] != 0 { index += 1 }
        while index < size && bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            let start = index
            while index < size && bytes[index] != 0 { index += 1 }
            guard index < size, let value = String(bytes: bytes[start..<index], encoding: .utf8) else {
                throw UpdatePreparationError.invalidState
            }
            arguments.append(value)
            index += 1
        }
        return arguments
    }
}
