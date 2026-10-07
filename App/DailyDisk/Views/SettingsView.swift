import DailyDiskCore
import DailyDiskPlatform
import Foundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("软件更新") {
                SoftwareUpdateSettings(updater: controller.softwareUpdater)
                LabeledContent("版本", value: "\(DailyDiskProduct.version) (\(DailyDiskProduct.installedBuildNumber))")
                if controller.updatePreparation != nil {
                    Text(updatePreparationMessage)
                    Button("恢复运行") { Task { await controller.restoreAfterUpdate() } }
                        .disabled(
                            controller.isPreparingUpdate
                                || controller.updatePreparation?.requiresExternalInstallationResolution == true
                                || (controller.updatePreparation?.phase == .sparkleInstalling
                                    && controller.updatePreparation?.targetBuild
                                        != DailyDiskProduct.installedBuildNumber)
                        )
                }
            }

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
                Toggle(
                    "检查完成后通知",
                    isOn: Binding(
                        get: { controller.completionNotifications.enabled },
                        set: { value in Task { await controller.setNotificationPreferences(enabled: value) } }))
                Toggle(
                    "播放提示音",
                    isOn: Binding(
                        get: { controller.completionNotifications.sound },
                        set: { value in Task { await controller.setNotificationPreferences(sound: value) } }))
                Toggle(
                    "应用图标显示未读报告角标",
                    isOn: Binding(
                        get: { controller.completionNotifications.badges },
                        set: { value in Task { await controller.setNotificationPreferences(badges: value) } }))
                HStack {
                    Button("发送测试通知") { Task { await controller.sendTestNotification() } }
                    Button("全部标为已读") { Task { await controller.markAllReportsRead() } }
                        .disabled(controller.completionNotifications.unread.isEmpty)
                }
                Text("最近未读报告：\(controller.completionNotifications.unread.count) 份。打开对应历史报告后清除角标；通知不显示文件路径。")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.completionNotifications.lastDelivery == .unavailable {
                    Text("最近一次通知未能提交，检查报告仍已保存。请检查系统通知设置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("当前状态", value: notificationLabel)
                if controller.notificationState == .denied {
                    Button("打开通知设置") {
                        controller.openNotificationSettings()
                    }
                } else {
                    Button("启用或更新通知权限") {
                        Task { await controller.requestNotifications() }
                    }
                    Button("打开通知设置") { controller.openNotificationSettings() }
                }
                Text("横幅、声音和角标仍以系统通知设置及专注模式为准。")
                    .font(.caption).foregroundStyle(.secondary)
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
                if controller.updatePreparation == nil {
                    Button("暂停运行以手动替换应用") { Task { await controller.prepareForUpdate() } }
                        .disabled(controller.isPreparingUpdate)
                    Text("仅在手动替换应用时使用：暂停新扫描并暂时移除每日任务，完成后在软件更新中恢复运行。应用内更新会自动处理这些步骤。")
                        .font(.caption).foregroundStyle(.secondary)
                }
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

    private var updatePreparationMessage: String {
        switch controller.updatePreparation?.phase {
        case .externalInstalling:
            "Homebrew 安装尚未完成，扫描保持暂停。若安装已中断，请退出应用并重试原 brew 命令。"
        case .externalRecoveryRequired:
            "Homebrew 安装需要恢复。请退出应用并重试原 brew 命令；不要删除更新状态文件或强行恢复每日任务。"
        case .sparkleInstalling:
            "正在更新，扫描已暂停；新版本启动后会恢复原有每日任务。若安装中断，请重新检查更新并完成安装。"
        default:
            "已进入更新准备，新的扫描已暂停。手动安装完成或放弃安装后，请恢复运行。"
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

private struct SoftwareUpdateSettings: View {
    @ObservedObject var updater: SoftwareUpdater
    var body: some View {
        CheckForSoftwareUpdates(updater: updater)
        if let message = updater.message {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
    }
}
