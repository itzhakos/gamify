import AppKit
import CrossCore
import Foundation

/// A process the app started in a bottle. Its stdout/stderr go to `logURL`; the child
/// is detached (own process group, log file instead of a pipe), so it keeps running
/// when the app quits.
@MainActor
final class Job: ObservableObject, Identifiable {
    let id = UUID()
    let bottle: String
    let label: String
    let logURL: URL
    let started = Date()
    @Published var pid: pid_t?
    @Published var termination: Termination?
    @Published var failure: String?

    init(bottle: String, label: String, logURL: URL) {
        self.bottle = bottle
        self.label = label
        self.logURL = logURL
    }

    var isRunning: Bool { pid != nil && termination == nil && failure == nil }

    var status: String {
        if let failure { return failure }
        if let termination { return termination.description }
        return pid.map { "running (pid \($0))" } ?? "starting"
    }

    /// Appends a line to the job's log (used for app-side messages, not the child).
    nonisolated func note(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var project: Project?
    @Published private(set) var runtime: Runtime?
    @Published private(set) var loadError: String?
    @Published private(set) var bottles: [Bottle] = []
    @Published var selection: String?
    @Published private(set) var jobs: [Job] = []
    @Published var alertMessage: String?
    /// Bottles where Install Steam / the first Steam start is in progress.
    @Published private(set) var steamSetup: Set<String> = []
    /// Bottles where Restart Steam is in progress (shutdown, wait, kill, launch).
    @Published private(set) var steamRestarting: Set<String> = []
    /// What Steam is doing per bottle (processes + newest connection_log state), refreshed
    /// by the bottle page every few seconds and before every Launch Steam.
    @Published private(set) var steamStatus: [String: Steam.Status] = [:]
    /// Launch Steam found a stuck Steam: the bottle page asks whether to restart it.
    @Published var steamStuckPrompt: SteamStuckPrompt?
    /// The last Check Steam… result per bottle, and the bottles being checked (AppModel+SteamCheck.swift).
    @Published var steamChecks: [String: Steam.Check] = [:]
    @Published var steamChecking: Set<String> = []
    /// Use of each image-backed bottle's disk, refreshed with the Steam status.
    @Published private(set) var storageUsage: [String: StorageUsage] = [:]
    /// Free space on the disk that holds each bottle (shown for folder bottles).
    @Published private(set) var hostFree: [String: Int64] = [:]
    /// Bottles being resized or moved (folder <-> disk image, to another folder or
    /// drive), with the current step.
    @Published var storageWork: [String: String] = [:]
    /// Bottles found on a drive that was just connected and that are not listed yet
    /// (AppModel+Location.swift); the sidebar offers to add them.
    @Published var foundOnDrives: [FoundBottle] = []
    /// Find Bottles sheet.
    @Published var showingFindBottles = false
    /// Store ids running per bottle (process scan by exe name, AppModel+Stores.swift).
    @Published var storesRunning: [String: Set<String>] = [:]
    /// "<bottle>/<store id>" while that store's installer runs.
    @Published var storeInstalls: Set<String> = []
    /// The Programs list per bottle (shortcuts + programs.json), refreshed with the status.
    @Published var programs: [String: [Program]] = [:]
    /// An installer opened with the app or dropped on a bottle page: Install or Just Run?
    @Published var installPrompt: InstallPrompt?
    /// D3DMetal's shader cache folders by lowercased exe name (ShaderCache, shared by all
    /// bottles), for Clear Shader Cache… in the Programs box.
    @Published var shaderCaches: [String: ShaderCache.Entry] = [:]

    struct SteamStuckPrompt: Identifiable, Equatable {
        let id = UUID()
        let bottle: String
        let reason: String
    }

    /// Settings > Paths override for the project root (used when the app bundle is not
    /// inside the checkout). Passed to Project.locate as CROSS_ROOT, never to Wine.
    static let rootOverrideKey = "crossRoot"

    /// Settings > Paths override for the bottles folder (where new bottles go and where
    /// the list is read from). Passed to Project.locate as CROSS_BOTTLES.
    static let bottlesOverrideKey = "bottlesFolder"

    /// Set once the first-run tutorial has been shown. `CROSS_RESET_TUTORIAL=1` in the
    /// app's environment clears it at launch, so the tutorial opens again.
    static let tutorialShownKey = "tutorialShown"

    let logsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Gamify")

    /// True until the first project lookup finished. The first file access can block for
    /// as long as macOS shows its "access files in your Desktop folder" prompt, so it
    /// runs off the main thread.
    @Published private(set) var isLocating = true

    init() {
        if ProcessInfo.processInfo.environment["CROSS_RESET_TUTORIAL"] == "1" {
            UserDefaults.standard.removeObject(forKey: Self.tutorialShownKey)
        }
        locateProject()
        observeVolumes()
    }

    // MARK: - First-run tutorial

    /// True exactly once per fresh UserDefaults domain: the first launch opens the
    /// tutorial window, and the flag is set right away so closing it counts as seen.
    func shouldOpenTutorialAtLaunch() -> Bool {
        guard !UserDefaults.standard.bool(forKey: Self.tutorialShownKey) else { return false }
        UserDefaults.standard.set(true, forKey: Self.tutorialShownKey)
        return true
    }

    /// Why `name` cannot be used for a new bottle, or nil (empty names give nil too, so
    /// the field shows no error before anything was typed).
    func newBottleNameError(_ name: String) -> String? {
        if name.isEmpty { return nil }
        if (try? Bottle.validate(name: name)) == nil { return "Invalid name" }
        if bottles.contains(where: { $0.name == name }) { return "A bottle with this name exists" }
        return nil
    }

    /// Rosetta 2 state for the tutorial, re-probed after an in-app install.
    @Published private(set) var rosettaInstalled = Runtime.rosettaAvailable
    @Published private(set) var rosettaInstalling = false

    /// Runs `softwareupdate --install-rosetta` with an administrator prompt (the
    /// standard macOS password dialog), then re-probes with `Runtime.recheckRosetta()`.
    func installRosetta() {
        guard !rosettaInstalling else { return }
        rosettaInstalling = true
        let source = "do shell script \"\(Runtime.rosettaInstallCommand)\" with administrator privileges"
        Task.detached {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            let message = error?[NSAppleScript.errorMessage] as? String
            let installed = Runtime.recheckRosetta()
            await MainActor.run {
                self.rosettaInstalled = installed
                self.rosettaInstalling = false
                if let message, !installed, !message.contains("-128") {   // -128: the user cancelled
                    self.alertMessage = "Rosetta 2 was not installed: \(message)"
                }
            }
        }
    }

    func recheckRosetta() {
        rosettaInstalled = Runtime.recheckRosetta()
    }

    /// The first of `games`, `games2`, … that is not a bottle yet (the tutorial's default).
    func suggestedBottleName() -> String {
        var n = 1
        while true {
            let name = n == 1 ? "games" : "games\(n)"
            if !bottles.contains(where: { $0.name == name }) { return name }
            n += 1
        }
    }

    // MARK: - Project and bottles

    func locateProject() {
        var env = ProcessInfo.processInfo.environment
        if let root = UserDefaults.standard.string(forKey: Self.rootOverrideKey), !root.isEmpty {
            env["CROSS_ROOT"] = root
        }
        if let bottles = UserDefaults.standard.string(forKey: Self.bottlesOverrideKey), !bottles.isEmpty {
            env["CROSS_BOTTLES"] = bottles
        }
        isLocating = true
        Task.detached {
            let result = Result { try Project.locate(environment: env) }
            if case .success(let project) = result {
                _ = try? Bottle.list(in: project)   // touch bottles/ here too, not on the main thread
            }
            await MainActor.run {
                switch result {
                case .success(let project):
                    self.project = project
                    self.runtime = Runtime(project: project)
                    self.loadError = nil
                case .failure(let error):
                    self.project = nil
                    self.runtime = nil
                    self.loadError = "\(error)"
                }
                self.isLocating = false
                self.reloadBottles()
            }
        }
    }

    /// Same listing as `cross bottle list`: every directory in bottles/, settings from
    /// cross.json with the .runtime fallback.
    func reloadBottles() {
        guard let project else { bottles = []; return }
        do {
            bottles = try Bottle.list(in: project)
        } catch {
            bottles = []
            alertMessage = "\(error)"
        }
        if let selection, !bottles.contains(where: { $0.name == selection }) {
            self.selection = nil
        }
        if selection == nil {
            selection = bottles.first(where: isDrivable)?.name ?? bottles.first?.name
        }
    }

    func bottle(named name: String?) -> Bottle? {
        bottles.first { $0.name == name }
    }

    /// Gamify (like the CLI) drives winecx and winecx-full bottles; others go through
    /// scripts/bottle.sh. A bottle whose disk image cannot be mounted is not drivable.
    func isDrivable(_ bottle: Bottle) -> Bool {
        Runtime.isKnown(bottle.config.runtime) && bottle.storageError == nil
    }

    /// Known runtimes whose build is present (runtimes/winecx, runtimes/winecx-full).
    var availableRuntimes: [String] {
        guard let project else { return [] }
        return Runtime.available(in: project)
    }

    /// The runtime new bottles default to (`Runtime.preferred`).
    var preferredRuntime: String {
        guard let project else { return Runtime.defaultName }
        return Runtime.preferred(in: project)
    }

    func runtime(for bottle: Bottle) -> Runtime? {
        guard let project else { return nil }
        return try? Runtime.forBottle(bottle, project: project)
    }

    func jobs(for bottle: String) -> [Job] {
        jobs.filter { $0.bottle == bottle }
    }

    func isBusy(_ bottle: String) -> Bool {
        jobs.contains { $0.bottle == bottle && $0.isRunning } || storageWork[bottle] != nil
    }

    /// The environment `cross env <bottle>` prints, computed from the app's own environment.
    /// `onlyChanged` keeps just the variables Runtime sets or changes.
    func environmentLines(for bottle: Bottle, export: Bool, onlyChanged: Bool = false) -> [String] {
        guard let project else { return [] }
        do {
            let base = ProcessInfo.processInfo.environment
            let runtime = try Runtime.forBottle(bottle, project: project, environment: base)
            var env = try runtime.environment(for: bottle, base: base)
            if onlyChanged { env = env.filter { base[$0.key] != $0.value } }
            return Runtime.environmentLines(env, export: export)
        } catch {
            return ["error: \(error)"]
        }
    }

    // MARK: - Launching

    /// Builds the invocation off the main thread (Steam prep runs regedit and copies
    /// files), then spawns it detached with its output in a per-job log file.
    @discardableResult
    func start(_ label: String, in bottleName: String,
               make: @escaping @Sendable (Runtime, Bottle, Job) async throws -> Invocation) -> Job? {
        guard let project else { alertMessage = loadError ?? "no project"; return nil }
        if let work = storageWork[bottleName] {
            alertMessage = "'\(bottleName)' is busy with its disk (\(work)). Try again when that is done."
            return nil
        }
        let dir = logsRoot.appendingPathComponent(bottleName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Self.stampFormatter.string(from: Date())
        let safeLabel = label.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "-")
        let logURL = dir.appendingPathComponent("\(stamp)-\(safeLabel).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let job = Job(bottle: bottleName, label: label, logURL: logURL)
        jobs.append(job)

        Task.detached {
            do {
                let (runtime, bottle) = try Runtime.loadBottle(bottleName, in: project)
                let inv = try await make(runtime, bottle, job)
                job.note("$ cd \(inv.cwd ?? "(inherited)")")
                job.note("$ " + ([inv.program] + inv.arguments).joined(separator: " "))
                let pid = try spawnDetached(inv, output: logURL) { termination in
                    Task { @MainActor in
                        job.termination = termination
                        self.reloadBottles()
                    }
                }
                await MainActor.run { job.pid = pid }
            } catch {
                job.note("cross: \(error)")
                await MainActor.run {
                    job.failure = "failed: \(error)"
                    self.alertMessage = "\(label): \(error)"
                }
            }
        }
        return job
    }

    /// Waits until `job` has ended (polled; jobs are few and short-lived waits are rare).
    func waitForExit(_ job: Job) async -> Termination? {
        while job.termination == nil && job.failure == nil {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return job.termination
    }

    /// Like `waitForExit`, but gives up after `timeout` seconds (false: still running).
    func waitForExit(_ job: Job, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while job.termination == nil && job.failure == nil {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return true
    }

    /// Run .exe: `cross run`, except that a Steam game's exe (inside steamapps/common) is
    /// started through Steam, like its Play button (`Runtime.programLaunch`).
    func runExe(_ exe: URL, arguments: [String], in bottle: String) {
        start(exe.lastPathComponent, in: bottle) { runtime, bottle, job in
            let (inv, steamGame) = try runtime.programLaunch(exe, arguments: arguments, in: bottle)
            if let steamGame { job.note("cross: \(steamGame.name) is a Steam game; starting it through Steam (\(steamGame.runURL))") }
            return inv
        }
    }

    /// .exe and .msi files opened with the app or dropped on a bottle page, for `bottle`
    /// (default: the selected one): installers (.msi, or an .exe named like setup/install)
    /// are offered Install a Program (`installPrompt`); other .exe files run, like
    /// `cross run <bottle> <exe>`.
    func openFiles(_ urls: [URL], in bottleName: String? = nil) {
        let files = urls.filter { $0.isFileURL && ["exe", "msi"].contains($0.pathExtension.lowercased()) }
        guard !files.isEmpty else { return }
        guard let name = bottleName ?? selection, let bottle = bottle(named: name), isDrivable(bottle) else {
            alertMessage = "Select a winecx bottle to run \(files.map(\.lastPathComponent).joined(separator: ", ")) in."
            return
        }
        var installers: [URL] = []
        for file in files {
            if Self.looksLikeInstaller(file) { installers.append(file) } else { runExe(file, arguments: [], in: bottle.name) }
        }
        if !installers.isEmpty { installPrompt = InstallPrompt(bottle: bottle.name, files: installers) }
    }

    func winecfg(_ bottle: String) {
        start("winecfg", in: bottle) { runtime, bottle, _ in
            try runtime.wineCommand(["winecfg"], in: bottle)
        }
    }

    /// `cross cmd` needs a terminal; from the GUI cmd gets Wine's own console window.
    func commandPrompt(_ bottle: String) {
        start("cmd", in: bottle) { runtime, bottle, _ in
            try runtime.wineCommand(["wineconsole", "cmd"], in: bottle)
        }
    }

    /// `cross cmd <bottle> /c <line>` with the output in the log view.
    func runCommandLine(_ line: String, in bottle: String) {
        start("cmd /c", in: bottle) { runtime, bottle, _ in
            try runtime.wineCommand(["cmd", "/c", line], in: bottle)
        }
    }

    func explorer(_ bottle: String) {
        start("explorer", in: bottle) { runtime, bottle, _ in
            try runtime.wineCommand(["explorer", "C:\\"], in: bottle)
        }
    }

    /// `cross steam`. On a fresh install (no bin/cef yet) it first runs the bootstrap
    /// launch, see `bootstrapAndLaunchSteam`. When Steam is already running in the
    /// bottle, steam.exe only forwards to that instance, so a stuck one (connection
    /// lost, or the browser processes outlived steam.exe) is detected first and the
    /// bottle page offers Restart Steam instead.
    func launchSteam(_ name: String) {
        guard let bottle = bottle(named: name) else { return }
        if Steam.isBootstrapped(in: bottle) {
            Task {
                let status = await refreshSteamStatus(name)
                if let reason = status?.stuckReason {
                    steamStuckPrompt = SteamStuckPrompt(bottle: name, reason: reason)
                } else {
                    await startSteamAgainIfItQuits(name)
                }
            }
            return
        }
        guard steamSetup.insert(name).inserted else { return }
        Task {
            defer { steamSetup.remove(name) }
            await bootstrapAndLaunchSteam(name)
        }
    }

    /// Downloads SteamSetup.exe into downloads/steam/ when it is not cached yet, runs it
    /// silently (/S), then bootstraps and launches Steam.
    func installSteam(_ name: String) {
        guard steamSetup.insert(name).inserted else { return }
        Task {
            defer { steamSetup.remove(name) }
            guard let job = startSteamInstaller(name) else { return }
            let termination = await waitForExit(job)
            reloadBottles()
            guard termination == .exited(0) else {
                if let termination { alertMessage = "Steam installer: \(termination)" }
                return
            }
            await bootstrapAndLaunchSteam(name)
        }
    }

    /// SteamSetup.exe only installs the bootstrapper. Its first launch must run without
    /// -noverifyfiles to download the client, and the webhelper shim can only be
    /// installed after that, so this launch paints black. Once Steam has started its
    /// webhelper: steam.exe -shutdown, wineserver -w, then the normal launch with the shim.
    private func bootstrapAndLaunchSteam(_ name: String) async {
        guard let bottle = bottle(named: name) else { return }
        let webhelperLog = Steam.webhelperLog(in: bottle)
        let launched = Date()
        guard let job = start("steam-bootstrap", in: name, make: { runtime, bottle, _ in
            try runtime.steamBootstrap(in: bottle)
        }) else { return }
        while job.pid == nil && job.failure == nil {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard job.failure == nil else { return }
        // The first wine process exits when the bootstrapper restarts itself after updating,
        // so wait for the files, not for the job.
        job.note("cross: waiting for Steam to download its client and start the webhelper")
        let deadline = launched.addingTimeInterval(30 * 60)
        while !(Steam.isBootstrapped(in: bottle) && Self.modified(webhelperLog, since: launched)) {
            guard Date() < deadline else {
                job.note("cross: Steam did not start its webhelper within 30 minutes")
                alertMessage = "Steam did not finish its first start in '\(name)'. Use Launch Steam to try again."
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        try? await Task.sleep(nanoseconds: 5_000_000_000)   // let the client finish starting up
        job.note("cross: client bootstrapped; restarting Steam with the webhelper shim")
        if let shutdown = start("steam-shutdown", in: name, make: { runtime, bottle, _ in
            try runtime.steamShutdown(in: bottle)
        }) {
            _ = await waitForExit(shutdown)
        }
        if let wait = start("wineserver-w", in: name, make: { runtime, bottle, _ in
            try runtime.waitForBottle(bottle)
        }) {
            _ = await waitForExit(wait)
        }
        reloadBottles()
        launchSteam(name)
    }

    private static func modified(_ url: URL, since date: Date) -> Bool {
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return modified.map { $0 >= date } ?? false
    }

    private func startSteamInstaller(_ name: String) -> Job? {
        start("steam-setup", in: name) { runtime, bottle, job in
            let setup = Steam.installerFile(in: runtime.project)
            if !FileManager.default.fileExists(atPath: setup.path) {
                job.note("cross: downloading \(Steam.installerURL.absoluteString)")
                let (tmp, response) = try await URLSession.shared.download(from: Steam.installerURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw CrossError("download failed: \(response)")
                }
                try FileManager.default.createDirectory(at: setup.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: tmp, to: setup)
            }
            return try runtime.steamInstaller(setup, in: bottle)
        }
    }

    func killBottle(_ bottle: String) {
        start("wineserver-k", in: bottle) { runtime, bottle, _ in
            try runtime.kill(bottle)
        }
    }

    // MARK: - Steam status and restart

    /// The plain `steam` job (shim, ActiveProcess reset, lock cleanup, steam.exe with the flags).
    @discardableResult
    private func startSteam(_ name: String) -> Job? {
        start("steam", in: name) { runtime, bottle, _ in
            try runtime.steam(in: bottle, arguments: [])
        }
    }

    /// The `steam` job, started again once when Steam quits within seconds of starting.
    /// After an unclean end (crash, Kill Bottle, wineserver -k) Steam logs "Looks like
    /// steam didn't shutdown cleanly, scheduling immediate update check", runs that
    /// check and exits after 2-3 s without a window; the next start works (seen on
    /// every such start on 2026-10-17). So: watch the job for 15 s, and if it ended with
    /// no steam.exe left in the bottle, start it once more.
    private func startSteamAgainIfItQuits(_ name: String) async {
        guard let job = startSteam(name) else { return }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard job.termination != nil || job.failure != nil else { continue }
            guard job.failure == nil else { return }
            let status = await refreshSteamStatus(name)
            if status?.isRunning == true { return }   // Steam re-spawned itself (bootstrapper update)
            job.note("cross: Steam quit right after starting (its check after an unclean end); starting it again")
            startSteam(name)
            return
        }
    }

    /// Re-reads `Steam.status` for a bottle off the main thread and publishes it.
    @discardableResult
    func refreshSteamStatus(_ name: String) async -> Steam.Status? {
        guard let bottle = bottle(named: name) else { return nil }
        let status = await Task.detached { Steam.status(in: bottle) }.value
        steamStatus[name] = status
        return status
    }

    /// Restart Steam: `steam.exe -shutdown` (only when a steam.exe is running: with no
    /// client to talk to, -shutdown starts the bootstrapper, which verifies the whole
    /// install for minutes), up to 20 s of `wineserver -w` for it to quit, `wineserver -k`
    /// to be sure (a stuck client or an orphaned webhelper does not react to -shutdown),
    /// a short wait for the server to go, then the normal launch. Every step is a job,
    /// so the list shows the progress.
    func restartSteam(_ name: String) {
        guard steamRestarting.insert(name).inserted else { return }
        steamStuckPrompt = nil
        Task {
            defer { steamRestarting.remove(name) }
            let before = await refreshSteamStatus(name)
            if before?.isRunning == true,
               let shutdown = start("steam-shutdown", in: name, make: { runtime, bottle, _ in
                   try runtime.steamShutdown(in: bottle)
               }) {
                if !(await waitForExit(shutdown, timeout: 15)) {
                    shutdown.note("cross: -shutdown did not return within 15 s")
                    stop(shutdown)
                    _ = await waitForExit(shutdown)
                }
            }
            if let wait = start("wineserver-w", in: name, make: { runtime, bottle, job in
                job.note("cross: waiting up to 20 s for Steam to quit")
                return try runtime.waitForBottle(bottle)
            }) {
                if !(await waitForExit(wait, timeout: 20)) {
                    wait.note("cross: Steam is still running after 20 s")
                    stop(wait)
                    _ = await waitForExit(wait)
                }
            }
            if let kill = start("wineserver-k", in: name, make: { runtime, bottle, _ in
                try runtime.kill(bottle)
            }) {
                _ = await waitForExit(kill)
            }
            // wineserver -k returns right away; let the server and its processes go.
            if let gone = start("wineserver-w", in: name, make: { runtime, bottle, job in
                job.note("cross: waiting for the bottle's processes to end")
                return try runtime.waitForBottle(bottle)
            }) {
                if !(await waitForExit(gone, timeout: 10)) {
                    gone.note("cross: still running after 10 s, launching anyway")
                    stop(gone)
                    _ = await waitForExit(gone)
                }
            }
            reloadBottles()
            if let bottle = bottle(named: name), Steam.isBootstrapped(in: bottle) {
                await startSteamAgainIfItQuits(name)
            } else {
                launchSteam(name)
            }
            await refreshSteamStatus(name)
        }
    }

    func stop(_ job: Job) {
        guard let pid = job.pid, job.isRunning else { return }
        Darwin.kill(pid, SIGTERM)
    }

    // MARK: - Storage

    /// The size a new bottle's disk image gets by default (nil: too little free space,
    /// the bottle becomes a plain folder).
    var defaultStorageGB: Int? { defaultStorageGB(at: nil) }

    /// The default for a new bottle kept in `home` (nil: the bottles folder).
    func defaultStorageGB(at home: URL?) -> Int? {
        guard let project else { return nil }
        return Runtime.defaultStorageGB(project: project, home: home)
    }

    /// Sizes the New Bottle sheet and the Change… sheet accept for `bottle` (or a new one
    /// kept in `home`): the free space of the drive the image is (or goes) on.
    func storageRange(for bottle: Bottle? = nil, home: URL? = nil) -> ClosedRange<Int> {
        guard let project else { return BottleStorage.minimumGB...BottleStorage.minimumGB }
        guard let bottle else { return Runtime.storageRange(project: project, home: home) }
        let used = storageUsage[bottle.name]?.used ?? bottle.storageUsage?.used ?? 0
        return Runtime.storageRange(project: project, currentUse: used, home: bottle.home(in: project))
    }

    /// statfs of the bottle's volume and of the disk that holds it, off the main thread.
    func refreshStorage(_ name: String) async {
        guard let bottle = bottle(named: name), let project else { return }
        let (usage, free) = await Task.detached {
            (bottle.storageUsage, DiskImage.hostFreeBytes(at: bottle.home(in: project)))
        }.value
        storageUsage[name] = usage
        hostFree[name] = free
    }

    /// Change… on the bottle page: resize an image, move a folder bottle into an image
    /// of `sizeGB`, or (nil) move an image bottle back into a folder. Refused while
    /// anything runs in the bottle; CrossCore checks again (wineserver included).
    func setStorage(_ sizeGB: Int?, for name: String) {
        guard let bottle = bottle(named: name), let project, storageWork[name] == nil else { return }
        if isBusy(name) || !Steam.bottleProcesses(in: bottle).isEmpty || bottle.hasRunningServer {
            alertMessage = "Programs are running in '\(name)'. Quit them (or use Kill Bottle) before changing its disk."
            return
        }
        storageWork[name] = "Preparing…"
        Task.detached {
            let report: @Sendable (String) -> Void = { text in
                Task { @MainActor in self.storageWork[name] = text }
            }
            do {
                let runtime = try Runtime.forBottle(bottle, project: project)
                switch (sizeGB, bottle.image) {
                case (nil, nil): break
                case (nil, _?): _ = try runtime.moveToFolder(bottle, progress: report)
                case (let gb?, nil): _ = try runtime.moveToImage(bottle, sizeGB: gb, progress: report)
                case (let gb?, _?):
                    report("Resizing to \(gb) GB…")
                    _ = try runtime.resizeStorage(bottle, to: gb)
                }
            } catch {
                await MainActor.run { self.alertMessage = "\(name): \(error)" }
            }
            await MainActor.run {
                self.storageWork[name] = nil
                self.reloadBottles()
            }
            await self.refreshStorage(name)
        }
    }

    // MARK: - Bottle management

    func setGraphics(_ graphics: Graphics, for name: String) {
        guard var bottle = bottle(named: name) else { return }
        bottle.config.graphics = graphics
        do {
            try bottle.saveConfig()
        } catch {
            alertMessage = "\(error)"
        }
        reloadBottles()
        if graphics == .d3dmetal { applyPerformance(to: bottle) }   // nvngx.dll + NGXCore for MetalFX
    }

    /// `cross bottle create`: writes cross.json, then runs wineboot --init as a job so
    /// the bottle shows up (with its log) right away.
    /// Returns the wineboot job (nil when the bottle could not be created).
    /// `storageGB`: size of the bottle's own disk image; nil makes a plain folder.
    /// `location`: a folder elsewhere (an external drive) to keep it in; nil: the bottles folder.
    @discardableResult
    func createBottle(name: String, runtime runtimeName: String? = nil, graphics: Graphics, storageGB: Int?,
                      location: URL? = nil) -> Job? {
        guard let project else { alertMessage = loadError ?? "no project"; return nil }
        let runtimeName = runtimeName ?? Runtime.preferred(in: project)
        let runtime = Runtime(project: project, name: runtimeName)
        do {
            _ = try runtime.createBottle(name: name, config: BottleConfig(runtime: runtimeName, graphics: graphics),
                                         storageGB: storageGB, location: location)
        } catch {
            alertMessage = "\(error)"
            return nil
        }
        reloadBottles()
        selection = name
        let job = start("wineboot", in: name) { runtime, bottle, _ in
            try runtime.wineboot(for: bottle)
        }
        if let job {
            // MetalFX's NGXCore registry value and RetinaMode need the initialised prefix
            Task {
                guard await waitForExit(job) == .exited(0), let bottle = bottle(named: name) else { return }
                applyPerformance(to: bottle, force: false)
            }
        }
        return job
    }

    func deleteBottle(_ name: String) {
        guard let bottle = bottle(named: name) else { return }
        guard let project else { return }
        Task.detached {
            do {
                // wineserver -k, eject the disk image (if any), remove image and prefix
                try Runtime(project: project, name: bottle.config.runtime).deleteBottle(bottle)
            } catch {
                await MainActor.run { self.alertMessage = "\(error)" }
            }
            await MainActor.run { self.reloadBottles() }
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
