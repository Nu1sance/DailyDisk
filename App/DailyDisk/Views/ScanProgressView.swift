import DailyDiskCore
import Foundation
import SwiftUI

struct ScanProgressView: View {
    let state: AppScanState
    let onCancel: () -> Void
    @State private var showsDetails = false

    var body: some View {
        if let progress = state.progress {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    ProgressView().controlSize(.small).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(isCancelling ? "正在取消检查" : progress.phase.userTitle)
                            .font(.title3.weight(.semibold))
                        Text(
                            isCancelling
                                ? "正在清理本次临时索引。文件较多时可能需要几分钟，已保存的结果会保留。"
                                : progress.phase.userDetail
                        )
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if progress.phase.allowsCancellation && !isCancelling {
                        Button("取消检查", role: .cancel, action: onCancel)
                    }
                }
                if !progress.phase.isSpaceMaintenance && progress.phase != .cleaningUpFailedRun && !isCancelling {
                    HStack(spacing: 6) {
                        stage("读取文件", active: progress.phase.sequenceRank < 8)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        stage("核对变化", active: (8...10).contains(progress.phase.sequenceRank))
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        stage("保存结果", active: progress.phase.sequenceRank >= 11)
                    }
                    .accessibilityElement(children: .combine)
                }
                if !progress.phase.isSpaceMaintenance {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                progress.counters.visitedPaths > 0
                                    ? "\(progress.counters.visitedPaths.formatted()) 个文件与目录"
                                    : "\(progress.counters.processedEvents.formatted()) 条变化记录"
                            )
                            .font(.system(size: 24, weight: .semibold)).monospacedDigit()
                            Text(progress.counters.visitedPaths > 0 ? "已检查" : "已读取")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("已用时 \(elapsed(progress.startedAt, context.date))").monospacedDigit()
                                Text(waitingStatus ?? updateLabel(progress.updatedAt, context.date))
                                    .foregroundStyle(
                                        waitingStatus == nil && context.date.timeIntervalSince(progress.updatedAt) > 15
                                            ? .orange : .secondary)
                            }.font(.caption)
                        }
                    }
                } else {
                    Text(progress.startedAt, style: .timer).monospacedDigit()
                }
                if progress.phase == .preservingOpaqueInventory {
                    Text(
                        "已处理 \(progress.counters.processedOpaqueRoots.formatted()) 个无法读取的目录或路径，保留 \(progress.counters.preservedPaths.formatted()) 条历史记录"
                    )
                    .font(.callout).monospacedDigit()
                }
                if progress.phase.isSpaceMaintenance {
                    Text("正在维护数据，请等待完成。此阶段不可取消，可以关闭窗口。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if progress.phase == .cleaningUpFailedRun {
                    Text("可以关闭窗口，后台会安全结束本次检查。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !progress.phase.allowsCancellation && !isCancelling {
                    Text("正在保存结果，请稍候。此阶段不可取消。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("可以关闭窗口，检查会在后台继续。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !progress.phase.isSpaceMaintenance {
                    DisclosureGroup("检查详情", isExpanded: $showsDetails) {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                            counter("读取的变化记录", progress.counters.processedEvents)
                            counter("检查的文件与目录", progress.counters.visitedPaths)
                            counter("已索引对象", progress.counters.indexedObjects)
                            counter("无法读取", progress.counters.unreadablePaths)
                            counter("检查期间发生变化", progress.counters.transientErrors)
                        }.font(.caption).padding(.top, 10)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            .card(padding: 22)
        }
    }

    private func stage(_ title: String, active: Bool) -> some View {
        Text(title).font(.caption.weight(active ? .semibold : .regular))
            .foregroundStyle(active ? Theme.accent : .secondary)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(active ? Theme.accent.opacity(0.12) : .clear, in: Capsule())
    }

    private func counter(_ label: String, _ value: UInt64) -> some View {
        GridRow {
            Text(label)
            Text(value.formatted()).monospacedDigit()
        }
    }

    private var isCancelling: Bool {
        if case .cancellationRequested = state { return true }
        return state.progress?.phase == .cancelling
    }

    private var waitingStatus: String? {
        if isCancelling || state.progress?.phase == .cleaningUpFailedRun {
            return "等待后台完成清理"
        }
        switch state.progress?.phase {
        case .committing, .publishingReport, .notifying, .applyingRetention:
            return "等待后台保存完成"
        default:
            return nil
        }
    }

    private func elapsed(_ start: Date, _ end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func updateLabel(_ update: Date, _ now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(update)))
        return seconds < 3 ? "刚刚收到进度" : "\(seconds) 秒前收到进度"
    }
}

extension ScanProgressPhase {
    var userTitle: String {
        switch self {
        case .cleaningRetiredInventory: "正在清理过期基线"
        case .reclaimingSpace: "正在回收数据库空间"
        case .verifyingMaintenance: "正在验证维护结果"
        case .queued, .waitingForWriter: "等待后台开始检查"
        case .preparing, .discoveringStorage: "正在准备检查"
        case .recoveringInterruptedRun: "正在恢复上次检查"
        case .replayingEvents: "正在读取文件变化"
        case .scanningFiles: "正在检查磁盘文件"
        case .preservingOpaqueInventory: "正在保留无法读取目录的历史记录"
        case .catchingUpEvents: "正在补齐最新变化"
        case .sealingInventory, .reconciling: "正在核对空间变化"
        case .collectingDiagnostics: "正在检查其他空间占用"
        case .committing, .publishingReport, .notifying, .applyingRetention: "正在保存检查结果"
        case .cleaningUpFailedRun: "检查遇到问题，正在清理"
        case .cancelling: "正在取消检查"
        case .completed: "检查已完成"
        case .cancelled: "检查已取消"
        case .failed: "检查未完成"
        }
    }

    var userDetail: String {
        switch self {
        case .cleaningRetiredInventory: "移除已超过恢复窗口的旧库存，历史报告和当前基线会保留。"
        case .reclaimingSpace: "正在整理数据库并释放空闲空间，较大的数据库可能需要几分钟。"
        case .verifyingMaintenance: "正在检查数据库、当前基线和报告是否完整。"
        case .queued, .waitingForWriter: "请求已收到，正在等待后台任务就绪。"
        case .preparing, .discoveringStorage: "正在识别内置磁盘并读取已有记录。"
        case .recoveringInterruptedRun: "正在清理上次未完成的检查。文件较多时可能需要几分钟，已保存的记录会保留。"
        case .replayingEvents: "读取自上次检查以来发生变化的文件。"
        case .scanningFiles: "正在逐项读取文件大小。首次检查可能需要较长时间。"
        case .preservingOpaqueInventory: "文件遍历已完成，正在保留本次无法读取的旧记录，避免把它们误判为删除。"
        case .catchingUpEvents: "把检查期间发生的文件变化也计入结果。"
        case .sealingInventory, .reconciling: "文件读取已完成，正在计算增长与释放的空间。"
        case .collectingDiagnostics: "检查磁盘快照及仍被占用的已删除文件。"
        case .committing: "正在保存本次检查。索引较大时可能需要几分钟，完成后会自动显示结果。"
        case .publishingReport, .notifying, .applyingRetention: "正在生成报告并完成后续处理，结果随后会自动显示。"
        case .cleaningUpFailedRun: "正在移除本次未完成的数据，已保存的记录会保留。文件较多时可能需要几分钟。"
        case .cancelling, .cancelled: "已保存的记录不会改变。"
        case .completed: "结果已保存。"
        case .failed: "已保存的记录仍然保留。"
        }
    }
}
