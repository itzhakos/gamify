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

    private var drivable: Bool { model.isDrivable(bottle) }
    private var jobs: [Job] { model.jobs(for: bottle.name) }
    private var shownJob: Job? { jobs.first { $0.id == selectedJob } ?? jobs.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = bottle.storageError {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("This bottle's disk image cannot be opened", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.headline)
                        Text(error).textSelection(.enabled)
                        Button("Try Again") { model.reloadBottles() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                Spacer()
            } else if drivable {
                storageRow
                actions
                    .disabled(model.storageWork[bottle.name] != nil)
                if Steam.isInstalled(in: bottle) { steamStatusLine }
                processes
                LogView(url: shownJob?.logURL)
                    .frame(minHeight: 160)
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
                    Text("Disk")
                    ProgressView(value: usage.fraction)
                        .tint(usage.fraction > 0.9 ? .red : (usage.fraction > 0.75 ? .orange : .accentColor))
                        .frame(width: 160)
                    Text("\(formatGB(usage.used)) of \(formatGB(usage.total)) used, \(formatGB(usage.available)) free")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Disk image not mounted").foregroundStyle(.secondary)
                }
            } else {
                Text("Folder, no size limit")
                if model.hostFreeBytes > 0 {
                    Text("· \(formatGB(model.hostFreeBytes)) free on this Mac").foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(bottle.isImageBacked ? "Change…" : "Move to a Disk Image…") { showingStorage = true }
                .controlSize(.small)
                .disabled(model.storageWork[bottle.name] != nil)
                .help(bottle.isImageBacked
                      ? "Resize this bottle's disk (programs in it must be closed)"
                      : "Copy this bottle into its own disk image of a size you choose")
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .sheet(isPresented: $showingStorage) {
            StorageSheet(bottle: bottle)
        }
    }

    /// The stuck prompt belongs to this page only when it is about this bottle.
    private var stuckPromptShown: Binding<Bool> {
        Binding(get: { model.steamStuckPrompt?.bottle == bottle.name },
                set: { if !$0 { model.steamStuckPrompt = nil } })
    }

    private var steamStatus: Steam.Status? { model.steamStatus[bottle.name] }

    /// One line: installed / running / online or offline, from `Steam.status`, with a
    /// Restart Steam shortcut when it looks stuck.
    private var steamStatusLine: some View {
        HStack(spacing: 8) {
            Circle().fill(steamStatusColor).frame(width: 8, height: 8)
            Text(steamStatusText)
            if let reason = steamStatus?.stuckReason, !model.steamRestarting.contains(bottle.name) {
                Text(reason).foregroundStyle(.secondary)
                Button("Restart Steam") { model.restartSteam(bottle.name) }
                    .controlSize(.small)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 6)
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
                Text(bottle.prefix.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if drivable {
                Picker("Graphics", selection: Binding(get: { bottle.config.graphics },
                                                      set: { model.setGraphics($0, for: bottle.name) })) {
                    Text("D3DMetal").tag(Graphics.d3dmetal)
                    Text("wined3d").tag(Graphics.wined3d)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .help("DirectX 10/11/12 backend (first entry in WINEDLLPATH); applies to programs started afterwards")
            }
            Button {
                model.reveal(bottle.driveC)
            } label: {
                Label("Show C:", systemImage: "folder")
            }
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
                    TextField("arguments (optional)", text: $exeArguments)
                        .frame(maxWidth: 220)
                    Divider().frame(height: 20)
                    if model.steamSetup.contains(bottle.name) {
                        Button {} label: {
                            Label("Setting up Steam…", systemImage: "hourglass")
                        }
                        .disabled(true)
                        .help("First start: Steam downloads its client, then restarts with the webhelper shim (see the steam-bootstrap log)")
                    } else if model.steamRestarting.contains(bottle.name) {
                        Button {} label: {
                            Label("Restarting Steam…", systemImage: "hourglass")
                        }
                        .disabled(true)
                        .help("Steam is asked to quit, the bottle is cleared, then Steam starts again (see the job list)")
                    } else if Steam.isInstalled(in: bottle) {
                        Button {
                            model.launchSteam(bottle.name)
                        } label: {
                            Label("Launch Steam", systemImage: "gamecontroller")
                        }
                        .help("Installs the webhelper shim, resets ActiveProcess, clears stale locks, runs steam.exe \(Runtime.steamFlags.joined(separator: " ")) (the first start downloads the client and restarts Steam once). A stuck Steam is detected first and offered a restart.")
                        Button {
                            model.restartSteam(bottle.name)
                        } label: {
                            Label("Restart Steam", systemImage: "arrow.clockwise")
                        }
                        .help("steam.exe -shutdown, wait up to 20 s, wineserver -k to be sure, then Launch Steam. The way out of a Steam that lost its connection or stopped responding.")
                    } else {
                        Button {
                            model.installSteam(bottle.name)
                        } label: {
                            Label("Install Steam", systemImage: "arrow.down.circle")
                        }
                        .help("Runs SteamSetup.exe /S (downloads it into downloads/steam/ if missing), then starts Steam once to download its client")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        model.killBottle(bottle.name)
                    } label: {
                        Label("Kill Bottle", systemImage: "xmark.octagon")
                    }
                    .help("wineserver -k: ends every Windows process in this bottle")
                }
                HStack {
                    Button("Wine Configuration") { model.winecfg(bottle.name) }
                    Button("Command Prompt") { model.commandPrompt(bottle.name) }
                    Button("Explorer") { model.explorer(bottle.name) }
                    Divider().frame(height: 20)
                    TextField("cmd /c …  e.g. ver", text: $commandLine)
                        .onSubmit(runCommandLine)
                    Button("Run", action: runCommandLine)
                        .disabled(commandLine.isEmpty)
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
                        }
                    }
                }
                .frame(maxHeight: 110)
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
                    .help("SIGTERM to this process (Kill Bottle ends everything)")
            }
            Button {
                model.reveal(job.logURL)
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show the log file")
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
    }
}
