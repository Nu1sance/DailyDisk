import Foundation

/// Source metadata is shared by SwiftPM products and the packaging script.
public enum DailyDiskProduct: Sendable {
    private struct Metadata: Decodable {
        let version: String
        let buildNumber: String
        let minimumMacOSVersion: String
    }
    private static let metadata: Metadata = {
        guard let url = Bundle.module.url(forResource: "Product", withExtension: "json"),
            let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Metadata.self, from: data)
        else { preconditionFailure("Missing product metadata") }
        return value
    }()
    public static let name = "DailyDisk"
    public static var version: String { metadata.version }
    public static var buildNumber: String { metadata.buildNumber }
    public static var minimumMacOSVersion: String { metadata.minimumMacOSVersion }

    /// Embedded helpers share the enclosing application's release build number.
    public static var installedBuildNumber: String {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app", let bundle = Bundle(url: app),
            let value = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else { return buildNumber }
        return value
    }
}
