import AppKit
import Foundation
import Observation
import SwiftUI
import TunnelKit

/// Once a day (Settings › General › Check for updates automatically), asks GitHub for the latest
/// release and, when it is newer, says so in the menu and in General. The only network request
/// Portkeep makes itself. Failures are logged, never shown, except after Check for Updates….
@MainActor @Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// A newer release, once one has been found.
    private(set) var available: Release?
    private(set) var checking = false
    /// What the last Check for Updates… found, for General.
    private(set) var manualResult: String?

    @ObservationIgnored private var timer: Timer?

    static var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "checkForUpdates") }
    }

    private static var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck") }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Installed with Homebrew, so the way to update is `brew upgrade`.
    static var isHomebrew: Bool { ReleaseCheck.isHomebrewInstall(appPath: Bundle.main.bundlePath) }

    /// Checks now if a day has passed, then looks again every hour whether one has. Not for a
    /// development data folder (UI tests, screenshots), which stays off the network.
    func start() {
        guard ProcessInfo.processInfo.environment["PORTKEEP_DATA_DIR"] == nil else { return }
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.shared.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard Self.automatic, ReleaseCheck.isDue(lastCheck: Self.lastCheck, now: .now) else { return }
        Task { await check(manual: false) }
    }

    func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        if manual { manualResult = nil }
        var request = URLRequest(url: ReleaseCheck.latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Portkeep/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let release = Release(gitHubJSON: data) else {
                NSLog("Portkeep: update check got HTTP %d without a release", status)
                if manual { manualResult = String(localized: "Couldn’t check for updates. Try again later.") }
                return
            }
            Self.lastCheck = .now
            available = ReleaseCheck.newer(release, than: Self.currentVersion)
            if manual, available == nil {
                manualResult = String(localized: "Portkeep \(Self.currentVersion) is the latest version.")
            }
        } catch {
            NSLog("Portkeep: update check failed: %@", error.localizedDescription)
            if manual { manualResult = String(localized: "Couldn’t check for updates. Try again later.") }
        }
    }

    func openReleaseNotes() {
        if let release = available { NSWorkspace.shared.open(release.pageURL) }
    }

    func download() {
        if let release = available { NSWorkspace.shared.open(release.dmgURL ?? release.pageURL) }
    }

    func copyUpgradeCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ReleaseCheck.upgradeCommand, forType: .string)
    }
}

/// "Portkeep X is available" with Release Notes and the way to upgrade: the Homebrew command for a
/// Homebrew install, the download otherwise. In the menu and in General.
struct UpdateBanner: View {
    let release: Release
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Portkeep \(release.version.description) is available", systemImage: "arrow.down.circle")
            HStack(spacing: 6) {
                buttons
            }
        }
        .font(.system(size: 11))
        .controlSize(.small)
    }

    @ViewBuilder private var buttons: some View {
        Button("Release Notes") { UpdateChecker.shared.openReleaseNotes() }
        if UpdateChecker.isHomebrew {
            Button(copied ? "Copied" : "Copy Upgrade Command") {
                UpdateChecker.shared.copyUpgradeCommand()
                copied = true
            }
            .help(ReleaseCheck.upgradeCommand)
        } else {
            Button("Download") { UpdateChecker.shared.download() }
        }
    }
}
