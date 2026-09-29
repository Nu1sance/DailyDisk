import DailyDiskCore
import SwiftUI

struct HistoryView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        HStack(spacing: 0) {
            reportList.frame(width: 280)
            Divider()
            Group {
                if let report = controller.selectedReport {
                    ReportDetailView(controller: controller, report: report)
                        .id("\(report.runID)-\(report.storageDomainID.rawValue)")
                } else {
                    ContentUnavailableView("选择一份报告", systemImage: "doc.text.magnifyingglass")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.content)
        .navigationTitle("历史")
        .navigationSubtitle(controller.reports.isEmpty ? "暂无报告" : "\(controller.reports.count) 份报告")
        .task {
            if controller.inspectionSnapshot == nil { await controller.refresh() }
        }
    }

    @ViewBuilder
    private var reportList: some View {
        if controller.reports.isEmpty {
            ContentUnavailableView(
                "还没有历史报告",
                systemImage: "clock",
                description: Text("完成一次检查后，报告会按日期保存在这里。")
            )
        } else {
            List(selection: selection) {
                ForEach(controller.reports, id: \.reportIdentity) { report in
                    row(report).tag(report.reportIdentity)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private var selection: Binding<ReportIdentity?> {
        Binding(
            get: { controller.selectedReport?.reportIdentity },
            set: { identity in
                if let report = controller.reports.first(where: { $0.reportIdentity == identity }) {
                    controller.selectReport(report)
                }
            }
        )
    }

    private func row(_ report: DailyReport) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(report.generatedAt, format: .dateTime.month().day().weekday())
                    .fontWeight(.semibold)
                Text(
                    [report.generatedAt.formatted(.dateTime.hour().minute()), report.tagLabel]
                        .compactMap { $0 }.joined(separator: " · ")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(report.accounting.physicalUsedDelta.map(signedBytes) ?? "—")
                .monospacedDigit()
        }
        .padding(.vertical, 5)
    }
}
