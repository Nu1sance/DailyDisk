import AppKit
import DailyDiskCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ReportDetailView: View {
    @ObservedObject var controller: AppController
    let report: DailyReport
    @State private var confirmDisclosure = false
    @State private var confirmExport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                Text(report.accounting.physicalUsedDelta.map(signedBytes) ?? "基线已建立")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                Text(
                    report.accounting.physicalUsedDelta == nil
                        ? "这是第一次检查，下次检查起会显示空间变化。"
                        : "相比上一次成功检查的磁盘使用空间变化。"
                )
                .foregroundStyle(.secondary)
                pathControls
                rankedSection("增长来源", values: report.largestGrowth, color: .blue)
                rankedSection("释放空间", values: report.largestShrinkage, color: .green)
                DisclosureGroup("核算与诊断详情") {
                    VStack(alignment: .leading, spacing: 16) {
                        accounting
                        coverage
                        if let reconciliation = report.reconciliation {
                            reconciliationSection(reconciliation)
                        }
                        physicalSection
                        diagnostics
                        Text("检查编号：\(report.runID.rawValue.uuidString)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.padding(.top, 12)
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .confirmationDialog(
            "显示完整路径？",
            isPresented: $confirmDisclosure,
            titleVisibility: .visible
        ) {
            Button("显示完整路径", role: .destructive) {
                controller.setReportPathDisclosure(true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("路径可能包含用户名、项目名和文件名，只会在当前应用会话中显示。")
        }
        .confirmationDialog(
            "导出包含完整路径的 JSON？",
            isPresented: $confirmExport,
            titleVisibility: .visible
        ) {
            Button("选择导出位置", role: .destructive) { exportJSON() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("JSON 包含可还原的完整相对路径。请只保存到你信任的位置。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(report.generatedAt, format: .dateTime.year().month().day().hour().minute())
                .font(.system(size: 28, weight: .bold, design: .rounded))

        }
    }

    private var accounting: some View {
        GroupBox("空间核算") {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                metric("文件事件", report.accounting.eventAttributedDelta)
                metric("全量校正", report.accounting.reconciliationCorrection)
                metric("校正后索引", report.accounting.reconciledIndexedDelta)
                metric("DailyDisk 开销", report.accounting.dailyDiskOverheadDelta)
                metric("物理变化", report.accounting.physicalUsedDelta)
                metric("物理未归因", report.accounting.physicalUnattributedDelta)
            }
            .padding(.top, 6)
        }
    }

    private var coverage: some View {
        GroupBox("扫描覆盖") {
            Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 8) {
                countMetric("已访问路径", report.coverage.visitedPathCount)
                countMetric("已索引对象", report.coverage.indexedObjectCount)
                countMetric("不可读路径", report.coverage.unreadablePathCount)
                countMetric("瞬时错误", report.coverage.transientErrorCount)
            }
            .padding(.top, 6)
        }
    }

    private func reconciliationSection(_ value: ReconciliationBreakdown) -> some View {
        GroupBox("校正明细") {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                metric("漏记新增", value.missedAdditions)
                metric("残留删除", value.staleRemovals)
                metric("大小修正", value.sizeCorrections)
                metric("归属转移", value.attributionTransfers)
                GridRow {
                    Text("影响记录").foregroundStyle(.secondary)
                    Text(value.affectedRecords.formatted()).monospacedDigit()
                }
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var physicalSection: some View {
        if let diagnosis = report.physicalDiagnosis {
            GroupBox("物理诊断") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("快照数量变化", value: diagnosis.snapshotCountDelta.formatted())
                    LabeledContent(
                        "仍被进程占用的已删除文件",
                        value: bytes(diagnosis.uniqueDeletedOpenLogicalBytes)
                    )
                    LabeledContent("不可读路径", value: diagnosis.unreadablePathCount.formatted())
                    if !diagnosis.likelyCauses.isEmpty {
                        Text(diagnosis.likelyCauses.map(causeLabel).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(diagnosis.notes, id: \.self) { note in
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private var pathControls: some View {
        HStack {
            Toggle(
                "显示详细路径",
                isOn: Binding(
                    get: { controller.discloseReportPaths },
                    set: { value in
                        if value { confirmDisclosure = true } else { controller.setReportPathDisclosure(false) }
                    }
                )
            )
            .toggleStyle(.switch)
            Spacer()
            Button("导出完整 JSON") { confirmExport = true }
        }
    }

    private func rankedSection(
        _ title: String,
        values: [RankedPathChange],
        color: Color
    ) -> some View {
        GroupBox(title) {
            if values.isEmpty {
                Text("没有记录").foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        HStack(spacing: 12) {
                            Circle().fill(color).frame(width: 6, height: 6)
                            Text(
                                controller.discloseReportPaths
                                    ? reversibleDisplayPath(value.path) : "路径已隐藏"
                            )
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(2)
                            .textSelection(.enabled)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("分配 \(bytes(value.allocatedDelta))")
                                Text("逻辑 \(bytes(value.logicalDelta))")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                        }
                        .padding(.vertical, 8)
                        if index != values.indices.last { Divider() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var diagnostics: some View {
        if !report.diagnostics.isEmpty {
            GroupBox("错误与说明") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(report.diagnostics.enumerated()), id: \.offset) { _, message in
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func metric(_ label: String, _ value: Int64?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value.map(bytes) ?? "未知")
                .font(.system(.body, design: .monospaced).weight(.semibold))
        }
    }

    private func countMetric(_ label: String, _ value: UInt64) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value.formatted()).monospacedDigit()
        }
    }

    private func bytes(_ value: Int64) -> String {
        let sign = value > 0 ? "+" : ""
        return sign + ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func causeLabel(_ cause: PhysicalAttributionCause) -> String {
        switch cause {
        case .snapshotSetChanged: "APFS 快照变化"
        case .deletedOpenFiles: "已删除文件仍被占用"
        case .inaccessiblePaths: "存在不可读路径"
        case .apfsSharedBlocksOrMetadata: "APFS 共享块或元数据"
        }
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "DailyDisk-\(report.runID.rawValue.uuidString).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let runID = report.runID
        let domainID = report.storageDomainID
        Task {
            await controller.exportReport(
                runID: runID,
                storageDomainID: domainID,
                to: url
            )
        }
    }
}
