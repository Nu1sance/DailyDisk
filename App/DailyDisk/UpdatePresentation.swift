import AppKit
import Combine

/// Continue only after SwiftUI confirms that the settings sheet has disappeared.
/// No timer, forced process termination, or direct manipulation of AppKit sheets.
@MainActor
final class UpdatePresentation: ObservableObject {
    @Published var showsSettings = false
    @Published private(set) var installing = false
    private var afterDismissal: (() -> Void)?
    private var sheetBarrier: SettingsSheetDismissal?
    private var restoreSettings = false

    func beginCheck(_ action: @escaping () -> Void) {
        restoreSettings = showsSettings
        dismissSettings(action)
    }

    func dismissSettings(_ action: @escaping () -> Void) {
        guard afterDismissal == nil else { return }
        let needsSwiftUIDismissal = showsSettings
        afterDismissal = action
        sheetBarrier = SettingsSheetDismissal()
        showsSettings = false
        // A menu action can race a sheet that the user has just dismissed.
        // Even with the binding already false, wait for native detachment.
        if !needsSwiftUIDismissal { settingsDidDismiss() }
    }

    func prepareForInstallation(_ action: @escaping () -> Void) {
        installing = true
        dismissSettings(action)
    }

    func settingsDidDismiss() {
        guard let sheetBarrier else { return }
        sheetBarrier.whenDetached { [weak self] in
            guard let self else { return }
            let action = self.afterDismissal
            self.afterDismissal = nil
            self.sheetBarrier = nil
            action?()
        }
    }

    func finishedCheck(noUpdate: Bool) {
        installing = false
        let reopen = restoreSettings && noUpdate
        restoreSettings = false
        if reopen { showsSettings = true }
    }
}

/// SwiftUI onDismiss can precede AppKit detaching the sheet. Observe the sheets
/// captured before dismissal rather than assuming an animation duration.
@MainActor
private final class SettingsSheetDismissal {
    private let sheets: [(NSWindow, NSWindow)]
    private var observation: NSObjectProtocol?
    private var completion: (() -> Void)?

    init() {
        sheets = (NSApp?.windows ?? []).compactMap { window in
            window.attachedSheet.map { (window, $0) }
        }
        if !sheets.isEmpty {
            observation = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndSheetNotification, object: nil, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.finishIfDetached() }
            }
        }
    }

    func whenDetached(_ action: @escaping () -> Void) {
        completion = action
        finishIfDetached()
    }

    private func finishIfDetached() {
        guard let completion,
            sheets.allSatisfy({ owner, sheet in owner.attachedSheet !== sheet })
        else { return }
        self.completion = nil
        if let observation {
            NotificationCenter.default.removeObserver(observation)
            self.observation = nil
        }
        completion()
    }
}
