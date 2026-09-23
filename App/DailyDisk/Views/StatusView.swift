import DailyDiskCore
import DailyDiskPlatform
import Foundation
import SwiftUI

struct StatusView: View {
    @ObservedObject var controller: AppController
    var showHistory: () -> Void = {}
    @State private var confirmDisclosure = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("磁盘变化").font(.system(size: 28, weight: .semibold))
                        Text("知道空间多用了多少，也知道增长来自哪里。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 20)
                    if !controller.scanState.isActive {
                        Button(primaryTitle, action: primaryAction)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(!controller.hasRefreshed || controller.isRefreshing)
                            .keyboardShortcut("r", modifiers: [.command, .shift])
                    }
                }
                // Feedback always comes before the results, within the first screen.
                activity
                if let error = controller.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if !controller.scanState.isActive { setupOrOutcome }
                if let report = controller.latestReport {
                    result(report)
                } else if !controller.scanState.isActive {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "internaldrive").font(.system(size: 32)).foregroundStyle(.blue)
                        Text("先记下磁盘现在的样子").font(.title2.weight(.semibold))
                        Text("第一次检查会建立基线，文件较多时需要一些时间。下次检查起，就能看到新增和释放的空间。")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .background(.background, in: RoundedRectangle(cornerRadius: 16))
                }
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive")
                    Text("内置磁盘")
                    Text("·")
                    Text(controller.launchAgentStatus == .enabled ? "每天 09:00 自动检查" : "启用后每天 09:00 自动检查")
                    Spacer()
                    if let report = controller.latestReport {
                        Text("最近 \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("显示文件路径？", isPresented: $confirmDisclosure) {
            Button("显示路径") { controller.setReportPathDisclosure(true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("路径可能包含私人文件名，仅在本次应用会话中显示。")
        }
    }

    private var primaryTitle: String {
        if !controller.hasRefreshed { return "正在检查状态…" }
        if controller.fullDiskAccess.status == .likelyDenied { return "允许读取磁盘" }
        if controller.launchAgentStatus == .requiresApproval { return "允许后台检查" }
        if controller.launchAgentStatus != .enabled { return "启用每日检查" }
        if case .failed = controller.scanState { return "重试检查" }
        return controller.latestReport == nil ? "开始首次检查" : "立即检查"
    }

    private func primaryAction() {
        if controller.fullDiskAccess.status == .likelyDenied {
            controller.openFullDiskAccessSettings()
        } else if controller.launchAgentStatus == .requiresApproval {
            controller.openLoginItemsSettings()
        } else if controller.launchAgentStatus != .enabled {
            Task { await controller.installDailyRun() }
        } else {
            Task { await controller.scanNow() }
        }
    }

    @ViewBuilder private var activity: some View {
        switch controller.scanState {
        case .requesting:
            HStack(spacing: 14) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 5) {
                    Text("正在启动检查…").font(.headline)
                    Text("正在连接后台任务，开始后会显示已检查的文件数。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
                .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        case .running, .cancellationRequested, .finishing:
            ScanProgressView(state: controller.scanState) { Task { await controller.cancelScan() } }
        case .externalWriter:
            HStack(spacing: 14) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 5) {
                    Text("后台正在检查磁盘").font(.headline)
                    Text("暂时无法读取详细进度，完成后结果会自动出现在这里。")
                        .foregroundStyle(.secondary)
                }
            }.padding(22)
        default: EmptyView()
        }
    }

    @ViewBuilder private var setupOrOutcome: some View {
        if controller.fullDiskAccess.status == .likelyDenied {
            note("需要允许读取磁盘", "在系统设置的“完全磁盘访问权限”中添加 DailyDisk，开启后重新打开应用。", icon: "lock", color: .orange)
        } else if controller.launchAgentStatus == .requiresApproval {
            note("还差一步", "在“登录项与扩展”中允许 DailyDisk 后台运行，返回后会自动更新状态。", icon: "checkmark.shield", color: .orange)
        } else if controller.launchAgentStatus != .enabled {
            note("一次设置，每天自动检查", "启用后会开始检查，并在每天 09:00 自动运行。检查结束后后台任务会退出。", icon: "clock", color: .blue)
        } else {
            switch controller.scanState {
            case .cancelled:
                note("已取消检查", "已保存的记录不受影响，可以随时重新开始。", icon: "stop.circle", color: .secondary)
            case .failed(let failure):
                note("检查未完成", failureDetail(failure), icon: "exclamationmark.triangle", color: .orange)
            case .succeeded(let summary):
                if controller.latestReport == nil
                    || !summary.reportRunIDs.contains(controller.latestReport!.runID.rawValue)
                {
                    note("正在读取检查结果", "后台已完成，正在等待报告可用。", icon: "doc.text", color: .secondary)
                }
            default: EmptyView()
            }
        }
    }

    private func result(_ report: DailyReport) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(report.accounting.physicalUsedDelta == nil ? "首次检查已完成" : "相比上次检查")
                        .foregroundStyle(.secondary)
                    Text(report.accounting.physicalUsedDelta.map(signedBytes) ?? "基线已建立")
                        .font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(resultCaption(report)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
            }
            if report.accounting.physicalUsedDelta != nil {
                HStack(spacing: 32) {
                    summaryMetric("文件变化", report.accounting.reconciledIndexedDelta)
                    summaryMetric("未归因空间", report.accounting.physicalUnattributedDelta)
                    summaryMetric("DailyDisk 自身", report.accounting.dailyDiskOverheadDelta)
                }
                Text("磁盘净变化 = 文件净变化 + 未归因空间 + DailyDisk 自身。文件净变化包含增长与释放；未归因空间可能来自快照、APFS 元数据、共享块或无法读取的内容，不能直接归到某个文件夹。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Text("文件增长来源与占比").font(.headline)
                    Spacer()
                    if !controller.discloseReportPaths, !report.largestGrowth.isEmpty {
                        Button("显示路径") { confirmDisclosure = true }.buttonStyle(.link)
                    }
                }
                GrowthBreakdownView(ranking: report.largestGrowth, disclosePaths: controller.discloseReportPaths)

            }
            if report.coverage.unreadablePathCount > 0 {
                Label("有 \(report.coverage.unreadablePathCount.formatted()) 处无法读取，结果未覆盖全部文件。", systemImage: "lock")
                    .font(.callout).foregroundStyle(.orange)
            }
            Button("查看报告与历史", action: showHistory).buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private func resultCaption(_ report: DailyReport) -> String {
        guard let delta = report.accounting.physicalUsedDelta else {
            return "下次检查起，这里会显示磁盘增长和具体来源。"
        }
        return delta > 0 ? "磁盘使用空间增加" : delta < 0 ? "磁盘使用空间减少" : "磁盘使用空间没有净变化"
    }

    private func summaryMetric(_ title: String, _ value: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map(signedBytes) ?? "未知").monospacedDigit()
        }
    }

    private func note(_ title: String, _ detail: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).fontWeight(.medium)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.font(.callout)
    }

    private func failureDetail(_ failure: AppScanFailure) -> String {
        switch failure {
        case .helperStopped: "后台任务没有继续运行。点击“重试检查”恢复，已保存的记录不受影响。"
        case .launchAgentUnavailable: "后台检查尚未就绪，请检查“设置”中的每日运行状态。"
        case .controlChannel: "无法连接后台任务。请重新打开应用；如仍失败，可在“设置 → 诊断”查看详情。"
        case .writerBusy: "另一个检查任务正在运行，请等待它完成。"
        case .scanFailed: "本次检查未能完成，上一份结果仍然保留。可重试，或在“设置 → 诊断”查看原因。"
        }
    }
}

func signedBytes(_ value: Int64) -> String {
    (value > 0 ? "+" : "") + ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}
