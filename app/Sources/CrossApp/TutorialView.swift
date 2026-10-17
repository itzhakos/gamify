import AppKit
import CrossCore
import SwiftUI

/// The first-run tutorial: six steps with Back / Next / Skip. Every step reads the
/// model and adapts (Rosetta 2 already there, existing bottles can be picked instead
/// of created, an installed Steam skips the install). The bottle and Steam steps call
/// the same AppModel actions as the main window and show their job logs inline.
/// Written for someone who received the app and knows nothing about Wine.
struct TutorialView: View {
    static let windowID = "tutorial"

    @EnvironmentObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = 0

    // Bottle step
    @State private var choice: BottleChoice?
    @State private var newName = ""
    @State private var winebootJob: Job?
    // Steam step
    @State private var installStartedHere = false

    enum BottleChoice: Hashable {
        case existing(String)
        case new
    }

    private enum Step: Int, CaseIterable {
        case welcome, rosetta, bottles, steam, run, locations

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .rosetta: return "Rosetta 2"
            case .bottles: return "Bottles"
            case .steam: return "Steam"
            case .run: return "Run a game"
            case .locations: return "Where things live"
            }
        }
    }

    private var current: Step { Step(rawValue: step) ?? .locations }
    private var lastStep: Int { Step.allCases.count - 1 }

    /// The bottle the Steam step works on: the one picked or created in the bottle step.
    private var chosenBottle: Bottle? {
        if case .existing(let name)? = choice { return model.bottle(named: name) }
        return nil
    }

    private var drivableBottles: [Bottle] { model.bottles.filter(model.isDrivable) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch current {
                case .welcome: welcomeStep
                case .rosetta: rosettaStep
                case .bottles: bottleStep
                case .steam: steamStep
                case .run: runStep
                case .locations: pathsStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 640, height: 600)
        // Rosetta installed from the step: go on to the bottle step
        .onChange(of: model.rosettaInstalled) { _, installed in
            if installed && current == .rosetta { step = Step.bottles.rawValue }
        }
        .onAppear {
            if choice == nil {
                choice = drivableBottles.isEmpty ? .new
                       : .existing(drivableBottles.first { $0.name == model.selection }?.name ?? drivableBottles[0].name)
            }
            if newName.isEmpty { newName = model.suggestedBottleName() }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "wineglass")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(current.title).font(.title2.bold())
                Text("Step \(step + 1) of \(Step.allCases.count)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0...lastStep, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("Skip Tutorial") { finish() }
                .disabled(step == lastStep)
            Spacer()
            Button("Back") { step -= 1 }
                .disabled(step == 0)
            if step == lastStep {
                Button("Finish") { finish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Next") { step += 1 }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: AppModel.tutorialShownKey)
        dismissWindow(id: Self.windowID)
    }

    /// Scrollable step body with the Form look of the rest of the app.
    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func bullet(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func box<Content: View>(_ title: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        } label: {
            if let title { Text(title) }
        }
    }

    // MARK: - Step 1: what Gamify is

    private var welcomeStep: some View {
        page {
            Text("Gamify runs Windows games on your Mac.")
                .font(.title3.bold())
            Text("Gamify is built on Wine (the same CrossOver lineage) and on D3DMetal, Apple's layer that turns DirectX into Metal. Windows games run on your Apple Silicon Mac without a Windows license or a virtual machine. Everything stays inside Gamify: nothing is installed system-wide.")
            box("What works") {
                bullet("checkmark.circle.fill", .green, "DirectX 9, 10, 11 and 12 games",
                       "D3DMetal 3.0 handles the graphics; a second backend (wined3d) is one click away per bottle.")
                bullet("checkmark.circle.fill", .green, "Steam",
                       "Installed with one click, with the store and your library rendering normally.")
                bullet("checkmark.circle.fill", .green, "Plain Windows programs and installers",
                       "Run any .exe from the open panel or by drag-and-drop.")
            }
            box("What does not") {
                bullet("xmark.circle.fill", .red, "Games with kernel-level anti-cheat",
                       "Easy Anti-Cheat, BattlEye, Vanguard and similar need a real Windows kernel, which Wine does not provide.")
                bullet("exclamationmark.triangle.fill", .orange, "Anything that needs a Windows driver",
                       "Launchers or copy protection that install drivers, and hardware with its own driver.")
                bullet("exclamationmark.triangle.fill", .orange, "Performance varies",
                       "Most games run well, some need a try with the other graphics backend. Every launch is logged, so there is always something to look at.")
            }
        }
    }

    // MARK: - Step 2: Rosetta 2

    private var rosettaStep: some View {
        page {
            Text("Windows games are Intel programs. On an Apple Silicon Mac they run through Rosetta 2, Apple's translation layer. It is a free, one-time download from Apple.")
            if model.rosettaInstalled {
                box {
                    Label("Rosetta 2 is installed. Nothing to do here.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else {
                box("Rosetta 2 is not installed yet") {
                    Text("Gamify cannot create a bottle or run anything until it is. Install it now: macOS asks for your password, the download is about 300 MB and takes a minute.")
                    HStack {
                        Button {
                            model.installRosetta()
                        } label: {
                            Label(model.rosettaInstalling ? "Installing…" : "Install Rosetta 2…", systemImage: "arrow.down.circle")
                        }
                        .disabled(model.rosettaInstalling)
                        if model.rosettaInstalling { ProgressView().controlSize(.small) }
                    }
                    Text("Prefer the Terminal? Run this command, then click Check Again:")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Text(Runtime.rosettaInstallCommand)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Runtime.rosettaInstallCommand, forType: .string)
                        }
                        .controlSize(.small)
                        Button("Check Again") { model.recheckRosetta() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Step 3: bottles

    private var bottleStep: some View {
        page {
            Text("A bottle is a self-contained Windows: its own C: drive, settings and installed programs. Each bottle has a graphics backend (D3DMetal or wined3d) you can switch any time. Keep Steam in one bottle and experiments in another; deleting a bottle removes everything in it.")
            if model.project == nil {
                box {
                    Label(model.loadError ?? "Gamify could not find its runtime. See Settings.", systemImage: "exclamationmark.triangle")
                }
            } else if !model.rosettaInstalled || model.availableRuntimes.isEmpty {
                box {
                    Label(model.rosettaInstalled ? "No Wine runtime was found. See Settings."
                                                 : "Rosetta 2 is missing: go back one step and install it first.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else if let job = winebootJob {
                createdBox(job)
            } else {
                if !drivableBottles.isEmpty {
                    box("You already have \(drivableBottles.count == 1 ? "a bottle" : "\(drivableBottles.count) bottles")") {
                        Text("Pick the one to use for the next steps, or create a new one.")
                            .font(.callout).foregroundStyle(.secondary)
                        Picker("Bottle", selection: $choice) {
                            ForEach(drivableBottles, id: \.name) { bottle in
                                Text("\(bottle.name)  (\(bottle.config.graphics == .d3dmetal ? "D3DMetal" : "wined3d")\(Steam.isInstalled(in: bottle) ? ", Steam installed" : ""))")
                                    .tag(Optional(BottleChoice.existing(bottle.name)))
                            }
                            Text("Create a new bottle").tag(Optional(BottleChoice.new))
                        }
                        .frame(maxWidth: 420)
                    }
                }
                if choice == .new {
                    createBox
                }
            }
        }
    }

    private var createBox: some View {
        box(drivableBottles.isEmpty ? "Create your first bottle" : "Create a new bottle") {
            HStack {
                Text("Name").frame(width: 70, alignment: .trailing)
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .onSubmit(createBottle)
                if let error = model.newBottleNameError(newName) {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            if model.availableRuntimes.count > 1 {
                HStack {
                    Text("Runtime").frame(width: 70, alignment: .trailing)
                    Text(NewBottleSheet.runtimeTitle(model.preferredRuntime))
                }
            }
            HStack {
                Text("Graphics").frame(width: 70, alignment: .trailing)
                Text("D3DMetal 3.0")
            }
            Text("Setting up the C: drive takes about 40 seconds. The + button in the main window offers the other options.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Create Bottle", action: createBottle)
                .disabled(newName.isEmpty || model.newBottleNameError(newName) != nil)
        }
    }

    private func createBottle() {
        guard model.newBottleNameError(newName) == nil, !newName.isEmpty else { return }
        guard let job = model.createBottle(name: newName, graphics: .d3dmetal) else { return }
        winebootJob = job
        choice = .existing(newName)
    }

    private func createdBox(_ job: Job) -> some View {
        box("Creating bottle '\(job.bottle)'") {
            JobStatusLine(job: job, running: "Setting up the C: drive…",
                          done: "Bottle '\(job.bottle)' is ready. It is selected in the main window.")
            LogView(url: job.logURL)
                .frame(height: 150)
            Text("Every program Gamify starts gets a log like this; the bottle page shows them.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Step 4: Steam

    private var steamStep: some View {
        page {
            Text("Steam is the easiest way to get games into a bottle. Gamify installs it with Valve's official installer and takes care of the two things Steam needs help with on a Mac: its first start, and the built-in browser that draws the store, which Gamify swaps for one that renders here.")
            Text("If Steam ever shows \"No connection\" or stops responding (for example after the Mac slept), Restart Steam on the bottle page quits it and starts it again cleanly; Gamify also offers this by itself when Launch Steam finds Steam stuck.")
                .font(.callout).foregroundStyle(.secondary)
            if let bottle = chosenBottle {
                if model.steamSetup.contains(bottle.name) {
                    steamProgressBox(bottle)
                } else if Steam.isInstalled(in: bottle) {
                    steamInstalledBox(bottle)
                } else {
                    steamInstallBox(bottle)
                }
            } else {
                box {
                    Label("Pick or create a bottle in the previous step to install Steam from here. You can also do it later with Install Steam on any bottle page.",
                          systemImage: "info.circle")
                }
            }
        }
    }

    private func steamInstallBox(_ bottle: Bottle) -> some View {
        let winebootRunning = winebootJob.map { $0.bottle == bottle.name && $0.isRunning } ?? false
        return box("Install Steam in '\(bottle.name)'") {
            Text("What happens, all from one click:")
            bullet("1.circle", .accentColor, "The Steam installer runs in the bottle",
                   "Downloaded once from Steam and kept for later reinstalls.")
            bullet("2.circle", .accentColor, "Steam starts and downloads its client (about 1.7 GB)",
                   "A black Steam window during this first start is normal; the log shows the progress.")
            bullet("3.circle", .accentColor, "Gamify restarts Steam",
                   "The \"Sign in to Steam\" window appears. Sign in there with your Steam account; Gamify never sees your password.")
            if winebootRunning {
                Label("Waiting for the bottle to finish setting up…", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button {
                installStartedHere = true
                model.installSteam(bottle.name)
            } label: {
                Label("Install Steam", systemImage: "arrow.down.circle")
            }
            .disabled(winebootRunning)
        }
    }

    private func steamProgressBox(_ bottle: Bottle) -> some View {
        box("Setting up Steam in '\(bottle.name)'…") {
            if let job = model.jobs(for: bottle.name).last {
                JobStatusLine(job: job, running: "\(job.label): running", done: "\(job.label): \(job.status)")
                LogView(url: job.logURL)
                    .frame(height: 170)
            }
            Text("Installer, first start with the client download (black window), restart, then Steam with its sign-in window. This takes a few minutes; you can continue with Next in the meantime.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func steamInstalledBox(_ bottle: Bottle) -> some View {
        box {
            if installStartedHere {
                Label("Steam is installed in '\(bottle.name)' and should be showing its \"Sign in to Steam\" window. Sign in there, then continue.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Steam is already installed in '\(bottle.name)'. Nothing to do here.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(Steam.isBootstrapped(in: bottle)
                     ? "Launch Steam on the bottle page starts it."
                     : "Its client was not downloaded yet; the first Launch Steam on the bottle page does that.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.isBusy(bottle.name) {
                Label("Steam is running (see the bottle page).", systemImage: "circle.fill")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Button {
                    model.launchSteam(bottle.name)
                } label: {
                    Label("Launch Steam", systemImage: "gamecontroller")
                }
            }
        }
    }

    // MARK: - Step 5: running games

    private var runStep: some View {
        page {
            Text("Every bottle page in the main window has the same set of actions. Programs you start are listed there, each with its own log.")
            box("Three ways to run something") {
                bullet("gamecontroller", .accentColor, "Launch Steam",
                       "Starts Steam in the bottle. Install and play games from your library as on Windows.")
                bullet("play.fill", .accentColor, "Run .exe…",
                       "For games and installers outside Steam: pick any .exe, optionally with arguments. The panel opens in the bottle's C: drive.")
                bullet("arrow.down.doc", .accentColor, "Drag and drop",
                       "Drop an .exe onto a bottle page or onto the Gamify icon in the Dock, or open it with Gamify from Finder. It runs in that (or the selected) bottle.")
            }
            box("Also on the bottle page") {
                bullet("slider.horizontal.3", .secondary, "Graphics picker",
                       "D3DMetal or wined3d per bottle, for programs started afterwards. Try the other one when a game misbehaves.")
                bullet("wrench.and.screwdriver", .secondary, "Wine Configuration, Command Prompt, Explorer",
                       "Windows version and drive settings, a command window, and a file browser for the C: drive.")
                bullet("xmark.octagon", .red, "Kill Bottle",
                       "Ends every Windows program in the bottle: the way out of a stuck game or Steam.")
            }
        }
    }

    // MARK: - Step 6: locations

    private var pathsStep: some View {
        page {
            Text("Everything Gamify makes is a plain folder or file; nothing is hidden in the system.")
            box {
                locationRow("folder", "Bottles", model.project?.bottles,
                            "One folder per bottle, with its C: drive inside. Show C: on a bottle page opens it in Finder.")
                locationRow("doc.text", "Logs", model.logsRoot,
                            "One log per program started from Gamify, named after the bottle, the time and the program. Attach these when asking for help.")
                locationRow("arrow.down.circle", "Downloads", model.project?.downloads,
                            "Installers Gamify fetched (the Steam installer), kept so a reinstall needs no network.")
            }
            box("Settings") {
                Text("Settings (⌘,) shows every folder Gamify uses and the exact environment a bottle runs with. Its General tab replays this tutorial, and Help > Gamify Tutorial brings it back too.")
                    .font(.callout)
                SettingsLink { Label("Open Settings", systemImage: "gearshape") }
            }
            Text("That is all. Click Finish, then pick a bottle in the main window and launch something.")
                .fontWeight(.medium)
        }
    }

    private func locationRow(_ symbol: String, _ title: String, _ url: URL?, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(title).fontWeight(.medium)
                    Text(url.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "-")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if let url {
                        Button { model.reveal(url) } label: { Image(systemName: "arrow.right.circle") }
                            .buttonStyle(.borderless)
                            .help("Show in Finder")
                    }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// One line about a job: a spinner while it runs, then its outcome.
struct JobStatusLine: View {
    @ObservedObject var job: Job
    let running: String
    let done: String

    var body: some View {
        HStack(spacing: 8) {
            if job.isRunning || (job.pid == nil && job.termination == nil && job.failure == nil) {
                ProgressView().controlSize(.small)
                Text(running)
            } else if job.termination == .exited(0) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(done)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(job.label) \(job.status). See the log below.")
            }
        }
    }
}
