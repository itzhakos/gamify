import Foundation
import CrossCore

let usage = """
cross - bottle manager and launcher for the winecx runtimes

  cross bottle create <name> [--runtime winecx|winecx-full] [--graphics d3dmetal|wined3d]
                           [--storage <GB>|unlimited]
  cross bottle list
  cross bottle set <name> graphics <d3dmetal|wined3d>
  cross bottle set <name> storage <GB>|unlimited     (also: --storage <GB>)
  cross bottle delete <name>
  cross run   <bottle> <exe> [args...]     run a Windows exe (cwd = the exe's directory)
  cross cmd   <bottle> [args...]           run cmd.exe, e.g. cross cmd cx /c ver
  cross cfg   <bottle>                     open winecfg
  cross steam <bottle> [args...]           install the webhelper shim, clear stale locks, launch Steam
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

Bottles live in bottles/<name>; per-bottle settings in bottles/<name>/cross.json.
Storage: a new bottle gets its own disk of 64 GB by default (less when the disk has
less free): an APFS sparse bundle bottles/<name>.sparsebundle mounted at bottles/<name>,
so Windows sees a C: drive of that size and it only takes the space actually written.
`--storage unlimited` makes a plain folder instead (the original layout). `set storage`
resizes an image (shrinking only above what is used), moves a folder bottle into a new
image, or with `unlimited` moves an image bottle back into a folder; none of these run
while programs are running in the bottle. Images are mounted on demand (after a reboot).
Stores: steam, epic (Epic Games Store), gog (GOG Galaxy), battlenet (Battle.net). Installers
are cached in downloads/<store>/; install and installer output goes to
~/Library/Logs/Gamify/<bottle>/. Programs: shortcuts are read from the Start Menu and Desktop
folders of the bottle; entries added by hand (or found after an install that made no shortcut)
are kept in bottles/<name>/programs.json.
Runtimes: winecx (default) and winecx-full (same Wine + GStreamer, SDL2, MoltenVK),
both in runtimes/; a bottle keeps the runtime it was created with.
The project root is found by walking up from the binary (or set CROSS_ROOT).
Honoured from the caller's environment: WINEDEBUG (default -all), WINEESYNC (1),
WINEMSYNC (passthrough), MTL_HUD_ENABLED (0), WINECX_GRAPHICS (overrides cross.json),
D3DMETAL_HOME (runtimes/d3dmetal).
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

/// The storage column of `cross bottle list`.
func storageText(_ bottle: Bottle) -> String {
    if let error = bottle.storageError { return "unavailable: \(error)" }
    guard bottle.isImageBacked else { return "folder (no limit)" }
    guard let usage = bottle.storageUsage else { return "image, not mounted" }
    return "image \(formatGB(usage.used)) used of \(formatGB(usage.total))"
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
            var storageGB: Int? = Runtime.defaultStorageGB(project: project)
            var i = 2
            while i < args.count {
                switch args[i] {
                case "--runtime":
                    config.runtime = requireArg(args, i + 1, "runtime"); i += 2
                case "--graphics":
                    let g = requireArg(args, i + 1, "graphics")
                    guard let graphics = Graphics(rawValue: g) else { fail("unknown graphics '\(g)' (d3dmetal|wined3d)") }
                    config.graphics = graphics; i += 2
                case "--storage":
                    storageGB = parseStorage(requireArg(args, i + 1, "storage size")); i += 2
                default: fail("unknown option '\(args[i])'")
                }
            }
            guard Runtime.isKnown(config.runtime) else {
                fail("unknown runtime '\(config.runtime)' (\(Runtime.known.joined(separator: "|")))")
            }
            let runtime = Runtime(project: project, name: config.runtime)
            let bottle = try runtime.createBottle(name: name, config: config, storageGB: storageGB)
            let status = try runWaiting(try runtime.wineboot(for: bottle))
            guard status == 0 else { fail("wineboot --init failed with status \(status)") }
            let storage = storageGB.map { "\($0) GB disk image" } ?? "folder"
            print("bottle '\(name)' (\(config.runtime), \(config.graphics.rawValue), \(storage)) ready at \(bottle.prefix.path)")

        case "list":
            for b in try Bottle.list(in: project) {
                let graphics = Runtime.isKnown(b.config.runtime) ? b.config.graphics.rawValue : "-"
                func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s + " " : s.padding(toLength: n, withPad: " ", startingAt: 0) }
                print(pad(b.name, 12) + pad(b.config.runtime, 12) + pad(graphics, 9) + storageText(b))
            }

        case "set":
            let name = requireArg(args, 1, "bottle name")
            var key = requireArg(args, 2, "setting")
            if key.hasPrefix("--") { key.removeFirst(2) }
            let value = requireArg(args, 3, "value")
            var bottle = try Bottle.load(name: name, in: project)
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
            switch key {
            case "graphics":
                guard let g = Graphics(rawValue: value) else { fail("unknown graphics '\(value)' (d3dmetal|wined3d)") }
                bottle.config.graphics = g
            default: fail("unknown setting '\(key)' (graphics, storage)")
            }
            try bottle.saveConfig()
            print("\(name): \(key) = \(value)")

        case "delete":
            let name = requireArg(args, 1, "bottle name")
            // from the listing, so a bottle whose image cannot be mounted can be deleted too
            guard let bottle = try Bottle.list(in: project).first(where: { $0.name == name }) else {
                fail("no bottle '\(name)' in \(project.bottles.path)")
            }
            try Runtime(project: project, name: bottle.config.runtime).deleteBottle(bottle)
            print("deleted bottle '\(name)'")

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
            // an installer that starts its launcher may stay around with it (Battle.net)
            let ended = try runLogged(inv, log: log, done: { s.isInstalled(in: bottle) && s.isRunning(in: bottle) })
            if let ended, ended != .exited(0) { say("installer ended with \(ended)") }
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
            execReplacing(try runtime.runExe(exe, arguments: p.argumentList + args.dropFirst(3), in: bottle))
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

    default:
        fail("unknown command '\(command)'\n\n" + usage)
    }
}

do {
    try main()
} catch {
    fail("\(error)")
}
