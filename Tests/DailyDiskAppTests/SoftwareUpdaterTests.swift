import Foundation
import Testing

@testable import DailyDiskApp

@Test @MainActor
func updateConfigurationRequiresExplicitTrustedSource() {
    let key = Data(repeating: 7, count: 32).base64EncodedString()
    let valid: [String: Any] = [
        "DailyDiskUpdatesEnabled": true, "SUFeedURL": "https://updates.example/appcast.xml", "SUPublicEDKey": key,
    ]
    #expect(SoftwareUpdater.validConfiguration(valid))
    #expect(!SoftwareUpdater.validConfiguration([:]))
    for feed in ["http://updates.example/feed", "https://user:pass@updates.example/feed", "file:///tmp/feed"] {
        var config = valid
        config["SUFeedURL"] = feed
        #expect(!SoftwareUpdater.validConfiguration(config))
    }
    var config = valid
    config["SUPublicEDKey"] = "unset"
    #expect(!SoftwareUpdater.validConfiguration(config))
    let suite = "DailyDiskTests.Updater.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let updater = SoftwareUpdater(coordinator: nil, defaults: defaults)
    #expect(!updater.canCheck)
    #expect(updater.message != nil)
    #expect(updater.responds(to: NSSelectorFromString("updaterShouldPromptForPermissionToCheckForUpdates:")))
    updater.checkAutomaticallyIfDue()
    #expect(updater.availableUpdate == nil)
}

@Test @MainActor
func settingsDismissalIsAnUpdateBarrierAndRestoresAfterNoUpdate() {
    let presentation = UpdatePresentation()
    presentation.showsSettings = true
    var checks = 0
    presentation.beginCheck { checks += 1 }
    #expect(!presentation.showsSettings)
    #expect(checks == 0)
    presentation.settingsDidDismiss()
    #expect(checks == 1)
    presentation.settingsDidDismiss()
    #expect(checks == 1)
    #expect(!presentation.showsSettings)
    presentation.finishedCheck(noUpdate: true)
    #expect(presentation.showsSettings)
}

@Test @MainActor
func menuCheckDoesNotInventASettingsWindow() {
    let presentation = UpdatePresentation()
    var checks = 0
    presentation.beginCheck { checks += 1 }
    #expect(checks == 1)
    presentation.finishedCheck(noUpdate: true)
    #expect(!presentation.showsSettings)
}

@Test @MainActor
func installWaitsForSettingsReopenedDuringDownload() {
    let presentation = UpdatePresentation()
    presentation.beginCheck {}
    presentation.showsSettings = true
    var installations = 0
    presentation.prepareForInstallation { installations += 1 }
    #expect(presentation.installing)
    #expect(!presentation.showsSettings)
    #expect(installations == 0)
    presentation.settingsDidDismiss()
    #expect(installations == 1)
    presentation.settingsDidDismiss()
    #expect(installations == 1)
    presentation.finishedCheck(noUpdate: false)
    #expect(!presentation.installing)
    #expect(!presentation.showsSettings)
}

@Test @MainActor
func failedOrCancelledCheckDoesNotRestoreStaleSettingsIntent() {
    let presentation = UpdatePresentation()
    presentation.showsSettings = true
    presentation.beginCheck {}
    presentation.settingsDidDismiss()
    presentation.finishedCheck(noUpdate: false)
    #expect(!presentation.showsSettings)
    presentation.beginCheck {}
    presentation.finishedCheck(noUpdate: true)
    #expect(!presentation.showsSettings)
}

@Test
func downloadConsentIsSingleUseAndBoundToTheDisplayedBuild() {
    var intent = UpdateDownloadIntent()
    let unsolicited = intent.consume(matching: "21", notDownloaded: true)
    #expect(!unsolicited)
    intent.build = "21"
    let changedTarget = intent.consume(matching: "22", notDownloaded: true)
    #expect(!changedTarget)
    let staleTarget = intent.consume(matching: "21", notDownloaded: true)
    #expect(!staleTarget)
    intent.build = "21"
    let resumed = intent.consume(matching: "21", notDownloaded: false)
    #expect(!resumed)
    intent.build = "21"
    let download = intent.consume(matching: "21", notDownloaded: true)
    #expect(download)
    let repeated = intent.consume(matching: "21", notDownloaded: true)
    #expect(!repeated)
}
