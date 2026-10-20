import Foundation

/// `cross steam check` and the app's Check Steam…: is the client running and signed in,
/// does a game started in this bottle get the account's licences from it (asked through
/// src/steam-probe, a tiny Windows program that loads a game's steam_api64.dll and calls
/// the same API a game calls), and what licence each installed game has.
extension Project {
    public var steamProbeDir: URL { root.appendingPathComponent("src/steam-probe") }
    /// src/steam-probe/steam-probe.exe in the checkout (`make` builds it). A packaged app
    /// keeps it in Contents/Resources, the app layer, so shipping it is an app-only update
    /// (root/src counts towards runtime-version, which forces the full DMG).
    public var steamProbe: URL {
        bundled ? root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/steam-probe.exe")
                : steamProbeDir.appendingPathComponent("steam-probe.exe")
    }
}

extension Steam {
    /// Spacewar, Valve's Steamworks example: every account owns it, so the probe can
    /// start a Steam session as this app without touching a real game's state.
    public static let probeAppID = 480

    /// Where the probe runs inside the bottle: C:\ProgramData\Gamify\steam-probe.
    public static func probeDir(in bottle: Bottle) -> URL {
        bottle.driveC.appendingPathComponent("ProgramData/Gamify/steam-probe")
    }

    /// A 64-bit steam_api64.dll from an installed game (the Steam client ships none).
    /// The newest one wins: it speaks the current flat API; the probe handles old ones too.
    public static func steamAPIDLL(in bottle: Bottle) -> URL? {
        let fm = FileManager.default
        var found: [(URL, Date)] = []
        for app in installedApps(in: bottle) {
            guard let walker = fm.enumerator(at: app.folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                if walker.level > 6 { walker.skipDescendants(); continue }
                if url.lastPathComponent.lowercased() == "steam_api64.dll" {
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    found.append((url, date))
                }
            }
        }
        return found.max { $0.1 < $1.1 }?.0
    }

    // MARK: - Probe output

    /// What the probe printed, parsed.
    public struct ProbeResult: Equatable {
        public struct App: Equatable {
            public var subscribed: Bool
            public var installed: Bool
            /// GetEarliestPurchaseUnixTime: when the licence was added (also for free ones), nil = none.
            public var purchased: Date?
        }

        public var lines: [String]
        /// "ok", "fixed pid=0 -> 216", "wrong pid=…", "pid=…, no steam.exe running"
        public var activeProcess: String?
        /// SteamAPI_IsSteamRunning (only old and new SDK dlls that export it).
        public var steamRunning: Bool?
        public var initOK: Bool
        public var loggedOn: Bool?
        public var appID: Int?
        public var apps: [Int: App] = [:]
        public var error: String?

        public var repairedActiveProcess: Bool { activeProcess?.hasPrefix("fixed") == true }

        public init(output: String) {
            lines = output.split(whereSeparator: \.isNewline).map(String.init)
            initOK = false
            for line in lines {
                if line.hasPrefix("app "), let parsed = ProbeResult.app(line) {
                    apps[parsed.0] = parsed.1
                    continue
                }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon])
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "active process": activeProcess = value
                case "steam running": steamRunning = value == "1"
                case "init": initOK = value == "ok"
                case "logged on": loggedOn = value == "1"
                case "appid": appID = Int(value)
                case "error", "init error": error = value
                default: break
                }
            }
        }

        static func app(_ line: String) -> (Int, App)? {
            let words = line.split(separator: " ")
            guard words.count >= 2, let id = Int(words[1]) else { return nil }
            var fields: [String: String] = [:]
            for w in words.dropFirst(2) {
                let kv = w.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
            }
            let purchased = fields["purchased"].flatMap { TimeInterval($0) }.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            return (id, App(subscribed: fields["subscribed"] == "1", installed: fields["installed"] == "1", purchased: purchased))
        }
    }
}

