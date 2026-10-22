import Foundation

/// How Wine implements Windows synchronisation objects (events, mutexes, semaphores).
/// Both keep them out of the wineserver round trip; msync uses Mach semaphores, esync
/// file descriptors. Our wineserver supports both ("msync: up and running").
public enum SyncMode: String, Codable, CaseIterable {
    case esync
    case msync
}

/// Per-bottle performance settings, `performance` in cross.json. Every field has a
/// default, so a cross.json without the key (or with only some fields) loads unchanged.
/// Mapping (docs/app.md "Performance settings"): environment variables through
/// `environment(graphics:)`, applied by `Runtime.environment(for:)`; files and registry
/// values through `Runtime.applyPerformance(to:)`. Everything applies to programs
/// started afterwards.
public struct PerformanceSettings: Codable, Equatable {
    /// WINEESYNC=1 or WINEMSYNC=1 (exactly one).
    public var sync: SyncMode = .esync
    /// D3DMetal: DLSS calls go to Apple's MetalFX bridge (nvngx.dll), the adapter reports an
    /// NVIDIA vendor id (Streamline-based games require NVIDIA). DXMT: DXMT_ENABLE_NVEXT=1
    /// (its own NGX shim -> MetalFX temporal scaler). wined3d/DXVK: no effect.
    public var metalfx: Bool = true
    /// ROSETTA_ADVERTISE_AVX=1: Rosetta reports AVX/AVX2 in cpuid.
    public var avx: Bool = false
    /// D3DM_SUPPORT_DXR=1/0; nil leaves D3DMetal's default (on for M3 and later).
    public var raytracing: Bool?
    /// D3DM_MAX_FPS; nil: no cap.
    public var maxFPS: Int?
    /// MTL_HUD_ENABLED=1: Apple's Metal performance HUD.
    public var hud: Bool = false
    /// HKCU\Software\Wine\Mac Driver\RetinaMode: native pixels instead of half the
    /// backing resolution scaled up by Core Animation.
    public var retina: Bool = false
    /// D3DM_VENDOR_ID override; nil: 0x10DE (NVIDIA) while `metalfx` is on, else D3DMetal's own.
    public var vendorID: UInt32?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sync = try c.decodeIfPresent(SyncMode.self, forKey: .sync) ?? .esync
        metalfx = try c.decodeIfPresent(Bool.self, forKey: .metalfx) ?? true
        avx = try c.decodeIfPresent(Bool.self, forKey: .avx) ?? false
        raytracing = try c.decodeIfPresent(Bool.self, forKey: .raytracing)
        maxFPS = try c.decodeIfPresent(Int.self, forKey: .maxFPS)
        hud = try c.decodeIfPresent(Bool.self, forKey: .hud) ?? false
        retina = try c.decodeIfPresent(Bool.self, forKey: .retina) ?? false
        vendorID = try c.decodeIfPresent(UInt32.self, forKey: .vendorID)
    }

    public static let nvidiaVendorID: UInt32 = 0x10DE

    /// The vendor id D3DMetal is told to report, nil when it reports its own (0x1002).
    public func effectiveVendorID(graphics: Graphics) -> UInt32? {
        guard graphics == .d3dmetal else { return nil }
        return vendorID ?? (metalfx ? PerformanceSettings.nvidiaVendorID : nil)
    }

    public static func hex(_ id: UInt32) -> String { String(format: "0x%04X", id) }

    /// "0x10DE", "10de" or decimal "4318".
    public static func parseVendorID(_ text: String) -> UInt32? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { return UInt32(t.dropFirst(2), radix: 16) }
        if t.contains(where: { "abcdef".contains($0) }) { return UInt32(t, radix: 16) }
        return UInt32(t)
    }

    /// Variables these settings decide: a value sets it, nil removes it. D3DMetal's own
    /// variables are only set for D3DMetal bottles.
    public func environment(graphics: Graphics) -> [String: String?] {
        let d3dmetal = graphics == .d3dmetal
        var env: [String: String?] = [
            "WINEESYNC": sync == .esync ? "1" : nil,
            "WINEMSYNC": sync == .msync ? "1" : nil,
            "ROSETTA_ADVERTISE_AVX": avx ? "1" : nil,
            "MTL_HUD_ENABLED": hud ? "1" : "0",
            "D3DM_ENABLE_METALFX": d3dmetal && metalfx ? "1" : nil,
            "D3DM_VENDOR_ID": effectiveVendorID(graphics: graphics).map(PerformanceSettings.hex),
            "D3DM_SUPPORT_DXR": nil,
            "D3DM_MAX_FPS": nil,
            // DXMT's NVIDIA extensions: nvapi + its NGX shim (DLSS -> MetalFX temporal scaler)
            "DXMT_ENABLE_NVEXT": graphics == .dxmt && metalfx ? "1" : nil,
        ]
        if d3dmetal, let raytracing { env["D3DM_SUPPORT_DXR"] = raytracing ? "1" : "0" }
        if d3dmetal, let maxFPS, maxFPS > 0 { env["D3DM_MAX_FPS"] = String(maxFPS) }
        return env
    }

    /// Both sync variables are one choice: a caller that sets either keeps both as it gave them.
    public static let syncVariables: Set<String> = ["WINEESYNC", "WINEMSYNC"]
}

