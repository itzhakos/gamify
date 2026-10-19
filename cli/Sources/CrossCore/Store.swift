import Foundation

/// A game store's launcher that can be installed into a bottle and started: where its
/// official installer comes from, how it installs silently, where it ends up under C:,
/// how it is launched and which Wine workarounds it needs, and how to tell that it is
/// installed and running. Steam is listed here too, but its install and launch keep
/// their own code paths (Steam.swift, `Runtime.steam`, the app's bootstrap chain):
/// `isSteam` tells callers to use those.
public struct Store: Identifiable, Equatable {
    public enum InstallerKind: String {
        case exe    // run directly
        case msi    // msiexec /i <file>
    }

    /// Where the installer is downloaded from.
    public enum Source: Equatable {
        /// A fixed official URL (redirects are followed; the file keeps `fileName`).
        case direct(URL, fileName: String)
        /// GOG publishes the current Galaxy installer in a JSON document
        /// (`content.windows.downloadLink`); `fallback` is the build that was current
        /// when this was written, used when the document cannot be read.
        case gogRemoteConfig(URL, fallback: URL)
    }

    /// Short name used by the CLI and for downloads/<id>/ ("epic").
    public let id: String
    /// Display name ("Epic Games Store").
    public let name: String
    public let source: Source
    public let installerKind: InstallerKind
    /// Matches cached installers in downloads/<id>/ (prefix, suffix), e.g. setup_galaxy_*.exe.
    public let cachePattern: (prefix: String, suffix: String)
    /// Arguments for an unattended install: the installer's own (`/S`, `/VERYSILENT`) or,
    /// for an .msi, msiexec's (after `/i <file>`). Empty when the installer has none.
    public let installArguments: [String]
    /// The launcher, relative to drive_c with forward slashes; the first one present wins.
    public let executables: [String]
    public let launchArguments: [String]
    /// Registry values written before the install and before every launch (DLL overrides).
    public let registry: [RegistryValue]
    /// Lower-cased exe names: one of them running in the bottle means the store is running.
    public let processNames: [String]
    /// Folders (relative to drive_c) whose contents are stale locks when the store is not
    /// running; emptied before a launch, like Steam's htmlcache Singleton files.
    public let staleLockDirs: [String]
    /// How it installs and which workarounds it gets, in plain words (help text, `cross store list`).
    public let notes: String
    /// What does not work under Wine here yet, said plainly; nil when the launcher reaches
    /// its sign-in window.
    public let knownIssue: String?
    /// The installer starts a copy of itself (or a helper) and exits right away; the
    /// install is done once the launcher is installed and running (Battle.net).
    public var installerHandsOff = false

    public var isSteam: Bool { id == Store.steam.id }

    /// How long an install may take after a hands-off installer exited.
    public static let handsOffTimeout: TimeInterval = 20 * 60

    public static func == (a: Store, b: Store) -> Bool { a.id == b.id }

    /// A REG_SZ value; an empty `data` is how Wine spells "disabled" for a DLL override.
    public struct RegistryValue: Equatable {
        public var key: String
        public var name: String
        public var data: String

        public init(key: String, name: String, data: String) {
            self.key = key
            self.name = name
            self.data = data
        }

        /// HKCU\Software\Wine\DllOverrides\<name> = <data>.
        public static func dllOverride(_ name: String, _ data: String) -> RegistryValue {
            RegistryValue(key: "HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides", name: name, data: data)
        }
    }
}

extension Store {
    public static let steam = Store(
        id: "steam",
        name: "Steam",
        source: .direct(Steam.installerURL, fileName: "SteamSetup.exe"),
        installerKind: .exe,
        cachePattern: ("SteamSetup", ".exe"),
        installArguments: ["/S"],
        executables: ["Program Files (x86)/Steam/steam.exe"],
        launchArguments: Runtime.steamFlags,
        registry: [],
        processNames: ["steam.exe"],
        staleLockDirs: [],
        notes: "NSIS installer (/S) that only installs the bootstrapper; the first start downloads the client (~1.7 GB). Needs the webhelper shim (src/webhelper-shim) and -noverifyfiles -no-cef-sandbox.",
        knownIssue: nil)

