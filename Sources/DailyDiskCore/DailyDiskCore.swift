import Foundation

/// Source metadata is shared by SwiftPM products and the packaging script.
public enum DailyDiskProduct: Sendable {
    private struct Metadata: Decodable {
        let version: String
        let buildNumber: String
        let minimumMacOSVersion: String
    }
    private static let metadata: Metadata? = {
        guard
            let resources = DailyDiskResources.bundle(
                named: "DailyDisk_DailyDiskCore.bundle", developmentBundle: { Bundle.module }),
            let url = resources.url(forResource: "Product", withExtension: "json"),
            let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Metadata.self, from: data)
        else { return nil }
        return value
    }()
    public static let name = "DailyDisk"
    public static var version: String {
        installedValue("CFBundleShortVersionString") ?? metadata?.version ?? "unknown"
    }
    public static var buildNumber: String { metadata?.buildNumber ?? "unknown" }
    public static var minimumMacOSVersion: String {
        installedValue("LSMinimumSystemVersion") ?? metadata?.minimumMacOSVersion ?? "unknown"
    }

    /// Embedded helpers share the enclosing application's release build number.
    public static var installedBuildNumber: String {
        installedValue("CFBundleVersion") ?? buildNumber
    }

    private static func installedValue(_ key: String) -> String? {
        DailyDiskResources.applicationBundle?.object(forInfoDictionaryKey: key) as? String
    }
}
