import Foundation

/// Everything that has to happen before launching steam.exe in a bottle.
public enum Steam {
    /// Valve's official installer (NSIS, Valve-signed); `/S` installs silently.
    public static let installerURL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    /// Where the installer is cached: downloads/steam/SteamSetup.exe.
    public static func installerFile(in project: Project) -> URL {
        project.downloads.appendingPathComponent("steam/SteamSetup.exe")
    }

    public static func isInstalled(in bottle: Bottle) -> Bool {
        FileManager.default.fileExists(atPath: bottle.steamDir.appendingPathComponent("steam.exe").path)
    }

    /// SteamSetup.exe /S only installs the ~7 MB bootstrapper; the client (bin/cef with
    /// the webhelper, ~1.7 GB) arrives on the first launch without -noverifyfiles.
    public static func isBootstrapped(in bottle: Bottle) -> Bool {
        let cefRoot = bottle.steamDir.appendingPathComponent("bin/cef")
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: cefRoot.path)) ?? []
        return dirs.contains { name in
            name.hasPrefix("cef.win") && FileManager.default.fileExists(
                atPath: cefRoot.appendingPathComponent(name).appendingPathComponent("steamwebhelper.exe").path)
        }
    }

    /// Steam writes "Startup - webhelper launched" here once the bootstrapped client
    /// runs (after its self-updates and restarts).
    public static func webhelperLog(in bottle: Bottle) -> URL {
        bottle.steamDir.appendingPathComponent("logs/webhelper.txt")
    }

    /// Replace Steam's steamwebhelper.exe in every bin/cef/cef.win* dir with our shim
    /// (adds --disable-gpu --single-process; Valve's CEF paints black on Wine/macOS).
    /// Valve's binary is kept as steamwebhelper_real.exe. Steam must then run with
    /// -noverifyfiles or it restores the original on every start.
    public static func installShim(in bottle: Bottle, project: Project) throws {
        let fm = FileManager.default
        let shim = project.webhelperShim
        if !fm.fileExists(atPath: shim.path) {
            warn("building the webhelper shim (make -C src/webhelper-shim)")
            let status = try runWaiting(program: "/usr/bin/make", arguments: ["-C", project.webhelperShimDir.path],
                                        environment: ProcessInfo.processInfo.environment)
            guard status == 0, fm.fileExists(atPath: shim.path) else { throw CrossError("could not build \(shim.path)") }
        }
        let shimData = try Data(contentsOf: shim)
        let cefRoot = bottle.steamDir.appendingPathComponent("bin/cef")
        let dirs = (try? fm.contentsOfDirectory(atPath: cefRoot.path)) ?? []
        for dirName in dirs.sorted() where dirName.hasPrefix("cef.win") {
            let dir = cefRoot.appendingPathComponent(dirName)
            let helper = dir.appendingPathComponent("steamwebhelper.exe")
            let real = dir.appendingPathComponent("steamwebhelper_real.exe")
            guard fm.fileExists(atPath: helper.path) else { continue }
            let size = (try? fm.attributesOfItem(atPath: helper.path)[.size] as? Int) ?? 0
            if size > 1_000_000 {   // Valve's binary, not our ~150 KB shim
                try? fm.removeItem(at: real)
                try fm.copyItem(at: helper, to: real)
            }
            guard fm.fileExists(atPath: real.path) else {
                warn("no real webhelper in \(dir.path)")
                continue
            }
            if (try? Data(contentsOf: helper)) != shimData {
                try? fm.removeItem(at: helper)
                try fm.copyItem(at: shim, to: helper)
            }
        }
    }

    /// After an unclean exit HKCU\Software\Valve\Steam\ActiveProcess\pid still holds
    /// the old Wine pid; Wine reuses low pids, so Steam thinks it is already running
    /// and quits after ~5 s. Reset it.
    public static func resetActiveProcess(in bottle: Bottle, runtime: Runtime, environment: [String: String]) throws {
        let reg = "REGEDIT4\n\n[HKEY_CURRENT_USER\\Software\\Valve\\Steam\\ActiveProcess]\n\"pid\"=dword:00000000\n"
        let file = bottle.prefix.appendingPathComponent(".steam-reset.reg")
        try reg.write(to: file, atomically: true, encoding: .utf8)
        _ = try? runWaiting(program: runtime.wine.path, arguments: ["regedit", file.path],
                            environment: environment, quiet: true)
    }

    /// Stale Chromium Singleton*/*.lock files under htmlcache make Steam start
    /// silently with no window. Mirrors `find ... -maxdepth 2 -delete`.
    public static func clearLocks(in bottle: Bottle) {
        let fm = FileManager.default
        let cache = bottle.userProfile.appendingPathComponent("AppData/Local/Steam/htmlcache")
        func sweep(_ dir: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: []) else { return }
            for item in items {
                let name = item.lastPathComponent
                if name.hasPrefix("Singleton") || name.hasSuffix(".lock") {
                    try? fm.removeItem(at: item)
                } else if depth < 2, (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    sweep(item, depth: depth + 1)
                }
            }
        }
        sweep(cache, depth: 1)
    }
}