    /// Epic's MSI (~250 MB) installs the whole launcher; it updates itself on start.
    public static let epic = Store(
        id: "epic",
        name: "Epic Games Store",
        source: .direct(URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi")!,
                        fileName: "EpicGamesLauncherInstaller.msi"),
        installerKind: .msi,
        cachePattern: ("EpicGamesLauncherInstaller", ".msi"),
        installArguments: ["/passive", "/norestart"],
        // the MSI installs the 64-bit launcher under Program Files in a win64 bottle
        executables: ["Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe",
                      "Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe",
                      "Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win32/EpicGamesLauncher.exe"],
        launchArguments: ["-SkipBuildPatchPrereq"],
        registry: [],
        processNames: ["epicgameslauncher.exe"],
        staleLockDirs: [],
        notes: "MSI installed with msiexec /i … /passive; launched with -SkipBuildPatchPrereq. Updates itself on the first start and restarts.",
        knownIssue: nil)

    /// GOG Galaxy 2: an Inno Setup installer (~330 MB) with the whole client.
    public static let gog = Store(
        id: "gog",
        name: "GOG Galaxy",
        source: .gogRemoteConfig(URL(string: "https://remote-config.gog.com/components/webinstaller?component_version=2.0.0")!,
                                 fallback: URL(string: "https://content-system.gog.com/open_link/download?path=/open/galaxy/client/setup_galaxy_2.1.10.56.exe")!),
        installerKind: .exe,
        cachePattern: ("setup_galaxy_", ".exe"),
        installArguments: ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
        executables: ["Program Files/GOG Galaxy/GalaxyClient.exe",
                      "Program Files (x86)/GOG Galaxy/GalaxyClient.exe"],
        launchArguments: [],
        // CrossOver 25's GOG Galaxy profile disables the overlay process.
        registry: [.dllOverride("GalaxyOverlay.exe", "")],
        processNames: ["galaxyclient.exe"],
        // after an unclean end the next start finds its own lock, "detects a second
        // instance" and quits
        staleLockDirs: ["ProgramData/GOG.com/Galaxy/lock-files"],
        notes: "Inno Setup installer (/VERYSILENT). GalaxyOverlay.exe is disabled, as CrossOver does; stale lock files are cleared before a launch.",
        knownIssue: "The sign-in window opens but stays blank: Galaxy's Qt WebEngine view is not drawn under Wine here.")

    /// Battle.net-Setup.exe is a ~5 MB bootstrapper that downloads the app itself.
    public static let battlenet = Store(
        id: "battlenet",
        name: "Battle.net",
        source: .direct(URL(string: "https://downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe")!,
                        fileName: "Battle.net-Setup.exe"),
        installerKind: .exe,
        cachePattern: ("Battle.net-Setup", ".exe"),
        installArguments: ["--lang=enUS", "--installpath=C:\\Program Files (x86)\\Battle.net"],
        executables: ["Program Files (x86)/Battle.net/Battle.net Launcher.exe",
                      "Program Files (x86)/Battle.net/Battle.net.exe"],
        launchArguments: [],
        // CrossOver 25's Battle.net profile disables systemsurvey.exe (crashed Wine).
        registry: [.dllOverride("systemsurvey.exe", "")],
        processNames: ["battle.net.exe", "battle.net launcher.exe"],
        staleLockDirs: [],
        notes: "Bootstrapper that downloads and starts the app by itself (no clicks needed). systemsurvey.exe is disabled, as CrossOver does.",
        knownIssue: "The Battle.net Login window opens but only shows its spinner: the 32-bit app's browser finds no working graphics path under Wine here (needs DXVK).",
        installerHandsOff: true)

    /// Every store, Steam first.
    public static let all: [Store] = [.steam, .epic, .gog, .battlenet]

    /// By id ("epic"), or by name ignoring case and spaces ("Battle.net", "gog galaxy").
    public static func named(_ text: String) -> Store? {
        let key = text.lowercased().filter { !$0.isWhitespace && $0 != "." && $0 != "-" }
        return all.first { store in
            store.id == key || store.name.lowercased().filter { !$0.isWhitespace && $0 != "." && $0 != "-" } == key
        }
    }

    // MARK: - Installer

    public func downloadDir(in project: Project) -> URL {
        project.downloads.appendingPathComponent(id)
    }

