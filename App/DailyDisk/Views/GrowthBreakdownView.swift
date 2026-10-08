import DailyDiskCore
import Foundation
import SwiftUI

/// Only a non-overlapping subset of the stored top ranking is shown. This is
/// not a partition of physical disk usage, nor a complete file ledger.
struct GrowthBreakdown {
    enum Direction {
        case growth
        case release
    }

    let sources: [RankedPathChange]
    let total: Double

    init(ranking: [RankedPathChange], direction: Direction = .growth, includesAncestorRollups: Bool = true) {
        let candidates = ranking.filter {
            direction == .growth ? $0.allocatedDelta > 0 : $0.allocatedDelta < 0
        }
        var seen = Set<RelativePath>()
        sources = Array(
            candidates.filter { candidate in
                (!includesAncestorRollups
                    || !candidates.contains { other in
                        candidate.path != other.path && PathPolicy.isEqual(other.path, orDescendantOf: candidate.path)
                    }) && seen.insert(candidate.path).inserted
            }.prefix(5)
        )
        total = sources.reduce(0) { $0 + abs(Double($1.allocatedDelta)) }
    }

    func fraction(at index: Int) -> Double {
        guard total > 0 else { return 0 }
        return abs(Double(sources[index].allocatedDelta)) / total
    }

    func start(at index: Int) -> Double {
        sources.prefix(index).reduce(0) { $0 + abs(Double($1.allocatedDelta)) } / total
    }

    /// Bar length relative to the largest displayed source.
    func relativeMagnitude(at index: Int) -> Double {
        let largest = sources.map { abs(Double($0.allocatedDelta)) }.max() ?? 0
        guard largest > 0 else { return 0 }
        return abs(Double(sources[index].allocatedDelta)) / largest
    }
}

func sourceDescription(_ path: RelativePath) -> String? {
    // Only fixed system prefixes are translated; arbitrary private paths are
    // never exposed before the user opts into session path disclosure.
    let value = path.displayString
    if value == "private" { return "macOS 系统数据目录" }
    if value == "private/var" { return "系统运行数据：日志、缓存等" }
    if value == "private/var/db" { return "系统数据库与运行状态" }
    if value == "private/var/db/diagnostics" || value.hasPrefix("private/var/db/diagnostics/") {
        return "系统诊断日志"
    }
    if value == "private/var/log" || value.hasPrefix("private/var/log/") { return "系统日志" }
    if value == "private/var/folders" || value.hasPrefix("private/var/folders/") { return "应用缓存与临时数据" }
    if value == "private/var/vm" || value.hasPrefix("private/var/vm/") { return "虚拟内存与休眠数据" }
    if value.hasPrefix("System/Library/AssetsV2/") { return "macOS 下载的系统资源" }
    return nil
}

/// Up to five disjoint growth or release sources, each with a bar relative to the largest one.
struct ChangeSourceList: View {
    let ranking: [RankedPathChange]
    var includesAncestorRollups = true
    let direction: GrowthBreakdown.Direction
    let disclosePaths: Bool

