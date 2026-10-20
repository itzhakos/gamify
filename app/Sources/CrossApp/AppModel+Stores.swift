import AppKit
import CrossCore
import Foundation

/// An installer opened with the app (or dropped on a bottle page): the bottle page asks
/// whether to install it (Install a Program) or just run it.
struct InstallPrompt: Identifiable, Equatable {
    let id = UUID()
    let bottle: String
    let files: [URL]
}

/// Stores (Epic, GOG Galaxy, Battle.net beside Steam) and the Programs list. Steam keeps
/// its own actions in AppModel.swift (installSteam, launchSteam, restartSteam); everything
/// here asks CrossCore (Store.swift, Programs.swift) for the work and runs it as jobs.
extension AppModel {
    // MARK: - Stores

    func isInstallingStore(_ store: Store, in bottle: String) -> Bool {
        store.isSteam ? steamSetup.contains(bottle) : storeInstalls.contains("\(bottle)/\(store.id)")
    }

    /// Which stores run in the bottle (one libproc scan, by exe name) and its programs.
    func refreshStoresAndPrograms(_ name: String) async {
        guard let bottle = bottle(named: name), isDrivable(bottle) else { return }
        let (running, list) = await Task.detached { () -> (Set<String>, [Program]) in
            let processes = Steam.bottleProcesses(in: bottle)
            let running = Set(Store.all.filter { !$0.running(in: processes).isEmpty }.map(\.id))
            return (running, Programs.list(in: bottle))
        }.value
        if storesRunning[name] != running { storesRunning[name] = running }
        if programs[name] != list { programs[name] = list }
    }

