import Charts
import DailyDiskCore
import Foundation
import SwiftUI

/// Physical deltas of the most recent non-baseline reports, oldest first, with the latest highlighted.
struct TrendChartView: View {
    let reports: [DailyReport]
    let highlighted: ReportIdentity?

    var body: some View {
        Chart(Array(reports.enumerated()), id: \.offset) { index, report in
            let value = Double(report.accounting.physicalUsedDelta ?? 0)
            BarMark(
                x: .value("检查", index),
                y: .value("磁盘净变化", value),
                width: .fixed(22)
            )
            .foregroundStyle(color(report, value))
            .cornerRadius(3)
            .accessibilityLabel(report.generatedAt.formatted(.dateTime.month().day().hour().minute()))
            .accessibilityValue(signedBytes(Int64(value)))
        }
        .chartXScale(domain: -0.5...(Double(max(reports.count, 1)) - 0.5))
        .chartXAxis {
            AxisMarks(values: Array(reports.indices)) { value in
                AxisValueLabel(centered: false) {
                    if let index = value.as(Int.self), reports.indices.contains(index) {
                        Text(reports[index].generatedAt, format: .dateTime.month(.defaultDigits).day())
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(
                            bytes == 0
                                ? "0" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                        )
                    }
                }
            }
        }
    }

    private func color(_ report: DailyReport, _ value: Double) -> Color {
        if report.reportIdentity == highlighted { return Theme.accent }
        return value >= 0 ? Theme.unattributed : Theme.release
    }
}

extension AppController {
    /// Up to `limit` most recent non-baseline reports for the same storage domain, oldest first.
    func recentTrend(for report: DailyReport, limit: Int = 14) -> [DailyReport] {
        Array(
            reports
                .filter { $0.storageDomainID == report.storageDomainID && !$0.isBaseline }
                .prefix(limit)
                .reversed()
        )
    }
}
