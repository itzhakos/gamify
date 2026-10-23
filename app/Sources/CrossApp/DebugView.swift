import AppKit
import CrossCore
import SwiftUI
import UniformTypeIdentifiers

/// The bottle page's Debugging box: debugging mode (`BottleConfig.debug`), Export Logs…
/// and Sample Running Game (CrossCore Debug.swift; `cross debug export|sample`).
struct DebugBox: View {
    @EnvironmentObject var model: AppModel
    let bottle: Bottle
    /// What the export or sample is doing, or what it produced.
    @State private var status: String?
    @State private var working = false
    /// Files to show with Reveal in Finder (the zip, or the sample files).
    @State private var results: [URL] = []

    private var debugMode: Binding<Bool> {
        Binding(get: { bottle.config.debug }, set: { model.setDebug($0, for: bottle.name) })
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Toggle("Debugging mode", isOn: debugMode)
                        .help("More diagnostics in each program's log: Wine's errors, warnings and DLL loads with timestamps (WINEDEBUG=\(Debug.wineDebug) instead of -all) and one Metal HUD line per second with frame and GPU times (MTL_HUD_LOG_ENABLED=1). Applies to programs started afterwards; for Steam games restart Steam. Turn it on, reproduce the problem, then Export Logs….")
                    Button("Export Logs…", action: exportLogs)
                        .disabled(working)
                        .help("Saves a zip with everything needed to diagnose a crash or freeze: Gamify's launch logs, crash reports, macOS log entries, the games' own logs, system information and this bottle's settings (last 24 hours). Each folder has a README listing what is included. File paths and your macOS user name appear in it.")
                    Button("Sample Running Game", action: sampleGame)
                        .disabled(working)
                        .help("While a game is frozen: records where its threads are (a 5-second stack sample of the game and of wineserver) into this bottle's logs folder; the next Export Logs… includes it.")
                    if working { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                }
                if let status {
                    HStack(spacing: 8) {
                        Text(status)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        if !results.isEmpty && !working {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(results) }
                                .help("Show the file in Finder")
                        }
                    }
                }
                Text("Send the zip when you report a problem.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(4)
        } label: {
            Label("Debugging", systemImage: "ladybug")
        }
        .onChange(of: bottle.name) {
            status = nil
            results = []
        }
    }

    private func exportLogs() {
        guard let project = model.project else { return }
        let panel = NSSavePanel()
        panel.title = "Export Logs"
        panel.message = "Gamify diagnostics for '\(bottle.name)'. Send this zip with your problem report."
        panel.nameFieldStringValue = Debug.defaultExportName(bottle: bottle.name)
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bottle = bottle
        let info = Bundle.main.infoDictionary ?? [:]
        working = true
        results = []
        status = "Collecting…"
        Task.detached {
            let outcome = Result {
                try Debug.export(bottle: bottle, project: project, to: url, appInfo: info) { step in
                    Task { @MainActor in status = "\(step)…" }
                }
            }
            await MainActor.run {
                working = false
                switch outcome {
                case .success(let r):
                    status = "Saved \(r.zip.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file)))"
                    results = [r.zip]
                case .failure(let error):
                    status = "Export failed: \(error)"
                }
            }
        }
    }

    private func sampleGame() {
        let bottle = bottle
        let folder = Debug.logsRoot.appendingPathComponent(bottle.name)
        working = true
        results = []
        status = "Sampling for \(Debug.sampleSeconds) seconds…"
        Task.detached {
            let r = Debug.sample(bottle: bottle, into: folder)
            await MainActor.run {
                working = false
                let samples = r.files.filter { $0.lastPathComponent.contains("-sample-") }
                if let target = r.target, !samples.isEmpty {
                    status = "Sampled \(target.program) (pid \(target.pid)) into \(folder.path); Export Logs… includes it."
                } else {
                    status = (r.notes.isEmpty ? ["Nothing was sampled."] : r.notes).joined(separator: "; ")
                }
                results = r.files
            }
        }
    }
}

extension AppModel {
    /// Debugging mode on or off, saved to cross.json; programs started afterwards get it.
    func setDebug(_ on: Bool, for name: String) {
        guard var bottle = bottle(named: name), bottle.config.debug != on else { return }
        bottle.config.debug = on
        do {
            try bottle.saveConfig()
        } catch {
            alertMessage = "\(error)"
            return
        }
        reloadBottles()
    }
}
