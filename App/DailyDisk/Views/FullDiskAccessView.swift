import DailyDiskPlatform
import SwiftUI

struct FullDiskAccessView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("磁盘读取权限")
                    .font(.title2.weight(.semibold))
                Text("DailyDisk 不会绕过 macOS 安全机制。你需要主动授予“完全磁盘访问权限”。")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            accessStatus

            VStack(alignment: .leading, spacing: 16) {
                instruction(1, "打开系统设置", "进入“隐私与安全性 → 完全磁盘访问权限”。")
                instruction(2, "启用 DailyDisk", "如果列表中没有应用，请添加实际安装的 DailyDisk.app（默认位于 ~/Applications）。")
                instruction(3, "重新检查", "授权后请退出并重新打开 DailyDisk。部分系统保护区域仍可能不可读。")
            }

            HStack {
                Button("打开完全磁盘访问设置") {
                    controller.openFullDiskAccessSettings()
                }
                .buttonStyle(.borderedProminent)
                Button("重新检查") {
                    Task { await controller.refresh() }
                }
            }
            Spacer()
        }
        .padding(32)
    }

    private var accessStatus: some View {
        HStack(spacing: 14) {
            Image(systemName: statusIcon)
                .font(.system(size: 28))
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.headline)
                Text(statusDetail)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private func instruction(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(String(number))
                .font(.system(.body, design: .monospaced).bold())
                .frame(width: 28, height: 28)
                .foregroundStyle(Theme.accent).background(Theme.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }

    private var statusIcon: String {
        switch controller.fullDiskAccess.status {
        case .likelyGranted: "checkmark.shield.fill"
        case .likelyDenied: "xmark.shield.fill"
        case .inconclusive: "questionmark.diamond.fill"
        }
    }

    private var statusColor: Color {
        switch controller.fullDiskAccess.status {
        case .likelyGranted: .green
        case .likelyDenied: .orange
        case .inconclusive: .secondary
        }
    }

    private var statusTitle: String {
        switch controller.fullDiskAccess.status {
        case .likelyGranted: "已允许读取受保护目录"
        case .likelyDenied: "访问可能未开启"
        case .inconclusive: "无法自动确认"
        }
    }

    private var statusDetail: String {
        "可访问 \(controller.fullDiskAccess.accessiblePaths.count) 项，拒绝 \(controller.fullDiskAccess.deniedPaths.count) 项。最终覆盖率以扫描报告为准。"
    }
}
