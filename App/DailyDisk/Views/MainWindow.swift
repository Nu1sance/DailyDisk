import DailyDiskPlatform
import SwiftUI

enum MainSection: Hashable {
    case overview
    case history
}

/// Sidebar navigation: overview and history, with the daily-check status and settings at the bottom.
struct MainWindow: View {
    @ObservedObject var controller: AppController
    @Binding var section: MainSection?
    @Binding var showsSettings: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Label("概览", systemImage: "chart.bar").tag(MainSection.overview)
                Label("历史", systemImage: "clock").tag(MainSection.history)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        } detail: {
            switch section ?? .overview {
            case .overview:
                StatusView(controller: controller) { section = .history }
            case .history:
                HistoryView(controller: controller)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            status
            Button {
                showsSettings = true
            } label: {
                Label("设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }

    private var status: some View {
        let state = statusDescription
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if controller.scanState.isActive {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(state.color).frame(width: 7, height: 7)
                }
                Text(state.title).font(.caption.weight(.semibold))
            }
            Text(state.detail).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var statusDescription: (title: String, detail: String, color: Color) {
        if controller.scanState.isActive {
            return ("正在检查", "可以关闭窗口，检查会在后台继续", Theme.accent)
        }
        switch controller.launchAgentStatus {
        case .enabled: return ("每日检查已启用", "内置磁盘 · 每天 09:00", Theme.positive)
        case .requiresApproval: return ("等待系统批准", "在登录项中允许 DailyDisk", Theme.warning)
        case .notRegistered: return ("每日检查未启用", "在概览中启用", .secondary)
        case .notFound: return ("应用资源缺失", "请重新安装 DailyDisk", Theme.warning)
        case .unknown: return ("正在读取状态", "内置磁盘", .secondary)
        }
    }
}
