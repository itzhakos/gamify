import Foundation

/// The graphics backends next to D3DMetal and wined3d: DXVK (runtimes/dxvk, D3D9/10/11 over
/// MoltenVK, 32- and 64-bit, winecx-full only) and DXMT (runtimes/dxmt, D3D10/11 on Metal,
/// 32- and 64-bit). Both are Wine builtins selected like D3DMetal, by putting their folder
/// first in WINEDLLPATH; every backend then falls back to <runtime>/lib/wined3d for what it
/// lacks (D3DMetal: all of i386 and d3d9). Build, layout, recipe: docs/dxmt-dxvk.md.
extension Runtime {
    public static let defaultDXVK = "runtimes/dxvk"
    public static let defaultDXMT = "runtimes/dxmt"

    /// runtimes/dxvk (next to D3DMetal, also in the bundled app's root).
    public var dxvkHome: URL { project.root.appendingPathComponent(Runtime.defaultDXVK) }
    /// runtimes/dxmt.
    public var dxmtHome: URL { project.root.appendingPathComponent(Runtime.defaultDXMT) }
    /// winecx-full only: MoltenVK, the Vulkan driver DXVK needs.
    public var hasMoltenVK: Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent("lib/libMoltenVK.dylib").path)
    }

    /// The backends this runtime can run on this machine (built and, for DXVK, with Vulkan).
    public var availableGraphics: [Graphics] {
        Graphics.allCases.filter { (try? checkGraphics($0)) != nil }
    }

    /// Throws when `graphics` cannot run on this runtime: the backend is not built, or
    /// DXVK on a runtime without MoltenVK.
    public func checkGraphics(_ graphics: Graphics) throws {
        let fm = FileManager.default
        switch graphics {
        case .wined3d:
            return
        case .d3dmetal:
            guard fm.fileExists(atPath: d3dmetalHome.appendingPathComponent("x86_64-windows/d3d11.dll").path) else {
                throw CrossError("D3DMetal is not installed at \(d3dmetalHome.path)")
            }
        case .dxvk:
            guard fm.fileExists(atPath: dxvkHome.appendingPathComponent("x86_64-windows/d3d11.dll").path) else {
                throw CrossError("DXVK is not built (\(dxvkHome.path)); run scripts/build-dxvk.sh")
            }
            guard hasMoltenVK else {
                throw CrossError("DXVK needs Vulkan (MoltenVK), which the '\(name)' runtime does not have; use a winecx-full bottle")
            }
        case .dxmt:
            guard fm.fileExists(atPath: dxmtHome.appendingPathComponent("x86_64-unix/winemetal.so").path),
                  fm.fileExists(atPath: dxmtHome.appendingPathComponent("x86_64-windows/d3d11.dll").path) else {
                throw CrossError("DXMT is not built (\(dxmtHome.path)); run scripts/build-dxmt.sh")
            }
        }
    }

    /// What a backend needs in the environment beyond WINEDLLPATH (docs/dxmt-dxvk.md
    /// "Environment recipe"). `base` is the caller's environment.
    func backendEnvironment(_ graphics: Graphics, bottle: Bottle, base: [String: String]) -> [String: String] {
        var env: [String: String] = [:]
        switch graphics {
        case .dxvk:
            env["DXVK_CONFIG_FILE"] = dxvkHome.appendingPathComponent("dxvk.conf").path
            // State cache and logs otherwise land next to the game's .exe.
            let cache = dxvkCacheDir(bottle).path
            env["DXVK_STATE_CACHE_PATH"] = cache
            env["DXVK_LOG_PATH"] = cache
            // Wine's vulkan-1 is the only loader that reaches MoltenVK. An app's own copy
            // (Battle.net ships the Khronos loader) enumerates adapters through DXVK's dxgi
            // and recurses until the stack overflows.
            let overrides = base["WINEDLLOVERRIDES"] ?? ""
            if !overrides.contains("vulkan-1") {
                env["WINEDLLOVERRIDES"] = overrides.isEmpty ? "vulkan-1=b" : overrides + ";vulkan-1=b"
            }
        case .dxmt:
            let conf = dxmtHome.appendingPathComponent("dxmt.conf")
            if FileManager.default.fileExists(atPath: conf.path) { env["DXMT_CONFIG_FILE"] = conf.path }
        case .d3dmetal, .wined3d:
            break
        }
        return env
    }

    /// <prefix>/cache/dxvk: DXVK's state cache and logs for this bottle.
    public func dxvkCacheDir(_ bottle: Bottle) -> URL { bottle.prefix.appendingPathComponent("cache/dxvk") }

    /// Files a backend needs in the prefix; idempotent, cheap when nothing is missing, run by
    /// `applyPerformance` (create, settings change, before every launch). Returns what it did.
    func prepareBackend(_ graphics: Graphics, bottle: Bottle) throws -> [String] {
        let fm = FileManager.default
        var done: [String] = []
        switch graphics {
        case .dxmt:
            // Wine loads a builtin only when its file exists in the prefix: d3d11/dxgi are there
            // from wineboot, winemetal.dll is new ("Library winemetal.dll (which is needed by
            // dxgi.dll) not found" otherwise). Builtin-marked, so it stays harmless for the
            // other backends. With MetalFX on, DXMT's NGX shim and nvapi too.
            var files = [("x86_64-windows", "system32", "winemetal.dll"), ("i386-windows", "syswow64", "winemetal.dll")]
            if bottle.config.performance.metalfx {
                files += [("x86_64-windows", "system32", "nvapi64.dll"), ("x86_64-windows", "system32", "nvngx.dll")]
            }
            for (arch, dir, name) in files {
                let target = bottle.driveC.appendingPathComponent("windows/\(dir)/\(name)")
                let source = dxmtHome.appendingPathComponent("\(arch)/\(name)")
                guard !fm.fileExists(atPath: target.path), fm.fileExists(atPath: source.path),
                      fm.fileExists(atPath: target.deletingLastPathComponent().path) else { continue }
                try fm.copyItem(at: source, to: target)
                done.append("copied \(name) into \(dir) (DXMT)")
            }
        case .dxvk:
            let cache = dxvkCacheDir(bottle)
            if !fm.fileExists(atPath: cache.path) {
                try fm.createDirectory(at: cache, withIntermediateDirectories: true)
                done.append("created cache/dxvk")
            }
        case .d3dmetal, .wined3d:
            break
        }
        return done
    }
}
