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
                Button("Find Bottles on Drives…") { model.showingFindBottles = true }
                    .disabled(model.project == nil)
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
    @State private var pendingForget: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Bottles") {
                    ForEach(model.bottles, id: \.name) { bottle in
                        BottleRow(bottle: bottle)
                            .tag(bottle.name)
                            .contextMenu {
                                Button("Show in Finder") { model.reveal(bottle.location ?? bottle.prefix) }
                                    .help(HelpText.sidebarShowInFinder)
                                if bottle.location != nil, bottle.image != nil, bottle.storageError == nil {
                                    Button("Eject") { model.ejectBottle(bottle.name) }
                                        .help(HelpText.sidebarEject)
                                }
                                Divider()
                                if bottle.location != nil {
                                    Button("Remove from List…") { pendingForget = bottle.name }
                                        .help(HelpText.sidebarRemoveFromList)
                                }
                                Button("Delete Bottle…", role: .destructive) { pendingDelete = bottle.name }
                                    .help(HelpText.sidebarDelete)
                            }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.foundOnDrives.isEmpty {
                        FoundBottlesBanner()
                    }
                    Button {
                        model.showingFindBottles = true
                    } label: {
                        Label("Find Bottles…", systemImage: "externaldrive.badge.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.project == nil)
                    .help(HelpText.findBottles)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
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
                    .help(HelpText.newBottle)
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
        .sheet(isPresented: $model.showingFindBottles) {
            FindBottlesSheet()
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
            if let bottle = model.bottle(named: pendingDelete), bottle.isUnreachable {
                Text("'\(bottle.name)' lives on a drive that is not connected: only its entry in the list is removed, its files there are not touched.")
            } else if let bottle = model.bottle(named: pendingDelete), let location = bottle.location {
                Text("Stops its wineserver and removes the whole prefix, including installed programs, from \(location.path). To keep its files, use Remove from List instead.")
            } else {
                Text("Stops its wineserver and removes the whole prefix, including installed programs.")
            }
        }
        .confirmationDialog("Remove '\(pendingForget ?? "")' from the list?",
                            isPresented: Binding(get: { pendingForget != nil }, set: { if !$0 { pendingForget = nil } })) {
            Button("Remove from List") {
                if let name = pendingForget { model.forgetBottle(name) }
                pendingForget = nil
            }
        } message: {
            Text("Its files stay at \(model.bottle(named: pendingForget)?.location?.path ?? "their location"); Find Bottles adds it again, also on another Mac.")
        }
    }
}

struct BottleRow: View {
    @EnvironmentObject var model: AppModel
    let bottle: Bottle

    /// The subtitle lists runtime · backend · size · place (the other states say what is wrong).
    private var detailedSubtitle: Bool {
        !bottle.isUnreachable && !bottle.isEjected && bottle.storageError == nil && model.isDrivable(bottle)
    }

    private var subtitle: String {
        if bottle.isUnreachable { return "\(model.locationText(bottle) ?? "drive") not connected" }
        if bottle.isEjected { return "ejected · on \(model.locationText(bottle) ?? "another drive")" }
        if bottle.storageError != nil { return "disk image unavailable" }
        guard model.isDrivable(bottle) else { return "\(bottle.config.runtime) · bottle.sh only" }
        let disk = bottle.config.storage.map { " · \($0.sizeGB) GB" } ?? ""
        let place = model.locationText(bottle).map { " · on \($0)" } ?? ""
        return "\(bottle.config.runtime) · \(bottle.config.graphics.rawValue)\(disk)\(place)"
    }

    var body: some View {
        HStack {
            Image(systemName: bottle.location == nil ? "wineglass" : "externaldrive")
                .foregroundStyle(model.isDrivable(bottle) ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(bottle.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(detailedSubtitle ? HelpText.bottleRowSubtitle : "")
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
    /// A folder elsewhere (an external drive) to keep the bottle in; nil: the bottles folder.
    @State private var location: URL?
    @State private var locationError: String?

    private var nameError: String? { model.newBottleNameError(name) }
    private var sizeRange: ClosedRange<Int> { model.storageRange(home: location) }
    private var sizeValid: Bool { !ownDisk || sizeRange.contains(sizeGB) }
    /// Why the chosen place cannot hold a folder bottle (exFAT, FAT, NTFS, network).
    private var folderProblem: String? {
        Runtime.folderBottleProblem(at: location ?? model.project?.bottles ?? URL(fileURLWithPath: "/"))
    }
    private var canCreate: Bool {
        !name.isEmpty && nameError == nil && sizeValid && locationError == nil && (ownDisk || folderProblem == nil)
    }

    static func runtimeTitle(_ rt: String) -> String {
        rt == "winecx-full" ? "winecx-full (Wine 10.0 + GStreamer, SDL2, MoltenVK)" : "winecx (Wine 10.0, CrossOver lineage)"
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .help(HelpText.newBottleName)
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
                    .help(HelpText.newBottleRuntime)
                }
                Picker("Graphics", selection: $graphics) {
                    Text("D3DMetal 3.0").tag(Graphics.d3dmetal)
                    Text("wined3d").tag(Graphics.wined3d)
                    Text("DXVK").tag(Graphics.dxvk)
                    Text("DXMT").tag(Graphics.dxmt)
                }
                .pickerStyle(.radioGroup)
                .help(HelpText.newBottleGraphics)
            } header: {
                Text("New Bottle").font(.headline)
            } footer: {
                Text("Sets up the new bottle's C: drive (about 40 s).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Location") {
                    HStack {
                        Picker("Location", selection: Binding(get: { location?.path ?? "" },
                                                              set: { setLocation($0.isEmpty ? nil : URL(fileURLWithPath: $0)) })) {
                            Text("Bottles folder").tag("")
                            if let location {
                                Text(location.path).tag(location.path)
                            }
                        }
                        .labelsHidden()
                        .help(HelpText.newBottleLocation)
                        Button("Choose…", action: chooseLocation)
                            .help(HelpText.newBottleChooseLocation)
                    }
                }
                if let locationError {
                    Text(locationError).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text(location == nil
                     ? "In \(model.project?.bottles.path ?? "the bottles folder"). Choose a folder to keep it elsewhere, e.g. on an external drive; it is listed here and runs from there while the drive is connected."
                     : "The bottle goes to \(location!.appendingPathComponent(ownDisk ? "\(name.isEmpty ? "<name>" : name).sparsebundle" : (name.isEmpty ? "<name>" : name)).path) and runs from there while the drive is connected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Disk", selection: $ownDisk) {
                    Text("Its own disk").tag(true)
                    Text("Unlimited (a plain folder)").tag(false)
                }
                .pickerStyle(.radioGroup)
                .disabled(model.defaultStorageGB(at: location) == nil)
                .help(HelpText.newBottleDisk)
                if !ownDisk, let folderProblem {
                    Text(folderProblem).font(.caption).foregroundStyle(.red)
                }
                if ownDisk {
                    StorageSizeField(sizeGB: $sizeGB, range: sizeRange)
                    if !sizeValid {
                        Text("Choose \(sizeRange.lowerBound)–\(sizeRange.upperBound) GB.").font(.caption).foregroundStyle(.red)
                    }
                }
            } footer: {
                Text(ownDisk
                     ? "Windows sees C: as a \(sizeGB) GB drive and the bottle can never take more. The disk image only uses the space actually written; resize it later on the bottle page."
                     : "The bottle grows as far as \(location == nil ? "this Mac's disk" : "the drive") allows.")
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
                                       storageGB: ownDisk ? sizeGB : nil, location: location)
                    dismiss()
                }
                .disabled(!canCreate)
                .help(HelpText.newBottleCreate)
            }
        }
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.title = "Choose where to keep the new bottle"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = location ?? URL(fileURLWithPath: "/Volumes")
        if panel.runModal() == .OK, let url = panel.url { setLocation(url) }
    }

    /// Checks the folder (CrossCore Runtime.checkLocation) and fits the disk choice to
    /// it: the size range follows that drive's free space, and a drive that cannot hold
    /// a folder bottle switches to a disk image.
    private func setLocation(_ url: URL?) {
        locationError = nil
        guard let url, let runtime = model.runtime else { location = nil; refit(); return }
        do {
            location = try runtime.checkLocation(url)
        } catch {
            location = url
            locationError = "\(error)"
        }
        refit()
    }

    private func refit() {
        if !ownDisk, folderProblem != nil { ownDisk = true }
        sizeGB = min(max(sizeGB, sizeRange.lowerBound), sizeRange.upperBound)
    }
}

/// Bottles found on a drive that was just connected (AppModel.foundOnDrives).
struct FoundBottlesBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let drives = Set(model.foundOnDrives.map { $0.url.pathComponents.count > 2 ? $0.url.pathComponents[2] : $0.url.path })
        VStack(alignment: .leading, spacing: 6) {
            Label("\(model.foundOnDrives.count) bottle\(model.foundOnDrives.count == 1 ? "" : "s") on \(drives.sorted().joined(separator: ", "))",
                  systemImage: "externaldrive.badge.plus")
                .font(.callout)
            HStack {
                Button("Review…") { model.showingFindBottles = true }
                    .help(HelpText.foundReview)
                Button("Dismiss") { model.foundOnDrives = [] }
                    .help(HelpText.foundDismiss)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }
}
