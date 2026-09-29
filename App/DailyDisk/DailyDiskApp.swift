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
    @State private var section: MainSection? = .overview
    @State private var showsSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("DailyDisk") {
            MainWindow(controller: controller, section: $section, showsSettings: $showsSettings)
                .frame(minWidth: 900, minHeight: 600)
                .tint(Theme.accent)
                .sheet(isPresented: $showsSettings) {
                    PreferencesView(controller: controller)
                }
                .task { await controller.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await controller.refresh() } }
                }
        }
        .defaultSize(width: 1100, height: 740)
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
                Text("设置").font(.title3.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            TabView {
                SettingsView(controller: controller)
                    .tabItem { Label("通用", systemImage: "gearshape") }
                FullDiskAccessView(controller: controller)
                    .tabItem { Label("磁盘权限", systemImage: "lock.shield") }
                DiagnosticsView(controller: controller)
                    .tabItem { Label("诊断", systemImage: "stethoscope") }
            }
        }
        .frame(width: 720, height: 600)
    }
}
