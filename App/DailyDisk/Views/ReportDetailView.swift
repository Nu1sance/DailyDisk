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
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 8) {
                    Text(report.generatedAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let tag = report.tagLabel {
                        Text(tag)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Theme.track, in: Capsule())
                    }
                }
                ReportHeadline(
                    report: report,
                    previousDate: controller.previousReport(before: report)?.generatedAt,
                    numberSize: 40
                )
                if !report.isBaseline {
                    VStack(spacing: 0) {
                        SectionHeader("增长来源")
                        ChangeSourceList(
                            ranking: report.largestGrowth, direction: .growth,
                            disclosePaths: controller.discloseReportPaths)
                    }
                    VStack(spacing: 0) {
                        SectionHeader("释放空间")
                        ChangeSourceList(
                            ranking: report.largestShrinkage, direction: .release,
                            disclosePaths: controller.discloseReportPaths)
                    }
                }
                details
                Text("检查编号：\(report.runID.rawValue.uuidString)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if controller.discloseReportPaths {
                        controller.setReportPathDisclosure(false)
                    } else {
                        confirmDisclosure = true
                    }
                } label: {
                    Label(
                        controller.discloseReportPaths ? "路径已显示" : "路径已隐藏",
                        systemImage: controller.discloseReportPaths ? "eye" : "eye.slash"
                    )
                }
                .labelStyle(.titleAndIcon)
                .accessibilityValue(controller.discloseReportPaths ? "路径已显示" : "路径已隐藏")
                .accessibilityHint(controller.discloseReportPaths ? "点击隐藏详细路径" : "点击确认在本次会话中显示详细路径")
                .help(controller.discloseReportPaths ? "隐藏详细路径" : "在本次会话中显示详细路径")
                Button {
                    confirmExport = true
                } label: {
                    Label("导出 JSON", systemImage: "square.and.arrow.up")
                }
                .help("导出包含完整路径的 JSON")
            }
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

    // MARK: - Collapsed details

    private var details: some View {
        VStack(spacing: 0) {
            detail("空间核算", summary: report.accounting.physicalUsedDelta.map { "物理变化 \(bytes($0))" }) {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                    metric("库存对比", report.accounting.snapshotComparedDelta)
                    metric("文件事件", report.accounting.eventAttributedDelta)
                    metric("全量校正", report.accounting.reconciliationCorrection)
                    metric("校正后索引", report.accounting.reconciledIndexedDelta)
                    metric("DailyDisk 开销", report.accounting.dailyDiskOverheadDelta)
                    metric("物理变化", report.accounting.physicalUsedDelta)
                    metric("物理未归因", report.accounting.physicalUnattributedDelta)
                }
            }
            Divider()
            detail(
                "扫描覆盖",
                summary:
                    "\(report.coverage.visitedPathCount.formatted()) 个路径 · \(report.coverage.unreadablePathCount.formatted()) 处不可读"
            ) {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                    countMetric("已访问路径", report.coverage.visitedPathCount)
                    countMetric("已索引对象", report.coverage.indexedObjectCount)
                    countMetric("不可读路径", report.coverage.unreadablePathCount)
                    countMetric("瞬时错误", report.coverage.transientErrorCount)
                }
            }
            if let reconciliation = report.reconciliation {
                Divider()
                detail("校正明细", summary: "影响 \(reconciliation.affectedRecords.formatted()) 条记录") {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                        metric("漏记新增", reconciliation.missedAdditions)
                        metric("残留删除", reconciliation.staleRemovals)
                        metric("大小修正", reconciliation.sizeCorrections)
                        metric("归属转移", reconciliation.attributionTransfers)
                    }
                }
            }
            if let diagnosis = report.physicalDiagnosis {
                Divider()
                detail(
                    "物理诊断",
                    summary: diagnosis.likelyCauses.first.map(causeLabel) ?? "未发现明显原因"
                ) {
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
                }
            }
            if !report.largestGrowth.isEmpty || !report.largestShrinkage.isEmpty {
                Divider()
                detail(
                    "完整排名",
                    summary: "增长 \(report.largestGrowth.count) 项 · 释放 \(report.largestShrinkage.count) 项"
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("包含上级目录，因此各项之间可能重叠。")
                            .font(.caption).foregroundStyle(.secondary)
                        rankedList("增长", report.largestGrowth)
                        rankedList("释放", report.largestShrinkage)
                    }
                }
            }
            if !report.diagnostics.isEmpty {
                Divider()
                detail("错误与说明", summary: "\(report.diagnostics.count) 条") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(report.diagnostics.enumerated()), id: \.offset) { _, message in
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .card(padding: 4)
    }

    private func detail<Content: View>(
        _ title: String,
        summary: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let body = content()
        return DisclosureGroup {
            body
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.bottom, 4)
        } label: {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                if let summary {
                    Text(summary).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func rankedList(_ title: String, _ values: [RankedPathChange]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(
                            controller.discloseReportPaths
                                ? reversibleDisplayPath(value.path) : "\(title)来源 \(index + 1) · 路径已隐藏"
                        )
                        .font(.callout.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        Spacer(minLength: 12)
                        Text("分配 \(bytes(value.allocatedDelta)) · 逻辑 \(bytes(value.logicalDelta))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func metric(_ label: String, _ value: Int64?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value.map(bytes) ?? "未知").fontWeight(.semibold).monospacedDigit()
        }
    }

    private func countMetric(_ label: String, _ value: UInt64) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value.formatted()).monospacedDigit()
        }
    }

    private func bytes(_ value: Int64) -> String {
        signedBytes(value)
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