// MARK: - Files and registry

extension Runtime {
    /// Apple ships the DLSS bridge as nvngx-on-metalfx.{dll,so}; games load nvngx.dll.
    /// Adds x86_64-windows/nvngx.dll (a copy) and x86_64-unix/nvngx.so (a symlink to
    /// libd3dshared.dylib, like the other .so files: copies crash D3DMetal,
    /// docs/d3dmetal3.md) next to Apple's names. Idempotent; returns what it did.
    @discardableResult
    public func ensureNVNGXNames() throws -> [String] {
        let fm = FileManager.default
        var done: [String] = []
        let win = d3dmetalHome.appendingPathComponent("x86_64-windows")
        let dll = win.appendingPathComponent("nvngx.dll")
        let appleDLL = win.appendingPathComponent("nvngx-on-metalfx.dll")
        if !fm.fileExists(atPath: dll.path), fm.fileExists(atPath: appleDLL.path) {
            try fm.copyItem(at: appleDLL, to: dll)
            done.append("added \(dll.path)")
        }
        let unix = d3dmetalHome.appendingPathComponent("x86_64-unix")
        let so = unix.appendingPathComponent("nvngx.so")
        let shared = "libd3dshared.dylib"
        if fm.fileExists(atPath: unix.appendingPathComponent(shared).path),
           (try? fm.destinationOfSymbolicLink(atPath: so.path)) != shared {
            if fm.fileExists(atPath: so.path) || Bottle.isSymlink(so) { try fm.removeItem(at: so) }
            try fm.createSymbolicLink(atPath: so.path, withDestinationPath: shared)
            done.append("linked \(so.path) -> \(shared)")
        }
        return done
    }

    public static let ngxKey = "HKEY_LOCAL_MACHINE\\Software\\NVIDIA Corporation\\Global\\NGXCore"
    public static let ngxPath = "C:\\windows\\system32"
    public static let macDriverKey = "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver"

    /// The graphics backend a process in `bottle` gets (WINECX_GRAPHICS wins over cross.json).
    public func graphics(for bottle: Bottle, base: [String: String] = ProcessInfo.processInfo.environment) throws -> Graphics {
        guard let override = base["WINECX_GRAPHICS"], !override.isEmpty else { return bottle.config.graphics }
        guard let g = Graphics(rawValue: override) else {
            throw CrossError("unknown WINECX_GRAPHICS='\(override)' (\(Graphics.list))")
        }
        return g
    }

    /// Puts in place what the bottle's performance settings need beyond environment
    /// variables: with MetalFX on (D3DMetal bottles) the runtime's nvngx names,
    /// nvngx.dll + nvapi64.dll in system32 and NGXCore\FullPath; and RetinaMode.
    /// Cheap when nothing is missing (file checks and a look at user.reg/system.reg), so
    /// it runs before every launch (`runExe`, `steam`), at create and on a settings
    /// change. Needs an initialised prefix (after wineboot); returns what it changed.
    /// `force` writes the registry values without looking at the files first: a running
    /// wineserver saves them only later, so right after a change they can be stale (a
    /// settings change passes it; a launch does not need it).
    @discardableResult
    public func applyPerformance(to bottle: Bottle, force: Bool = false,
                                 base: [String: String] = ProcessInfo.processInfo.environment) throws -> [String] {
        let fm = FileManager.default
        let system32 = bottle.driveC.appendingPathComponent("windows/system32")
        guard fm.fileExists(atPath: system32.path),
              fm.fileExists(atPath: bottle.prefix.appendingPathComponent("system.reg").path) else { return [] }
        let perf = bottle.config.performance
        var done: [String] = []
        var values: [Store.RegistryValue] = []
        let graphics = try graphics(for: bottle, base: base)
        done += try prepareBackend(graphics, bottle: bottle)
        if graphics == .d3dmetal && perf.metalfx {
            do {
                done += try ensureNVNGXNames()
            } catch {
                warn("cannot add nvngx.dll/nvngx.so to \(d3dmetalHome.path): \(error)")
            }
            let win = d3dmetalHome.appendingPathComponent("x86_64-windows")
            for name in ["nvngx.dll", "nvapi64.dll"] {
                let target = system32.appendingPathComponent(name)
                let source = win.appendingPathComponent(name)
                guard !fm.fileExists(atPath: target.path) else { continue }
                guard fm.fileExists(atPath: source.path) else {
                    warn("\(source.path) is missing; DLSS through MetalFX needs it")
                    continue
                }
                try fm.copyItem(at: source, to: target)
                done.append("copied \(name) into system32")
            }
            if force || Registry.value(in: bottle, key: Runtime.ngxKey, name: "FullPath")?.lowercased() != Runtime.ngxPath.lowercased() {
                values.append(Store.RegistryValue(key: Runtime.ngxKey, name: "FullPath", data: Runtime.ngxPath))
            }
        }
        let retina = Registry.value(in: bottle, key: Runtime.macDriverKey, name: "RetinaMode")
        let retinaOn = retina.map(Registry.isTrue) ?? false
        if force || retinaOn != perf.retina {
            values.append(Store.RegistryValue(key: Runtime.macDriverKey, name: "RetinaMode", data: perf.retina ? "Y" : "N"))
        }
        if !values.isEmpty {
            try applyRegistry(values, in: bottle, base: base)
            done += values.map { "set \($0.key)\\\($0.name) = \($0.data)" }
        }
        return done
    }

