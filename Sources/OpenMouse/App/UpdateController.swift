import AppKit
import Observation
import Sparkle

/// Where the app is in the Sparkle update cycle.
enum UpdateStatus: Equatable {
    case notChecked
    case checking
    case upToDate
    case available
    case installing
    /// An update exists but this user can't write the app bundle, so the
    /// silent install would dead-end in an admin prompt they can't answer.
    case requiresAdmin
    case unavailable
    case failed
}

/// Drives Sparkle with no Sparkle windows. A background check that finds an
/// update lights up the "Update App" button; clicking it
/// (`installAvailableUpdate`) downloads, installs, and relaunches silently.
@MainActor
@Observable
final class UpdateController: NSObject, SPUUserDriver {
    private(set) var status: UpdateStatus = .notChecked
    private(set) var latestVersion: String?
    private(set) var message: String?

    @ObservationIgnored private var updater: SPUUpdater?
    /// The install decision Sparkle hands over when it finds an update, held
    /// until the user clicks the button.
    @ObservationIgnored private var pendingInstall: ((SPUUserUpdateChoice) -> Void)?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    /// Release builds carry a feed and public key; local builds don't, so they
    /// never replace themselves with a release.
    var isConfigured: Bool {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        return feedURL?.isEmpty == false && publicKey?.isEmpty == false
    }

    func start() {
        guard updater == nil else { return }
        guard isConfigured else {
            emit(.unavailable, message: "Updates are only available in release builds.")
            return
        }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
        do {
            try updater.start()
            self.updater = updater
        } catch {
            emit(.unavailable, message: error.localizedDescription)
        }
    }

    /// A user-initiated check. Background checks only report when they find
    /// something; this always ends in found, not found, or an error.
    func checkForUpdates() {
        guard let updater else {
            emit(.unavailable, message: message ?? "Updater unavailable")
            return
        }
        // Ignored while another session (e.g. a background check) is running;
        // showing "Checking…" then would stick, since no callback follows.
        guard updater.canCheckForUpdates else { return }
        emit(.checking)
        updater.checkForUpdates()
    }

    /// The user clicked "Update App": resume the update Sparkle already found
    /// and let it download, install, and relaunch. With nothing pending, check.
    func installAvailableUpdate() {
        guard let pendingInstall else {
            checkForUpdates()
            return
        }
        self.pendingInstall = nil
        emit(.installing, latestVersion: latestVersion)
        pendingInstall(.install)
    }

    private func emit(_ status: UpdateStatus, latestVersion: String? = nil, message: String? = nil) {
        self.status = status
        self.latestVersion = latestVersion
        self.message = message
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard FileManager.default.isWritableFile(atPath: Bundle.main.bundlePath) else {
            reply(.dismiss)
            emit(.requiresAdmin, latestVersion: appcastItem.displayVersionString)
            return
        }
        pendingInstall = reply
        emit(.available, latestVersion: appcastItem.displayVersionString)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error) async {
        emit(.upToDate, message: error.localizedDescription)
    }

    func showUpdaterError(_ error: any Error) async {
        pendingInstall = nil
        emit(.failed, message: error.localizedDescription)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

    func showDownloadDidReceiveData(ofLength length: UInt64) {}

    func showDownloadDidStartExtractingUpdate() {}

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {}

    func dismissUpdateInstallation() {
        pendingInstall = nil
    }
}
