import AppKit
import Sparkle

/// Sparkle, reading the newest GitHub release's appcast.xml (SUFeedURL in Info.plist) once a day.
/// Updates are checked against SUPublicEDKey, so only DMGs signed by the release workflow install.
@MainActor
final class Updater: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    func checkForUpdates() {
        // Peeko has no Dock icon, so bring it forward or Sparkle's window opens behind everything.
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    // A menu bar app: let scheduled update alerts wait politely instead of jumping in front.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
