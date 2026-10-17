import Foundation
import CrossCore

let usage = """
cross - bottle manager and launcher for the winecx runtimes

  cross bottle create <name> [--runtime winecx|winecx-full] [--graphics d3dmetal|wined3d]
  cross bottle list
  cross bottle set <name> graphics <d3dmetal|wined3d>
  cross bottle delete <name>
  cross run   <bottle> <exe> [args...]     run a Windows exe (cwd = the exe's directory)
  cross cmd   <bottle> [args...]           run cmd.exe, e.g. cross cmd cx /c ver
  cross cfg   <bottle>                     open winecfg
  cross steam <bottle> [args...]           install the webhelper shim, clear stale locks, launch Steam
  cross kill  <bottle>                     wineserver -k
  cross env   <bottle> [--export]          print the environment the bottle runs with

Bottles live in bottles/<name>; per-bottle settings in bottles/<name>/cross.json.
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
            var i = 2
            while i < args.count {
                switch args[i] {
                case "--runtime":
                    config.runtime = requireArg(args, i + 1, "runtime"); i += 2
                case "--graphics":
                    let g = requireArg(args, i + 1, "graphics")
                    guard let graphics = Graphics(rawValue: g) else { fail("unknown graphics '\(g)' (d3dmetal|wined3d)") }
                    config.graphics = graphics; i += 2
                default: fail("unknown option '\(args[i])'")
                }
            }
            guard Runtime.isKnown(config.runtime) else {
                fail("unknown runtime '\(config.runtime)' (\(Runtime.known.joined(separator: "|")))")
            }
            let runtime = Runtime(project: project, name: config.runtime)
            let bottle = try runtime.createBottle(name: name, config: config)
            let status = try runWaiting(try runtime.wineboot(for: bottle))
            guard status == 0 else { fail("wineboot --init failed with status \(status)") }
            print("bottle '\(name)' (\(config.runtime), \(config.graphics.rawValue)) ready at \(bottle.prefix.path)")

        case "list":
            for b in try Bottle.list(in: project) {
                let graphics = Runtime.isKnown(b.config.runtime) ? b.config.graphics.rawValue : "-"
                print(String(format: "%-12@ %-10@ %@", b.name as NSString, b.config.runtime as NSString, graphics as NSString))
            }

        case "set":
            let name = requireArg(args, 1, "bottle name")
            let key = requireArg(args, 2, "setting")
            let value = requireArg(args, 3, "value")
            var bottle = try Bottle.load(name: name, in: project)
            switch key {
            case "graphics":
                guard let g = Graphics(rawValue: value) else { fail("unknown graphics '\(value)' (d3dmetal|wined3d)") }
                bottle.config.graphics = g
            default: fail("unknown setting '\(key)' (graphics)")
            }
            try bottle.saveConfig()
            print("\(name): \(key) = \(value)")

        case "delete":
            let name = requireArg(args, 1, "bottle name")
            let bottle = try Bottle.load(name: name, in: project)
            if let runtime = try? Runtime.forBottle(bottle, project: project) {
                _ = try? runWaiting(try runtime.kill(bottle), quiet: true)
            }
            try FileManager.default.removeItem(at: bottle.prefix)
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
