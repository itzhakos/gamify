import Foundation

/// Debugging mode and the log export (docs/app.md "Debugging mode and log export").
/// Debugging mode (`BottleConfig.debug`) makes programs started afterwards log more:
/// `Runtime.environment` uses `wineDebug` instead of WINEDEBUG=-all and adds
/// `environment`, each only where the caller's environment sets nothing. The export
/// (`export(bottle:...)`) zips everything we need to diagnose a crash or a freeze on
/// another Mac; `sample(bottle:...)` takes a stack sample of a running (frozen) game.
public enum Debug {
    /// WINEDEBUG in debugging mode: errors and fixmes of every channel (Wine's own
    /// default, which `-all` silences), exception and module-load warnings, every DLL
    /// load with native/builtin, and a timestamp + pid on each line (when a freeze began,
    /// which process). `+seh` (trace) is left out on purpose: it dumps registers for every
    /// exception and floods games that use exceptions for control flow.
    public static let wineDebug = "+timestamp,+pid,err+all,fixme+all,warn+seh,warn+module,+loaddll"

    /// Added in debugging mode. MTL_HUD_LOG_ENABLED: Apple's Metal HUD writes one line per
    /// frame to stdout ("metal-HUD: <frame>,<mem>,<mem>,<present ms>,<gpu ms>,..."), so the
    /// log shows frame times right up to a freeze, without the HUD on screen.
    public static let environment: [String: String] = [
        "MTL_HUD_LOG_ENABLED": "1",
    ]