    /// The newest cached installer in downloads/<id>/, if any.
    public func cachedInstaller(in project: Project) -> URL? {
        let dir = downloadDir(in: project)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let matches = names.filter { $0.hasPrefix(cachePattern.prefix) && $0.lowercased().hasSuffix(cachePattern.suffix) }
            .map { dir.appendingPathComponent($0) }
        return matches.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    /// The official URL and the file name to keep it under. For GOG this reads the
    /// current version from GOG's remote config.
    public func resolveDownload() async -> (url: URL, fileName: String) {
        switch source {
        case let .direct(url, fileName):
            return (url, fileName)
        case let .gogRemoteConfig(config, fallback):
            if let (data, response) = try? await URLSession.shared.data(from: config),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = json["content"] as? [String: Any],
               let windows = content["windows"] as? [String: Any],
               let link = windows["downloadLink"] as? String,
               let url = URL(string: link) {
                return (url, Store.gogFileName(url) ?? "setup_galaxy.exe")
            }
            return (fallback, Store.gogFileName(fallback) ?? "setup_galaxy.exe")
        }
    }

    /// setup_galaxy_2.1.10.56.exe from `…/open_link/download?path=/open/galaxy/client/setup_galaxy_2.1.10.56.exe`.
    static func gogFileName(_ url: URL) -> String? {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value ?? url.path
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("setup_galaxy") && name.lowercased().hasSuffix(".exe") ? name : nil
    }

    /// The cached installer, or downloads it into downloads/<id>/ first (via a .part
    /// file, so an interrupted download is never mistaken for an installer).
    public func installer(in project: Project, say: (String) -> Void = { _ in }) async throws -> URL {
        if let cached = cachedInstaller(in: project) {
            say("using the cached installer \(cached.path)")
            return cached
        }
        let (url, fileName) = await resolveDownload()
        say("downloading \(url.absoluteString)")
        let started = Date()
        let (tmp, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw CrossError("download of \(url.absoluteString) failed: \((response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? "\(response)")")
        }
        let dir = downloadDir(in: project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let part = dir.appendingPathComponent(fileName + ".part")
        let file = dir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: part)
        try FileManager.default.moveItem(at: tmp, to: part)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: part, to: file)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        say(String(format: "downloaded %@ (%.1f MB in %.0f s)", file.lastPathComponent,
                   Double(size) / 1_000_000, Date().timeIntervalSince(started)))
        return file
    }

    // MARK: - Installed / running

