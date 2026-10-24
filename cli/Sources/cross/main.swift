import Foundation
import CrossCore

let usage = """
cross - bottle manager and launcher for the winecx runtimes

  cross bottle create <name> [--runtime winecx|winecx-full] [--graphics d3dmetal|wined3d|dxvk|dxmt]
                           [--storage <GB>|unlimited] [--location <folder>|default]
  cross bottle list
  cross bottle show <name>                 settings of one bottle (runtime, graphics, disk, performance)
  cross bottle set <name> graphics <d3dmetal|wined3d|dxvk|dxmt>
                                           d3dmetal: DX11/12 (64-bit); dxvk: DX9/10/11 32+64-bit over
                                           MoltenVK (winecx-full); dxmt: DX10/11 32+64-bit on Metal
  cross bottle set <name> sync auto|esync|msync      Windows sync objects: auto (default, = msync), esync or msync
  cross bottle set <name> metalfx on|off             DLSS through MetalFX (D3DMetal; default on)
  cross bottle set <name> avx on|off                 advertise AVX/AVX2 to games (ROSETTA_ADVERTISE_AVX)
  cross bottle set <name> raytracing on|off|default  DirectX ray tracing in D3DMetal (D3DM_SUPPORT_DXR)
  cross bottle set <name> maxfps <n>|off             frame cap inside D3DMetal (D3DM_MAX_FPS)
  cross bottle set <name> hud on|off                 Metal performance HUD (MTL_HUD_ENABLED)
  cross bottle set <name> retina on|off              High Resolution (Retina) mode of the Mac driver
  cross bottle set <name> vendor <hex>|default       GPU vendor id D3DMetal reports (D3DM_VENDOR_ID)
  cross bottle set <name> debug on|off               debugging mode: more Wine output and metal-HUD
                                                     frame lines in each launch log
  cross bottle set <name> storage <GB>|unlimited     (also: --storage <GB>)
  cross bottle set <name> location <folder>|default  move the bottle (e.g. to an external drive)
  cross bottle delete <name>
  cross bottle eject <name>                unmount a disk-image bottle so its drive can be disconnected
  cross bottle forget <name>               take a bottle kept elsewhere off the list, keep its files
  cross bottle find [<folder>...]          search connected drives (or folders) for bottles
  cross bottle add <folder|image> [--name <name>]   list a bottle found elsewhere (e.g. a drive from another Mac)
  cross run   <bottle> <exe> [args...]     run a Windows exe (cwd = the exe's directory)
  cross cmd   <bottle> [args...]           run cmd.exe, e.g. cross cmd cx /c ver
  cross cfg   <bottle>                     open winecfg
  cross steam <bottle> [args...]           install the webhelper shim, clear stale locks, launch Steam
  cross steam check <bottle> [--no-fix]    is Steam running and signed in, do games get their licences
                                           from it (a test program asks Steam), what licence each
                                           installed game has (owned, Friend's Pass, free weekend, ...)
  cross store list [<bottle>]              the stores cross can install (with their state in <bottle>)
  cross store install <bottle> <store>     download the store's official installer, install it silently
  cross store launch  <bottle> <store> [args...]   start an installed store (steam = cross steam)
  cross install <bottle> <installer.exe|.msi> [args...]   run any installer in the bottle (.msi via
                                           msiexec /i), then list the programs it added
  cross programs <bottle>                  list the bottle's programs (Start Menu shortcuts + added ones)
  cross programs <bottle> launch <name> [args...]
  cross programs <bottle> add <exe> [--name <name>] [args...]
  cross programs <bottle> remove <name>
  cross kill  <bottle>                     wineserver -k
  cross env   <bottle> [--export]          print the environment the bottle runs with
  cross debug export <bottle> [--out <file.zip>] [--since <hours>]
                                           zip logs, crash reports, system info and game logs of the
                                           last <hours> (24) for a problem report (default: ~/Desktop)
  cross debug sample <bottle> [--out <folder>]
                                           5 s stack sample of the running game and wineserver
                                           (default folder: ~/Library/Logs/Gamify/<bottle>/)
  cross cache clear <bottle> [<exe name>]  delete D3DMetal's shader cache of one executable (e.g. Game.exe);
                                           without one, list the cache folders and their sizes

Bottles live in bottles/<name> (or are linked from there); per-bottle settings in bottles/<name>/cross.json.
Storage: a new bottle gets its own disk of 64 GB by default (less when the disk has
less free): an APFS sparse bundle bottles/<name>.sparsebundle mounted at bottles/<name>,
so Windows sees a C: drive of that size and it only takes the space actually written.
`--storage unlimited` makes a plain folder instead (the original layout). `set storage`
resizes an image (shrinking only above what is used), moves a folder bottle into a new
image, or with `unlimited` moves an image bottle back into a folder; none of these run
while programs are running in the bottle. Images are mounted on demand (after a reboot).
Location: `--location <folder>` keeps the bottle in <folder>/<name> (or <folder>/<name>.sparsebundle)
instead of the bottles folder, e.g. on an external drive; bottles/<name> (or <name>.sparsebundle)
links to it and bottles/<name>.location records where it is. While that drive is not connected
the bottle is listed as unavailable. Folder bottles need APFS or Mac OS Extended; on exFAT, FAT,
NTFS or a network share use a disk image (--storage <GB>). `set location` copies the bottle there,
verifies the copy, switches over and deletes the original (`default` moves it back).
An image bottle on another drive stays mounted once used, which keeps that drive from being
ejected: `cross bottle eject <name>` unmounts it until the bottle is used again. `find` looks
through every connected local drive (3 folder levels deep) or the given folders for bottle
folders and .sparsebundle images (looked into read-only); `add` lists one in the bottles folder.
CROSS_BOTTLES=<folder> uses another bottles folder (downloads stay where they are).
Performance settings (cross.json "performance") apply to programs started afterwards; change
sync and retina only while nothing runs in the bottle. metalfx (D3DMetal bottles) sets
D3DM_ENABLE_METALFX=1 and D3DM_VENDOR_ID=0x10DE, puts nvngx.dll + nvapi64.dll in system32 and
sets HKLM\\Software\\NVIDIA Corporation\\Global\\NGXCore\\FullPath; games that offer DLSS then get
MetalFX upscaling (and frame generation on macOS 26+ where the game's DLSS-G runs). Files and
registry values are checked before every launch. The shader cache lives in
$(getconf DARWIN_USER_CACHE_DIR)d3dm/<exe name>/, one folder per executable name, shared by
all bottles; clearing it makes the next start rebuild shaders (Apple's advice for a game that
stopped booting).
Stores: steam, epic (Epic Games Store), gog (GOG Galaxy), battlenet (Battle.net). Installers
are cached in downloads/<store>/; install and installer output goes to
~/Library/Logs/Gamify/<bottle>/. Programs: shortcuts are read from the Start Menu and Desktop
folders of the bottle; entries added by hand (or found after an install that made no shortcut)
are kept in bottles/<name>/programs.json. A program inside a Steam library (steamapps/common)
is launched through Steam (steam://rungameid/<appid>) unless it is given arguments.
`steam check` runs src/steam-probe/steam-probe.exe with a game's steam_api64.dll as Spacewar
(app 480) while Steam runs, and repairs Steam's ActiveProcess pid when it is stale (unless --no-fix).
Runtimes: winecx (default) and winecx-full (same Wine + GStreamer, SDL2, MoltenVK),
both in runtimes/; a bottle keeps the runtime it was created with.
The project root is found by walking up from the binary (or set CROSS_ROOT).
Debugging mode (cross.json "debug") applies to programs started afterwards (Steam games: after
Steam restarts): MTL_HUD_LOG_ENABLED=1 and, instead of -all,
WINEDEBUG=\(Debug.wineDebug).
Honoured from the caller's environment: WINEDEBUG (default -all), WINECX_GRAPHICS (overrides
cross.json), D3DMETAL_HOME (runtimes/d3dmetal), and any variable a performance setting decides
(WINEESYNC/WINEMSYNC as a pair, MTL_HUD_ENABLED, ROSETTA_ADVERTISE_AVX, D3DM_*): a non-empty
value in the caller's environment wins over the bottle's setting.
"""

