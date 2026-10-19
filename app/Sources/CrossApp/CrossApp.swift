import AppKit
import CrossCore
import SwiftUI

/// Files opened with the app (`open -a Gamify.app game.exe`, Dock drop) run in the
/// selected bottle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var openHandler: (([URL]) -> Void)?
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let openHandler { openHandler(urls) } else { pending += urls }
    }

    func attach(_ handler: @escaping ([URL]) -> Void) {
        openHandler = handler
        if !pending.isEmpty { handler(pending); pending = [] }
    }
}

@main
struct CrossApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var updates = UpdateController()

    var body: some Scene {
        WindowGroup("Gamify") {
            ContentView()
                .environmentObject(model)
                .environmentObject(updates)
                .frame(minWidth: 860, minHeight: 640)
                // bottles made by the CLI or scripts while the app was in the background
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.reloadBottles()
                }
                .onAppear {
                    delegate.attach { urls in model.openFiles(urls) }
                    updates.hasRunningJobs = { model.jobs.contains { $0.isRunning } }
                }
        }
        // opened files go to AppDelegate; never spawn another window for them
        .handlesExternalEvents(matching: [])
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reload Bottles") { model.reloadBottles() }
                    .keyboardShortcut("r")
            }
            TutorialCommands()
            UpdateCommands(updates: updates, model: model)
        }

        // The first-run tutorial. A window rather than a sheet, so the main window stays
        // usable (the bottle it creates shows up in the sidebar) and it can be replayed
        // from Help > Gamify Tutorial or Settings > General at any time.
        Window("Welcome to Gamify", id: TutorialView.windowID) {
            TutorialView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(updates)
        }
    }
}

/// Help > Gamify Tutorial replays the first-run tutorial.
struct TutorialCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .help) {
            Button("Gamify Tutorial") { openWindow(id: TutorialView.windowID) }
            Divider()
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updates: UpdateController
    @Environment(\.openWindow) private var openWindow
    @State private var showingNewBottle = false
    @State private var pendingDelete: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Bottles") {
                    ForEach(model.bottles, id: \.name) { bottle in
                        BottleRow(bottle: bottle)
                            .tag(bottle.name)
                            .contextMenu {
                                Button("Show in Finder") { model.reveal(bottle.prefix) }
                                Divider()
                                Button("Delete Bottle…", role: .destructive) { pendingDelete = bottle.name }
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                ToolbarItem {
                    Button {
                        showingNewBottle = true
                    } label: {
                        Label("New Bottle", systemImage: "plus")
                    }
                    .disabled(model.runtime == nil)
                    .help("Create a winecx bottle")
                }
            }
        } detail: {
            if model.isLocating {
                ProgressView("Opening the Gamify checkout…\nmacOS may ask for permission to access its folder.")
                    .multilineTextAlignment(.center)
            } else if let error = model.loadError {
                ContentUnavailableView("Gamify checkout not found", systemImage: "folder.badge.questionmark",
                                       description: Text("\(error)\nSet the project root in Settings > Paths."))
            } else if let bottle = model.bottle(named: model.selection) {
                BottleView(bottle: bottle)
                    .id(bottle.name)
            } else {
                ContentUnavailableView("No bottle selected", systemImage: "wineglass",
                                       description: Text("Create one with the + button."))
            }
        }
        // update available / progress / errors: a banner, never a modal
        .safeAreaInset(edge: .top, spacing: 0) {
            UpdateBanner()
        }
        .sheet(isPresented: $showingNewBottle) {
            NewBottleSheet()
        }
        // First launch: open the tutorial once the checkout is located (its bottle step
        // needs the project), so it opens after the Desktop-folder permission prompt.
        .task(id: model.isLocating) {
            guard !model.isLocating else { return }
            updates.launchOnce(project: model.project)
            if model.shouldOpenTutorialAtLaunch() {
                openWindow(id: TutorialView.windowID)
            }
        }
        .alert("Gamify", isPresented: Binding(get: { model.alertMessage != nil },
                                             set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .confirmationDialog("Delete bottle '\(pendingDelete ?? "")'?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let name = pendingDelete { model.deleteBottle(name) }
                pendingDelete = nil
            }
        } message: {
            Text("Stops its wineserver and removes the whole prefix, including installed programs.")
        }
    }
}

struct BottleRow: View {
    @EnvironmentObject var model: AppModel
    let bottle: Bottle

    private var subtitle: String {
        if bottle.storageError != nil { return "disk image unavailable" }
        guard model.isDrivable(bottle) else { return "\(bottle.config.runtime) · bottle.sh only" }
        let disk = bottle.config.storage.map { " · \($0.sizeGB) GB" } ?? ""
        return "\(bottle.config.runtime) · \(bottle.config.graphics.rawValue)\(disk)"
    }

    var body: some View {
        HStack {
            Image(systemName: "wineglass")
                .foregroundStyle(model.isDrivable(bottle) ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(bottle.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isBusy(bottle.name) {
                ProgressView().controlSize(.small)
            }
        }
    }
}

struct NewBottleSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var runtimeName = Runtime.defaultName
    @State private var graphics: Graphics = .d3dmetal
    @State private var ownDisk = true
    @State private var sizeGB = BottleStorage.defaultGB

    private var nameError: String? { model.newBottleNameError(name) }
    private var sizeRange: ClosedRange<Int> { model.storageRange() }
    private var sizeValid: Bool { !ownDisk || sizeRange.contains(sizeGB) }

    static func runtimeTitle(_ rt: String) -> String {
        rt == "winecx-full" ? "winecx-full (Wine 10.0 + GStreamer, SDL2, MoltenVK)" : "winecx (Wine 10.0, CrossOver lineage)"
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                if let nameError {
                    Text(nameError).font(.caption).foregroundStyle(.red)
                }
                // one runtime (the bundled app): nothing to choose
                if model.availableRuntimes.count > 1 {
                    Picker("Runtime", selection: $runtimeName) {
                        ForEach(model.availableRuntimes, id: \.self) { rt in
                            Text(Self.runtimeTitle(rt)).tag(rt)
                        }
                    }
                }
                Picker("Graphics", selection: $graphics) {
                    Text("D3DMetal 3.0").tag(Graphics.d3dmetal)
                    Text("wined3d").tag(Graphics.wined3d)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("New Bottle").font(.headline)
            } footer: {
                Text("Sets up the new bottle's C: drive (about 40 s).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Disk", selection: $ownDisk) {
                    Text("Its own disk").tag(true)
                    Text("Unlimited (a plain folder)").tag(false)
                }
                .pickerStyle(.radioGroup)
                .disabled(model.defaultStorageGB == nil)
                if ownDisk {
                    StorageSizeField(sizeGB: $sizeGB, range: sizeRange)
                    if !sizeValid {
                        Text("Choose \(sizeRange.lowerBound)–\(sizeRange.upperBound) GB.").font(.caption).foregroundStyle(.red)
                    }
                }
            } footer: {
                Text(ownDisk
                     ? "Windows sees C: as a \(sizeGB) GB drive and the bottle can never take more. The disk image only uses the space actually written; resize it later on the bottle page."
                     : "The bottle grows as far as this Mac's disk allows.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear {
            runtimeName = model.preferredRuntime
            ownDisk = model.defaultStorageGB != nil
            sizeGB = model.defaultStorageGB ?? BottleStorage.defaultGB
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    model.createBottle(name: name, runtime: runtimeName, graphics: graphics,
                                       storageGB: ownDisk ? sizeGB : nil)
                    dismiss()
                }
                .disabled(name.isEmpty || nameError != nil || !sizeValid)
            }
        }
    }
}