    /// The launcher exe in the bottle, nil when the store is not installed.
    public func executable(in bottle: Bottle) -> URL? {
        executables.map { bottle.driveC.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func isInstalled(in bottle: Bottle) -> Bool {
        isSteam ? Steam.isInstalled(in: bottle) : executable(in: bottle) != nil
    }

    /// Empties `staleLockDirs` when none of the store's processes runs in the bottle.
    public func clearStaleLocks(in bottle: Bottle) {
        guard !staleLockDirs.isEmpty, !isRunning(in: bottle) else { return }
        let fm = FileManager.default
        for dir in staleLockDirs.map({ bottle.driveC.appendingPathComponent($0) }) {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    /// This store's processes among a bottle's processes (`Steam.bottleProcesses`).
    public func running(in processes: [Steam.BottleProcess]) -> [Steam.BottleProcess] {
        processes.filter { p in
            guard processNames.contains(p.program) else { return false }
            // `steam.exe -shutdown` is a request to quit, not Steam running
            return !(isSteam && p.arguments.dropFirst().contains { $0.lowercased() == "-shutdown" })
        }
    }

    public func isRunning(in bottle: Bottle) -> Bool {
        !running(in: Steam.bottleProcesses(in: bottle)).isEmpty
    }
}

extension Runtime {
    /// Writes registry values into the bottle (REGEDIT4 file imported with regedit,
    /// like `Steam.resetActiveProcess`). Blocks until regedit is done.
    public func applyRegistry(_ values: [Store.RegistryValue], in bottle: Bottle,
                              base: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard !values.isEmpty else { return }
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var reg = "REGEDIT4\n"
        for key in values.map(\.key).uniqued() {
            reg += "\n[\(key)]\n"
            for value in values where value.key == key {
                reg += "\(quoted(value.name))=\(quoted(value.data))\n"
            }
        }
        let file = bottle.prefix.appendingPathComponent(".cross-registry.reg")
        try reg.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let status = try runWaiting(program: wine.path, arguments: ["regedit", file.path],
                                    environment: try environment(for: bottle, base: base), quiet: true)
        if status != 0 { warn("regedit exited with \(status) while writing \(values.map(\.name).joined(separator: ", "))") }
    }

    /// Any installer: an .msi through `msiexec /i`, anything else run directly, with
    /// cwd = the installer's directory (as `cross run`).
    public func installer(_ file: URL, arguments: [String], in bottle: Bottle,
                          base: [String: String] = ProcessInfo.processInfo.environment) throws -> Invocation {
        let file = file.standardizedFileURL
        guard file.pathExtension.lowercased() == "msi" else {
            return try runExe(file, arguments: arguments, in: bottle, base: base)
        }
        return Invocation(program: wine.path, arguments: ["msiexec", "/i", file.lastPathComponent] + arguments,
                          environment: try environment(for: bottle, base: base),
                          cwd: file.deletingLastPathComponent().path)
    }

    /// A store's unattended installer, after its registry workarounds. Not for Steam
    /// (`steamInstaller`, which the app chains with the client bootstrap).
    public func storeInstaller(_ store: Store, installer file: URL, in bottle: Bottle,
                               base: [String: String] = ProcessInfo.processInfo.environment) throws -> Invocation {
        try applyRegistry(store.registry, in: bottle, base: base)
        return try installer(file, arguments: store.installArguments, in: bottle, base: base)
    }

    /// `cross store launch`: Steam goes through `steam(in:)` (shim, flags, lock cleanup);
    /// the others get their registry workarounds again (cheap, and a bottle installed
    /// by hand gets them too), then their exe with cwd = its directory.
    public func storeLaunch(_ store: Store, in bottle: Bottle, arguments: [String] = [],
                            base: [String: String] = ProcessInfo.processInfo.environment) throws -> Invocation {
        if store.isSteam { return try steam(in: bottle, arguments: arguments, base: base) }
        guard let exe = store.executable(in: bottle) else {
            throw CrossError("\(store.name) is not installed in '\(bottle.name)'")
        }
        try applyRegistry(store.registry, in: bottle, base: base)
        store.clearStaleLocks(in: bottle)
        return try runExe(exe, arguments: store.launchArguments + arguments, in: bottle, base: base)
    }
}

extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Waiting installs (CLI)

/// ~/Library/Logs/Gamify/<bottle>/<yyyyMMdd-HHmmss>-<label>.log, the layout the app uses
/// for its jobs, so `cross store install` / `cross install` logs sit next to them.
public func newJobLog(bottle: String, label: String) -> URL {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Gamify/\(bottle)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    let url = dir.appendingPathComponent("\(f.string(from: Date()))-\(label.replacingOccurrences(of: " ", with: "-")).log")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    return url
}

private final class TerminationBox: @unchecked Sendable {
    var value: Termination?
}

/// Starts `invocation` with its output in `log` and returns when it has ended, or
/// earlier when `done()` (polled every 2 s) says the work is finished, e.g. an
/// installer that starts the launcher it installed and stays around with it.
@discardableResult
public func runLogged(_ invocation: Invocation, log: URL, done: (() -> Bool)? = nil) throws -> Termination? {
    let box = TerminationBox()
    let finished = DispatchSemaphore(value: 0)
    try spawnDetached(invocation, output: log) { termination in
        box.value = termination
        finished.signal()
    }
    while finished.wait(timeout: .now() + 2) == .timedOut {
        if done?() == true { return nil }
    }
    return box.value
}

/// Runs an async CrossCore call (downloads) from synchronous CLI code.
private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

public func blockingAwait<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let finished = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
        finished.signal()
    }
    finished.wait()
    return try box.result!.get()
}

extension Runtime {
    /// The CLI's version of the app's first Steam start (AppModel.bootstrapAndLaunchSteam):
    /// steam.exe without -noverifyfiles downloads the client, then once its webhelper has
    /// started, steam.exe -shutdown and wineserver -w. The next `cross steam` (or
    /// `cross store launch <bottle> steam`) starts it with the shim.
    public func bootstrapSteamWaiting(in bottle: Bottle, log: URL, timeout: TimeInterval = 30 * 60,
                                      say: (String) -> Void) throws {
        let launched = Date()
        try spawnDetached(try steamBootstrap(in: bottle), output: log)
        say("first start: Steam downloads its client (~1.7 GB) and restarts itself; its window stays black meanwhile")
        let webhelperLog = Steam.webhelperLog(in: bottle)
        func modifiedSinceLaunch() -> Bool {
            let date = try? webhelperLog.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return date.map { $0 >= launched } ?? false
        }
        while !(Steam.isBootstrapped(in: bottle) && modifiedSinceLaunch()) {
            guard Date().timeIntervalSince(launched) < timeout else {
                throw CrossError("Steam did not start its webhelper within \(Int(timeout / 60)) minutes (log: \(log.path))")
            }
            Thread.sleep(forTimeInterval: 2)
        }
        Thread.sleep(forTimeInterval: 5)   // let the client finish starting up
        say("client bootstrapped; stopping Steam so the next launch uses the webhelper shim")
        _ = try runLogged(try steamShutdown(in: bottle), log: log)
        _ = try runLogged(try waitForBottle(bottle), log: log)
    }
}