func fail(_ message: String) -> Never {
    warn(message)
    exit(1)
}

func requireArg(_ args: [String], _ index: Int, _ what: String) -> String {
    guard index < args.count else { fail("missing \(what)\n\n" + usage) }
    return args[index]
}

/// `--storage` / `set storage` values: whole GB, or unlimited (nil: a plain folder).
func parseStorage(_ value: String) -> Int? {
    if ["unlimited", "none", "folder"].contains(value.lowercased()) { return nil }
    let digits = value.lowercased().hasSuffix("g") ? String(value.dropLast()) : value
    guard let gb = Int(digits.hasSuffix("gb") ? String(digits.dropLast(2)) : digits), gb > 0 else {
        fail("storage must be a whole number of GB or 'unlimited', not '\(value)'")
    }
    return gb
}

/// `--location` / `set location` values: a folder, or nil for the bottles folder.
func parseLocation(_ value: String) -> URL? {
    if ["default", "none", "-"].contains(value.lowercased()) { return nil }
    return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
}

func storageText(_ bottle: Bottle) -> String { bottle.storageText }

/// on/off values of `bottle set`.
func parseSwitch(_ value: String, _ key: String) -> Bool {
    switch value.lowercased() {
    case "on", "yes", "true", "1": return true
    case "off", "no", "false", "0": return false
    default: fail("\(key) must be on or off, not '\(value)'")
    }
}

