import DailyDiskCore
import DailyDiskStore
import SwiftUI

/// Only the current page is retained. Task identity prevents a late response
/// from exposing another report/filter/page after the user navigates away.
struct ReportChangeDetailsView: View {
    @ObservedObject var controller: AppController
    let report: DailyReport
    @State private var filter: ReportChangeFilter = .all
    @State private var cursors: [Int64] = [0]
    @State private var page: ReportChangePage?
    @State private var loading = false
    @State private var failed = false
    @State private var retry = 0

    private var queryID: String {
        "\(report.runID)-\(report.storageDomainID.rawValue)-\(filter.rawValue)-\(cursors.last ?? 0)-\(retry)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("筛选", selection: $filter) {
                Text("全部记录").tag(ReportChangeFilter.all)
                Text("占用增加").tag(ReportChangeFilter.growth)
                Text("占用减少").tag(ReportChangeFilter.release)
                Text("仅逻辑大小变化").tag(ReportChangeFilter.logicalOnly)
            }
            .pickerStyle(.segmented)
            .onChange(of: filter) { _, _ in
                cursors = [0]
                page = nil
            }
            Text("按记录顺序分页，不设文件大小门槛。同一路径可能有多条记录；这不是逐次文件写入日志。")
                .font(.caption).foregroundStyle(.secondary)
            if loading {
                ProgressView("正在读取变化记录…")
            } else if failed {
                Text("读取失败，历史数据未被修改。请稍后重试。")
                Button("重试") { retry += 1 }
            } else if let page {
                if page.entries.isEmpty { Text("没有符合条件的变化记录。").foregroundStyle(.secondary) }
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(page.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pathLabel(entry.change)).font(.callout.monospaced()).lineLimit(3)
                            HStack {
                                Text(kindLabel(entry.change.kind))
                                Spacer()
                                Text(
                                    "分配 \(signedBytes(entry.change.allocatedDelta)) · 逻辑 \(signedBytes(entry.change.logicalDelta))"
                                )
                                .monospacedDigit()
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
                HStack {
                    Button("上一页") {
                        self.page = nil
                        cursors.removeLast()
                    }.disabled(cursors.count == 1)
                    Text("第 \(cursors.count) 页 · 本页 \(page.entries.count) 条").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("下一页") {
                        if let next = page.nextSequence {
                            self.page = nil
                            cursors.append(next)
                        }
                    }.disabled(page.nextSequence == nil)
                }
            }
        }
        .task(id: queryID) {
            let requestedID = queryID
            loading = true
            failed = false
            page = nil
            do {
                let result = try await controller.reportChangePage(
                    report, afterSequence: cursors.last ?? 0, filter: filter)
                try Task.checkCancellation()
                guard requestedID == queryID else { return }
                page = result
                loading = false
            } catch is CancellationError {
                // A replacement task owns the current state.
            } catch {
                guard !Task.isCancelled, requestedID == queryID else { return }
                failed = true
                loading = false
            }
        }
    }

    private func pathLabel(_ change: ChangeRecord) -> String {
        guard controller.discloseReportPaths else { return "路径已隐藏" }
        if let before = change.pathBefore, let after = change.pathAfter, before != after {
            return "\(reversibleDisplayPath(before)) → \(reversibleDisplayPath(after))"
        }
        return change.attributionPath.map(reversibleDisplayPath) ?? "无路径"
    }

    private func kindLabel(_ kind: ChangeKind) -> String {
        switch kind {
        case .baseline: "基线"
        case .eventCreated, .reconciliationAddition, .snapshotAddition: "新增"
        case .eventRemoved, .reconciliationRemoval, .snapshotRemoval: "删除"
        case .eventModified, .reconciliationCorrection, .snapshotModification: "变化"
        case .eventMoved: "移动"
        case .eventLinkAdded: "新增链接"
        case .eventLinkRemoved: "移除链接"
        case .eventAttributionTransfer, .reconciliationAttributionTransfer, .snapshotAttributionTransfer: "归属调整"
        }
    }
}
