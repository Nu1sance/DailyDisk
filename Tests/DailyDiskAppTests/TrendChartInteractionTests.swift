import Foundation
import Testing

@testable import DailyDiskApp

@Test("Trend columns include date labels and zero-height bars but exclude axes and margins")
@MainActor
func trendColumnHitRegions() {
    let plot = CGRect(x: 40, y: 8, width: 280, height: 80)
    for index in 0..<14 {
        for y in [8.0, 48.0, 100.0, 120.0] {
            #expect(
                TrendChartView.reportIndex(
                    at: CGPoint(x: 50 + Double(index) * 20, y: y),
                    plot: plot, chartHeight: 120, count: 14) == index)
        }
    }
    for point in [
        CGPoint(x: 39, y: 40), CGPoint(x: 320, y: 40),
        CGPoint(x: 50, y: 7), CGPoint(x: 50, y: 121),
    ] {
        #expect(TrendChartView.reportIndex(at: point, plot: plot, chartHeight: 120, count: 14) == nil)
    }
    #expect(TrendChartView.reportIndex(at: CGPoint(x: 40, y: 8), plot: plot, chartHeight: 120, count: 14) == 0)
    #expect(TrendChartView.reportIndex(at: CGPoint(x: 319, y: 8), plot: plot, chartHeight: 120, count: 14) == 13)
    #expect(TrendChartView.reportIndex(at: .zero, plot: .zero, chartHeight: 120, count: 0) == nil)
}
