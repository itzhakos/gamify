import AppKit
import CrossCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            EnvironmentTab()
                .tabItem { Label("Environment", systemImage: "terminal") }
            PathsTab()
                .tabItem { Label("Paths", systemImage: "folder") }
        }
        .frame(width: 760, height: 520)
    }
}

struct GeneralTab: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppModel.tutorialShownKey) private var tutorialShown = false

    var body: some View {
        Form {
            Section("First-run tutorial") {
                LabeledContent("Status", value: tutorialShown ? "shown" : "opens on the next launch")
                HStack {
                    Button("Show Tutorial Again") { openWindow(id: TutorialView.windowID) }
                        .help(HelpText.tutorialShowAgain)
                    Button("Show on Next Launch") { tutorialShown = false }
                        .disabled(!tutorialShown)
                        .help(HelpText.tutorialShowOnNextLaunch)
                }
                Text("The tutorial walks through bottles, Steam and running games. It opens on the first launch (user default `\(AppModel.tutorialShownKey)`; `CROSS_RESET_TUTORIAL=1` in the environment resets it).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            UpdateSettingsSection()
        }
        .formStyle(.grouped)
    }
}

/// The resolved environment of a bottle: exactly what `cross env <bottle> [--export]`
/// prints (Runtime.environmentLines), inherited from the app's own environment.
struct EnvironmentTab: View {
    @EnvironmentObject var model: AppModel
    @State private var bottleName: String?
    @State private var export = false
    @State private var onlyCross = true

    private var drivable: [Bottle] { model.bottles.filter(model.isDrivable) }
    private var bottle: Bottle? {
        drivable.first { $0.name == bottleName } ?? drivable.first { $0.name == model.selection } ?? drivable.first
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Picker("Bottle", selection: Binding(get: { bottle?.name }, set: { bottleName = $0 })) {
                    ForEach(drivable, id: \.name) { Text($0.name).tag(Optional($0.name)) }
                }
                .frame(maxWidth: 240)
                .help(HelpText.envBottle)
                Toggle("only variables Gamify sets", isOn: $onlyCross)
                    .help(HelpText.envOnlyGamify)
                Toggle("export format (--export)", isOn: $export)
                    .help(HelpText.envExport)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .help(HelpText.envCopy)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .border(Color.secondary.opacity(0.3))
            Text("With the filter off this is exactly `cross env \(bottle?.name ?? "<bottle>")`, inherited from the app's environment (launchd's when opened from Finder, the caller's when started with `open` from a shell).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    private var text: String {
        guard let bottle else { return "no winecx bottle" }
        return model.environmentLines(for: bottle, export: export, onlyChanged: onlyCross).joined(separator: "\n")
    }
}

struct PathsTab: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(AppModel.rootOverrideKey) private var rootOverride = ""
    @AppStorage(AppModel.bottlesOverrideKey) private var bottlesOverride = ""

    private var bundled: Bool { model.project?.bundled ?? false }

    var body: some View {
        Form {
            Section("Your data") {
                pathRow("Bottles", model.project?.bottles)
                pathRow("Downloads", model.project?.downloads)
                pathRow("Logs", model.logsRoot)
            }
            Section("Bottles folder") {
                LabeledContent("Now", value: bottlesOverride.isEmpty ? "the default (\(model.project?.defaultBottles.path ?? "-"))" : bottlesOverride)
                HStack {
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.title = "Choose the bottles folder"
                        panel.prompt = "Use This Folder"
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            bottlesOverride = url.path
                            model.locateProject()
                        }
                    }
                    .help(HelpText.pathsChooseBottles)
                    Button("Reset to Default") {
                        bottlesOverride = ""
                        model.locateProject()
                    }
                    .disabled(bottlesOverride.isEmpty)
                    .help(HelpText.pathsResetBottles)
                }
                Text("Where new bottles go and where the bottle list is read from (user default `\(AppModel.bottlesOverrideKey)`, passed on as CROSS_BOTTLES). Bottles in the old folder are not listed while another folder is set: reset the setting, or move them first (bottle page > Move to…). To keep a single bottle somewhere else, e.g. on an external drive, choose its location in New Bottle or use Move to… instead; it stays in the list. Folder bottles need an APFS or Mac OS Extended drive; on exFAT the bottles folder can hold disk-image bottles only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Runtime") {
                LabeledContent("Available", value: model.availableRuntimes.isEmpty ? "none" : model.availableRuntimes.joined(separator: ", "))
                    .help(HelpText.pathsRuntimes)
                ForEach(model.availableRuntimes, id: \.self) { rt in
                    pathRow(rt, model.project.map { Runtime(project: $0, name: rt).home })
                }
                pathRow("D3DMetal", model.runtime?.d3dmetalHome, help: HelpText.pathD3DMetal)
                pathRow("wined3d", model.runtime?.wined3dDir, help: HelpText.pathWined3d)
                pathRow("DXVK", model.runtime?.dxvkHome, help: HelpText.pathDXVK)
                pathRow("DXMT", model.runtime?.dxmtHome, help: HelpText.pathDXMT)
                pathRow("Webhelper shim", model.project?.webhelperShim, help: HelpText.pathWebhelper)
                pathRow("Third-party notices", model.project?.notices)
                LabeledContent("Rosetta 2", value: model.rosettaInstalled ? "installed" : "missing")
                    .help(HelpText.pathsRosetta)
            }
            Section(bundled ? "App" : "Checkout") {
                pathRow(bundled ? "Runtime files" : "Gamify root", model.project?.root)
                if let error = model.loadError {
                    Text(error).foregroundStyle(.red)
                }
                if !bundled {
                    HStack {
                        TextField("Root override (empty = find it from the app's location)", text: $rootOverride)
                            .help(HelpText.pathsRootOverride)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url { rootOverride = url.path }
                        }
                        .help(HelpText.pathsRootOverride)
                        Button("Apply") { model.locateProject() }
                            .help(HelpText.pathsRootOverride)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// `help`: what the row is (the reveal arrow has its own "Show in Finder").
    private func pathRow(_ title: String, _ url: URL?, help: String? = nil) -> some View {
        LabeledContent(title) {
            HStack {
                Text(url?.path ?? "-").textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                if let url {
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    Image(systemName: exists ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(exists ? .green : .orange)
                    Button { model.reveal(url) } label: { Image(systemName: "arrow.right.circle") }
                        .buttonStyle(.borderless)
                        .help(HelpText.showInFinder)
                }
            }
        }
        .help(help ?? "")
    }
}