    /// Gamify's per-launch logs: <logsRoot>/<bottle>/<yyyyMMdd-HHmmss>-<label>.log.
    public static var logsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Gamify")
    }

    /// Default zip name: Gamify-logs-<bottle>-<yyyyMMdd-HHmm>.zip.
    public static func defaultExportName(bottle: String, date: Date = Date()) -> String {
        "Gamify-logs-\(bottle)-\(stamp(date, "yyyyMMdd-HHmm")).zip"
    }

    // MARK: - Limits

    /// Per-file cap for logs; a bigger file keeps its first 1 MB and its last 4 MB.
    public static let fileCap = 5 * 1024 * 1024
    /// Total of all copied files (uncompressed); logs compress about 10:1, so the zip
    /// stays well under 50 MB.
    public static let totalBudget = 120 * 1024 * 1024
    public static let maxLaunchLogs = 20
    public static let maxWineserverLogs = 3
    public static let maxGameLogsPerFolder = 30
    public static let systemLogLines = 20_000
    public static let sampleSeconds = 5

    // MARK: - Export

    public struct ExportResult {
        public var zip: URL
        public var bytes: Int64
        /// "<folder>: <n> files" per sub-folder.
        public var summary: [String]
        /// Sources that were missing or failed (also in the READMEs).
        public var notes: [String]
    }

    /// Writes the zip for `bottle` to `zip` (replaced when it exists). `sinceHours`: logs,
    /// crash reports and system log entries of the last N hours. `appInfo`: the app's
    /// Info.plist (the GUI passes Bundle.main's); nil reads the bundle around a packaged
    /// root or app/Info.plist in a checkout. `base`: the environment programs inherit
    /// (for env.txt). Missing sources are noted in the READMEs, never an error; only
    /// failing to write the zip throws.
    public static func export(bottle: Bottle, project: Project, to zip: URL, sinceHours: Double = 24,
                              appInfo: [String: Any]? = nil,
                              base: [String: String] = ProcessInfo.processInfo.environment,
                              progress: (String) -> Void = { _ in }) throws -> ExportResult {
        let fm = FileManager.default
        let now = Date()
        let since = now.addingTimeInterval(-sinceHours * 3600)
        let name = zip.deletingPathExtension().lastPathComponent
        let staging = fm.temporaryDirectory.appendingPathComponent("gamify-export-\(UUID().uuidString)")
        let top = staging.appendingPathComponent(name)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: top, withIntermediateDirectories: true)
        let budget = Budget()
        let runtime = try? Runtime.forBottle(bottle, project: project, environment: base)
        let hours = sinceHours == sinceHours.rounded() ? String(Int(sinceHours)) : String(format: "%.1f", sinceHours)

        // samples/ first: a frozen game is sampled before anything else takes time
        progress("Running processes")
        let samples = Section(top, "samples", budget, """
            What runs in the bottle at the time of the export and, when a game runs, a \(sampleSeconds)-second stack sample
            (`sample`) of it and of the bottle's wineserver: a frozen game shows where its threads are stuck.
            """)
        writeSamples(samples, bottle: bottle) { progress($0) }
        samples.finish()

        // gamify/
        progress("Gamify and bottle settings")
        let gamify = Section(top, "gamify", budget, """
            Gamify's version, this bottle's settings and the environment its programs run with.
            Paths and the macOS user name appear in these files; nothing was removed from them
            (Gamify keeps no passwords or tokens in them).
            """)
        gamify.write("version.txt", versionLines(project: project, appInfo: appInfo, runtime: runtime).joined(separator: "\n"),
                     why: "app version and build, runtime-version, Wine version")
        gamify.copy(bottle.prefix.appendingPathComponent(Bottle.configFile), as: "cross.json",
                    why: "the bottle's settings (runtime, graphics, performance, debugging mode)")
        gamify.copy(bottle.prefix.appendingPathComponent(Programs.file), as: "programs.json",
                    why: "programs added by hand", optional: true)
        gamify.write("bottle-show.txt", bottle.showLines(in: project).joined(separator: "\n"),
                     why: "`cross bottle show`: settings with the variables each one sets")
        if let runtime {
            do {
                let env = try runtime.environment(for: bottle, base: base)
                gamify.write("env.txt", Runtime.environmentLines(env, export: false).joined(separator: "\n"),
                             why: "`cross env`: the exact environment programs in this bottle start with (from the process that made this export)")
            } catch {
                gamify.missing("env.txt: \(error)")
            }
        } else {
            gamify.missing("env.txt and steam-check.txt: the bottle's runtime '\(bottle.config.runtime)' is not available")
        }
        gamify.write("programs.txt", Programs.list(in: bottle).map { p in
            p.name.padding(toLength: 28, withPad: " ", startingAt: 0) + p.source.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
                + p.exe + (p.arguments.isEmpty ? "" : " " + p.arguments)
        }.joined(separator: "\n"), why: "`cross programs`: the Programs list")
        let steamApps = Steam.installedApps(in: bottle)
        if Steam.isInstalled(in: bottle) {
            gamify.write("steam-games.txt", steamApps.map { a in
                "\(a.appID)\t\(a.name)\tstateFlags=\(a.stateFlags)\t\(a.folder.path)"
            }.joined(separator: "\n"), why: "installed Steam games (appmanifest files)")
            if let runtime {
                progress("Steam check")
                gamify.write("steam-check.txt", Steam.check(in: bottle, runtime: runtime, fix: false).text,
                             why: "`cross steam check --no-fix`: is Steam running and signed in, licences")
            }
        } else {
            gamify.missing("steam-check.txt, steam-games.txt: Steam is not installed in this bottle")
        }
        if let runtime {
            gamify.write("d3dmetal-files.txt", listing([runtime.d3dmetalHome.appendingPathComponent("x86_64-unix"),
                                                        runtime.d3dmetalHome.appendingPathComponent("x86_64-windows")]),
                         why: "D3DMetal's files with symlink targets (its .so files must be symlinks to libd3dshared.dylib)")
        }
        gamify.finish()

        // system/
        progress("System information")
        let system = Section(top, "system", budget, "The Mac: macOS version, chip, memory, GPU and displays, disk space, Rosetta, power and thermal state, what uses the CPU.")
        system.run("sw_vers.txt", "/usr/bin/sw_vers", [], why: "macOS version and build")
        system.run("hardware.txt", "/usr/sbin/sysctl", ["machdep.cpu.brand_string", "hw.model", "hw.memsize", "hw.ncpu",
                                                         "hw.perflevel0.physicalcpu", "hw.perflevel1.physicalcpu"],
                   why: "chip, Mac model, memory, cores")
        system.run("displays.txt", "/usr/sbin/system_profiler", ["SPDisplaysDataType"], why: "GPU, Metal support, displays", timeout: 60)
        let volumes = [fm.homeDirectoryForCurrentUser.path, bottle.prefix.path, project.root.path].uniqued()
        system.run("disk.txt", "/bin/df", ["-h"] + volumes, why: "free space on the home disk, the bottle's disk and Gamify's")
        system.write("rosetta.txt", rosettaText(), why: "Rosetta 2 (our Wine is x86_64)")
        system.run("power.txt", "/usr/bin/pmset", ["-g"], why: "power settings (Low Power Mode, on battery)")
        system.run("thermal.txt", "/usr/bin/pmset", ["-g", "therm"], why: "thermal throttling (CPU speed limit)")
        system.run("memory.txt", "/usr/bin/memory_pressure", ["-Q"], why: "memory pressure and free memory")
        system.run("top.txt", "/usr/bin/top", ["-l", "1", "-n", "25", "-o", "cpu", "-stats", "pid,command,cpu,mem,state,time"],
                   why: "the processes using the most CPU right now", timeout: 30)
        system.finish()

        // logs/
        progress("Gamify launch logs")
        let logs = Section(top, "logs", budget, """
            Gamify's per-launch logs for '\(bottle.name)' from the last \(hours) hours (the newest \(maxLaunchLogs) at most), from
            \(logsRoot.appendingPathComponent(bottle.name).path). Each holds the Wine output (stdout and stderr) of one
            program start; with debugging mode on it also has WINEDEBUG output and metal-HUD frame lines.
            Sample Running Game results (*-sample-*.txt) are kept here too.
            """)
        let logDir = logsRoot.appendingPathComponent(bottle.name)
        let all = files(in: logDir).sorted { $0.date > $1.date }
        if all.isEmpty { logs.missing("no logs in \(logDir.path)") }
        let isServer: (FileInfo) -> Bool = { $0.url.lastPathComponent.contains("wineserver") }
        let recent = all.filter { !isServer($0) && $0.date >= since }.prefix(maxLaunchLogs)
        if all.contains(where: { !isServer($0) }) && recent.isEmpty { logs.missing("no launch log from the last \(hours) hours") }
        for f in recent { logs.copy(f.url, as: f.url.lastPathComponent, why: "launch log, \(dateText(f.date))") }
        for f in all.filter(isServer).prefix(maxWineserverLogs) {
            logs.copy(f.url, as: f.url.lastPathComponent, why: "wineserver log (newest), \(dateText(f.date))")
        }
        logs.finish()

        // crash-reports/
        progress("Crash reports")
        let crashes = Section(top, "crash-reports", budget, """
            macOS crash, hang and spin reports (~/Library/Logs/DiagnosticReports and its Retired folder) from the
            last \(hours) hours whose name starts with wine, wineloader, wineserver, steam, Gamify/CrossApp/cross or the name
            of a program or Steam game exe in this bottle (also as ExcUserFault_<name>; not the Mac Steam client, steam_osx).
            """)
        let prefixes = crashPrefixes(bottle: bottle, steamApps: steamApps)
        let reportDirs = ["Library/Logs/DiagnosticReports", "Library/Logs/DiagnosticReports/Retired"].map {
            fm.homeDirectoryForCurrentUser.appendingPathComponent($0)
        }
        let reports = reportDirs.flatMap { files(in: $0) }.filter { f in
            // "wine-2026-10-17-165353.ips", "ExcUserFault_wine-….ips"; not the Mac Steam client (steam_osx)
            var n = f.url.lastPathComponent.lowercased()
            if let i = n.firstIndex(of: "_"), n.hasPrefix("exc") { n = String(n[n.index(after: i)...]) }
            return ["ips", "crash", "hang", "spin", "diag"].contains(f.url.pathExtension.lowercased())
                && f.date >= since && !n.hasPrefix("steam_osx") && prefixes.contains { n.hasPrefix($0) }
        }.sorted { $0.date > $1.date }
        if reports.isEmpty { crashes.missing("no matching report from the last \(hours) hours") }
        for f in reports.prefix(40) { crashes.copy(f.url, as: f.url.lastPathComponent, why: dateText(f.date)) }
        crashes.finish()

        // system-log/
        progress("System log")
        let syslog = Section(top, "system-log", budget, """
            Entries from the macOS unified log of the last \(hours) hours (`log show --style compact`), at most the newest
            \(systemLogLines) lines per file: D3DMetal's messages, Metal HUD frame lines, what Wine and game processes logged,
            GPU messages of the kernel. (macOS Game Mode is not included: macOS does not log when it turns on.)
            """)
        systemLog(syslog, hours: sinceHours)
        syslog.finish()

        // game-logs/
        progress("Game logs")
        let games = Section(top, "game-logs", budget, """
            Log files the games write themselves, modified in the last \(hours) hours: *.log next to (or below) the exe of every
            program in the Programs list and every installed Steam game, *.txt inside a logs/Logs/Saved/Logs folder, the
            same under the Windows user's AppData (Local, LocalLow, Roaming) and Documents (My Games), and Steam's own logs.
            Unreal Engine settings (GameUserSettings.ini, Engine.ini) are included whatever their date. At most \(fileCap / 1024 / 1024) MB
            per file (larger files keep their beginning and end).
            """)
        gameLogs(games, bottle: bottle, steamApps: steamApps, since: since)
        games.finish()

        let sections = [gamify, system, logs, crashes, syslog, games, samples]
        var readme = """
            Gamify diagnostics for the bottle '\(bottle.name)'
            Made \(dateText(now)) (\(TimeZone.current.identifier)), covering the last \(hours) hours.

            Please send this zip with your problem report: what you did, what happened, and when.

            Folders:

            """
        let what = ["gamify": "Gamify version, the bottle's settings and environment, Programs, Steam check",
                    "system": "macOS version, chip, memory, GPU and displays, disk space, Rosetta, power, CPU use",
                    "logs": "Gamify's launch logs (Wine output of each program start), Sample Running Game results",
                    "crash-reports": "macOS crash/hang reports of Wine, Steam and the games",
                    "system-log": "macOS log entries: D3DMetal, Metal HUD frame lines, Wine processes, GPU",
                    "game-logs": "the games' own log files and Unreal settings",
                    "samples": "the bottle's processes and, when a game runs, a stack sample of it"]
        for s in sections {
            readme += "  \(s.name)/".padding(toLength: 18, withPad: " ", startingAt: 0)
                + "\(s.count) file\(s.count == 1 ? "" : "s"): \(what[s.name] ?? "")\n"
        }
        readme += """

            Each folder has its own README.txt listing every file and why it is there, and what was not found.
            Privacy: file paths (with your macOS user name), the names of your games, and your Steam account name
            (in steam-check.txt, when Steam is installed) appear in these files. Nothing was removed or rewritten.
            Large files were cut in the middle (marked "[... cut ...]").
            """
        try readme.write(to: top.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        progress("Writing the zip")
        let tmpZip = staging.appendingPathComponent(name + ".zip")
        let status = try runWaiting(program: "/usr/bin/ditto", arguments: ["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent", top.path, tmpZip.path],
                                    environment: ProcessInfo.processInfo.environment, quiet: true)
        guard status == 0 else { throw CrossError("ditto could not write the zip (status \(status))") }
        try fm.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: zip.path) { try fm.removeItem(at: zip) }
        try fm.moveItem(at: tmpZip, to: zip)
        let bytes = (try? fm.attributesOfItem(atPath: zip.path)[.size] as? Int64) ?? 0
        return ExportResult(zip: zip, bytes: bytes,
                            summary: sections.map { "\($0.name)/: \($0.count) files" },
                            notes: sections.flatMap { s in s.notes.map { "\(s.name): \($0)" } })
    }

    // MARK: - Samples

    public struct SampleResult {
        /// The sampled game process (nil: nothing but Wine's own processes runs).
        public var target: Steam.BottleProcess?
        public var files: [URL]
        public var notes: [String]
    }

    /// Wine's own processes and the Steam client, not what a user calls "the game".
    static let systemPrograms: Set<String> = [
        "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "rpcss.exe", "explorer.exe",
        "conhost.exe", "start.exe", "winedbg.exe", "wineboot.exe", "tabtip.exe", "rundll32.exe", "regedit.exe",
        "steamwebhelper.exe", "steamwebhelper_real.exe", "steamservice.exe", "gameoverlayui.exe", "gameoverlayui64.exe",
    ]

    /// The process `sample` should look at: the newest one in the bottle that is not Wine's
    /// own, preferring anything over steam.exe (only Steam running: steam.exe).
    public static func sampleTarget(in bottle: Bottle) -> Steam.BottleProcess? {
        let candidates = Steam.bottleProcesses(in: bottle)
            .filter { !systemPrograms.contains($0.program) }
            .sorted { ($0.started ?? .distantPast) > ($1.started ?? .distantPast) }
        return candidates.first { $0.program != "steam.exe" } ?? candidates.first
    }

    /// The bottle's wineserver: its working directory is the server dir Wine names after
    /// the prefix's device and inode (`server-<dev>-<ino>`, under /tmp/.wine-<uid>).
    public static func wineserverPID(for bottle: Bottle) -> pid_t? {
        var st = stat()
        guard stat(DiskImage.realPath(bottle.prefix), &st) == 0 else { return nil }
        let dir = String(format: "/server-%llx-%llx", UInt64(UInt32(bitPattern: st.st_dev)), UInt64(st.st_ino))
        return allPIDs().first { pid in
            guard let cwd = Steam.workingDirectory(of: pid), cwd.hasSuffix(dir) else { return false }
            return Steam.commandLine(of: pid).first.map { ($0 as NSString).lastPathComponent == "wineserver" } ?? false
        }
    }

    /// `cross debug sample` / Sample Running Game: `sample <pid> 5` of the game and of the
    /// bottle's wineserver (both at once), into `folder` as
    /// <yyyyMMdd-HHmmss>-sample-<exe>.txt, plus the bottle's process list.
    public static func sample(bottle: Bottle, into folder: URL, seconds: Int = sampleSeconds) -> SampleResult {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ts = stamp(Date(), "yyyyMMdd-HHmmss")
        var result = SampleResult(target: sampleTarget(in: bottle), files: [], notes: [])
        let processes = folder.appendingPathComponent("\(ts)-processes.txt")
        if (try? processList(bottle).write(to: processes, atomically: true, encoding: .utf8)) != nil {
            result.files.append(processes)
        }
        var jobs: [(pid_t, URL)] = []
        if let target = result.target {
            let exe = (target.program as NSString).deletingPathExtension
            jobs.append((target.pid, folder.appendingPathComponent("\(ts)-sample-\(exe.isEmpty ? "game" : exe).txt")))
        } else {
            result.notes.append("no game runs in '\(bottle.name)' (only Wine's own processes, or nothing)")
        }
        if let server = wineserverPID(for: bottle) {
            jobs.append((server, folder.appendingPathComponent("\(ts)-sample-wineserver.txt")))
        } else {
            result.notes.append("no wineserver runs for '\(bottle.name)'")
        }
        let group = DispatchGroup()
        let lock = NSLock()
        for (pid, file) in jobs {
            group.enter()
            DispatchQueue.global().async {
                let outcome = capture("/usr/bin/sample", [String(pid), String(seconds), "-mayDie", "-file", file.path],
                                      to: folder.appendingPathComponent(".\(pid)-sample-output"), timeout: TimeInterval(seconds + 90))
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(".\(pid)-sample-output"))
                lock.lock()
                if FileManager.default.fileExists(atPath: file.path) {
                    result.files.append(file)
                } else {
                    result.notes.append("sample of pid \(pid) failed: \(outcome ?? "no output")")
                }
                lock.unlock()
                group.leave()
            }
        }
        group.wait()
        return result
    }

    /// The bottle's processes with ps's view of them (CPU, memory, state, run time).
    static func processList(_ bottle: Bottle) -> String {
        let procs = Steam.bottleProcesses(in: bottle).sorted { $0.pid < $1.pid }
        var text = "Processes in '\(bottle.name)' (working directory inside \(bottle.prefix.path)):\n"
        if procs.isEmpty { return text + "  none\n" }
        for p in procs {
            text += "  \(p.pid)\t\(p.started.map(dateText) ?? "?")\t\(p.arguments.joined(separator: " "))\n"
        }
        var pids = procs.map { String($0.pid) }
        if let server = wineserverPID(for: bottle) {
            text += "  \(server)\t(wineserver)\n"
            pids.append(String(server))
        }
        text += "\nps:\n" + (output("/bin/ps", ["-o", "pid,ppid,%cpu,%mem,rss,etime,state,command", "-p", pids.joined(separator: ",")]) ?? "ps failed\n")
        return text
    }

    private static func writeSamples(_ section: Section, bottle: Bottle, progress: (String) -> Void) {
        let dir = section.dir
        if sampleTarget(in: bottle) == nil {
            section.write("processes.txt", processList(bottle), why: "the bottle's processes at export time")
            section.missing("no stack sample: no game runs in the bottle")
            return
        }
        progress("Sampling the running game (\(sampleSeconds) s)")
        let result = sample(bottle: bottle, into: dir)
        for f in result.files {
            let n = f.lastPathComponent
            let why = n.hasSuffix("-processes.txt") ? "the bottle's processes at export time"
                : n.contains("-sample-wineserver") ? "stack sample of the bottle's wineserver"
                : "stack sample of \(result.target.map { "\($0.program) (pid \($0.pid))" } ?? "the game")"
            section.adopt(n, why: why)
        }
        result.notes.forEach { section.missing($0) }
    }

    // MARK: - Sources

    /// App version and build, runtime-version, the git commit of a checkout, Wine's version.
    public static func versionLines(project: Project, appInfo: [String: Any]?, runtime: Runtime?) -> [String] {
        var info = appInfo
        var infoSource = "the running app"
        if info == nil {
            // packaged: <App>.app/Contents/SharedSupport/root -> Contents/Info.plist
            let plist = project.bundled
                ? project.root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
                : project.root.appendingPathComponent("app/Info.plist")
            info = NSDictionary(contentsOf: plist) as? [String: Any]
            infoSource = plist.path
        }
        var lines = [
            "Gamify \(info?["CFBundleShortVersionString"] as? String ?? "?") (build \(info?["CFBundleVersion"] as? String ?? "?"), from \(infoSource))",
            "root: \(project.root.path) (\(project.bundled ? "packaged app" : "checkout"))",
            "bottles folder: \(project.bottles.path)",
        ]
        let rv = project.root.appendingPathComponent("runtime-version")
        if let text = try? String(contentsOf: rv, encoding: .utf8) {
            lines.append("runtime-version: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            lines.append("runtime-version: none (\(project.bundled ? "older bundle" : "checkout build"))")
        }
        if !project.bundled, FileManager.default.fileExists(atPath: project.root.appendingPathComponent(".git").path),
           let commit = output("/usr/bin/git", ["-C", project.root.path, "log", "-1", "--format=%h %cd %s", "--date=short"]) {
            lines.append("git: \(commit.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let runtime {
            lines.append("runtime: \(runtime.name) at \(runtime.home.path)")
            lines.append("D3DMetal: \(runtime.d3dmetalHome.path)")
            let version = output(runtime.wine.path, ["--version"], timeout: 15)?.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("wine --version: \(version ?? "failed")")
        }
        return lines
    }

    static func rosettaText() -> String {
        var text = "Rosetta 2 available: \(Runtime.recheckRosetta() ? "yes" : "no") (an x86_64 /usr/bin/true ran through arch -x86_64)\n"
        let oah = FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
        text += "/Library/Apple/usr/libexec/oah/libRosettaRuntime: \(oah ? "present" : "missing")\n"
        if let v = output("/usr/sbin/pkgutil", ["--pkg-info", "com.apple.pkg.RosettaUpdateAuto"]) { text += "\n" + v }
        return text
    }

    /// Lower-cased name prefixes of crash reports worth sending.
    static func crashPrefixes(bottle: Bottle, steamApps: [Steam.InstalledApp]) -> [String] {
        var names = ["wine", "wineloader", "wine64-preloader", "wineserver", "steam", "gamify", "crossapp", "cross-"]
        for p in Programs.list(in: bottle) { names.append((Programs.exeName(p.exe) as NSString).deletingPathExtension) }
        for p in Steam.bottleProcesses(in: bottle) { names.append((p.program as NSString).deletingPathExtension) }
        for app in steamApps {
            for exe in executables(in: app.folder, depth: 3) { names.append((exe as NSString).deletingPathExtension) }
        }
        return names.map { $0.lowercased() }.filter { $0.count >= 3 }.uniqued()
    }

    /// .exe file names at most `depth` folder levels below `root` (not uninstallers, crash handlers).
    static func executables(in root: URL, depth: Int) -> [String] {
        var out: [String] = []
        walk(root, depth: depth, limit: 5000) { url, _ in
            let n = url.lastPathComponent
            if n.lowercased().hasSuffix(".exe"), !n.lowercased().hasPrefix("unins") { out.append(n) }
        }
        return out.uniqued()
    }

    /// Subsystems of a Wine process that log a lot and never tell us anything.
    static let systemLogNoise = ["[com.apple.coreaudio:", "[com.apple.appintents:", "[com.apple.TextInputUI:",
                                 "[com.apple.GenerativeModels:"]

    /// One `log show` over every process whose name starts with wine (every Windows program
    /// runs as "wine"), D3DMetal's category and the kernel's GPU messages, split into files.
    /// Filtering on process and category is fast (24 h in about 10 s); eventMessage
    /// CONTAINS clauses made it scan for minutes, so the split is done here.
    private static func systemLog(_ section: Section, hours: Double) {
        let predicate = """
            process BEGINSWITH "wine" OR category == "D3DMetal" \
            OR (process == "kernel" AND (eventMessage CONTAINS[c] "gpu" OR eventMessage CONTAINS "AGX"))
            """
        let raw = section.dir.appendingPathComponent(".log-show.txt")
        defer { try? FileManager.default.removeItem(at: raw) }
        let minutes = max(1, Int((hours * 60).rounded()))
        if let error = capture("/usr/bin/log", ["show", "--last", "\(minutes)m", "--style", "compact", "--predicate", predicate],
                               to: raw, timeout: 300) {
            section.missing("log show: \(error)")
        }
        // stream the file once, keeping the newest lines of each kind
        var hud = Tail(systemLogLines), d3dm = Tail(systemLogLines), gpu = Tail(2000), wine = Tail(systemLogLines)
        var noise = 0
        forEachLine(raw) { line in
            if line.contains("metal-HUD:") { hud.append(line) }
            else if line.contains("[D3DMetal") { d3dm.append(line) }
            else if line.contains(" kernel[") || line.contains(" kernel:") { gpu.append(line) }
            else if line.hasPrefix("Timestamp") || line.hasPrefix("Filtering") { return }
            else if systemLogNoise.contains(where: { line.contains($0) }) { noise += 1 }
            else { wine.append(line) }
        }
        func lines(_ t: Tail) -> String { "\(t.total) lines" + (t.cut ? ", the newest \(t.capacity) kept" : "") }
        section.write("d3dmetal.txt", d3dm.text, why: "D3DMetal's own messages (unsupported API calls, errors) (\(lines(d3dm)))")
        section.write("metal-hud.txt", hud.text,
                      why: "Metal HUD lines, one per second per game with MTL_HUD_LOG_ENABLED=1 (debugging mode): frame counter, memory, then present interval and GPU time per frame (\(lines(hud)))")
        section.write("gpu-kernel.txt", gpu.text, why: "kernel messages about the GPU (restarts, AGX errors) (\(lines(gpu)))")
        section.write("wine.txt", wine.text,
                      why: "everything else Wine processes logged (\(lines(wine)); \(noise) Core Audio/App Intents/text input lines left out)")
        section.write("predicate.txt", predicate, why: "the `log show` filter used")
    }

    private static func gameLogs(_ section: Section, bottle: Bottle, steamApps: [Steam.InstalledApp], since: Date) {
        var roots: [(String, URL)] = []
        for p in Programs.list(in: bottle) {
            guard let exe = Programs.unixURL(of: p.exe, in: bottle) else { continue }
            // Program Files\Vendor\Game\bin\game.exe: also look one level up
            var dir = exe.deletingLastPathComponent()
            if ["bin", "binaries", "win64", "x64", "bin64"].contains(dir.lastPathComponent.lowercased()) { dir.deleteLastPathComponent() }
            roots.append((p.name, dir))
        }
        for app in steamApps { roots.append((app.name, app.folder)) }
        let profile = bottle.userProfile
        for sub in ["AppData/Local", "AppData/LocalLow", "AppData/Roaming", "Documents/My Games", "Documents"] {
            roots.append((sub.replacingOccurrences(of: "/", with: " "), profile.appendingPathComponent(sub)))
        }
        if Steam.isInstalled(in: bottle) { roots.append(("Steam", bottle.steamDir.appendingPathComponent("logs"))) }

        var seen = Set<String>()
        var found = 0
        for (label, root) in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let rootPath = root.resolvingSymlinksInPath().path
            var hits: [(URL, Date, Bool)] = []   // (file, date, is a settings file)
            walk(root, depth: 6, limit: 40_000, skip: skipFolders) { url, date in
                let n = url.lastPathComponent
                let lower = n.lowercased()
                if lower == "gameusersettings.ini" || lower == "engine.ini" {
                    if url.path.contains("/Saved/Config/") { hits.append((url, date, true)) }
                    return
                }
                guard date >= since else { return }
                let inLogFolder = url.pathComponents.dropLast().contains { ["logs", "log"].contains($0.lowercased()) }
                if lower.hasSuffix(".log") || (inLogFolder && (lower.hasSuffix(".txt") || lower.hasSuffix(".json"))) {
                    hits.append((url, date, false))
                }
            }
            let settings = hits.filter { $0.2 }
            let logs = hits.filter { !$0.2 }.sorted { $0.1 > $1.1 }.prefix(maxGameLogsPerFolder)
            for (url, date, isSettings) in settings + logs {
                guard seen.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
                // the enumerator reports resolved paths (/private/tmp for /tmp)
                let rel = url.resolvingSymlinksInPath().path.dropFirst(rootPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let dest = safeName(label) + "/" + rel
                section.copy(url, as: dest, why: (isSettings ? "Unreal settings" : "log") + ", \(dateText(date)), from \(url.path)")
                found += 1
            }
        }
        if found == 0 {
            let looked = roots.filter { FileManager.default.fileExists(atPath: $0.1.path) }.map(\.0)
            section.missing("no game log modified in that time and no Unreal settings (looked in: \(looked.joined(separator: ", ")))")
        }
    }

    /// Big folders that never hold game logs.
    static let skipFolders: Set<String> = ["htmlcache", "shadercache", "GPUCache", "Code Cache", "Cache", "cache",
                                           "steamapps", "Microsoft", "Temp", "D3DSCache", "NVIDIA", "Packages", "CEF", "fonts"]

    // MARK: - Helpers

    struct FileInfo {
        var url: URL
        var date: Date
    }

    static func files(in dir: URL) -> [FileInfo] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return [] }
        return items.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return FileInfo(url: url, date: v.contentModificationDate ?? .distantPast)
        }
    }

    /// Visits regular files below `root`, at most `depth` levels and `limit` entries;
    /// symlinks are not followed (a game folder may link into the whole drive).
    static func walk(_ root: URL, depth: Int, limit: Int, skip: Set<String> = [], _ visit: (URL, Date) -> Void) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { return }
        var count = 0
        for case let url as URL in e {
            count += 1
            if count > limit { break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if e.level >= depth || skip.contains(url.lastPathComponent) || v.isSymbolicLink == true { e.skipDescendants() }
                continue
            }
            if v.isRegularFile == true { visit(url, v.contentModificationDate ?? .distantPast) }
        }
    }

    static func listing(_ dirs: [URL]) -> String {
        let fm = FileManager.default
        var text = ""
        for dir in dirs {
            text += "\(dir.path):\n"
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { text += "  (missing)\n\n"; continue }
            for n in names.sorted() {
                let path = dir.appendingPathComponent(n).path
                if let target = try? fm.destinationOfSymbolicLink(atPath: path) {
                    text += "  \(n) -> \(target)\(fm.fileExists(atPath: path) ? "" : "  (BROKEN)")\n"
                } else {
                    let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
                    text += "  \(n)  \(size.map(String.init) ?? "?") bytes\n"
                }
            }
            text += "\n"
        }
        return text
    }

    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(got, 0)))).filter { $0 > 0 }
    }

    /// Runs a program with stdout and stderr in `file`; kills it after `timeout`.
    /// Returns nil on exit 0, else what went wrong.
    @discardableResult
    static func capture(_ program: String, _ arguments: [String], to file: URL, timeout: TimeInterval = 30) -> String? {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: file) else { return "cannot write \(file.path)" }
        defer { try? handle.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: program)
        p.arguments = arguments
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return "cannot run \(program): \(error)" }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 5)
            return "stopped after \(Int(timeout)) s"
        }
        return p.terminationStatus == 0 ? nil : "exit status \(p.terminationStatus)"
    }

    /// stdout+stderr of a short command, nil when it cannot run.
    static func output(_ program: String, _ arguments: [String], timeout: TimeInterval = 30) -> String? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gamify-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let error = capture(program, arguments, to: tmp, timeout: timeout)
        guard let text = try? String(contentsOf: tmp, encoding: .utf8), error == nil || !text.isEmpty else { return nil }
        return text
    }

    static func forEachLine(_ url: URL, _ body: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var rest = Data()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            rest.append(chunk)
            var start = rest.startIndex
            while let nl = rest[start...].firstIndex(of: 0x0a) {
                body(String(decoding: rest[start..<nl], as: UTF8.self))
                start = nl + 1
            }
            rest = Data(rest[start...])
        }
        if !rest.isEmpty { body(String(decoding: rest, as: UTF8.self)) }
    }

    /// The last `capacity` lines appended.
    struct Tail {
        let capacity: Int
        private var ring: [String] = []
        private var start = 0
        private(set) var total = 0
        init(_ capacity: Int) { self.capacity = capacity }
        var cut: Bool { total > capacity }
        mutating func append(_ line: String) {
            total += 1
            if ring.count < capacity { ring.append(line) } else { ring[start] = line; start = (start + 1) % capacity }
        }
        var text: String {
            let lines = Array(ring[start...] + ring[..<start])
            return (cut ? "[... \(total - capacity) older lines cut ...]\n" : "") + lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        }
    }

    static func safeName(_ s: String) -> String {
        String(s.map { "/:\\".contains($0) ? "_" : $0 })
    }

    static func stamp(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }

    static func dateText(_ date: Date) -> String { stamp(date, "yyyy-MM-dd HH:mm:ss") }

    // MARK: - Sections

    /// Shared by all sections: the uncompressed bytes still allowed.
    final class Budget {
        var left = Debug.totalBudget
    }

    /// One folder of the zip with its README.txt.
    final class Section {
        let name: String
        let dir: URL
        let intro: String
        let budget: Budget
        private(set) var entries: [(String, String)] = []
        private(set) var notes: [String] = []
        var count: Int { entries.count }

        init(_ top: URL, _ name: String, _ budget: Budget, _ intro: String) {
            self.name = name
            self.dir = top.appendingPathComponent(name)
            self.intro = intro
            self.budget = budget
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        func missing(_ note: String) { notes.append(note) }

        func write(_ file: String, _ text: String, why: String) {
            let data = Data((text.hasSuffix("\n") || text.isEmpty ? text : text + "\n").utf8)
            guard data.count <= budget.left else { missing("\(file): skipped, the export's size limit was reached"); return }
            do {
                try data.write(to: dir.appendingPathComponent(file))
                budget.left -= data.count
                entries.append((file, why))
            } catch {
                missing("\(file): \(error.localizedDescription)")
            }
        }

        /// A file a helper already wrote into `dir`.
        func adopt(_ file: String, why: String) {
            let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file).path)[.size] as? Int) ?? 0
            budget.left -= size
            entries.append((file, why))
        }

        /// Copies `source` (cut in the middle beyond `Debug.fileCap`) to `file`, which may
        /// contain sub-folders.
        func copy(_ source: URL, as file: String, why: String, optional: Bool = false) {
            let fm = FileManager.default
            guard let size = (try? fm.attributesOfItem(atPath: source.path)[.size] as? Int) ?? nil else {
                if !optional { missing("\(file): \(source.path) not found") }
                return
            }
            let dest = dir.appendingPathComponent(file)
            let kept = min(size, Debug.fileCap)
            guard kept <= budget.left else { missing("\(file): skipped, the export's size limit was reached"); return }
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if size <= Debug.fileCap {
                    try fm.copyItem(at: source, to: dest)
                } else {
                    let head = 1024 * 1024, tail = Debug.fileCap - head
                    let h = try FileHandle(forReadingFrom: source)
                    defer { try? h.close() }
                    var data = try h.read(upToCount: head) ?? Data()
                    data.append(Data("\n\n[... cut \(size - head - tail) bytes of \(size) ...]\n\n".utf8))
                    try h.seek(toOffset: UInt64(size - tail))
                    data.append(try h.readToEnd() ?? Data())
                    try data.write(to: dest)
                }
                budget.left -= kept
                entries.append((file, why + (size > Debug.fileCap ? " (cut: \(size / 1024 / 1024) MB, kept the first 1 MB and the last \(Debug.fileCap / 1024 / 1024 - 1) MB)" : "")))
            } catch {
                missing("\(file): \(error.localizedDescription)")
            }
        }

        /// Runs a command into `file`; a failure is kept in the file and noted.
        func run(_ file: String, _ program: String, _ arguments: [String], why: String, timeout: TimeInterval = 20) {
            let dest = dir.appendingPathComponent(file)
            if let error = Debug.capture(program, arguments, to: dest, timeout: timeout) {
                missing("\(file): `\(([program] + arguments).joined(separator: " "))` \(error)")
            }
            adopt(file, why: why + " (`\((program as NSString).lastPathComponent) \(arguments.joined(separator: " "))`)")
        }

        func finish() {
            var text = intro + "\n\nFiles:\n"
            if entries.isEmpty { text += "  (none)\n" }
            for (file, why) in entries { text += "  \(file)\n      \(why)\n" }
            if !notes.isEmpty {
                text += "\nNot included / problems:\n"
                for n in notes { text += "  - \(n)\n" }
            }
            try? text.write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Bottle summary (`cross bottle show`, gamify/bottle-show.txt)

extension Bottle {
    /// The storage column of `cross bottle list`.
    public var storageText: String {
        if let error = storageError { return "unavailable: \(error)" }
        guard isImageBacked else { return "folder (no limit)" }
        guard let usage = storageUsage else { return "image, not mounted" }
        return "image \(formatGB(usage.used)) used of \(formatGB(usage.total))"
    }

    /// `cross bottle show`.
    public func showLines(in project: Project) -> [String] {
        var lines = [name,
                     "  runtime     \(config.runtime)",
                     "  graphics    \(config.graphics.rawValue)",
                     "  disk        \(storageText)",
                     "  location    \(location?.path ?? prefix.path)",
                     "  debugging   \(config.debug ? "on (WINEDEBUG=\(Debug.wineDebug), " + Debug.environment.keys.sorted().map { "\($0)=\(Debug.environment[$0]!)" }.joined(separator: " ") + ")" : "off")",
                     "performance (applies to programs started afterwards):"]
        lines += Bottle.performanceLines(config)
        return lines
    }

    /// Each performance setting with what it does in this bottle.
    public static func performanceLines(_ config: BottleConfig) -> [String] {
        func onOff(_ b: Bool) -> String { b ? "on" : "off" }
        let p = config.performance
        let d3dmetal = config.graphics == .d3dmetal
        let env = p.environment(graphics: config.graphics)
        func vars(_ keys: [String]) -> String {
            let set = keys.compactMap { k in env[k].flatMap { $0 }.map { "\(k)=\($0)" } }
            return set.isEmpty ? "" : set.joined(separator: " ")
        }
        let onlyD3DMetal = "(D3DMetal bottles only)"
        var lines: [(String, String, String)] = [
            ("sync", p.sync.rawValue, vars(["WINEESYNC", "WINEMSYNC"])),
            ("metalfx", onOff(p.metalfx), d3dmetal ? (p.metalfx ? vars(["D3DM_ENABLE_METALFX"]) + ", nvngx.dll + nvapi64.dll in system32, NGXCore\\FullPath" : "") : onlyD3DMetal),
            ("avx", onOff(p.avx), vars(["ROSETTA_ADVERTISE_AVX"])),
            ("raytracing", p.raytracing.map(onOff) ?? "default", d3dmetal ? vars(["D3DM_SUPPORT_DXR"]) : onlyD3DMetal),
            ("maxfps", p.maxFPS.map(String.init) ?? "off", d3dmetal ? vars(["D3DM_MAX_FPS"]) : onlyD3DMetal),
            ("hud", onOff(p.hud), vars(["MTL_HUD_ENABLED"])),
            ("retina", onOff(p.retina), "RetinaMode=\(p.retina ? "Y" : "N")"),
        ]
        lines.append(("vendor", p.vendorID.map(PerformanceSettings.hex) ?? "default",
                      d3dmetal ? (vars(["D3DM_VENDOR_ID"]).isEmpty ? "D3DMetal's own (0x1002)" : vars(["D3DM_VENDOR_ID"])) : onlyD3DMetal))
        return lines.map { "  " + $0.0.padding(toLength: 12, withPad: " ", startingAt: 0) + $0.1.padding(toLength: 9, withPad: " ", startingAt: 0) + $0.2 }
    }
}
