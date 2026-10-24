import AppKit
import CrossCore
import SwiftUI

/// Drives CrossCore's Updater for the UI: the launch check, Gamify > Check for Updates…,
/// and the banner at the top of the main window (docs/updates.md).
@MainActor
final class UpdateController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(Update)
        case unsupported(Update, minimum: String)
        case downloading(Update, received: Int64, expected: Int64)
        /// Unpacking / copying out of the disk image, then handing over to the helper.
        case installing(Update, String)
        case installed(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// The banner is showing (Later hides it until the next check).
    @Published var bannerVisible = false
    @Published private(set) var lastChecked: Date?

    /// Set by AppModel: true while games or Steam started by the app are running.
    var hasRunningJobs: () -> Bool = { false }

    private var task: Task<Void, Never>?

    var updater: Updater { Updater(bundle: Bundle.main.bundleURL, feed: Updater.feedURL()) }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var runtimeVersion: String? { updater.runtimeVersion }

    init() {
        UserDefaults.standard.register(defaults: [Updater.checkOnLaunchKey: true])
    }

    /// Whether this copy can update itself at all: the packaged app, or a checkout build
    /// with GAMIFY_UPDATE_FORCE=1 / the updateForce default.
    func updatesEnabled(project: Project?) -> Bool {
        (project?.bundled ?? false) || Updater.forced()
    }

    private var launched = false

    /// Called once the project is located: report what the last helper run did, then check
    /// (silently: only an available update or a finished install shows the banner).
    func launchOnce(project: Project?) {
        guard !launched else { return }
        launched = true
        if let result = updater.takeLastResult() {
            phase = result.succeeded ? .installed(result.version) : .failed("Updating to \(result.version) failed: \(result.message). Details: ~/Library/Logs/Gamify/update.log")
            bannerVisible = true
            // just updated (or failed to): no check this launch, so the message stays and a
            // failing automatic install cannot loop
            return
        }
        guard updatesEnabled(project: project),
              UserDefaults.standard.bool(forKey: Updater.checkOnLaunchKey) else { return }
        check(userInitiated: false)
    }

    /// Gamify > Check for Updates… and Settings > Check Now: always shows the result.
    func checkNow(project: Project?) {
        guard updatesEnabled(project: project) else {
            phase = .failed("This Gamify runs from the source checkout, which does not update itself. (GAMIFY_UPDATE_FORCE=1 enables updates for testing.)")
            bannerVisible = true
            return
        }
        check(userInitiated: true)
    }

    private func check(userInitiated: Bool) {
        switch phase {
        case .checking, .downloading, .installing: return
        default: break
        }
        phase = .checking
        if userInitiated { bannerVisible = true }
        let updater = self.updater
        task = Task {
            do {
                let result = try await updater.check()
                lastChecked = Date()
                switch result {
                case .upToDate:
                    phase = .upToDate(updater.currentVersion)
                case .available(let update):
                    phase = .available(update)
                    bannerVisible = true
                    // Settings > General > "Install updates automatically" (launch check only)
                    if !userInitiated && UserDefaults.standard.bool(forKey: Updater.autoInstallKey) {
                        install()
                    }
                case .requiresNewerSystem(let update, let minimum):
                    phase = .unsupported(update, minimum: minimum)
                    bannerVisible = true
                }
            } catch {
                lastChecked = Date()
                phase = .failed("Could not check for updates: \(error)")
                // a failed launch check (offline) is not worth a banner
            }
        }
    }

    func later() {
        bannerVisible = false
        if case .downloading = phase { task?.cancel() }
    }

    func install() {
        guard case .available(let update) = phase else { return }
        let updater = self.updater
        if let reason = updater.installBlockedReason(for: update.kind) {
            phase = .failed(reason)
            return
        }
        if update.kind == .full && (hasRunningJobs() || updater.runtimeInUse()) {
            phase = .failed("Gamify \(update.version) replaces the Wine runtime, which Steam or a game is still using. Quit them (Stop Steam on the bottle page), then choose Gamify > Check for Updates… again.")
            return
        }
        phase = .downloading(update, received: 0, expected: update.asset.size)
        task = Task {
            do {
                let file = try await updater.download(update) { received, expected in
                    Task { @MainActor in
                        guard case .downloading = self.phase else { return }
                        self.phase = .downloading(update, received: received, expected: expected > 0 ? expected : update.asset.size)
                    }
                }
                try Task.checkCancellation()
                phase = .installing(update, update.kind == .full ? "Copying the new app out of the disk image…" : "Unpacking…")
                let staged = try await Task.detached { try updater.stage(update, file: file) }.value
                phase = .installing(update, "Restarting Gamify…")
                do {
                    try updater.launchHelper(staged)
                } catch {
                    updater.discard(staged)
                    throw error
                }
                // let the banner draw, then quit; the helper waits for this pid to exit
                try? await Task.sleep(for: .milliseconds(300))
                NSApp.terminate(nil)
            } catch is CancellationError {
                phase = .available(update)
            } catch let error as URLError where error.code == .cancelled {
                phase = .available(update)
            } catch {
                phase = .failed("Updating to \(update.version) failed: \(error)")
                bannerVisible = true
            }
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The update control in the main window's toolbar (CrossApp.swift, `.primaryAction`): a
/// pull-down button whose label shows the state ("Gamify 0.9 available", "Downloading… 40%",
/// "Up to date") and whose menu holds the details and the actions (Install Now, Release
/// Notes, Later / Cancel / OK). Never a modal, never a layout inset (see CrossApp.swift).
struct UpdateBanner: View {
    @EnvironmentObject var updates: UpdateController

    var body: some View {
        if updates.bannerVisible, let content = content {
            Menu {
                if let detail = content.detail {
                    Text(detail)
                    Divider()
                }
                buttons
            } label: {
                Label {
                    HStack(spacing: 6) {
                        if let progress = content.progress {
                            ProgressView(value: progress).frame(width: 60)
                        } else if content.spinner {
                            ProgressView().controlSize(.small)
                        }
                        Text(content.title)
                    }
                } icon: {
                    Image(systemName: content.icon).foregroundStyle(content.tint)
                }
            }
            .labelStyle(.titleAndIcon)
            .menuIndicator(.visible)
            .help(content.help)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch updates.phase {
        case .available(let update):
            Button("Install Now") { updates.install() }
                .help(HelpText.updateInstallNow)
            if let notes = update.manifest.notesURL {
                Button("Release Notes") { NSWorkspace.shared.open(notes) }
                    .help(HelpText.updateReleaseNotes)
            }
            Button("Later") { updates.later() }
                .help(HelpText.updateLater)
        case .downloading:
            Button("Cancel") { updates.later() }
                .help(HelpText.updateCancel)
        case .installing:
            EmptyView()
        default:
            Button("OK") { updates.bannerVisible = false }
        }
    }

    private struct Content {
        var icon: String
        var tint: Color
        /// Short, for the toolbar button.
        var title: String
        /// The full sentences, shown at the top of the menu.
        var detail: String?
        var progress: Double?
        var spinner = false
        var help: String { detail.map { "\(title). \($0)" } ?? title }
    }

    private var content: Content? {
        switch updates.phase {
        case .idle:
            return nil
        case .checking:
            return Content(icon: "arrow.triangle.2.circlepath", tint: .secondary, title: "Checking…", spinner: true)
        case .upToDate(let version):
            return Content(icon: "checkmark.circle", tint: .green, title: "Up to date", detail: "Gamify \(version) is the newest version.")
        case .available(let update):
            let what = update.kind == .app
                ? "Downloads \(UpdateController.size(update.asset.size)), installs and restarts Gamify. Your bottles and games stay as they are."
                : "Includes a new Wine runtime: downloads \(UpdateController.size(update.asset.size)), replaces the app and restarts it. Your bottles and games stay as they are."
            return Content(icon: "arrow.down.circle.fill", tint: .accentColor,
                           title: "Gamify \(update.version) available",
                           detail: "Gamify \(update.version) is available (\(UpdateController.size(update.asset.size))). You have \(updates.currentVersion). \(what)")
        case .unsupported(let update, let minimum):
            return Content(icon: "exclamationmark.triangle", tint: .orange,
                           title: "Update needs macOS \(minimum)",
                           detail: "Gamify \(update.version) is available but needs macOS \(minimum) or later.")
        case .downloading(let update, let received, let expected):
            let fraction = expected > 0 ? Double(received) / Double(expected) : 0
            return Content(icon: "arrow.down.circle", tint: .accentColor,
                           title: "Downloading \(update.version)…",
                           detail: "Downloading Gamify \(update.version): \(UpdateController.size(received)) of \(UpdateController.size(expected)).",
                           progress: min(max(fraction, 0), 1))
        case .installing(let update, let step):
            return Content(icon: "gearshape.2", tint: .accentColor, title: "Installing \(update.version)…",
                           detail: "Installing Gamify \(update.version): \(step)", spinner: true)
        case .installed(let version):
            return Content(icon: "checkmark.seal.fill", tint: .green, title: "Updated to \(version)", detail: "Gamify was updated to \(version).")
        case .failed(let message):
            return Content(icon: "xmark.octagon", tint: .red, title: "Update problem", detail: message)
        }
    }
}

/// Gamify > Check for Updates…
struct UpdateCommands: Commands {
    let updates: UpdateController
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkNow(project: model.project) }
        }
    }
}

/// Settings > General > Updates.
struct UpdateSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updates: UpdateController
    @AppStorage(Updater.checkOnLaunchKey) private var checkOnLaunch = true
    @AppStorage(Updater.autoInstallKey) private var autoInstall = false

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates on launch", isOn: $checkOnLaunch)
                .help(HelpText.updatesCheckOnLaunch)
            Toggle("Install updates automatically", isOn: $autoInstall)
                .disabled(!checkOnLaunch)
                .help(HelpText.updatesAutoInstall)
            LabeledContent("Version", value: updates.currentVersion)
            LabeledContent("Runtime", value: updates.runtimeVersion ?? "not versioned (source checkout)")
                .help(HelpText.updatesRuntimeVersion)
            HStack {
                Button("Check Now") { updates.checkNow(project: model.project) }
                    .help(HelpText.updatesCheckNow)
                if let last = updates.lastChecked {
                    Text("Last checked \(last.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Gamify asks github.com/itzhakos/gamify-releases for the latest version (one small file, nothing about you or your Mac is sent) and downloads an update only when you click Install.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