extension Runtime {
    /// Copies the probe, a game's steam_api64.dll and steam_appid.txt (480) into
    /// C:\ProgramData\Gamify\steam-probe and returns its launch. `fix` lets the probe
    /// repair a stale ActiveProcess pid. nil when no installed game has a steam_api64.dll.
    public func steamProbe(in bottle: Bottle, appIDs: [Int], fix: Bool = true) throws -> Invocation? {
        let fm = FileManager.default
        let probe = project.steamProbe
        if !fm.fileExists(atPath: probe.path) {
            guard !project.bundled else { throw CrossError("\(probe.path) is missing from the app") }
            warn("building the Steam probe (make -C src/steam-probe)")
            let status = try runWaiting(program: "/usr/bin/make", arguments: ["-C", project.steamProbeDir.path],
                                        environment: ProcessInfo.processInfo.environment)
            guard status == 0, fm.fileExists(atPath: probe.path) else { throw CrossError("could not build \(probe.path)") }
        }
        guard let dll = Steam.steamAPIDLL(in: bottle) else { return nil }
        let dir = Steam.probeDir(in: bottle)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (source, name) in [(probe, "steam-probe.exe"), (dll, "steam_api64.dll")] {
            let target = dir.appendingPathComponent(name)
            if (try? Data(contentsOf: target)) != (try? Data(contentsOf: source)) {
                try? fm.removeItem(at: target)
                try fm.copyItem(at: source, to: target)
            }
        }
        try "\(Steam.probeAppID)".write(to: dir.appendingPathComponent("steam_appid.txt"), atomically: true, encoding: .utf8)
        let ids = ([Steam.probeAppID] + appIDs).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        return try runExe(dir.appendingPathComponent("steam-probe.exe"),
                          arguments: (fix ? ["--fix"] : []) + ids.map(String.init), in: bottle)
    }

    /// Runs an invocation to completion (at most `timeout` seconds) and returns its exit
    /// code and stdout. Output goes through a file, not a pipe: Wine helpers that outlive
    /// the program must not keep the reader waiting.
    public func runCapturing(_ invocation: Invocation, timeout: TimeInterval = 60) throws -> (Int32, String) {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("cross-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: out) }
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: invocation.program)
        p.arguments = invocation.arguments
        p.environment = invocation.environment
        if let cwd = invocation.cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        p.standardOutput = handle
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning {
            p.terminate()
            p.waitUntilExit()
            throw CrossError("\(URL(fileURLWithPath: invocation.arguments.first ?? invocation.program).lastPathComponent) did not finish within \(Int(timeout)) s")
        }
        return (p.terminationStatus, String(decoding: (try? Data(contentsOf: out)) ?? Data(), as: UTF8.self))
    }

    /// How a program of the bottle is started. An exe inside a Steam library's
    /// steamapps/common/<game> (with no extra arguments) is started through Steam
    /// (`steam.exe steam://rungameid/<appid>`), like the library's Play button: Steam
    /// then runs its launch steps (cloud saves, install scripts, overlay, playtime) and
    /// hands the game its app id. Steam's own steam.exe gets the launch of `steam(in:)`
    /// (its flags keep the webhelper shim). Everything else runs directly (`runExe`).
    public func programLaunch(_ exe: URL, arguments: [String], in bottle: Bottle,
                              base: [String: String] = ProcessInfo.processInfo.environment) throws -> (Invocation, Steam.InstalledApp?) {
        if DiskImage.realPath(exe).lowercased() == DiskImage.realPath(bottle.steamDir.appendingPathComponent("steam.exe")).lowercased() {
            return (try steam(in: bottle, arguments: arguments, base: base), nil)
        }
        if arguments.isEmpty, Steam.isBootstrapped(in: bottle), let app = Steam.installedApp(containing: exe, in: bottle) {
            return (try steam(in: bottle, arguments: [app.runURL], base: base), app)
        }
        return (try runExe(exe, arguments: arguments, in: bottle, base: base), nil)
    }
}

extension Steam {
    // MARK: - The check

    public struct CheckItem: Equatable, Identifiable {
        public enum Level: String { case ok, info, warning, problem }
        public var title: String
        public var detail: String
        public var level: Level
        public var id: String { title + "\u{0}" + detail }

        public init(_ level: Level, _ title: String, _ detail: String) {
            self.level = level
            self.title = title
            self.detail = detail
        }
    }

    public struct AppCheck: Equatable, Identifiable {
        public var app: InstalledApp
        public var item: CheckItem
        public var id: Int { app.appID }
    }

    public struct Check: Equatable {
        public var bottle: String
        public var checked: Date
        public var client: [CheckItem]
        public var apps: [AppCheck]
        public var launchAdvice: String
        public var probe: ProbeResult?

