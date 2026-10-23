import AppKit
import CrossCore
import SwiftUI
import UniformTypeIdentifiers

struct BottleView: View {
    @EnvironmentObject var model: AppModel
    let bottle: Bottle
    @State private var selectedJob: UUID?
    @State private var commandLine = ""
    @State private var exeArguments = ""
    @State private var showingStorage = false
    /// Install… on a store row asks first (download size, what it does, known issues).
    @State private var storeToInstall: Store?
    @State private var showingSteamCheck = false

    private var drivable: Bool { model.isDrivable(bottle) }
    private var jobs: [Job] { model.jobs(for: bottle.name) }
    private var shownJob: Job? { jobs.first { $0.id == selectedJob } ?? jobs.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = bottle.storageError {
                unavailableBox(error)
                Spacer()
            } else if drivable {
                storageRow
                actions
                    .disabled(model.storageWork[bottle.name] != nil)
                PerformanceBox(bottle: bottle)
                    .disabled(model.storageWork[bottle.name] != nil)
                HStack(alignment: .top, spacing: 12) {
                    storesBox
                    ProgramsBox(bottle: bottle)
                }
                .disabled(model.storageWork[bottle.name] != nil)
                processes
                LogView(url: shownJob?.logURL)
                    .frame(minHeight: 120)
            } else {
                GroupBox {
                    Text("This bottle uses the '\(bottle.config.runtime)' runtime. Gamify (like the `cross` CLI) only drives \(Runtime.known.joined(separator: " and ")) bottles; use scripts/bottle.sh for this one.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
                Spacer()
            }
        }
        .padding()
        .navigationTitle(bottle.name)
        .dropDestination(for: URL.self) { urls, _ in
            guard drivable else { return false }
            model.openFiles(urls, in: bottle.name)
            selectedJob = nil
            return true
        }
        // Steam status: processes + the newest line of its connection log, every 3 s
        // while this page is shown.
        .task(id: bottle.name) {
            guard drivable else { return }
            while !Task.isCancelled {
                await model.refreshSteamStatus(bottle.name)
                await model.refreshStoresAndPrograms(bottle.name)
                await model.refreshStorage(bottle.name)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .alert("Steam looks stuck", isPresented: stuckPromptShown, presenting: model.steamStuckPrompt) { prompt in
            Button("Restart Steam") { model.restartSteam(prompt.bottle) }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text("\(prompt.reason) Restart it? Steam quits and starts again; nothing is lost.")
        }
        .alert("Install \(storeToInstall?.name ?? "")?", isPresented: Binding(get: { storeToInstall != nil },
                                                                     set: { if !$0 { storeToInstall = nil } }),
               presenting: storeToInstall) { store in
            Button("Install") { model.installStore(store, in: bottle.name) }
            Button("Cancel", role: .cancel) {}
        } message: { store in
            Text("Gamify downloads \(store.name)'s official installer (once, kept in Downloads) and installs it in '\(bottle.name)'. \(store.notes)" + (store.knownIssue.map { "\n\nKnown issue: \($0)" } ?? ""))
        }
        .alert(installPromptTitle, isPresented: installPromptShown, presenting: model.installPrompt) { prompt in
            Button("Install") { prompt.files.forEach { model.installProgram($0, in: prompt.bottle) } }
            if prompt.files.allSatisfy({ $0.pathExtension.lowercased() == "exe" }) {
                Button("Just Run") { prompt.files.forEach { model.runExe($0, arguments: [], in: prompt.bottle) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text("\(prompt.files.map(\.lastPathComponent).joined(separator: ", ")) looks like an installer. Install it in '\(prompt.bottle)'? Its programs then show up under Programs.")
        }
    }

    private var installPromptShown: Binding<Bool> {
        Binding(get: { model.installPrompt?.bottle == bottle.name },
                set: { if !$0 { model.installPrompt = nil } })
    }

    private var installPromptTitle: String {
        model.installPrompt?.files.count == 1 ? "Install \(model.installPrompt!.files[0].lastPathComponent)?" : "Install these programs?"
    }

    /// A bottle that cannot be used now: its drive is not connected (Try Again once it
    /// is), it was ejected (Mount), or its disk image cannot be opened.
    private func unavailableBox(_ error: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if bottle.isUnreachable {
                    Label("This bottle's drive is not connected", systemImage: "externaldrive.badge.xmark")
                        .font(.headline)
                } else if bottle.isEjected {
                    Label("This bottle is ejected", systemImage: "eject")
                        .font(.headline)
                } else {
                    Label("This bottle's disk image cannot be opened", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.headline)
                }
                Text(error).textSelection(.enabled)
                if let location = bottle.location {
                    Text("Kept at \(location.path)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if bottle.isUnreachable {
                    Text("Connect the drive, then try again. Nothing in the bottle was changed; Remove from List takes it off the list and leaves its files on the drive.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    if let work = model.storageWork[bottle.name] {
                        ProgressView().controlSize(.small)
                        Text(work).foregroundStyle(.secondary)
                    } else if bottle.isEjected && !bottle.isUnreachable {
                        Button("Mount") { model.mountBottle(bottle.name) }
                            .help(HelpText.mount)
                    } else {
                        Button("Try Again") { model.reloadBottles() }
                            .help(HelpText.tryAgain)
                    }
                    if bottle.location != nil {
                        Button("Remove from List") { model.forgetBottle(bottle.name) }
                            .help(HelpText.removeFromList)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    /// Disk: used / allocated with a bar for an image-backed bottle, the Mac's free
    /// space for a folder bottle, and the button to change it (StorageSheet).
    private var storageRow: some View {
        HStack(spacing: 8) {
            Image(systemName: bottle.isImageBacked ? "internaldrive" : "folder")
                .foregroundStyle(.secondary)
            if let work = model.storageWork[bottle.name] {
                ProgressView().controlSize(.small)
                Text(work).foregroundStyle(.secondary)
            } else if bottle.isImageBacked {
                if let usage = model.storageUsage[bottle.name] ?? bottle.storageUsage {
                    Group {
                        Text("Disk")
                        ProgressView(value: usage.fraction)
                            .tint(usage.fraction > 0.9 ? .red : (usage.fraction > 0.75 ? .orange : .accentColor))
                            .frame(width: 160)
                        Text("\(formatGB(usage.used)) of \(formatGB(usage.total)) used, \(formatGB(usage.available)) free")
                            .foregroundStyle(.secondary)
                    }
                    .help(HelpText.diskUsage)
                } else {
                    Text("Disk image not mounted").foregroundStyle(.secondary)
                }
            } else {
                Text("Folder, no size limit")
                    .help(HelpText.diskFolder)
                if let free = model.hostFree[bottle.name], free > 0 {
                    Text("· \(formatGB(free)) free").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if model.storageWork[bottle.name] == nil {
                Text("·").foregroundStyle(.secondary)
                Image(systemName: bottle.location == nil ? "wineglass" : "externaldrive")
                    .foregroundStyle(.secondary)
                Text(model.locationText(bottle).map { "on \($0)" } ?? "in the bottles folder")
                    .foregroundStyle(.secondary)
                    .help(HelpText.diskLocation(bottle.location?.path ?? model.project?.bottles.path ?? ""))
            }
            Spacer()
            Menu("Move to…") {
                Button("Choose a Folder…", action: chooseMoveTarget)
                    .help(HelpText.moveChooseFolder)
                Button("The Bottles Folder") { model.moveBottle(bottle.name, to: nil) }
                    .disabled(bottle.location == nil)
                    .help(HelpText.moveBottlesFolder)
                if bottle.location != nil && bottle.isImageBacked {
                    Divider()
                    Button("Eject") { model.ejectBottle(bottle.name) }
                        .help(HelpText.moveEject)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
            .disabled(model.storageWork[bottle.name] != nil)
            .help(HelpText.moveMenu)
            Button(bottle.isImageBacked ? "Change…" : "Move to a Disk Image…") { showingStorage = true }
                .controlSize(.small)
                .disabled(model.storageWork[bottle.name] != nil)
                .help(bottle.isImageBacked ? HelpText.changeSize : HelpText.moveToImage)
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .sheet(isPresented: $showingStorage) {
            StorageSheet(bottle: bottle)
        }
    }

    /// Move to… > Choose a Folder…: the bottle goes to <folder>/<name> (or its image to
    /// <folder>/<name>.sparsebundle) after a confirmation.
    private func chooseMoveTarget() {
        let panel = NSOpenPanel()
        panel.title = "Move \(bottle.name) to…"
        panel.message = "The bottle is copied into the folder you choose, checked, and then removed from where it is now."
        panel.prompt = "Move Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !bottle.isImageBacked, let problem = Runtime.folderBottleProblem(at: url) {
            model.alertMessage = "\(bottle.name): \(problem). Move it into a disk image first (Move to a Disk Image…), then move the image."
            return
        }
        model.moveBottle(bottle.name, to: url)
    }

    /// The stuck prompt belongs to this page only when it is about this bottle.
    private var stuckPromptShown: Binding<Bool> {
        Binding(get: { model.steamStuckPrompt?.bottle == bottle.name },
                set: { if !$0 { model.steamStuckPrompt = nil } })
    }

    private var steamStatus: Steam.Status? { model.steamStatus[bottle.name] }

    /// Steam first (its own install chain, status line and Restart), then the other
    /// stores: state from a process scan by exe name, Install… (asks first) or Launch.
    private var storesBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                steamRow
                ForEach(Store.all.filter { !$0.isSteam }) { store in
                    Divider()
                    storeRow(store)
                }
            }
            .padding(4)
        } label: {
            Label("Stores", systemImage: "bag")
        }
        .frame(minWidth: 360, maxWidth: .infinity)
        .layoutPriority(1)
    }

    /// Steam: installed / running / online or offline from `Steam.status` (the former
    /// status line), the Install / Launch / Restart buttons, and the stuck reason with a
    /// Restart Steam shortcut.
    private var steamRow: some View {
        let installed = Steam.isInstalled(in: bottle)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Group {
                    Circle().fill(installed ? steamStatusColor : .clear)
                        .overlay(Circle().stroke(Color.secondary.opacity(installed ? 0 : 0.6)))
                        .frame(width: 8, height: 8)
                    Text("Steam").fontWeight(.medium)
                    Text(installed || model.steamSetup.contains(bottle.name)
                         ? String(steamStatusText.dropFirst("Steam: ".count)) : "not installed")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help(HelpText.steamStatus)
                Spacer()
                steamButtons
            }
            if let reason = steamStatus?.stuckReason, installed, !model.steamRestarting.contains(bottle.name) {
                HStack(spacing: 8) {
                    Text(reason).foregroundStyle(.secondary)
                    Button("Restart Steam") { model.restartSteam(bottle.name) }
                        .controlSize(.small)
                        .help(HelpText.restartSteam)
                }
                .padding(.leading, 16)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var steamButtons: some View {
        if model.steamSetup.contains(bottle.name) {
            Button {} label: {
                Label("Setting up…", systemImage: "hourglass")
            }
            .disabled(true)
            .help(HelpText.steamSettingUp)
        } else if model.steamRestarting.contains(bottle.name) {
            Button {} label: {
                Label("Restarting…", systemImage: "hourglass")
            }
            .disabled(true)
            .help(HelpText.steamRestarting)
        } else if Steam.isInstalled(in: bottle) {
            Button("Launch") {
                model.launchSteam(bottle.name)
            }
            .help(HelpText.launchSteam)
            Button {
                model.restartSteam(bottle.name)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(HelpText.restartSteam)
            Button("Check…") {
                model.checkSteam(bottle.name)
                showingSteamCheck = true
            }
            .help(HelpText.checkSteam)
            .sheet(isPresented: $showingSteamCheck) {
                SteamCheckSheet(bottle: bottle.name)
            }
        } else {
            Button("Install Steam") {
                model.installSteam(bottle.name)
            }
            .help(HelpText.installSteam)
        }
    }

    private func storeRow(_ store: Store) -> some View {
        let installed = store.isInstalled(in: bottle)
        let running = model.storesRunning[bottle.name]?.contains(store.id) == true
        let installing = model.isInstallingStore(store, in: bottle.name)
        return HStack(spacing: 8) {
            Group {
                Circle().fill(running ? Color.green : (installed ? Color.secondary : .clear))
                    .overlay(Circle().stroke(Color.secondary.opacity(installed || running ? 0 : 0.6)))
                    .frame(width: 8, height: 8)
                Text(store.name).fontWeight(.medium)
                Text(installing ? "installing…" : (running ? "running" : (installed ? "installed" : "not installed")))
                    .foregroundStyle(.secondary)
            }
            .help(HelpText.storeStatus(store.name))
            if let issue = store.knownIssue {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(HelpText.storeKnownIssue(issue))
            }
            Spacer()
            if installing {
                ProgressView().controlSize(.small)
            } else if installed {
                Button("Launch") { model.launchStore(store, in: bottle.name) }
                    .help(HelpText.storeLaunch(store.name))
            } else {
                Button("Install…") { storeToInstall = store }
                    .help(HelpText.storeInstall(store.name))
            }
        }
        .font(.callout)
    }

    private var steamStatusText: String {
        if model.steamRestarting.contains(bottle.name) { return "Steam: restarting…" }
        if model.steamSetup.contains(bottle.name) { return "Steam: setting up…" }
        guard let status = steamStatus else { return "Steam: installed" }
        guard status.isRunning else {
            return status.processes.hasOrphanWebhelper ? "Steam: not running properly" : "Steam: installed, not running"
        }
        guard let connection = status.connection, connection.date >= (status.processes.steamStarted ?? .distantPast) else {
            return "Steam: running, starting…"
        }
        switch connection.state {
        case .loggedOn: return "Steam: running, online"
        case .connecting:
            return connection.account == nil ? "Steam: running, not signed in" : "Steam: running, connecting…"
        case .loggedOff:
            if connection.isSignedOut { return "Steam: running, not signed in" }
            return "Steam: running, offline since \(Steam.Status.timeText(connection.date))"
        }
    }

    private var steamStatusColor: Color {
        if model.steamRestarting.contains(bottle.name) || model.steamSetup.contains(bottle.name) { return .orange }
        guard let status = steamStatus else { return .secondary }
        if status.stuckReason != nil { return .red }
        guard status.isRunning else { return .secondary }
        return status.connection?.state == .loggedOn ? .green : .orange
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bottle.name).font(.largeTitle.bold())
                Text(bottle.location?.path ?? bottle.prefix.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if drivable {
                Picker("Graphics", selection: Binding(get: { bottle.config.graphics },
                                                      set: { model.setGraphics($0, for: bottle.name) })) {
                    ForEach(Graphics.allCases, id: \.self) { g in Text(g.title).tag(g) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                .help(HelpText.graphicsPicker)
            }
            Button {
                model.reveal(bottle.driveC)
            } label: {
                Label("Show C:", systemImage: "folder")
            }
            .help(HelpText.showC)
        }
    }

    private var actions: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button {
                        chooseExe()
                    } label: {
                        Label("Run .exe…", systemImage: "play.fill")
                    }
                    .keyboardShortcut("o")
                    .help(HelpText.runExe)
                    TextField("arguments (optional)", text: $exeArguments)
                        .frame(maxWidth: 220)
                        .help(HelpText.exeArguments)
                    Spacer()
                    Button(role: .destructive) {
                        model.killBottle(bottle.name)
                    } label: {
                        Label("Kill Bottle", systemImage: "xmark.octagon")
                    }
                    .help(HelpText.killBottle)
                }
                HStack {
                    Button("Wine Configuration") { model.winecfg(bottle.name) }
                        .help(HelpText.wineConfiguration)
                    Button("Command Prompt") { model.commandPrompt(bottle.name) }
                        .help(HelpText.commandPrompt)
                    Button("Explorer") { model.explorer(bottle.name) }
                        .help(HelpText.explorer)
                    Divider().frame(height: 20)
                    TextField("cmd /c …  e.g. ver", text: $commandLine)
                        .onSubmit(runCommandLine)
                        .help(HelpText.commandLine)
                    Button("Run", action: runCommandLine)
                        .disabled(commandLine.isEmpty)
                        .help(HelpText.runCommand)
                }
            }
            .padding(4)
        }
    }

    private var processes: some View {
        GroupBox("Processes started from Gamify") {
            if jobs.isEmpty {
                Text("None yet. Output of every program started here is logged to ~/Library/Logs/Gamify/\(bottle.name)/.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(jobs.reversed()) { job in
                            JobRow(job: job, selected: job.id == shownJob?.id)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedJob = job.id }
                                .help(HelpText.jobRow)
                        }
                    }
                }
                .frame(maxHeight: 88)
            }
        }
    }

    private func runCommandLine() {
        guard !commandLine.isEmpty else { return }
        model.runCommandLine(commandLine, in: bottle.name)
        selectedJob = nil
    }

    private func chooseExe() {
        let panel = NSOpenPanel()
        panel.title = "Run a Windows program in \(bottle.name)"
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = bottle.driveC
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let args = exeArguments.split(separator: " ").map(String.init)
        model.runExe(url, arguments: args, in: bottle.name)
        selectedJob = nil
    }
}

/// The bottle page's Performance box: `BottleConfig.performance` (Performance.swift), saved
/// to cross.json on every change and used by programs started afterwards.
struct PerformanceBox: View {
    @EnvironmentObject var model: AppModel
    let bottle: Bottle

    private var d3dmetal: Bool { bottle.config.graphics == .d3dmetal }

    /// A binding to one setting that saves the whole set when it changes.
    private func setting<T>(_ keyPath: WritableKeyPath<PerformanceSettings, T>) -> Binding<T> {
        Binding(get: { bottle.config.performance[keyPath: keyPath] },
                set: { value in
                    var p = bottle.config.performance
                    p[keyPath: keyPath] = value
                    model.setPerformance(p, for: bottle.name)
                })
    }

    /// Ray tracing: 0 = D3DMetal's default, 1 = on, 2 = off.
    private var raytracing: Binding<Int> {
        Binding(get: { bottle.config.performance.raytracing.map { $0 ? 1 : 2 } ?? 0 },
                set: { setting(\.raytracing).wrappedValue = $0 == 0 ? nil : $0 == 1 })
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Picker("Sync", selection: setting(\.sync)) {
                        Text("ESync").tag(SyncMode.esync)
                        Text("MSync").tag(SyncMode.msync)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help(HelpText.perfSync)
                    Toggle("DLSS via MetalFX", isOn: setting(\.metalfx))
                        .disabled(!d3dmetal)
                        .help(d3dmetal ? HelpText.perfMetalFX : HelpText.perfMetalFXDisabled)
                    Toggle("Advertise AVX", isOn: setting(\.avx))
                        .help(HelpText.perfAVX)
                    Picker("Ray tracing", selection: raytracing) {
                        Text("Default").tag(0)
                        Text("On").tag(1)
                        Text("Off").tag(2)
                    }
                    .fixedSize()
                    .disabled(!d3dmetal)
                    .help(HelpText.perfRayTracing)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 16) {
                    LabeledContent("FPS cap") {
                        TextField("FPS cap", value: setting(\.maxFPS), format: .number, prompt: Text("off"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                    }
                    .fixedSize()
                    .disabled(!d3dmetal)
                    .help(HelpText.perfFPSCap)
                    Toggle("Metal HUD", isOn: setting(\.hud))
                        .help(HelpText.perfHUD)
                    Toggle("Retina (High Resolution)", isOn: setting(\.retina))
                        .help(HelpText.perfRetina)
                    Spacer(minLength: 0)
                }
                Text("Applies to programs started afterwards; change Sync and Retina only while nothing runs in this bottle.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(4)
        } label: {
            Label("Performance", systemImage: "gauge.with.dots.needle.67percent")
        }
    }
}

/// Size picker shared by the New Bottle sheet and StorageSheet: slider + whole-GB field.
struct StorageSizeField: View {
    @Binding var sizeGB: Int
    let range: ClosedRange<Int>

    var body: some View {
        LabeledContent("Size") {
            HStack {
                if range.count > 1 {
                    Slider(value: Binding(get: { Double(min(max(sizeGB, range.lowerBound), range.upperBound)) },
                                          set: { sizeGB = Int($0.rounded()) }),
                           in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                        .frame(minWidth: 160)
                }
                TextField("Size", value: $sizeGB, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Text("GB")
                Stepper("Size", value: $sizeGB, in: range)
                    .labelsHidden()
            }
            .help(HelpText.storageSize)
        }
    }
}

/// Change… / Move to a Disk Image… on the bottle page.
struct StorageSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let bottle: Bottle
    @State private var sizeGB = BottleStorage.defaultGB

    private var range: ClosedRange<Int> { model.storageRange(for: bottle) }
    private var usage: StorageUsage? { model.storageUsage[bottle.name] ?? bottle.storageUsage }
    private var valid: Bool { range.contains(sizeGB) }

    var body: some View {
        Form {
            Section {
                if let usage {
                    LabeledContent("Now", value: "\(formatGB(usage.used)) used of \(formatGB(usage.total))")
                }
                StorageSizeField(sizeGB: $sizeGB, range: range)
                if !valid {
                    Text("Choose \(range.lowerBound)–\(range.upperBound) GB.").font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text(bottle.isImageBacked ? "Disk of '\(bottle.name)'" : "Move '\(bottle.name)' to a disk image")
                    .font(.headline)
            } footer: {
                Text(bottle.isImageBacked
                     ? "Windows sees C: as a drive of this size. Shrinking needs room above what is used; the minimum is \(range.lowerBound) GB, the maximum what this Mac has free. Takes a few seconds; programs in the bottle must be closed."
                     : "The bottle is copied into its own disk image (an APFS sparse bundle next to it, which only takes the space actually used), checked, and swapped in; the folder is removed once the copy is verified. Needs as much free space as the bottle takes while it copies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if bottle.isImageBacked {
                Section {
                    Button("Move to a Folder (no size limit)") {
                        model.setStorage(nil, for: bottle.name)
                        dismiss()
                    }
                    .help(HelpText.storageToFolder)
                } footer: {
                    Text("Copies the bottle out of its disk image into a plain folder, then deletes the image.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear {
            let current = bottle.config.storage?.sizeGB ?? usage.map { Int(($0.total + BottleStorage.gib / 2) / BottleStorage.gib) }
            sizeGB = min(max(current ?? model.defaultStorageGB ?? BottleStorage.defaultGB, range.lowerBound), range.upperBound)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(bottle.isImageBacked ? "Resize" : "Move") {
                    model.setStorage(sizeGB, for: bottle.name)
                    dismiss()
                }
                .disabled(!valid)
                .help(bottle.isImageBacked ? HelpText.storageResize : HelpText.storageMove)
            }
        }
    }
}

struct JobRow: View {
    @ObservedObject var job: Job
    let selected: Bool
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Circle()
                .fill(job.isRunning ? Color.green : (job.termination == .exited(0) ? Color.secondary : Color.orange))
                .frame(width: 8, height: 8)
            Text(job.label).fontWeight(.medium)
            Text(job.started, style: .time).foregroundStyle(.secondary)
            Text(job.status).foregroundStyle(.secondary)
            Spacer()
            if job.isRunning {
                Button("Stop") { model.stop(job) }
                    .controlSize(.small)
                    .help(HelpText.jobStop)
            }
            Button {
                model.reveal(job.logURL)
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help(HelpText.jobLog)
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
    }
}
