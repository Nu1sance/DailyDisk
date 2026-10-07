import AppKit
import Combine
import DailyDiskPlatform
import Foundation
import Sparkle

/// Network/UI work stays in the foreground app; the helper never imports Sparkle.
@MainActor
final class SoftwareUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private var sparkleReady = false
    @Published private(set) var isConfigured = false
    var canCheck: Bool { sparkleReady && state.cycle == nil }
    var availableUpdate: DailyUpdateState.AvailableUpdate? { state.available }
    var automaticallyChecks: Bool {
        get { state.automaticallyChecks }
        set {
            state.automaticallyChecks = newValue
            if newValue { checkAutomaticallyIfDue() }
        }
    }
    @Published private(set) var message: String?
    let presentation = UpdatePresentation()
    private var updater: SPUUpdater?
    private var observation: AnyCancellable?
    private var driver: GatedUpdateDriver?
    private let state: DailyUpdateState
    private let automaticCheckAllowed: () -> Bool
    private var lifecycleObservations = Set<AnyCancellable>()

    init(
        bundle: Bundle = .main, coordinator: UpdateCoordinator?, defaults: UserDefaults = .standard,
        automaticCheckAllowed: @escaping () -> Bool = { true }
    ) {
        let info = bundle.infoDictionary ?? [:]
        let build = info["CFBundleVersion"] as? String ?? "0"
        let context = [
            build, info["SUFeedURL"] as? String ?? "", info["SUPublicEDKey"] as? String ?? "",
            ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        .joined(separator: "\n")
        state = DailyUpdateState(defaults: defaults, context: context, currentBuild: build)
        self.automaticCheckAllowed = automaticCheckAllowed
        super.init()
        state.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &lifecycleObservations)
        guard let coordinator, Self.validConfiguration(bundle.infoDictionary ?? [:]),
            bundle.bundleURL.pathExtension == "app"
        else {
            message = "此构建尚未配置应用内更新。"
            return
        }
        let driver = GatedUpdateDriver(hostBundle: bundle, coordinator: coordinator, presentation: presentation)
        self.driver = driver
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
        self.updater = updater
        do {
            // Our informational probes own scheduling; Sparkle must never schedule UI or downloads.
            updater.automaticallyChecksForUpdates = false
            updater.automaticallyDownloadsUpdates = false
            updater.sendsSystemProfile = false
            try updater.start()
            observation = updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
                self?.sparkleReady = value
            }
            isConfigured = true
            Timer.publish(every: 15 * 60, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in self?.checkAutomaticallyIfDue() }
                .store(in: &lifecycleObservations)
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in self?.checkAutomaticallyIfDue() }
                .store(in: &lifecycleObservations)
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
                .sink { [weak self] _ in self?.checkAutomaticallyIfDue() }
                .store(in: &lifecycleObservations)
        } catch {
            message = "更新配置无法启动，请使用手动安装。"
        }
    }

    static func validConfiguration(_ info: [String: Any]) -> Bool {
        guard info["DailyDiskUpdatesEnabled"] as? Bool == true,
            let feed = info["SUFeedURL"] as? String, let url = URL(string: feed),
            url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil,
            let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32
        else { return false }
        return true
    }

    @objc(updaterShouldPromptForPermissionToCheckForUpdates:)
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    func checkAutomaticallyIfDue() {
        guard let updater, isConfigured, automaticCheckAllowed(),
            state.beginProbe(now: Date(), ready: sparkleReady && !updater.sessionInProgress)
        else { return }
        updater.checkForUpdateInformation()
    }

    func checkForUpdates() {
        beginManualCheck(downloadBuild: nil)
    }

    func downloadAvailableUpdate() {
        guard let hint = availableUpdate else { return }
        beginManualCheck(downloadBuild: hint.build)
    }

    private func beginManualCheck(downloadBuild: String?) {
        guard state.beginManual(ready: canCheck) else { return }
        driver?.downloadIntent.build = downloadBuild
        presentation.beginCheck { [weak self] in self?.updater?.checkForUpdates() }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard item.installationType == "application" else { return }
        state.found(build: item.versionString, version: item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        let noUpdate =
            (error as NSError?)?.domain == SUSparkleErrorDomain
            && (error as NSError?)?.code == Int(SUError.noUpdateError.rawValue)
        if updateCheck == .updateInformation {
            state.finish(.probe, noUpdate: noUpdate)
            return
        }
        guard updateCheck == .updates, state.finish(.manual, noUpdate: noUpdate) else { return }
        driver?.finishedCycle()
        presentation.finishedCheck(noUpdate: noUpdate)
    }

    func updater(
        _ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        guard updateItem.installationType == "application" else {
            throw NSError(
                domain: "DailyDisk.Update", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "仅支持应用程序更新。"])
        }
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard
            (state.cycle == .manual && updateCheck == .updates)
                || (state.cycle == .probe && updateCheck == .updateInformation)
        else {
            throw NSError(domain: "DailyDisk.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: "请手动检查更新。"])
        }
    }
}

