import AppKit
import DailyDiskPlatform
import Darwin
import SwiftUI

@main
enum DailyDiskEntryPoint {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == NotificationDelivery.command || arguments.first == NotificationDelivery.statusCommand {
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task { @MainActor in
                exit(await NotificationDelivery.run(arguments: arguments))
            }
            dispatchMain()
        }
        DailyDiskApplication.main()
    }
}

struct DailyDiskApplication: App {
    @StateObject private var controller = AppController()
    @State private var showsHistory = false
    @State private var showsSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("DailyDisk") {
            Group {
                if showsHistory {
                    HistoryView(controller: controller)
                } else {
                    StatusView(controller: controller) { showsHistory = true }
                }
            }
            .frame(minWidth: 760, minHeight: 560)
            .tint(.blue)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("页面", selection: $showsHistory) {
                        Text("概览").tag(false)
                        Text("历史").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                ToolbarItem {
                    Button {
                        showsSettings = true
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showsSettings) {
                PreferencesView(controller: controller)
            }
            .task { await controller.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await controller.refresh() } }
            }
        }
        .defaultSize(width: 840, height: 680)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { showsSettings = true }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .appInfo) {
                Button("关于 DailyDisk") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [.applicationName: "DailyDisk", .version: "0.1.0"]
                    )
                }
            }
        }
    }
}

private struct PreferencesView: View {
    @ObservedObject var controller: AppController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            TabView {
                SettingsView(controller: controller).tabItem { Text("通用") }
                FullDiskAccessView(controller: controller).tabItem { Text("磁盘权限") }
                DiagnosticsView(controller: controller).tabItem { Text("诊断") }
            }
        }
        .frame(width: 720, height: 600)
    }
}
