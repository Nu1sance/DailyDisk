import SwiftUI

struct AvailableSoftwareUpdateButton: View {
    @ObservedObject var updater: SoftwareUpdater
    var blocked: Bool

    var body: some View {
        if let update = updater.availableUpdate {
            Button(action: updater.downloadAvailableUpdate) {
                Label {
                    Text("下载更新")
                } icon: {
                    Image(systemName: "arrow.down.circle").resizable().scaledToFit().frame(width: 16, height: 16)
                }
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .disabled(blocked || !updater.canCheck)
            .help(blocked ? "当前任务结束或安装状态恢复后可更新" : "更新至 \(update.version)")
            .accessibilityLabel("下载更新至 \(update.version)")
        }
    }
}
