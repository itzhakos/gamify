import Foundation

/// The bottle operations behind each `cross` command, shared with the GUI. Each one
/// either does its work in place or returns the Invocation to start; the CLI execve()s
/// it, the app spawns it with spawnDetached.
extension Runtime {
    /// The Steam flags every launch needs: -noverifyfiles keeps the webhelper shim in
    /// place, CEF's sandbox does not work under Wine.
    public static let steamFlags = ["-noverifyfiles", "-no-cef-sandbox"]

    /// Loads a bottle this runtime instance drives and checks the runtime. Prefer
    /// `Runtime.loadBottle(_:in:)`, which picks the runtime from the bottle's config.
    public func loadBottle(_ name: String) throws -> Bottle {
        let bottle = try Bottle.load(name: name, in: project)
        guard bottle.config.runtime == self.name else {
            throw CrossError("bottle '\(name)' uses runtime '\(bottle.config.runtime)', not '\(self.name)'")
        }
        try check()
        return bottle
    }

    /// Creates bottles/<name> with its cross.json (and .runtime). The prefix itself is
    /// initialised by running `wineboot(for:)` afterwards. With `storageGB` the bottle
    /// gets its own disk image of that size (Storage.swift); nil makes a plain folder.
    public func createBottle(name: String, config: BottleConfig, storageGB: Int? = nil) throws -> Bottle {
        guard Runtime.isKnown(config.runtime) else {
            throw CrossError("cross only creates \(Runtime.known.joined(separator: "/")) bottles (unknown runtime '\(config.runtime)')")
        }
        guard config.runtime == self.name else {
            throw CrossError("runtime mismatch: creating a '\(config.runtime)' bottle with the '\(self.name)' runtime")
        }
        try Bottle.validate(name: name)
        try check()
        let prefix = project.bottles.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: prefix.path) else {
            throw CrossError("bottle '\(name)' already exists at \(prefix.path)")
        }
        guard let storageGB else {
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
            let bottle = Bottle(name: name, prefix: prefix, config: config)
            try bottle.saveConfig()
            return bottle
        }
        try Runtime.checkSize(storageGB, in: Runtime.storageRange(project: project), what: "bottle '\(name)'")
        let image = try createImage(for: name, prefix: prefix, sizeGB: storageGB)
        var config = config
        config.storage = BottleStorage(image: image.lastPathComponent, sizeGB: storageGB)
        let bottle = Bottle(name: name, prefix: prefix, config: config, image: image)
        do {
            try bottle.saveConfig()
        } catch {
            try? Bottle.delete(bottle)
            throw error
        }
        return bottle
    }

    public func wineboot(for bottle: Bottle, base: [String: String] = ProcessInfo.processInfo.environment) throws -> Invocation {
        Invocation(program: wine.path, arguments: ["wineboot", "--init"], environment: try environment(for: bottle, base: base))
    }

    /// `cross run`: wine <exe name> [args] with cwd = the exe's directory.
    public func runExe(_ exe: URL, arguments: [String], in bottle: Bottle,
                       base: [String: String] = ProcessInfo.processInfo.environment) throws -> Invocation {
        let exe = exe.standardizedFileURL
        return Invocation(program: wine.path, arguments: [exe.lastPathComponent] + arguments,
                          environment: try environment(for: bottle, base: base),
                          cwd: exe.deletingLastPathComponent().path)
    }

    /// `cross cmd` / `cross cfg`: a wine builtin (cmd, winecfg, ...) in the bottle.
    public func wineCommand(_ arguments: [String], in bottle: Bottle,
                            base: [String: String] = ProcessInfo.processInfo.environment) throws -> Invocation {
        Invocation(program: wine.path, arguments: arguments, environment: try environment(for: bottle, base: base))
    }

    /// `cross steam`: installs the webhelper shim, resets ActiveProcess, clears stale
    /// locks, then returns the steam.exe launch (blocks for the regedit run).
    public func steam(in bottle: Bottle, arguments: [String],
                      base: [String: String] = ProcessInfo.processInfo.environment) throws -> Invocation {
        let steamExe = bottle.steamDir.appendingPathComponent("steam.exe")
        guard FileManager.default.fileExists(atPath: steamExe.path) else {
            throw CrossError("Steam not installed in '\(bottle.name)'")
        }
        let env = try environment(for: bottle, base: base)
        try Steam.installShim(in: bottle, project: project)
        try Steam.resetActiveProcess(in: bottle, runtime: self, environment: env)
        Steam.clearLocks(in: bottle)
        return Invocation(program: wine.path, arguments: ["steam.exe"] + Runtime.steamFlags + arguments,
                          environment: env, cwd: bottle.steamDir.path)
    }

    /// Silent Steam install: wine SteamSetup.exe /S (cwd = the installer's directory).
    /// Steam bootstraps the full client on its first launch.
    public func steamInstaller(_ setup: URL, in bottle: Bottle,
                               base: [String: String] = ProcessInfo.processInfo.environment) throws -> Invocation {
        try runExe(setup, arguments: ["/S"], in: bottle, base: base)
    }

    /// First launch after SteamSetup.exe: steam.exe without -noverifyfiles, which makes
    /// the bootstrapper skip its download and show "Steam - Fatal Error". There is no
    /// bin/cef yet, so no shim: the client's windows paint black until Steam is shut
    /// down (`steamShutdown`) and started again with `steam(in:)`.
    public func steamBootstrap(in bottle: Bottle,
                               base: [String: String] = ProcessInfo.processInfo.environment) throws -> Invocation {
        let steamExe = bottle.steamDir.appendingPathComponent("steam.exe")
        guard FileManager.default.fileExists(atPath: steamExe.path) else {
            throw CrossError("Steam not installed in '\(bottle.name)'")
        }
        let env = try environment(for: bottle, base: base)
        try Steam.resetActiveProcess(in: bottle, runtime: self, environment: env)
        Steam.clearLocks(in: bottle)
        return Invocation(program: wine.path, arguments: ["steam.exe", "-no-cef-sandbox"],
                          environment: env, cwd: bottle.steamDir.path)
    }

    /// steam.exe -shutdown: asks the running Steam in the bottle to quit.
    public func steamShutdown(in bottle: Bottle,
                              base: [String: String] = ProcessInfo.processInfo.environment) throws -> Invocation {
        Invocation(program: wine.path, arguments: ["steam.exe", "-shutdown"],
                   environment: try environment(for: bottle, base: base), cwd: bottle.steamDir.path)
    }

    /// wineserver -w: returns once every process in the bottle has ended.
    public func waitForBottle(_ bottle: Bottle, base: [String: String] = ProcessInfo.processInfo.environment) throws -> Invocation {
        Invocation(program: wineserver.path, arguments: ["-w"], environment: try environment(for: bottle, base: base))
    }

    /// `cross kill`: wineserver -k for the bottle.
    public func kill(_ bottle: Bottle, base: [String: String] = ProcessInfo.processInfo.environment) throws -> Invocation {
        Invocation(program: wineserver.path, arguments: ["-k"], environment: try environment(for: bottle, base: base))
    }

    /// `cross env` lines: KEY=VALUE, or shell-quoted `export` lines, sorted by key.
    public static func environmentLines(_ env: [String: String], export: Bool) -> [String] {
        env.keys.sorted().map { key in
            let value = env[key]!
            if export {
                return "export \(key)=" + "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            return "\(key)=\(value)"
        }
    }
}
