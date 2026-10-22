import Foundation

/// A CrossOver-lineage Wine 10.0 build in runtimes/<name> (x86_64 under Rosetta)
/// paired with Apple D3DMetal. Two builds exist: `winecx` (the default) and
/// `winecx-full` (same Wine plus GStreamer, SDL2 and MoltenVK, docs/runtime-full.md).
/// This is scripts/winecx-env.sh expressed as a value: `environment(for:)` yields the
/// exact variables the script exports, on top of the caller's environment.
public struct Runtime {
    /// Runtime names `cross` can drive (builds under runtimes/).
    public static let known = ["winecx", "winecx-full"]
    public static let defaultName = "winecx"

    public let name: String
    public let project: Project
    /// runtimes/<name>
    public let home: URL
    /// D3DMetal tree with x86_64-windows/ and x86_64-unix/. 3.0 by default; its
    /// x86_64-unix/*.so must be symlinks to libd3dshared.dylib, not copies, so dyld
    /// loads one image with shared globals (docs/d3dmetal3.md).
    public let d3dmetalHome: URL

    public static let defaultD3DMetal = "runtimes/d3dmetal"

    public init(project: Project, name: String = Runtime.defaultName,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.project = project
        self.name = name
        self.home = project.runtimes.appendingPathComponent(name)
        if let override = environment["D3DMETAL_HOME"], !override.isEmpty {
            self.d3dmetalHome = URL(fileURLWithPath: override)
        } else {
            self.d3dmetalHome = project.root.appendingPathComponent(Runtime.defaultD3DMetal)
        }
    }

    public var wine: URL { home.appendingPathComponent("bin/wine") }
    public var wineloader: URL { home.appendingPathComponent("bin/wineloader") }   // ntdll hardcodes this name (CW HACK 22144)
    public var wineserver: URL { home.appendingPathComponent("bin/wineserver") }
    public var wined3dDir: URL { home.appendingPathComponent("lib/wined3d") }
    public var dllDir: URL { home.appendingPathComponent("lib/wine") }
    public var unixDir: URL { dllDir.appendingPathComponent("x86_64-unix") }
    /// winecx-full only: GStreamer plugins built into the runtime.
    public var gstreamerPluginDir: URL { home.appendingPathComponent("lib/gstreamer-1.0") }
    public var hasGStreamer: Bool { FileManager.default.fileExists(atPath: gstreamerPluginDir.path) }

    public static func isKnown(_ name: String) -> Bool { known.contains(name) }

