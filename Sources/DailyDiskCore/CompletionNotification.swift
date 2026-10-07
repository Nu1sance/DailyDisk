import Foundation

/// A summary of committed accounting, never paths or an inventory scan.
public enum CompletionNotification {
    public static func message(
        report: DailyReport, availableBytes: Int64?, sound: Bool, badge: Int?, badgeOnly: Bool = false,
        alertReasons: [AlertReason] = []
    ) -> NotificationMessage {
        let physical = report.accounting.physicalUsedDelta
        var body: String
        if let physical {
            if physical > 0 {
                body = "磁盘占用较上次增加 \(bytes(physical))"
            } else if physical < 0 {
                body = "磁盘占用较上次减少 \(bytes(physical == .min ? .max : -physical))"
            } else {
                body = "磁盘占用较上次基本不变"
            }
            body += "；文件净变化 \(signedBytes(report.accounting.reconciledIndexedDelta))"
        } else {
            body = "已建立磁盘基线，下次检查开始显示变化"
        }
        if let availableBytes { body += "；当前可用 \(bytes(availableBytes))" }
        let lowSpace =
            (availableBytes.map { $0 <= AlertThresholds.default.minimumAvailableBytes } ?? false)
            || alertReasons.contains(.lowAvailableFraction) || alertReasons.contains(.lowAvailableBytes)
        if lowSpace { body += "。剩余空间偏低" }
        if report.coverage.unreadablePathCount > 0 {
            body += "。部分位置无法读取，详情见报告"
        } else if !report.diagnostics.isEmpty {
            body += "。检查附有诊断说明，详情见报告"
        }
        if !Set(alertReasons).subtracting([.lowAvailableBytes, .lowAvailableFraction, .scanErrors]).isEmpty {
            body += "。另有空间诊断提示，请查看报告"
        }
        return NotificationMessage(
            identifier: identifier(runID: report.runID.rawValue),
            title: physical == nil ? "DailyDisk 首次检查完成" : "DailyDisk 检查完成",
            body: body, severity: lowSpace || !alertReasons.isEmpty ? .warning : .information,
            playsSound: sound, badgeCount: badge, reportRunID: report.runID.rawValue, badgeOnly: badgeOnly)
    }

    public static func identifier(runID: UUID) -> String { "dailydisk.report.\(runID.uuidString)" }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
    private static func signedBytes(_ value: Int64) -> String { (value > 0 ? "+" : "") + bytes(value) }
}
