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
    let updater = SoftwareUpdater(coordinator: nil)
    #expect(!updater.canCheck)
    #expect(updater.message != nil)
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
