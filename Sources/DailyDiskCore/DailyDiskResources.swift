import Foundation

/// Resolve packaged resources without falling back to a developer's build tree.
public enum DailyDiskResources {
    public static var applicationBundle: Bundle? {
        applicationBundle(executableURL: Bundle.main.executableURL)
    }

    public static func applicationBundle(executableURL: URL?) -> Bundle? {
        applicationURL(executableURL: executableURL).flatMap(Bundle.init(url:))
    }

    private static func applicationURL(executableURL: URL?) -> URL? {
        guard let executableURL else { return nil }
        let directory = executableURL.deletingLastPathComponent()
        guard ["MacOS", "Helpers"].contains(directory.lastPathComponent),
            directory.deletingLastPathComponent().lastPathComponent == "Contents"
        else { return nil }
        let app = directory.deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app" else { return nil }
        return app
    }

    public static func bundle(
        named name: String,
        executableURL: URL? = Bundle.main.executableURL,
        developmentBundle: () -> Bundle
    ) -> Bundle? {
        if let app = applicationURL(executableURL: executableURL) {
            // Missing packaged resources must never be masked by Bundle.module's
            // absolute build-directory fallback (which also traps if absent).
            return Bundle(
                url: app.appendingPathComponent("Contents/Resources", isDirectory: true)
                    .appendingPathComponent(name, isDirectory: true))
        }
        return developmentBundle()
    }
}