    var body: some View {
        let model = GrowthBreakdown(
            ranking: ranking, direction: direction, includesAncestorRollups: includesAncestorRollups)
        VStack(spacing: 0) {
            if model.sources.isEmpty {
                Text(direction == .growth ? "这次没有记录到文件增长。" : "这次没有记录到释放的空间。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }
            ForEach(model.sources.indices, id: \.self) { index in
                row(model, index)
                if index != model.sources.indices.last { Divider().opacity(0.6) }
            }
        }
    }

    private func row(_ model: GrowthBreakdown, _ index: Int) -> some View {
        let source = model.sources[index]
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                label(source, index).frame(maxWidth: .infinity, alignment: .leading)
                Text(signedBytes(source.allocatedDelta))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .fixedSize()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule()
                        .fill(direction == .growth ? Theme.accent : Theme.release)
                        .frame(width: max(3, proxy.size.width * model.relativeMagnitude(at: index)))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func label(_ source: RankedPathChange, _ index: Int) -> some View {
        if disclosePaths {
            PathDisclosureView(
                path: reversibleDisplayPath(source.path), description: sourceDescription(source.path))
        } else {
            Text("\(direction == .growth ? "增长" : "释放")来源 \(index + 1)")
                + Text("  路径已隐藏").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Physical delta split into its three accounting parts, with the explanation on demand.
struct SpaceCompositionView: View {
    let accounting: AccountingSummary
    @State private var showsExplanation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("空间构成").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    showsExplanation.toggle()
                } label: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("空间构成说明")
                .accessibilityLabel("空间构成说明")
                .popover(isPresented: $showsExplanation, arrowEdge: .bottom) { explanation }
            }
            if let segments = barSegments {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(segments.indices, id: \.self) { index in
                            Rectangle()
                                .fill(segments[index].color)
                                .frame(width: max(2, segments[index].fraction * (proxy.size.width - 4)))
                        }
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
                .accessibilityHidden(true)
            }
            VStack(spacing: 7) {
                legend("文件净变化", accounting.reconciledIndexedDelta, Theme.accent)
                legend("未归因空间", accounting.physicalUnattributedDelta, Theme.unattributed)
                legend("DailyDisk 自身", accounting.dailyDiskOverheadDelta, Theme.overhead)
            }
        }
        .card(padding: 16)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("磁盘净变化 = 文件净变化 + 未归因空间 + DailyDisk 自身")
                .font(.callout.weight(.semibold))
            Text("文件净变化是可追溯到具体文件的增长减去释放。")
            Text("未归因空间可能来自 APFS 快照、元数据、共享块或无法读取的内容，不能归到某个文件夹。")
            Text("DailyDisk 自身是本应用数据库、报告与日志的占用变化。")
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 300, alignment: .leading)
        .padding(16)
    }

    private func legend(_ title: String, _ value: Int64?, _ color: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title)
            Spacer(minLength: 12)
            Text(value.map(signedBytes) ?? "未知").fontWeight(.semibold).monospacedDigit()
        }
        .font(.callout)
    }

    /// A proportional bar is only honest when every non-zero part has the same sign.
    private var barSegments: [(fraction: Double, color: Color)]? {
        guard let unattributed = accounting.physicalUnattributedDelta else { return nil }
        let parts: [(Int64, Color)] = [
            (accounting.reconciledIndexedDelta, Theme.accent),
            (unattributed, Theme.unattributed),
            (accounting.dailyDiskOverheadDelta, Theme.overhead),
        ].filter { $0.0 != 0 }
        guard !parts.isEmpty, parts.allSatisfy({ $0.0 > 0 }) || parts.allSatisfy({ $0.0 < 0 }) else {
            return nil
        }
        let total = parts.reduce(0) { $0 + abs(Double($1.0)) }
        return parts.map { (abs(Double($0.0)) / total, $0.1) }
    }
}

/// Headline delta for a report, followed by its composition when there is a previous run.
struct ReportHeadline: View {
    let report: DailyReport
    let previousDate: Date?
    var numberSize: CGFloat = 52

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 32) {
                summary.frame(minWidth: 260, alignment: .leading)
                Spacer(minLength: 0)
                composition.frame(width: 360)
            }
            VStack(alignment: .leading, spacing: 18) {
                summary
                composition
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(comparisonTitle).font(.callout).foregroundStyle(.secondary)
            Text(report.accounting.physicalUsedDelta.map(signedBytes) ?? "基线已建立")
                .font(.system(size: numberSize, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var composition: some View {
        if !report.isBaseline {
            SpaceCompositionView(accounting: report.accounting)
        }
    }

    private var comparisonTitle: String {
        if report.isBaseline { return "首次检查已完成" }
        guard let previousDate else { return "相比上次检查" }
        return "相比上次检查（\(relativeDateTime(previousDate))）"
    }

    private var caption: String {
        guard let delta = report.accounting.physicalUsedDelta else {
            return "下次检查起，这里会显示磁盘增长和具体来源。"
        }
        return delta > 0 ? "磁盘使用空间增加" : delta < 0 ? "磁盘使用空间减少" : "磁盘使用空间没有净变化"
    }
}

extension AppController {
    /// The report immediately before `report` for the same storage domain.
    func previousReport(before report: DailyReport) -> DailyReport? {
        guard let index = reports.firstIndex(where: { $0.reportIdentity == report.reportIdentity }) else {
            return nil
        }
        return reports[(index + 1)...].first { $0.storageDomainID == report.storageDomainID }
    }
}
