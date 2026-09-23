import DailyDiskCore
import DailyDiskStore

/// Namespace for macOS integrations such as APFS discovery, FSEvents,
/// notifications, and launchd registration.
public enum DailyDiskPlatformModule: Sendable {
    public static let isAvailable = true
}