    /// `applyPerformance` before a launch: a failure is reported and the launch goes on.
    func preparePerformance(_ bottle: Bottle, base: [String: String]) {
        do {
            try applyPerformance(to: bottle, base: base)
        } catch {
            warn("performance settings of '\(bottle.name)' not fully applied: \(error)")
        }
    }
}

/// Reads values from a prefix's registry files (system.reg for HKLM, user.reg for HKCU)
/// without starting Wine. The files can lag behind a running wineserver (it saves
/// periodically and on exit), which at worst makes `applyPerformance` write a value again.
enum Registry {
    static func value(in bottle: Bottle, key: String, name: String) -> String? {
        let hives = [("HKEY_LOCAL_MACHINE\\", "system.reg"), ("HKEY_CURRENT_USER\\", "user.reg")]
        guard let (prefix, file) = hives.first(where: { key.hasPrefix($0.0) }) else { return nil }
        let url = bottle.prefix.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let header = "[" + escape(String(key.dropFirst(prefix.count))).lowercased() + "]"
        let wanted = escape(name).lowercased()
        var inKey = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("[") {
                inKey = line.lowercased().hasPrefix(header)
                continue
            }
            guard inKey, line.hasPrefix("\"") else { continue }
            // "Name"="data" (REG_SZ); other types are not read here
            guard let eq = line.range(of: "\"=\"") else { continue }
            guard line[line.index(after: line.startIndex)..<eq.lowerBound].lowercased() == wanted else { continue }
            var raw = line[eq.upperBound...]
            if raw.hasSuffix("\"") { raw = raw.dropLast() }
            return unescape(String(raw))
        }
        return nil
    }

    /// winemac.drv's IS_OPTION_TRUE: y, Y, t, T or 1.
    static func isTrue(_ value: String) -> Bool {
        guard let c = value.first else { return false }
        return "yYtT1".contains(c)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\\\", with: "\\").replacingOccurrences(of: "\\\"", with: "\"")
    }
}

// MARK: - Shader cache

/// D3DMetal's shader cache: $(getconf DARWIN_USER_CACHE_DIR)/d3dm/<exe name>/, one folder
/// per executable name (e.g. SplitFiction.exe), shared by every bottle and kept when a
/// bottle moves or is deleted. Apple recommends deleting it when a game stops booting.
public enum ShaderCache {
    public struct Entry: Identifiable, Equatable {
        public let name: String
        public let url: URL
        public let bytes: Int64
        public var id: String { name }
        /// "12 KB", "811.3 MB": the cache folders are often far below a GB.
        public var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    }

    /// The d3dm folder in this user's cache directory (confstr _CS_DARWIN_USER_CACHE_DIR).
    public static var root: URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count)
        let dir = n > 0 ? String(cString: buffer) : NSTemporaryDirectory()
        return URL(fileURLWithPath: dir).appendingPathComponent("d3dm")
    }

    /// Every cache folder with its size, by name.
    public static func list() -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.sorted { $0.lowercased() < $1.lowercased() }.compactMap { name in
            let url = root.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard !name.hasPrefix("."), fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return Entry(name: name, url: url, bytes: size(of: url))
        }
    }

    /// The cache folder of an executable (`Game.exe`, a Windows or Mac path to it, case
    /// does not matter), nil when there is none.
    public static func entry(forExe exe: String) -> Entry? {
        let name = exeName(exe).lowercased()
        return list().first { $0.name.lowercased() == name }
    }

    /// The file name D3DMetal keys the cache on: the last component of a Windows or Mac path.
    public static func exeName(_ exe: String) -> String {
        String(exe.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? Substring(exe))
    }

    /// Deletes the executable's cache folder; returns the bytes freed (nil: there was none).
    /// D3DMetal rebuilds it on the next launch (slower first start, shader stutter).
    @discardableResult
    public static func clear(exe: String) throws -> Int64? {
        guard let entry = entry(forExe: exe) else { return nil }
        guard entry.url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw CrossError("refusing to delete \(entry.url.path)")
        }
        try FileManager.default.removeItem(at: entry.url)
        return entry.bytes
    }

    private static func size(of dir: URL) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return 0 }
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: Set(keys))
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
