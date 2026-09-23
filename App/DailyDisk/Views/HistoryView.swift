import DailyDiskCore
import SwiftUI

struct HistoryView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        HSplitView {
            Group {
                if controller.reports.isEmpty {
                    ContentUnavailableView(
                        "还没有历史报告",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("完成一次扫描后，报告会按日期保存在这里。")
                    )
                } else {
                    List(controller.reports, id: \.reportIdentity) { report in
                        Button {
                            controller.selectReport(report)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(report.generatedAt, format: .dateTime.year().month().day())
                                    .font(.headline)
                                Text(report.generatedAt, format: .dateTime.hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(report.storageDomainID.rawValue)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Text(bytes(report.accounting.physicalUsedDelta))
                                    Spacer()
                                    Text("校正 \(bytes(report.accounting.reconciliationCorrection))")
                                }
                                .font(.caption.monospaced())
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            controller.selectedReport?.reportIdentity == report.reportIdentity
                                ? Color.accentColor.opacity(0.12) : Color.clear
                        )
                    }
                }
            }
            .frame(minWidth: 230, idealWidth: 270, maxWidth: 330)

            if let report = controller.selectedReport {
                ReportDetailView(controller: controller, report: report)
                    .id("\(report.runID)-\(report.storageDomainID.rawValue)")
            } else {
                ContentUnavailableView("选择一份报告", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if controller.inspectionSnapshot == nil { await controller.refresh() }
        }
    }

    private func bytes(_ value: Int64?) -> String {
        guard let value else { return "未知" }
        let sign = value > 0 ? "+" : ""
        return sign + ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