/// Standard Sparkle UI with one asynchronous barrier before its Install response.
/// Once extraction starts the external installer can survive the GUI: keep the
/// durable gate until the expected new build opens, including install-on-quit.
@MainActor
private final class GatedUpdateDriver: SPUStandardUserDriver {
    private let coordinator: UpdateCoordinator
    private let presentation: UpdatePresentation
    private var preparationID: UUID?
    private var extractionStarted = false
    var downloadIntent = UpdateDownloadIntent()

    init(hostBundle: Bundle, coordinator: UpdateCoordinator, presentation: UpdatePresentation) {
        self.coordinator = coordinator
        self.presentation = presentation
        super.init(hostBundle: hostBundle, delegate: nil)
    }

    override func showUpdateFound(
        with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let respond: (SPUUserUpdateChoice) -> Void = { [weak self] choice in
            guard let self else {
                reply(.dismiss)
                return
            }
            guard choice == .install else {
                reply(choice)
                return
            }
            Task { @MainActor in
                do {
                    let resuming = try await self.coordinator.hasPendingSparkleInstallation()
                    self.preparationID = try await self.coordinator.prepareSparkleInstallation(
                        targetBuild: appcastItem.versionString)
                    self.extractionStarted = resuming || state.stage != .notDownloaded
                    if state.stage == .notDownloaded {
                        self.presentation.dismissSettings { reply(.install) }
                    } else {
                        self.presentation.prepareForInstallation { reply(.install) }
                    }
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "暂时不能安装更新"
                    alert.informativeText =
                        (error as? UpdatePreparationError)?.errorDescription
                        ?? "无法准备更新。请在设置中检查更新状态；若已暂停运行，请完成待安装更新。"
                    alert.runModal()
                    reply(.dismiss)
                }
            }
        }
        let directlyDownload = downloadIntent.consume(
            matching: appcastItem.versionString, notDownloaded: state.stage == .notDownloaded)
        if directlyDownload {
            // Skipping the offer also skips its normal checking-window dismissal.
            // Reset only the standard driver's presentation before showing download UI.
            super.dismissUpdateInstallation()
            respond(.install)
        } else {
            // A changed target or resumed installation still needs Sparkle's confirmation.
            super.showUpdateFound(with: appcastItem, state: state, reply: respond)
        }
    }

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        super.showReady(toInstallAndRelaunch: { [weak self] choice in
            guard let self else { return }
            if choice == .install {
                do {
                    try UpdateSessionGuard.requireSingleUser()
                    self.presentation.prepareForInstallation { reply(choice) }
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "暂时不能安装更新"
                    alert.informativeText = "请先退出其他用户的登录会话，再重新检查更新以完成安装。"
                    alert.runModal()
                    reply(.dismiss)
                }
            } else {
                reply(choice)
            }
        })
    }

    override func showDownloadDidStartExtractingUpdate() {
        extractionStarted = true
        super.showDownloadDidStartExtractingUpdate()
    }

    func finishedCycle() {
        downloadIntent.build = nil
        guard !extractionStarted, let id = preparationID else { return }
        preparationID = nil
        Task { try? await coordinator.cancelSparkleDownload(id: id) }
    }
}
