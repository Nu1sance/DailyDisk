import DailyDiskPlatform
import Foundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("每日运行") {
                LabeledContent("计划时间", value: "每天 05:00")
                LabeledContent("定时任务", value: launchStatusLabel)
                HStack {
                    if controller.launchAgentStatus == .enabled
                        || controller.launchAgentStatus == .requiresApproval
                    {
                        Button("移除每日任务") {
                            Task { await controller.uninstallDailyRun() }
                        }
                    } else {
                        Button("安装每日任务") {
                            Task { await controller.installDailyRun() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if controller.launchAgentStatus == .requiresApproval {
                        Button("打开登录项设置") {
                            controller.openLoginItemsSettings()
                        }
                    }
                }
                if controller.helperRuntimeStatus?.isRunning == true {
                    Button("停止当前后台任务", role: .destructive) {
                        Task { await controller.stopCurrentHelper() }
                    }
                    .disabled(
                        controller.scanState.progress.map { !$0.phase.allowsCancellation } ?? false
                    )
                }
                Text("错过计划时间后，登录时的到期检查会补跑；任务完成后立即退出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("通知") {
                LabeledContent("当前状态", value: notificationLabel)
                if controller.notificationState == .denied {
                    Button("打开通知设置") {
                        controller.openNotificationSettings()
                    }
                } else {
                    Button("请求通知权限") {
                        Task { await controller.requestNotifications() }
                    }
                    .disabled(controller.notificationState == .authorized)
                }
                if let message = controller.actionMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = controller.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("锁屏通知只包含汇总数值，不显示完整文件路径。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("高级操作") {
                Button("重新完整检查磁盘") {
                    Task { await controller.scanNow(requestedMode: .fullReconciliation) }
                }
                .disabled(controller.scanState.isActive || controller.launchAgentStatus != .enabled)
                Text("通常无需手动使用。DailyDisk 每天 05:00 会自动完整核对一次。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("本地数据") {
                LabeledContent("数据库", value: "~/Library/Application Support/DailyDisk")
                HStack {
                    Button("打开私有数据目录") { controller.openDataDirectory() }
                    Button("打开最近报告") { controller.openLatestReport() }
                        .disabled(controller.latestReport == nil)
                }
                Text("文件路径、索引和报告均保存在本机，不上传遥测。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("危险区") {
                Button("重置历史与基线…", role: .destructive) {
                    confirmReset = true
                }
                .disabled(controller.scanState.isActive)
                Text("这会移除定时任务，并删除 DailyDisk 的数据库、基线、报告、日志和提醒状态；不会删除你的文件，也不会撤销完全磁盘访问或通知权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .confirmationDialog(
            "确认重置 DailyDisk？",
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button("删除历史与基线", role: .destructive) {
                Task { await controller.resetHistory() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("重置后，下一次扫描会重新建立完整基线。完全磁盘访问和通知授权不会自动撤销。")
        }
    }

    private var launchStatusLabel: String {
        switch controller.launchAgentStatus {
        case .enabled: "已启用"
        case .notRegistered: "未安装"
        case .requiresApproval: "等待系统批准"
        case .notFound: "应用资源缺失"
        case .unknown: "未知"
        }
    }

    private var notificationLabel: String {
        switch controller.notificationState {
        case .notDetermined: "尚未请求"
        case .denied: "已拒绝"
        case .authorized: "已允许"
        case .provisional: "临时允许"
        case .ephemeral: "临时会话"
        case .unknown: "未知"
        }
    }
}
