import SwiftUI

struct AvailableSoftwareUpdateButton: View {
    @ObservedObject var updater: SoftwareUpdater
    var blockedReason: String?

    var body: some View {
        if let update = updater.availableUpdate {
            HStack(spacing: 0) {
                Button(action: updater.downloadAvailableUpdate) {
                    Label {
                        Text("下载更新")
                    } icon: {
                        Image(systemName: "arrow.down.circle").resizable().scaledToFit().frame(width: 16, height: 16)
                    }
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .disabled(blockedReason != nil || !updater.canCheck)
                .accessibilityLabel("下载更新至 \(update.version)")
                .accessibilityHint(blockedReason ?? (!updater.canCheck ? "正在检查更新或处理更新操作，请稍候。" : ""))
            }
            // Help belongs to an enabled container so it also works over the disabled button.
            .contentShape(Rectangle())
            .help(blockedReason ?? (!updater.canCheck ? "正在检查更新或处理更新操作，请稍候。" : "更新至 \(update.version)"))
        }
    }
}
