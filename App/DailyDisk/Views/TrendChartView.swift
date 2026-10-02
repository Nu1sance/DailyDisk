import Charts
import DailyDiskCore
import Foundation
import SwiftUI

/// Physical deltas of the most recent non-baseline reports, oldest first, with the latest highlighted.
struct TrendChartView: View {
    let reports: [DailyReport]
    let highlighted: ReportIdentity?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredIndex: Int?
    @State private var hoverLocation = CGPoint.zero

    var body: some View {
        Chart(Array(reports.enumerated()), id: \.offset) { index, report in
            let value = Double(report.accounting.physicalUsedDelta ?? 0)
            BarMark(
                x: .value("检查", index),
                y: .value("磁盘净变化", value),
                width: .fixed(22)
            )
            .foregroundStyle(hoveredIndex == index ? Theme.chartHover : color(report, value))
            .opacity(hoveredIndex == nil || hoveredIndex == index ? 1 : 0.55)
            .cornerRadius(3)
            .accessibilityLabel(report.generatedAt.formatted(.dateTime.month().day().hour().minute()))
            .accessibilityValue(
                "\(signedBytes(report.accounting.physicalUsedDelta ?? 0))，\((report.accounting.physicalUsedDelta ?? 0).formatted()) 字节"
            )
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let plot = geometry[anchor]
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard plot.contains(location),
                                        let value = proxy.value(atX: location.x - plot.minX, as: Double.self)
                                    else {
                                        hoveredIndex = nil
                                        return
                                    }
                                    hoverLocation = location
                                    let index = Int(value.rounded())
                                    hoveredIndex = reports.indices.contains(index) ? index : nil
                                case .ended:
                                    hoveredIndex = nil
                                }
                            }
                        if let index = hoveredIndex, reports.indices.contains(index) {
                            let width = min(136.0, geometry.size.width)
                            let center = min(max(hoverLocation.x, width / 2), geometry.size.width - width / 2)
                            let preferredY = hoverLocation.y >= 48 ? hoverLocation.y - 28 : hoverLocation.y + 28
                            let centerY = min(max(preferredY, 20), geometry.size.height - 20)
                            hoverCard(reports[index])
                                .frame(width: width, height: 38)
                                .position(x: center, y: centerY)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                                .transition(.opacity)
                        }
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hoveredIndex)
        .onChange(of: reports.map(\.reportIdentity)) { _, _ in hoveredIndex = nil }
        .onDisappear { hoveredIndex = nil }
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

    private func hoverCard(_ report: DailyReport) -> some View {
        let bytes = report.accounting.physicalUsedDelta ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            Text(report.generatedAt.formatted(.dateTime.month().day().hour().minute()))
                .font(.caption2).foregroundStyle(.secondary)
            Text(signedBytes(bytes))
                .font(.caption.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.content, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline))
    }

    private func color(_ report: DailyReport, _ value: Double) -> Color {
        if value >= 0, report.reportIdentity == highlighted { return Theme.accent }
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