        /// The whole report as plain text (the CLI prints it, the app offers to copy it).
        public var text: String {
            func mark(_ level: CheckItem.Level) -> String {
                switch level {
                case .ok: return "ok  "
                case .info: return "    "
                case .warning: return "!   "
                case .problem: return "!!  "
                }
            }
            var lines = ["Steam in '\(bottle)' (checked \(Status.timeText(checked)))"]
            for item in client { lines.append("  \(mark(item.level))\(item.title): \(item.detail)") }
            lines.append("Installed games and their licences")
            if apps.isEmpty { lines.append("      none installed") }
            for a in apps { lines.append("  \(mark(a.item.level))\(a.item.title): \(a.item.detail)") }
            lines.append("How to launch")
            lines.append("      " + launchAdvice)
            return lines.joined(separator: "\n")
        }
    }

    /// Runs the check (blocks: the probe takes ~1-2 s while Steam runs). Never touches the
    /// account; the only change it may make is the ActiveProcess pid repair (`fix`).
    public static func check(in bottle: Bottle, runtime: Runtime, fix: Bool = true) -> Check {
        let status = status(in: bottle)
        let processes = bottleProcesses(in: bottle)
        let apps = installedApps(in: bottle)
        let licences = licenses(in: bottle).filter(\.isUsable)
        var client: [CheckItem] = []

        // Client and account
        guard status.installed else {
            return Check(bottle: bottle.name, checked: status.checked,
                         client: [CheckItem(.problem, "Steam", "not installed in this bottle")], apps: [],
                         launchAdvice: "Install Steam first (Stores, or `cross store install \(bottle.name) steam`).", probe: nil)
        }
        let account = currentAccount(in: bottle, connection: status.connection)
        let who = account.map { "signed in as \($0.accountName)" + ($0.personaName.isEmpty || $0.personaName == $0.accountName ? "" : " (\($0.personaName))") }
        if status.isRunning {
            let since = status.processes.steamStarted.map { " since \(Status.timeText($0))" } ?? ""
            switch status.connection?.state {
            case .loggedOn?:
                client.append(CheckItem(.ok, "Client", "running\(since), \(who ?? "signed in"), online"))
            case .connecting?:
                client.append(CheckItem(.info, "Client", "running\(since), connecting to Steam (\(who ?? "not signed in yet"))"))
            case .loggedOff(let state)?:
                let signedOut = status.connection?.isSignedOut == true
                client.append(CheckItem(.warning, "Client", signedOut
                    ? "running\(since), at the sign-in window: sign in to Steam so games can check their licences"
                    : "running\(since), \(state.lowercased()) (offline)\(status.connection?.reason.map { ": \($0)" } ?? ""). Games only see the licences Steam cached; Restart Steam reconnects."))
            case nil:
                client.append(CheckItem(.info, "Client", "running\(since), no connection state logged yet"))
            }
        } else {
            client.append(CheckItem(.info, "Client", "not running" + (who.map { "; last \($0)" } ?? "")
                                    + ". Launch Steam and check again for Steam's own answer."))
        }
        if let stuck = status.stuckReason { client.append(CheckItem(.problem, "Stuck", stuck + " Restart Steam fixes it.")) }
        if account?.wantsOfflineMode == true {
            client.append(CheckItem(.warning, "Offline mode", "this account is set to start Steam in offline mode (Steam > Go Online turns it off)"))
        }

        // Steam Client Service
        let serviceRunning = processes.contains { $0.program == "steamservice.exe" }
        let registered = serviceRegistered(in: bottle)
        client.append(CheckItem(serviceRunning ? .ok : .info, "Steam Client Service",
            (serviceRunning ? "running" : registered ? "installed, not running (Steam starts it when it needs it)" : "not installed (Steam installs it on its first start)")
            + ". It installs game prerequisites and helps some anti-cheat; licences do not go through it."))

        // Steam's live answer, through the probe
        var probe: ProbeResult?
        if status.isRunning {
            do {
                if let inv = try runtime.steamProbe(in: bottle, appIDs: apps.map(\.appID), fix: fix) {
                    let (code, output) = try runtime.runCapturing(inv)
                    let result = ProbeResult(output: output)
                    probe = result
                    if result.initOK {
                        let logged = result.loggedOn == true ? "signed in" : "not signed in"
                        client.append(CheckItem(result.loggedOn == true ? .ok : .warning, "Game check",
                            "a test program (Spacewar, app \(probeAppID)) asked Steam what a game asks: \(logged), licences answered"))
                    } else {
                        client.append(CheckItem(.problem, "Game check", "a test program could not start a Steam session (exit \(code)\(result.error.map { ": \($0)" } ?? "")); games would not see Steam either. Restart Steam and check again."))
                    }
                    if result.repairedActiveProcess {
                        client.append(CheckItem(.warning, "Repaired", "Steam's \"running\" marker in the registry (ActiveProcess pid) did not point at steam.exe, so games built with older Steam SDKs would have started without Steam (trial or demo mode, or \"Steam must be running\"). Fixed; restart such a game."))
                    } else if let ap = result.activeProcess, ap.hasPrefix("wrong") {
                        client.append(CheckItem(.problem, "Running marker", "ActiveProcess \(ap): older games will not find Steam. Restart Steam fixes it."))
                    }
                } else {
                    client.append(CheckItem(.info, "Game check", "skipped: no installed game has a steam_api64.dll to test with; showing Steam's cached licences"))
                }
            } catch {
                client.append(CheckItem(.warning, "Game check", "could not run the test program: \(error)"))
            }
        }

        // Per game
        let appChecks = apps.map { app -> AppCheck in
            let packages = licences.filter { $0.appIDs.contains(app.appID) && $0.packageID != 0 }
            let kinds = Set(packages.map(\.kind))
            let live = probe?.initOK == true ? probe?.apps[app.appID] : nil
            let title = "\(app.name) (\(app.appID))" + (app.isFullyInstalled ? "" : " [not fully installed]")
            let added = live?.purchased.map { ", licence added \(dateText($0))" } ?? ""
            if app.appID == 228980 {   // Steamworks Common Redistributables: free for everyone, no package of its own
                return AppCheck(app: app, item: CheckItem(.ok, title, "Steam's shared game prerequisites (no licence needed)"))
            }
            if live?.subscribed == false {
                return AppCheck(app: app, item: CheckItem(.problem, title, "Steam says this account has no licence for it: it runs as a demo or not at all until it is bought (or the account that owns it signs in)."))
            }
            if kinds.contains(.purchased) {
                return AppCheck(app: app, item: CheckItem(.ok, title, "owned (bought)\(added)"))
            }
            if kinds.contains(.friendsPass) {
                return AppCheck(app: app, item: CheckItem(.warning, title, "only the free Friend's Pass licence\(added). The game runs in its Friend's Pass mode (playing with a friend who owns it) because the account has not bought it; buying it on Steam adds the full licence, nothing in Gamify needs to change."))
            }
            if kinds.contains(.freeWeekend) {
                return AppCheck(app: app, item: CheckItem(.warning, title, "free weekend licence only\(added): it stops working when the free weekend ends"))
            }
            if kinds.contains(.freePromotion) {
                return AppCheck(app: app, item: CheckItem(.ok, title, "free (promotion)\(added)"))
            }
            if kinds.contains(.freeToPlay) {
                return AppCheck(app: app, item: CheckItem(.ok, title, "free to play\(added)"))
            }
            if kinds.contains(.free) {
                return AppCheck(app: app, item: CheckItem(.ok, title, "free licence\(added)"))
            }
            if live?.subscribed == true {
                return AppCheck(app: app, item: CheckItem(.ok, title, "licensed (Steam's own free apps and tools)"))
            }
            return AppCheck(app: app, item: CheckItem(.info, title, "not in Steam's licence cache; start Steam and check again for Steam's own answer"))
        }

        let advice = "Start games from Steam's library, or from Gamify's Programs list or Run .exe: for an exe inside steamapps/common Gamify asks Steam to start the game (steam://rungameid/<appid>), so Steam runs its launch steps (cloud saves, overlay) and the game gets its licence the same way."
        return Check(bottle: bottle.name, checked: status.checked, client: client, apps: appChecks,
                     launchAdvice: advice, probe: probe)
    }

    /// The service key steamservice.exe /install writes into the bottle's system.reg.
    static func serviceRegistered(in bottle: Bottle) -> Bool {
        guard let data = try? Data(contentsOf: bottle.prefix.appendingPathComponent("system.reg"), options: .alwaysMapped) else { return false }
        return data.range(of: Data("\\\\Services\\\\Steam Client Service]".utf8)) != nil
    }

    static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}
