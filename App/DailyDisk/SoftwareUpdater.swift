import AppKit
import Combine
import DailyDiskPlatform
import Foundation
import Sparkle

/// Network/UI work stays in the foreground app; the helper never imports Sparkle.
@MainActor
final class SoftwareUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var message: String?
    let presentation = UpdatePresentation()
    private var updater: SPUUpdater?
    private var observation: AnyCancellable?
    private var driver: GatedUpdateDriver?
    private var manualCheckRequested = false

    init(bundle: Bundle = .main, coordinator: UpdateCoordinator?) {
        super.init()
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
            // First release is explicitly user-initiated; don't honor legacy auto-download defaults.
            updater.automaticallyChecksForUpdates = false
            updater.automaticallyDownloadsUpdates = false
            updater.sendsSystemProfile = false
            try updater.start()
            observation = updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
                self?.canCheck = value
            }
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

    func checkForUpdates() {
        guard canCheck, !manualCheckRequested else { return }
        manualCheckRequested = true
        presentation.beginCheck { [weak self] in self?.updater?.checkForUpdates() }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        manualCheckRequested = false
        driver?.finishedCycle()
        presentation.finishedCheck(
            noUpdate: (error as NSError?)?.domain == SUSparkleErrorDomain
                && (error as NSError?)?.code == Int(SUError.noUpdateError.rawValue))
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
        guard manualCheckRequested, updateCheck == .updates else {
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

    init(hostBundle: Bundle, coordinator: UpdateCoordinator, presentation: UpdatePresentation) {
        self.coordinator = coordinator
        self.presentation = presentation
        super.init(hostBundle: hostBundle, delegate: nil)
    }

    override func showUpdateFound(
        with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        super.showUpdateFound(with: appcastItem, state: state) { [weak self] choice in
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
        guard !extractionStarted, let id = preparationID else { return }
        preparationID = nil
        Task { try? await coordinator.cancelSparkleDownload(id: id) }
    }
}
