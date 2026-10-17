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

/// The non-blocking banner at the top of the main window.
struct UpdateBanner: View {
    @EnvironmentObject var updates: UpdateController

    var body: some View {
        if updates.bannerVisible, let content = content {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: content.icon)
                    .font(.title3)
                    .foregroundStyle(content.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(content.title).fontWeight(.semibold)
                    if let detail = content.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if let progress = content.progress {
                        ProgressView(value: progress).frame(maxWidth: 360)
                    } else if content.spinner {
                        ProgressView().controlSize(.small)
                    }
                }
                Spacer()
                buttons
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    @ViewBuilder private var buttons: some View {
        switch updates.phase {
        case .available(let update):
            if let notes = update.manifest.notesURL {
                Button("Release Notes") { NSWorkspace.shared.open(notes) }
                    .buttonStyle(.link)
            }
            Button("Later") { updates.later() }
            Button("Install Now") { updates.install() }
                .keyboardShortcut(.defaultAction)
        case .downloading:
            Button("Cancel") { updates.later() }
        case .installing:
            EmptyView()
        default:
            Button("OK") { updates.bannerVisible = false }
        }
    }

    private struct Content {
        var icon: String
        var tint: Color
        var title: String
        var detail: String?
        var progress: Double?
        var spinner = false
    }

    private var content: Content? {
        switch updates.phase {
        case .idle:
            return nil
        case .checking:
            return Content(icon: "arrow.triangle.2.circlepath", tint: .secondary, title: "Checking for updates…", spinner: true)
        case .upToDate(let version):
            return Content(icon: "checkmark.circle", tint: .green, title: "Gamify \(version) is up to date.")
        case .available(let update):
            let what = update.kind == .app
                ? "Downloads \(UpdateController.size(update.asset.size)), installs and restarts Gamify. Your bottles and games stay as they are."
                : "Includes a new Wine runtime: downloads \(UpdateController.size(update.asset.size)), replaces the app and restarts it. Your bottles and games stay as they are."
            return Content(icon: "arrow.down.circle.fill", tint: .accentColor,
                           title: "Gamify \(update.version) is available (\(UpdateController.size(update.asset.size))). You have \(updates.currentVersion).",
                           detail: what)
        case .unsupported(let update, let minimum):
            return Content(icon: "exclamationmark.triangle", tint: .orange,
                           title: "Gamify \(update.version) is available but needs macOS \(minimum) or later.")
        case .downloading(let update, let received, let expected):
            let fraction = expected > 0 ? Double(received) / Double(expected) : 0
            return Content(icon: "arrow.down.circle", tint: .accentColor,
                           title: "Downloading Gamify \(update.version)…",
                           detail: "\(UpdateController.size(received)) of \(UpdateController.size(expected))",
                           progress: min(max(fraction, 0), 1))
        case .installing(let update, let step):
            return Content(icon: "gearshape.2", tint: .accentColor, title: "Installing Gamify \(update.version)…",
                           detail: step, spinner: true)
        case .installed(let version):
            return Content(icon: "checkmark.seal.fill", tint: .green, title: "Gamify was updated to \(version).")
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

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates on launch", isOn: $checkOnLaunch)
            LabeledContent("Version", value: updates.currentVersion)
            LabeledContent("Runtime", value: updates.runtimeVersion ?? "not versioned (source checkout)")
            HStack {
                Button("Check Now") { updates.checkNow(project: model.project) }
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
