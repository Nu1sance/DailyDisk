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
                // Feedback always comes before the results, within the first screen.
                activity
                if let error = controller.errorMessage {
                    banner(error, icon: "exclamationmark.triangle.fill", color: Theme.warning)
                }
                if !controller.scanState.isActive { setupOrOutcome }
                if let report = controller.latestReport {
                    result(report)
                } else if !controller.scanState.isActive {
                    emptyState
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.content)
        .navigationTitle("概览")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !controller.scanState.isActive {
                    Button(action: primaryAction) {
                        Label(primaryTitle, systemImage: primaryIcon).labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.hasRefreshed || controller.isRefreshing)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                }
            }
        }
        .confirmationDialog("显示文件路径？", isPresented: $confirmDisclosure) {
            Button("显示路径") { controller.setReportPathDisclosure(true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("路径可能包含私人文件名，仅在本次应用会话中显示。")
        }
    }

    private var subtitle: String {
        guard let report = controller.latestReport else { return "尚未检查" }
        return "上次检查 \(relativeDateTime(report.generatedAt))"
    }

    private var primaryTitle: String {
        if !controller.hasRefreshed { return "正在检查状态…" }
        if controller.fullDiskAccess.status == .likelyDenied { return "允许读取磁盘" }
        if controller.launchAgentStatus == .requiresApproval { return "允许后台检查" }
        if controller.launchAgentStatus != .enabled { return "启用每日检查" }
        if case .failed = controller.scanState { return "重试检查" }
        return controller.latestReport == nil ? "开始首次检查" : "立即检查"
    }

    private var primaryIcon: String {
        if !controller.hasRefreshed { return "hourglass" }
        if controller.fullDiskAccess.status == .likelyDenied { return "lock.open" }
        if controller.launchAgentStatus == .requiresApproval { return "checkmark.shield" }
        if controller.launchAgentStatus != .enabled { return "clock" }
        return "arrow.clockwise"
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
            waiting("正在启动检查…", "正在连接后台任务，开始后会显示已检查的文件数。")
        case .running, .cancellationRequested, .finishing:
            ScanProgressView(state: controller.scanState) { Task { await controller.cancelScan() } }
        case .externalWriter:
            waiting("后台正在检查磁盘", "暂时无法读取详细进度，完成后结果会自动出现在这里。")
        default: EmptyView()
        }
    }

    private func waiting(_ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    @ViewBuilder private var setupOrOutcome: some View {
        if controller.fullDiskAccess.status == .likelyDenied {
            banner(
                "需要允许读取磁盘", "在系统设置的“完全磁盘访问权限”中添加 DailyDisk，开启后重新打开应用。",
                icon: "lock.fill", color: Theme.warning)
        } else if controller.launchAgentStatus == .requiresApproval {
            banner(
                "还差一步", "在“登录项与扩展”中允许 DailyDisk 后台运行，返回后会自动更新状态。",
                icon: "checkmark.shield.fill", color: Theme.warning)
        } else if controller.launchAgentStatus != .enabled {
            banner(
                "一次设置，每天自动检查", "启用后会开始检查，并在每天 09:00 自动运行。检查结束后后台任务会退出。",
                icon: "clock.fill", color: Theme.accent)
        } else {
            switch controller.scanState {
            case .cancelled:
                banner("已取消检查", "已保存的记录不受影响，可以随时重新开始。", icon: "stop.circle.fill", color: .secondary)
            case .failed(let failure):
                banner("检查未完成", failureDetail(failure), icon: "exclamationmark.triangle.fill", color: Theme.warning)
            case .succeeded(let summary):
                if summary.terminalState == .maintenanceCompleted {
                    Label("空间维护已完成，可在设置的诊断页查看占用。", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if controller.latestReport == nil
                    || !summary.reportRunIDs.contains(controller.latestReport!.runID.rawValue)
                {
                    banner("正在读取检查结果", "后台已完成，正在等待报告可用。", icon: "doc.text.fill", color: .secondary)
                }
            default: EmptyView()
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "internaldrive").font(.system(size: 28)).foregroundStyle(Theme.accent)
            Text("先记下磁盘现在的样子").font(.title3.weight(.semibold))
            Text("第一次检查会建立基线，文件较多时需要一些时间。下次检查起，就能看到新增和释放的空间。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 24)
    }

    private func result(_ report: DailyReport) -> some View {
        let trend = controller.recentTrend(for: report)
        return VStack(alignment: .leading, spacing: 24) {
            ReportHeadline(report: report, previousDate: controller.previousReport(before: report)?.generatedAt)
            if trend.count >= 2 {
                VStack(spacing: 12) {
                    SectionHeader("最近 \(trend.count) 次检查") {
                        Text("累计 \(signedBytes(trend.reduce(0) { $0 &+ ($1.accounting.physicalUsedDelta ?? 0) }))")
                    }
                    TrendChartView(reports: trend, highlighted: report.reportIdentity)
                        .frame(height: 120)
                }
            }
            if !report.isBaseline {
                HStack(alignment: .top, spacing: 28) {
                    VStack(spacing: 0) {
                        SectionHeader("增长来源") { pathToggle(report) }
                        ChangeSourceList(
                            ranking: report.largestGrowth, direction: .growth,
                            disclosePaths: controller.discloseReportPaths)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 0) {
                        SectionHeader("释放空间")
                        ChangeSourceList(
                            ranking: report.largestShrinkage, direction: .release,
                            disclosePaths: controller.discloseReportPaths)
                    }
                    .frame(minWidth: 220, maxWidth: 320)
                }
            }
            HStack(spacing: 12) {
                if report.coverage.unreadablePathCount > 0 {
                    Label(
                        "有 \(report.coverage.unreadablePathCount.formatted()) 处无法读取，结果未覆盖全部文件",
                        systemImage: "lock"
                    )
                    .foregroundStyle(Theme.warning)
                }
                Spacer()
                Button("查看完整报告", action: showHistory).buttonStyle(.link)
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private func pathToggle(_ report: DailyReport) -> some View {
        if !report.largestGrowth.isEmpty || !report.largestShrinkage.isEmpty {
            Toggle(
                "显示路径",
                isOn: Binding(
                    get: { controller.discloseReportPaths },
                    set: { value in
                        if value { confirmDisclosure = true } else { controller.setReportPathDisclosure(false) }
                    }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }

    private func banner(_ title: String, _ detail: String? = nil, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).font(.body)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                if let detail {
                    Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .card(padding: 14)
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
