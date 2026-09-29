import DailyDiskCore
import Foundation
import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("诊断")
                        .font(.title2.weight(.semibold))
                    Text("检查数据库、后台任务和最近运行；复制内容始终经过脱敏。")
                        .foregroundStyle(.secondary)
                }

                databaseHealth
                helperStatus
                recentRuns
                errorSummary

                HStack {
                    Button(controller.isVerifying ? "正在验证…" : "验证数据库") { Task { await controller.verifyDatabase() } }
                        .disabled(controller.isVerifying || controller.scanState.isActive)
                    Button("复制脱敏诊断") {
                        Task { await controller.copySanitizedDiagnostics() }
                    }
                }
                if let error = controller.errorMessage { Text(error).foregroundStyle(.orange) }
                if let message = controller.actionMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(32)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .task {
            if controller.inspectionSnapshot == nil { await controller.refresh() }
        }
    }

    @ViewBuilder
    private var databaseHealth: some View {
        GroupBox("数据库健康") {
            VStack(alignment: .leading, spacing: 10) {
                if let snapshot = controller.inspectionSnapshot {
                    switch snapshot.health {
                    case .notChecked:
                        Label("尚未执行完整验证", systemImage: "checkmark.shield")
                    case .notInitialized:
                        Label("尚未建立数据库", systemImage: "circle.dotted")
                    case .waitingForWriter:
                        Label("等待扫描完成后执行严格检查", systemImage: "hourglass")
                            .foregroundStyle(.orange)
                    case .verified(let verification):
                        Label(
                            verification.isHealthy ? "数据库健康" : "数据库需要检查",
                            systemImage: verification.isHealthy
                                ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(verification.isHealthy ? .green : .orange)
                        LabeledContent(
                            "Schema",
                            value: "\(verification.schemaVersion) / \(verification.expectedSchemaVersion)"
                        )
                        LabeledContent("外键违规", value: verification.foreignKeyViolationCount.formatted())
                        LabeledContent("不变量违规", value: verification.invariantViolationCount.formatted())
                        LabeledContent("遗留运行", value: verification.abandonedRunCount.formatted())
                    }
                    if let diagnostics = snapshot.diagnostics {
                        Divider()
                        LabeledContent("数据库", value: bytes(diagnostics.databaseBytes))
                        LabeledContent("WAL", value: bytes(diagnostics.walBytes))
                        Text(
                            diagnostics.tableCounts.keys.sorted().map {
                                "\($0): \(diagnostics.tableCounts[$0] ?? 0)"
                            }.joined(separator: "   ")
                        )
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    }
                } else {
                    ProgressView()
                }
            }
            .padding(.top, 6)
        }
    }

    private var helperStatus: some View {
        GroupBox("后台任务") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("注册", value: launchStatus)
                LabeledContent(
                    "运行",
                    value: controller.helperRuntimeStatus?.isRunning == true ? "正在运行" : "未运行"
                )
                if let pid = controller.helperRuntimeStatus?.processID {
                    LabeledContent("PID", value: pid.formatted())
                }
                if let code = controller.helperRuntimeStatus?.lastExitCode {
                    LabeledContent("上次退出", value: code.formatted())
                }
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var recentRuns: some View {
        GroupBox("最近运行") {
            if let runs = controller.inspectionSnapshot?.recentRuns, !runs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(runs.prefix(8).enumerated()), id: \.offset) { index, run in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.startedAt, format: .dateTime.month().day().hour().minute())
                                Text("\(run.kind.rawValue) · \(run.reason.rawValue)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(run.status.rawValue)
                                .font(.caption.weight(.medium))
                        }
                        .padding(.vertical, 7)
                        if index != min(runs.count, 8) - 1 { Divider() }
                    }
                }
            } else {
                Text("没有运行记录").foregroundStyle(.secondary).padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var errorSummary: some View {
        if let errors = controller.inspectionSnapshot?.recentErrorKinds, !errors.isEmpty {
            GroupBox("最近错误类别") {
                ForEach(errors.keys.sorted(), id: \.self) { key in
                    LabeledContent(key, value: (errors[key] ?? 0).formatted())
                }
                .padding(.top, 6)
            }
        }
    }

    private var launchStatus: String {
        switch controller.launchAgentStatus {
        case .enabled: "已启用"
        case .notRegistered: "未安装"
        case .requiresApproval: "等待批准"
        case .notFound: "资源缺失"
        case .unknown: "未知"
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
