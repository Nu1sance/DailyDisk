import DailyDiskCore
import Foundation
import SwiftUI

/// Only a non-overlapping subset of the stored top ranking is charted. This is
/// not a partition of physical disk usage, nor a complete positive file ledger.
struct GrowthBreakdown {
    let sources: [RankedPathChange]
    let total: Double

    init(ranking: [RankedPathChange]) {
        let positive = ranking.filter { $0.allocatedDelta > 0 }
        var seen = Set<RelativePath>()
        sources = Array(
            positive.filter { candidate in
                !positive.contains { other in
                    candidate.path != other.path && PathPolicy.isEqual(other.path, orDescendantOf: candidate.path)
                } && seen.insert(candidate.path).inserted
            }.prefix(5)
        )
        total = sources.reduce(0) { $0 + Double($1.allocatedDelta) }
    }

    func fraction(at index: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(sources[index].allocatedDelta) / total
    }

    func start(at index: Int) -> Double {
        sources.prefix(index).reduce(0) { $0 + Double($1.allocatedDelta) } / total
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

struct GrowthBreakdownView: View {
    let ranking: [RankedPathChange]
    let disclosePaths: Bool
    private let colors: [Color] = [
        Color(red: 0.16, green: 0.40, blue: 0.74),
        Color(red: 0.10, green: 0.58, blue: 0.55),
        Color(red: 0.76, green: 0.48, blue: 0.16),
        Color(red: 0.55, green: 0.39, blue: 0.70),
        Color(red: 0.50, green: 0.56, blue: 0.64),
    ]

    var body: some View {
        let model = GrowthBreakdown(ranking: ranking)
        VStack(alignment: .leading, spacing: 14) {
            if model.sources.isEmpty {
                Text("这次没有记录到文件占用增长。").foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 24) {
                        ring(model).frame(width: 156, height: 156)
                        rows(model).frame(width: 440)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        ring(model).frame(width: 140, height: 140).frame(maxWidth: .infinity)
                        rows(model)
                    }
                }
                Text("比例仅针对上面列出的文件增长来源，已去除相互包含的上级目录。它不是全部文件增长，也不是磁盘净增量；释放的空间不计入饼图。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func ring(_ model: GrowthBreakdown) -> some View {
        ZStack {
            ForEach(model.sources.indices, id: \.self) { index in
                Circle()
                    .trim(from: model.start(at: index), to: min(1, model.start(at: index) + model.fraction(at: index)))
                    .stroke(colors[index], style: StrokeStyle(lineWidth: 24, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .padding(13)
            }
            VStack(spacing: 4) {
                Text("100%").font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("所列增长来源").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("所列文件增长来源占比；比例详见右侧列表")
        .accessibilityElement(children: .ignore)
    }

    private func rows(_ model: GrowthBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.sources.indices, id: \.self) { index in
                let source = model.sources[index]
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(colors[index]).frame(width: 8, height: 8).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            disclosePaths
                                ? sourceDescription(source.path) ?? reversibleDisplayPath(source.path)
                                : "增长来源 \(index + 1)"
                        )
                        .lineLimit(2)
                        if disclosePaths, sourceDescription(source.path) != nil {
                            Text(reversibleDisplayPath(source.path)).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else if !disclosePaths {
                            Text("路径已隐藏").font(.caption).foregroundStyle(.secondary)
                        }
                    }.textSelection(.enabled)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(signedBytes(source.allocatedDelta)).fontWeight(.medium)
                        Text(model.fraction(at: index).formatted(.percent.precision(.fractionLength(1))))
                            .font(.caption).foregroundStyle(.secondary)
                    }.monospacedDigit()
                }
            }
        }
    }
}