func main() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        print(usage)
        exit(1)
    }
    args.removeFirst()
    if ["-h", "--help", "help"].contains(command) {
        print(usage)
        return
    }

    let project = try Project.locate()

    func loadBottle(_ name: String) throws -> (Runtime, Bottle) {
        try Runtime.loadBottle(name, in: project)
    }

    switch command {
    case "bottle":
        let sub = requireArg(args, 0, "bottle subcommand")
        switch sub {
        case "create":
            let name = requireArg(args, 1, "bottle name")
            var config = BottleConfig(runtime: Runtime.preferred(in: project))
            var storageGB: Int?? = nil   // nil: not given, the default for the location
            var location: URL? = nil
            var i = 2
            while i < args.count {
                switch args[i] {
                case "--runtime":
                    config.runtime = requireArg(args, i + 1, "runtime"); i += 2
                case "--graphics":
                    let g = requireArg(args, i + 1, "graphics")
                    guard let graphics = Graphics(rawValue: g) else { fail("unknown graphics '\(g)' (\(Graphics.list))") }
                    config.graphics = graphics; i += 2
                case "--storage":
                    storageGB = .some(parseStorage(requireArg(args, i + 1, "storage size"))); i += 2
                case "--location":
                    location = parseLocation(requireArg(args, i + 1, "location folder")); i += 2
                default: fail("unknown option '\(args[i])'")
                }
            }
            guard Runtime.isKnown(config.runtime) else {
                fail("unknown runtime '\(config.runtime)' (\(Runtime.known.joined(separator: "|")))")
            }
            let runtime = Runtime(project: project, name: config.runtime)
            let home = try runtime.checkLocation(location)
            let sizeGB: Int? = storageGB ?? Runtime.defaultStorageGB(project: project, home: home)
            let bottle = try runtime.createBottle(name: name, config: config, storageGB: sizeGB, location: home)
            let status = try runWaiting(try runtime.wineboot(for: bottle))
            guard status == 0 else { fail("wineboot --init failed with status \(status)") }
            for line in try runtime.applyPerformance(to: bottle) { print(line) }
            let storage = sizeGB.map { "\($0) GB disk image" } ?? "folder"
            print("bottle '\(name)' (\(config.runtime), \(config.graphics.rawValue), \(storage)) ready at \(bottle.location?.path ?? bottle.prefix.path)")

        case "list":
            for b in try Bottle.list(in: project) {
                let graphics = Runtime.isKnown(b.config.runtime) ? b.config.graphics.rawValue : "-"
                func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s + " " : s.padding(toLength: n, withPad: " ", startingAt: 0) }
                let location = b.location.map { "  (in \($0.deletingLastPathComponent().path))" } ?? ""
                print(pad(b.name, 12) + pad(b.config.runtime, 12) + pad(graphics, 9) + storageText(b) + location)
            }

        case "show":
            let name = requireArg(args, 1, "bottle name")
            guard let b = try Bottle.list(in: project).first(where: { $0.name == name }) else {
                fail("no bottle '\(name)' in \(project.bottles.path)")
            }
            b.showLines(in: project).forEach { print($0) }

        case "set":
            let name = requireArg(args, 1, "bottle name")
            var key = requireArg(args, 2, "setting")
            if key.hasPrefix("--") { key.removeFirst(2) }
            let value = requireArg(args, 3, "value")
            var bottle = try Bottle.load(name: name, in: project)
            if key == "location" {
                let runtime = try Runtime.forBottle(bottle, project: project)
                bottle = try runtime.moveBottle(bottle, to: parseLocation(value), progress: { print($0) })
                print("\(name): now in \(bottle.home(in: project).path) (\(storageText(bottle)))")
                return
            }
            if key == "storage" {
                let runtime = try Runtime.forBottle(bottle, project: project)
                let progress: (String) -> Void = { print($0) }
                switch (parseStorage(value), bottle.image) {
                case (nil, nil):
                    print("\(name) already is a folder bottle (no size limit)")
                case (nil, _?):
                    bottle = try runtime.moveToFolder(bottle, progress: progress)
                    print("\(name): moved into a folder (no size limit)")
                case (let gb?, nil):
                    bottle = try runtime.moveToImage(bottle, sizeGB: gb, progress: progress)
                    print("\(name): moved into a \(gb) GB disk image (\(storageText(bottle)))")
                case (let gb?, _?):
                    bottle = try runtime.resizeStorage(bottle, to: gb)
                    print("\(name): disk resized to \(gb) GB (\(storageText(bottle)))")
                }
                return
            }
            switch key.lowercased() {
            case "graphics":
                guard let g = Graphics(rawValue: value) else { fail("unknown graphics '\(value)' (\(Graphics.list))") }
                try Runtime.forBottle(bottle, project: project).checkGraphics(g)
                bottle.config.graphics = g
            case "sync":
                guard let mode = SyncMode(rawValue: value.lowercased()) else { fail("sync must be auto, esync or msync, not '\(value)'") }
                bottle.config.performance.sync = mode
            case "metalfx", "dlss":
                bottle.config.performance.metalfx = parseSwitch(value, key)
            case "avx":
                bottle.config.performance.avx = parseSwitch(value, key)
            case "raytracing", "dxr":
                bottle.config.performance.raytracing = value.lowercased() == "default" ? nil : parseSwitch(value, key)
            case "maxfps", "fps":
                if ["off", "none", "default", "0"].contains(value.lowercased()) {
                    bottle.config.performance.maxFPS = nil
                } else {
                    guard let n = Int(value), n > 0 else { fail("maxfps must be a positive number or off, not '\(value)'") }
                    bottle.config.performance.maxFPS = n
                }
            case "debug", "debugging":
                bottle.config.debug = parseSwitch(value, key)
            case "hud":
                bottle.config.performance.hud = parseSwitch(value, key)
            case "retina":
                bottle.config.performance.retina = parseSwitch(value, key)
            case "vendor", "vendorid":
                if value.lowercased() == "default" {
                    bottle.config.performance.vendorID = nil
                } else {
                    guard let id = PerformanceSettings.parseVendorID(value) else { fail("vendor must be a hex id like 0x10DE or default, not '\(value)'") }
                    bottle.config.performance.vendorID = id
                }
            default: fail("unknown setting '\(key)' (graphics, storage, location, sync, metalfx, avx, raytracing, maxfps, hud, retina, vendor, debug)")
            }
            try bottle.saveConfig()
            print("\(name): \(key) = \(value)")
            // files and registry values (nvngx.dll, NGXCore, RetinaMode); env vars need nothing
            if ["graphics", "metalfx", "dlss", "retina"].contains(key.lowercased()) {
                let runtime = try Runtime.forBottle(bottle, project: project)
                for line in try runtime.applyPerformance(to: bottle, force: true) { print("\(name): \(line)") }
            }

        case "delete":
            let name = requireArg(args, 1, "bottle name")
            // from the listing, so a bottle whose image cannot be mounted can be deleted too
            guard let bottle = try Bottle.list(in: project).first(where: { $0.name == name }) else {
                fail("no bottle '\(name)' in \(project.bottles.path)")
            }
            let unreachable = bottle.isUnreachable
            try Runtime(project: project, name: bottle.config.runtime).deleteBottle(bottle)
            if unreachable, let location = bottle.location {
                print("removed '\(name)' from the bottles folder; its data at \(location.path) could not be reached and was not touched")
            } else {
                print("deleted bottle '\(name)'")
            }

        case "eject":
            let name = requireArg(args, 1, "bottle name")
            guard let bottle = try Bottle.list(in: project).first(where: { $0.name == name }) else {
                fail("no bottle '\(name)' in \(project.bottles.path)")
            }
            try Runtime(project: project, name: bottle.config.runtime).ejectBottle(bottle)
            print("ejected '\(name)'; it is mounted again when it is used")

        case "forget":
            let name = requireArg(args, 1, "bottle name")
            guard let bottle = try Bottle.list(in: project).first(where: { $0.name == name }) else {
                fail("no bottle '\(name)' in \(project.bottles.path)")
            }
            try Runtime(project: project, name: bottle.config.runtime).forgetBottle(bottle)
            print("removed '\(name)' from the list; its files stay in \(bottle.location?.path ?? "?")")

        case "find":
            let folders = args.count > 1 ? args.dropFirst().map { parseLocation($0) ?? project.bottles } : Bottle.searchableVolumes()
            print("searching " + (folders.isEmpty ? "(no connected drives)" : folders.map(\.path).joined(separator: ", ")))
            for f in Bottle.find(in: folders, project: project) {
                let kind = f.isImage ? "image " : "folder"
                let what = f.config.map { "\($0.runtime), \($0.graphics.rawValue)" } ?? "no cross.json"
                let state = f.registeredAs.map { "listed as '\($0)'" } ?? "not listed: cross bottle add '\(f.url.path)'"
                print("\(kind)  \(f.url.path)  (\(what))  \(state)")
            }

        case "add":
            let path = URL(fileURLWithPath: (requireArg(args, 1, "bottle folder or image") as NSString).expandingTildeInPath).standardizedFileURL
            var name: String? = nil
            if let i = args.firstIndex(of: "--name") { name = requireArg(args, i + 1, "name") }
            let runtime = Runtime(project: project)
            let bottle = try runtime.addBottle(at: path, name: name)
            print("added '\(bottle.name)' (\(bottle.config.runtime), \(storageText(bottle))) from \(bottle.location?.path ?? path.path)")

        default:
            fail("unknown bottle subcommand '\(sub)'\n\n" + usage)
        }

    case "run":
        let (runtime, bottle) = try loadBottle(requireArg(args, 0, "bottle name"))
        let exe = URL(fileURLWithPath: requireArg(args, 1, "exe path"))
        execReplacing(try runtime.runExe(exe, arguments: Array(args.dropFirst(2)), in: bottle))

    case "cmd":
        let (runtime, bottle) = try loadBottle(requireArg(args, 0, "bottle name"))
        execReplacing(try runtime.wineCommand(["cmd"] + args.dropFirst(), in: bottle))

    case "cfg":
        let (runtime, bottle) = try loadBottle(requireArg(args, 0, "bottle name"))
        execReplacing(try runtime.wineCommand(["winecfg"], in: bottle))

    case "steam":
        if args.first == "check", args.count >= 2 {
            let (runtime, bottle) = try loadBottle(args[1])
            print(Steam.check(in: bottle, runtime: runtime, fix: !args.contains("--no-fix")).text)
            return
        }
        let (runtime, bottle) = try loadBottle(requireArg(args, 0, "bottle name"))
        execReplacing(try runtime.steam(in: bottle, arguments: Array(args.dropFirst())))

    case "store":
        let sub = requireArg(args, 0, "store subcommand")
        func store(_ index: Int) -> Store {
            let text = requireArg(args, index, "store")
            guard let store = Store.named(text) else {
                fail("unknown store '\(text)' (\(Store.all.map(\.id).joined(separator: "|")))")
            }
            return store
        }
        switch sub {
        case "list":
            let bottle = args.count > 1 ? try loadBottle(args[1]).1 : nil
            let processes = bottle.map { Steam.bottleProcesses(in: $0) } ?? []
            for s in Store.all {
                var line = s.id.padding(toLength: 11, withPad: " ", startingAt: 0) + s.name.padding(toLength: 18, withPad: " ", startingAt: 0)
                if let bottle {
                    line += !s.isInstalled(in: bottle) ? "not installed" : (s.running(in: processes).isEmpty ? "installed" : "running")
                } else {
                    line += s.cachedInstaller(in: project).map { "installer cached: \($0.lastPathComponent)" } ?? "installer not downloaded"
                }
                print(line)
                print("           " + s.notes)
                if let issue = s.knownIssue { print("           known issue: " + issue) }
            }

        case "install":
            let (runtime, bottle) = try loadBottle(requireArg(args, 1, "bottle name"))
            let s = store(2)
            let started = Date()
            let say: (String) -> Void = { print("\(s.id): \($0)") }
            if s.isInstalled(in: bottle) && !(s.isSteam && !Steam.isBootstrapped(in: bottle)) {
                say("already installed in '\(bottle.name)'")
                return
            }
            let setup = try blockingAwait { try await s.installer(in: project, say: { print("\(s.id): \($0)") }) }
            let log = newJobLog(bottle: bottle.name, label: "\(s.id)-setup")
            say("installing (log: \(log.path))")
            let inv = s.isSteam ? try runtime.steamInstaller(setup, in: bottle) : try runtime.storeInstaller(s, installer: setup, in: bottle)
            let ended = try runLogged(inv, log: log)
            if let ended, ended != .exited(0) { say("installer ended with \(ended)") }
            if ended != nil, s.installerHandsOff {
                say("the installer continues in its own window; waiting for \(s.name) to start")
                let deadline = Date().addingTimeInterval(Store.handsOffTimeout)
                while !(s.isInstalled(in: bottle) && s.isRunning(in: bottle)) && Date() < deadline {
                    Thread.sleep(forTimeInterval: 2)
                }
            }
            guard s.isInstalled(in: bottle) else {
                fail("\(s.name) is not installed in '\(bottle.name)' after its installer (\(ended?.description ?? "running")); see \(log.path)")
            }
            if s.isSteam {
                try runtime.bootstrapSteamWaiting(in: bottle, log: newJobLog(bottle: bottle.name, label: "steam-bootstrap"), say: say)
            }
            say(String(format: "installed in '%@' in %.0f s; start it with: cross store launch %@ %@",
                       bottle.name, Date().timeIntervalSince(started), bottle.name, s.id))
            if let issue = s.knownIssue { say("known issue: \(issue)") }

        case "launch":
            let (runtime, bottle) = try loadBottle(requireArg(args, 1, "bottle name"))
            let s = store(2)
            execReplacing(try runtime.storeLaunch(s, in: bottle, arguments: Array(args.dropFirst(3))))

        default:
            fail("unknown store subcommand '\(sub)'\n\n" + usage)
        }

    case "install":
        let (runtime, bottle) = try loadBottle(requireArg(args, 0, "bottle name"))
        let file = URL(fileURLWithPath: requireArg(args, 1, "installer path")).standardizedFileURL
        guard FileManager.default.fileExists(atPath: file.path) else { fail("no such file: \(file.path)") }
        let before = Programs.snapshot(of: bottle)
        let log = newJobLog(bottle: bottle.name, label: "install-\(file.deletingPathExtension().lastPathComponent)")
        print("running \(file.lastPathComponent) in '\(bottle.name)' (log: \(log.path))")
        let started = Date()
        let ended = try runLogged(try runtime.installer(file, arguments: Array(args.dropFirst(2)), in: bottle), log: log)
        print(String(format: "installer ended with %@ after %.0f s", ended?.description ?? "?", Date().timeIntervalSince(started)))
        let added = Programs.recordInstall(since: before, in: bottle)
        if added.isEmpty {
            print("no new programs found (no new shortcut, no new exe under Program Files); add one with `cross programs \(bottle.name) add <exe>`")
        }
        for p in added {
            print("new program: \(p.name)  \(p.exe)" + (p.source == .shortcut ? "  (shortcut)" : "  (added to programs.json)"))
        }

    case "programs":
        let (runtime, bottle) = try loadBottle(requireArg(args, 0, "bottle name"))
        let sub = args.count > 1 ? args[1] : "list"
        switch sub {
        case "list":
            for p in Programs.list(in: bottle) {
                let argText = p.arguments.isEmpty ? "" : " " + p.arguments
                print(p.name.padding(toLength: 28, withPad: " ", startingAt: 0) + p.source.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0) + p.exe + argText)
            }
        case "launch":
            let name = requireArg(args, 2, "program name")
            guard let p = Programs.find(name, in: bottle) else { fail("no program '\(name)' in '\(bottle.name)' (see cross programs \(bottle.name))") }
            guard let exe = Programs.unixURL(of: p.exe, in: bottle), FileManager.default.fileExists(atPath: exe.path) else {
                fail("\(p.exe) does not exist in '\(bottle.name)'")
            }
            let (inv, steamGame) = try runtime.programLaunch(exe, arguments: p.argumentList + args.dropFirst(3), in: bottle)
            if let steamGame { print("starting \(steamGame.name) through Steam (\(steamGame.runURL))") }
            execReplacing(inv)
        case "add":
            let path = URL(fileURLWithPath: requireArg(args, 2, "exe path")).standardizedFileURL
            guard FileManager.default.fileExists(atPath: path.path) else { fail("no such file: \(path.path)") }
            var name = path.deletingPathExtension().lastPathComponent
            var rest = Array(args.dropFirst(3))
            if let i = rest.firstIndex(of: "--name") {
                name = requireArg(rest, i + 1, "name")
                rest.removeSubrange(i...(i + 1))
            }
            let argText = rest.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
            let p = Program(name: name, exe: Programs.windowsPath(of: path, in: bottle), arguments: argText, source: .manual)
            try Programs.add(p, to: bottle)
            print("added \(p.name): \(p.exe)\(argText.isEmpty ? "" : " " + argText)")
        case "remove":
            let name = requireArg(args, 2, "program name")
            guard let p = Programs.find(name, in: bottle) else { fail("no program '\(name)' in '\(bottle.name)'") }
            try Programs.remove(p, from: bottle)
            print("removed \(p.name)" + (p.source == .shortcut ? " from the list (its shortcut stays in the bottle)" : ""))
        default:
            fail("unknown programs subcommand '\(sub)'\n\n" + usage)
        }

    case "kill":
        let (runtime, bottle) = try loadBottle(requireArg(args, 0, "bottle name"))
        _ = try? runWaiting(try runtime.kill(bottle))
        print("killed bottle '\(bottle.name)'")

    case "env":
        let (runtime, bottle) = try loadBottle(requireArg(args, 0, "bottle name"))
        let export = args.contains("--export")
        for line in Runtime.environmentLines(try runtime.environment(for: bottle), export: export) {
            print(line)
        }

    case "debug":
        let sub = requireArg(args, 0, "debug subcommand")
        let bottle = try Bottle.load(name: requireArg(args, 1, "bottle name"), in: project)
        func option(_ name: String) -> String? {
            args.firstIndex(of: name).map { requireArg(args, $0 + 1, String(name.dropFirst(2))) }
        }
        func path(_ text: String) -> URL { URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL }
        switch sub {
        case "export":
            var hours = 24.0
            if let text = option("--since") {
                guard let h = Double(text), h > 0 else { fail("--since takes a number of hours, not '\(text)'") }
                hours = h
            }
            let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            var out = option("--out").map(path) ?? desktop.appendingPathComponent(Debug.defaultExportName(bottle: bottle.name))
            if out.pathExtension.lowercased() != "zip" { out.appendPathExtension("zip") }
            let result = try Debug.export(bottle: bottle, project: project, to: out, sinceHours: hours,
                                          progress: { print("debug: \($0)") })
            result.summary.forEach { print("  " + $0) }
            if !result.notes.isEmpty {
                print("not included (see the READMEs):")
                result.notes.forEach { print("  " + $0) }
            }
            print("wrote \(result.zip.path) (\(ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file)))")
        case "sample":
            let folder = option("--out").map(path) ?? Debug.logsRoot.appendingPathComponent(bottle.name)
            print("sampling for \(Debug.sampleSeconds) s ...")
            let result = Debug.sample(bottle: bottle, into: folder)
            if let t = result.target { print("game: \(t.program) (pid \(t.pid))") }
            result.notes.forEach { print("note: " + $0) }
            result.files.forEach { print("wrote \($0.path)") }
        default:
            fail("unknown debug subcommand '\(sub)'\n\n" + usage)
        }

    case "cache":
        let sub = requireArg(args, 0, "cache subcommand")
        guard sub == "clear" else { fail("unknown cache subcommand '\(sub)'\n\n" + usage) }
        let bottle = try Bottle.load(name: requireArg(args, 1, "bottle name"), in: project)
        if args.count > 2 {
            let exe = ShaderCache.exeName(args[2])
            guard let entry = ShaderCache.entry(forExe: exe) else {
                fail("no shader cache for \(exe) in \(ShaderCache.root.path)")
            }
            try ShaderCache.clear(exe: exe)
            print("cleared the shader cache of \(entry.name) (\(entry.sizeText)); the next start rebuilds it")
            return
        }
        let entries = ShaderCache.list()
        let programExes = Set(Programs.list(in: bottle).map { ShaderCache.exeName($0.exe).lowercased() })
        print("D3DMetal shader cache: \(ShaderCache.root.path) (shared by all bottles)")
        if entries.isEmpty { print("  (empty)") }
        for e in entries {
            let mark = programExes.contains(e.name.lowercased()) ? "  (a program in '\(bottle.name)')" : ""
            print("  " + e.name.padding(toLength: 40, withPad: " ", startingAt: 0) + e.sizeText + mark)
        }
        print("clear one with: cross cache clear \(bottle.name) <exe name>")

    default:
        fail("unknown command '\(command)'\n\n" + usage)
    }
}

do {
    try main()
} catch {
    fail("\(error)")
}
