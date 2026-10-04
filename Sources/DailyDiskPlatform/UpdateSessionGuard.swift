import Darwin
import Foundation

/// Conservative single-user update policy. Other user launchd domains include idle
/// login sessions; a one-time DailyDisk process check would miss their jobs.
public enum UpdateSessionGuard {
    public static func requireSingleUser() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            throw UpdatePreparationError.otherUserSession
        }
        try validate(text, currentUID: getuid())
    }

    static func validate(_ output: String, currentUID: uid_t) throws {
        guard output.hasPrefix("system = {") else { throw UpdatePreparationError.otherUserSession }
        var foundCurrentUser = false
        for line in output.split(separator: "\n") {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("user/") else { continue }
            guard let uid = UInt32(value.dropFirst(5)) else { throw UpdatePreparationError.otherUserSession }
            if uid == currentUID { foundCurrentUser = true }
            if uid >= 500 && uid != currentUID { throw UpdatePreparationError.otherUserSession }
        }
        guard foundCurrentUser else { throw UpdatePreparationError.otherUserSession }
    }
}
