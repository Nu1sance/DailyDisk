import AppKit
import DailyDiskCore
import DailyDiskPlatform
import Darwin
import SwiftUI

@main
enum DailyDiskEntryPoint {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == HomebrewInstallation.installCommand
            || arguments.first == HomebrewInstallation.uninstallCommand
        {
            // A Caskroom payload is an installer, not another GUI instance.
            // Avoid registering the staged app with Launch Services.
            Task { exit(await HomebrewInstallation.run(arguments: arguments)) }
            dispatchMain()
        }
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
    @StateObject private var controller: AppController
    @State private var section: MainSection? = .overview
    @StateObject private var updatePresentation: UpdatePresentation

    init() {
        let controller = AppController()
        _controller = StateObject(wrappedValue: controller)
        _updatePresentation = StateObject(wrappedValue: controller.softwareUpdater.presentation)
    }
    @Environment(\.scenePhase) private var scenePhase

    private var settingsBinding: Binding<Bool> {
        Binding(
            get: { updatePresentation.showsSettings },
            set: { if !$0 || !updatePresentation.installing { updatePresentation.showsSettings = $0 } }
        )
    }

    var body: some Scene {
        WindowGroup("DailyDisk") {
            MainWindow(controller: controller, section: $section, showsSettings: settingsBinding)
                .frame(minWidth: 900, minHeight: 600)
                .tint(Theme.accent)
                .sheet(isPresented: settingsBinding, onDismiss: updatePresentation.settingsDidDismiss) {
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
                Button("设置…") { updatePresentation.showsSettings = true }
                    .keyboardShortcut(",")
                    .disabled(updatePresentation.installing)
            }
            CommandGroup(after: .appInfo) {
                CheckForSoftwareUpdates(updater: controller.softwareUpdater)
            }
            CommandGroup(replacing: .appInfo) {
                Button("关于 DailyDisk") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: "DailyDisk", .version: DailyDiskProduct.version,
                            .applicationVersion: DailyDiskProduct.installedBuildNumber,
                        ]
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

struct CheckForSoftwareUpdates: View {
    @ObservedObject var updater: SoftwareUpdater
    var body: some View {
        Button("检查更新…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
    }
}
