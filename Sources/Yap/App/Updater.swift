import Foundation
import Sparkle

/// In-app updates via Sparkle, from the appcast attached to the latest GitHub release.
/// Updates are verified with an EdDSA signature; builds without a public key (local builds) don't check.
///
/// Yap lives in the menu bar, so an update window can easily end up behind other apps. Scheduled checks are
/// "gentle": when one finds an update, the menu shows "Update to Yap x.y…" and a message says so, and
/// Sparkle's own window only opens straight away if Yap is the app in front.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?

    /// The version waiting to be installed, if a check found one.
    @Published private(set) var available: String?
    @Published private(set) var lastChecked: Date?

    var isAvailable: Bool { controller != nil }
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    func start() {
        guard controller == nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        lastChecked = controller?.updater.lastUpdateCheckDate
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let v = item.displayVersionString
        MainActor.assumeIsolated { available = v; lastChecked = Date() }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { available = nil; lastChecked = Date() }
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Let Sparkle open its window right away only when Yap is in front; otherwise we nudge (below).
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let v = update.displayVersionString, quiet = !handleShowingUpdate && !state.userInitiated
        MainActor.assumeIsolated {
            available = v
            if quiet { HUD.shared.toast("Yap \(v) is ready. Choose “Update to Yap \(v)…” in Yap's menu", symbol: "arrow.down.circle.fill") }
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { lastChecked = Date() }
    }
}