    /// The runtime a bottle was created with, checked to be complete.
    public static func forBottle(_ bottle: Bottle, project: Project,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Runtime {
        guard isKnown(bottle.config.runtime) else {
            throw CrossError("bottle '\(bottle.name)' uses runtime '\(bottle.config.runtime)'; cross only drives \(known.joined(separator: ", "))")
        }
        let runtime = Runtime(project: project, name: bottle.config.runtime, environment: environment)
        try runtime.check()
        return runtime
    }

    /// Loads bottles/<name> together with the runtime that drives it.
    public static func loadBottle(_ name: String, in project: Project,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) throws -> (Runtime, Bottle) {
        let bottle = try Bottle.load(name: name, in: project)
        return (try forBottle(bottle, project: project, environment: environment), bottle)
    }

    /// The known runtimes whose build is present and complete on this machine.
    public static func available(in project: Project) -> [String] {
        known.filter { (try? Runtime(project: project, name: $0).check()) != nil }
    }

    /// The runtime new bottles should default to: `defaultName` when it is present,
    /// otherwise the first available one (a packaged app ships a single runtime).
    public static func preferred(in project: Project) -> String {
        let avail = available(in: project)
        return avail.contains(defaultName) ? defaultName : (avail.first ?? defaultName)
    }

    /// Our Wine is x86_64, so an Apple Silicon Mac needs Rosetta 2. Probed once by
    /// running an x86_64 binary through `arch`; `recheckRosetta()` probes again (after
    /// an in-app install) so no relaunch is needed.
    public private(set) static var rosettaAvailable: Bool = probeRosetta()

    @discardableResult
    public static func recheckRosetta() -> Bool {
        rosettaAvailable = probeRosetta()
        return rosettaAvailable
    }

    private static func probeRosetta() -> Bool {
        #if arch(arm64)
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        p.arguments = ["-x86_64", "/usr/bin/true"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
        #else
        return true
        #endif
    }

    public static let rosettaInstallCommand = "/usr/sbin/softwareupdate --install-rosetta --agree-to-license"

    public func check() throws {
        guard Runtime.rosettaAvailable else {
            throw CrossError("Rosetta 2 is not installed; it is required to run Windows programs. Install it with: \(Runtime.rosettaInstallCommand)")
        }
        let fm = FileManager.default
        for (what, url) in [("wine", wine), ("wineloader", wineloader), ("wineserver", wineserver)] {
            guard fm.isExecutableFile(atPath: url.path) else {
                throw CrossError("\(name) runtime incomplete: missing \(what) at \(url.path)")
            }
        }
    }

    /// Directory that supplies the 64-bit d3d10*/d3d11/d3d12/dxgi DLLs. ntdll always
    /// searches its own lib/wine first, so the build moves Wine's copies to
    /// lib/wined3d and exactly one of the two dirs is put first in WINEDLLPATH.
    /// Entries must be the PARENT of x86_64-windows/x86_64-unix: ntdll appends
    /// "/x86_64-windows/<name>.dll" and expects the unix half at
    /// "<entry>/x86_64-unix/<name>.so".
    public func graphicsDir(_ graphics: Graphics) -> URL {
        switch graphics {
        case .d3dmetal: return d3dmetalHome
        case .wined3d: return wined3dDir
        }
    }

    /// The environment a process in `bottle` runs with. `base` is the environment
    /// to inherit (WINEDEBUG, DYLD fallback paths and WINECX_GRAPHICS are honoured when
    /// already set, like the script). The bottle's performance settings decide WINEESYNC/
    /// WINEMSYNC, MTL_HUD_ENABLED, ROSETTA_ADVERTISE_AVX and the D3DM_* variables, except
    /// where `base` already sets one (non-empty): the caller's value wins.
    public func environment(for bottle: Bottle, base: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: String] {
        var env = base
        let graphics = try self.graphics(for: bottle, base: base)
        let d3dUnix = d3dmetalHome.appendingPathComponent("x86_64-unix")

        env["WINEPREFIX"] = bottle.prefix.path
        env["WINECX_HOME"] = home.path
        env["D3DMETAL_HOME"] = d3dmetalHome.path
        env["WINECX_GRAPHICS"] = graphics.rawValue
        env["WINEDLLPATH"] = [graphicsDir(graphics).path, dllDir.path].joined(separator: ":")
        // CW HACK 22434: ntdll dlopens this (lazily, on the first native PE load) and
        // registers D3DMetal's JIT code regions with Rosetta.
        env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = d3dUnix.appendingPathComponent("libd3dshared.dylib").path
        // gnutls/freetype are dlopened by leaf name and the D3DMetal .so files reference
        // @rpath/libd3dshared.dylib + D3DMetal.framework.
        env["DYLD_FALLBACK_LIBRARY_PATH"] = [
            home.appendingPathComponent("lib").path, d3dUnix.path, unixDir.path,
            nonEmpty(base["DYLD_FALLBACK_LIBRARY_PATH"]) ?? "/usr/local/lib:/usr/lib",
        ].joined(separator: ":")
        env["DYLD_FALLBACK_FRAMEWORK_PATH"] = [
            d3dUnix.path,
            nonEmpty(base["DYLD_FALLBACK_FRAMEWORK_PATH"]) ?? "/Library/Frameworks:/System/Library/Frameworks",
        ].joined(separator: ":")
        env["WINELOADER"] = wineloader.path
        env["WINESERVER"] = wineserver.path
        env["WINEDEBUG"] = nonEmpty(base["WINEDEBUG"]) ?? "-all"
        env["DOTNET_EnableWriteXorExecute"] = "0"   // CrossOver sets this for .NET under Rosetta
        // Performance settings (Performance.swift). WINEESYNC and WINEMSYNC are one choice:
        // a caller that sets either keeps both as given.
        let callerSync = PerformanceSettings.syncVariables.contains { nonEmpty(base[$0]) != nil }
        for (key, value) in bottle.config.performance.environment(graphics: graphics) where nonEmpty(base[key]) == nil {
            if callerSync && PerformanceSettings.syncVariables.contains(key) { continue }
            env[key] = value
        }
        env["PATH"] = [home.appendingPathComponent("bin").path, base["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        // winecx-full only: GStreamer's plugin dir and scanner are compiled in as absolute
        // paths; set them explicitly so the runtime keeps working if the tree is moved.
        if hasGStreamer {
            env["GST_PLUGIN_SYSTEM_PATH_1_0"] = gstreamerPluginDir.path
            env["GST_PLUGIN_SCANNER_1_0"] = home.appendingPathComponent("libexec/gstreamer-1.0/gst-plugin-scanner").path
        }
        return env
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