    /// Install… on a store row: download the official installer into downloads/<id>/ (once),
    /// apply the store's registry workarounds, run it unattended as the `<id>-setup` job.
    /// A hands-off installer (Battle.net) exits at once and finishes from a copy of
    /// itself, so for it the install is done once the launcher is installed and running.
    /// Others are done when their installer exits (GOG's starts Galaxy for a moment,
    /// which then quits). A finished install whose launcher is not running is launched.
    /// Steam: `installSteam`.
    func installStore(_ store: Store, in name: String) {
        if store.isSteam { installSteam(name); return }
        let key = "\(name)/\(store.id)"
        guard !storeInstalls.contains(key) else { return }
        storeInstalls.insert(key)
        Task {
            defer { storeInstalls.remove(key) }
            let started = Date()
            guard let job = start("\(store.id)-setup", in: name, make: { runtime, bottle, job in
                let file = try await store.installer(in: runtime.project) { job.note("cross: \($0)") }
                return try runtime.storeInstaller(store, installer: file, in: bottle)
            }) else { return }
            // A hands-off installer (Battle.net) exits at once and installs from a copy
            // of itself, so its job ending is not the end of the install.
            var handOffNoted = false
            while job.failure == nil {
                if job.termination != nil {
                    guard store.installerHandsOff, Date().timeIntervalSince(started) < Store.handsOffTimeout else { break }
                    if !handOffNoted {
                        job.note("cross: the installer continues in its own window; waiting for \(store.name) to start")
                        handOffNoted = true
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if job.termination != nil && !store.installerHandsOff { break }
                if store.installerHandsOff, let bottle = bottle(named: name), store.isInstalled(in: bottle),
                   await Task.detached(operation: { store.isRunning(in: bottle) }).value {
                    job.note("cross: \(store.name) is installed and running")
                    break
                }
            }
            guard job.failure == nil else { return }
            reloadBottles()
            guard let bottle = bottle(named: name), store.isInstalled(in: bottle) else {
                alertMessage = "\(store.name) was not installed in '\(name)' (installer: \(job.termination?.description ?? "?")). See the \(store.id)-setup log."
                return
            }
            job.note(String(format: "cross: %@ installed in %.0f s", store.name, Date().timeIntervalSince(started)))
            await refreshStoresAndPrograms(name)
            if storesRunning[name]?.contains(store.id) != true { launchStore(store, in: name) }
        }
    }

    /// Launch on a store row: Steam through `launchSteam` (stuck check, bootstrap, shim),
    /// the others through `Runtime.storeLaunch` (workarounds, stale locks, exe + arguments).
    func launchStore(_ store: Store, in name: String) {
        if store.isSteam { launchSteam(name); return }
        start(store.id, in: name) { runtime, bottle, _ in
            try runtime.storeLaunch(store, in: bottle)
        }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await refreshStoresAndPrograms(name)
        }
    }

    // MARK: - Programs

    /// An .msi, or an .exe whose name says setup/install (setup.exe, npp.8.6.Installer.x64.exe).
    static func looksLikeInstaller(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "msi" { return true }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return ext == "exe" && (name.contains("setup") || name.contains("install"))
    }

    /// Install a Program…: runs an installer in the bottle (.exe directly, .msi through
    /// msiexec /i) as a job with its log; afterwards the Programs list picks up the
    /// shortcuts it created, or the windowed exes it added under Program Files when it
    /// created none (`Programs.recordInstall`).
    func installProgram(_ file: URL, arguments: [String] = [], in name: String) {
        final class SnapshotBox: @unchecked Sendable { var value: Programs.Snapshot? }
        let box = SnapshotBox()
        guard let job = start("install \(file.deletingPathExtension().lastPathComponent)", in: name, make: { runtime, bottle, _ in
            box.value = Programs.snapshot(of: bottle)
            return try runtime.installer(file, arguments: arguments, in: bottle)
        }) else { return }
        Task {
            _ = await waitForExit(job)
            guard job.failure == nil, let before = box.value, let bottle = bottle(named: name) else { return }
            let added = await Task.detached { Programs.recordInstall(since: before, in: bottle) }.value
            if added.isEmpty {
                job.note("cross: no new programs found (no new shortcut, no new program under Program Files); use Add a Program… to add its exe")
            } else {
                job.note("cross: new programs: " + added.map { "\($0.name) (\($0.exe))" }.joined(separator: ", "))
            }
            await refreshStoresAndPrograms(name)
        }
    }

    /// Add a Program…: an exe inside the bottle's C: drive, with optional arguments.
    func addProgram(_ exe: URL, name programName: String? = nil, arguments: String = "", in name: String) {
        guard let bottle = bottle(named: name) else { return }
        let drive = bottle.driveC.resolvingSymlinksInPath().standardizedFileURL.path.lowercased() + "/"
        guard exe.resolvingSymlinksInPath().standardizedFileURL.path.lowercased().hasPrefix(drive) else {
            alertMessage = "Pick a program inside the C: drive of '\(name)'. To use one from elsewhere, install it into the bottle first (Install a Program…) or use Run .exe…."
            return
        }
        let program = Program(name: programName ?? exe.deletingPathExtension().lastPathComponent,
                              exe: Programs.windowsPath(of: exe, in: bottle), arguments: arguments, source: .manual)
        do {
            try Programs.add(program, to: bottle)
        } catch {
            alertMessage = "\(error)"
        }
        Task { await refreshStoresAndPrograms(name) }
    }

    func removeProgram(_ program: Program, in name: String) {
        guard let bottle = bottle(named: name) else { return }
        do {
            try Programs.remove(program, from: bottle)
        } catch {
            alertMessage = "\(error)"
        }
        Task { await refreshStoresAndPrograms(name) }
    }

    /// Launch on a Programs row: the same path as Run .exe (cwd = the exe's directory;
    /// a Steam game's exe without arguments goes through Steam).
    func launchProgram(_ program: Program, in name: String) {
        guard let bottle = bottle(named: name) else { return }
        guard let exe = Programs.unixURL(of: program.exe, in: bottle), FileManager.default.fileExists(atPath: exe.path) else {
            alertMessage = "\(program.exe) is no longer in '\(name)'. Remove it from the list, or reinstall it."
            return
        }
        start(program.name, in: name) { runtime, bottle, job in
            let (inv, steamGame) = try runtime.programLaunch(exe, arguments: program.argumentList, in: bottle)
            if let steamGame { job.note("cross: \(steamGame.name) is a Steam game; starting it through Steam (\(steamGame.runURL))") }
            return inv
        }
    }
}
