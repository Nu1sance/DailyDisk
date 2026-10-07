/// One-use consent for the exact build named by the download button. A changed
/// feed target or a resumed installation must use Sparkle's normal confirmation.
struct UpdateDownloadIntent {
    var build: String?

    mutating func consume(matching target: String, notDownloaded: Bool) -> Bool {
        defer { build = nil }
        return build == target && notDownloaded
    }
}
