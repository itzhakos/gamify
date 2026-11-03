import Foundation

/// 64-bit DirectX 10/11/12 backend for a bottle. Its directory goes first in WINEDLLPATH
/// (see Runtime.environment); a D3DMetal bottle adds its `Graphics32`/`Graphics9` backends
/// after it.
public enum Graphics: String, Codable, CaseIterable {
    case d3dmetal   // Apple D3DMetal 3.0 (runtimes/d3dmetal), the default: DX11/DX12, 64-bit only
    case wined3d    // Wine's own d3d9/d3d10*/d3d11/d3d12/dxgi, moved to <runtime>/lib/wined3d
    case dxvk       // DXVK 1.10.3 (runtimes/dxvk): DX9/10/11, 32- and 64-bit, over MoltenVK (winecx-full)
    case dxmt       // DXMT 0.80 (runtimes/dxmt): DX10/11 on Metal, 32- and 64-bit

    /// "d3dmetal|wined3d|dxvk|dxmt" for usage texts.
    public static var list: String { allCases.map(\.rawValue).joined(separator: "|") }
    public var title: String {
        switch self {
        case .d3dmetal: return "D3DMetal"
        case .wined3d: return "wined3d"
        case .dxvk: return "DXVK"
        case .dxmt: return "DXMT"
        }
    }
}

/// Where a D3DMetal bottle sends 32-bit DirectX 10/11 programs. D3DMetal has no i386 DLLs,
/// so before 0.10 every 32-bit DX10/11 game in a D3DMetal bottle fell through to wined3d
/// (feature level 9_3/10_1). The chosen backend's folder goes right after D3DMetal's in
/// WINEDLLPATH (`Runtime.d3dmetalFallbacks`); 64-bit programs still find D3DMetal first.
/// Only used when `graphics` is d3dmetal: the other backends cover both architectures.
public enum Graphics32: String, Codable, CaseIterable {
    case dxmt      // DXMT (runtimes/dxmt), the default: 32-bit DX10/11 on Metal
    case dxvk      // DXVK (runtimes/dxvk): 32-bit DX10/11 over MoltenVK (winecx-full)
    case wined3d   // nothing in between: Wine's wined3d, as before 0.10

    /// "dxmt|dxvk|wined3d" for usage texts.
    public static var list: String { allCases.map(\.rawValue).joined(separator: "|") }
    public var title: String { graphics.title }
    /// The backend whose DLLs 32-bit programs get.
    public var graphics: Graphics {
        switch self {
        case .dxmt: return .dxmt
        case .dxvk: return .dxvk
        case .wined3d: return .wined3d
        }
    }
}

/// Where a D3DMetal bottle sends DirectX 9 programs, 32- and 64-bit: D3DMetal has no d3d9,
/// so they get wined3d (OpenGL) unless DXVK's folder goes after the 32-bit choice in
/// WINEDLLPATH (`Runtime.d3dmetalFallbacks`). Only used when `graphics` is d3dmetal.
public enum Graphics9: String, Codable, CaseIterable {
    case dxvk      // DXVK (runtimes/dxvk) over MoltenVK (winecx-full)
    case wined3d   // Wine's wined3d, the default (as before 0.10)

    /// What a bottle gets when cross.json does not say. wined3d until DXVK's d3d9 is shown to
    /// render a real game here: Portal 2 ran on it (2026-11-03) but MoltenVK failed to compile
    /// its shadow-sampler shaders and the screen was locked, so no picture (docs/app.md).
    public static let standard: Graphics9 = .wined3d
    /// "dxvk|wined3d" for usage texts.
    public static var list: String { allCases.map(\.rawValue).joined(separator: "|") }
    public var title: String { graphics.title }
    /// The backend whose d3d9.dll DirectX 9 programs get.
    public var graphics: Graphics { self == .dxvk ? .dxvk : .wined3d }
}

/// Per-bottle settings, stored as `bottles/<name>/cross.json`.
public struct BottleConfig: Codable, Equatable {
    public var runtime: String = Runtime.defaultName
    public var graphics: Graphics = .d3dmetal
    /// 32-bit DirectX 10/11 programs of a D3DMetal bottle (no effect on the other backends).
    public var graphics32: Graphics32 = .dxmt
    /// DirectX 9 programs (both arches) of a D3DMetal bottle (no effect on the other backends).
    public var graphics9: Graphics9 = Graphics9.standard
    /// Set for bottles backed by a disk image (Storage.swift); absent for folder bottles.
    public var storage: BottleStorage?
    /// Sync, DLSS via MetalFX, AVX, ray tracing, FPS cap, HUD, Retina (Performance.swift).
    public var performance = PerformanceSettings()
    /// Debugging mode: programs started afterwards log more (Debug.swift, `Debug.environment`).
    public var debug: Bool = false

    public init(runtime: String = Runtime.defaultName, graphics: Graphics = .d3dmetal, graphics32: Graphics32 = .dxmt,
                graphics9: Graphics9 = Graphics9.standard, storage: BottleStorage? = nil,
                performance: PerformanceSettings = PerformanceSettings(), debug: Bool = false) {
        self.runtime = runtime
        self.graphics = graphics
        self.graphics32 = graphics32
        self.graphics9 = graphics9
        self.storage = storage
        self.performance = performance
        self.debug = debug
    }

    /// Missing keys take their defaults (cross.json files written before a key existed).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime) ?? Runtime.defaultName
        graphics = try c.decodeIfPresent(Graphics.self, forKey: .graphics) ?? .d3dmetal
        graphics32 = try c.decodeIfPresent(Graphics32.self, forKey: .graphics32) ?? .dxmt
        graphics9 = try c.decodeIfPresent(Graphics9.self, forKey: .graphics9) ?? Graphics9.standard
        storage = try c.decodeIfPresent(BottleStorage.self, forKey: .storage)
        performance = try c.decodeIfPresent(PerformanceSettings.self, forKey: .performance) ?? PerformanceSettings()
        debug = try c.decodeIfPresent(Bool.self, forKey: .debug) ?? false
    }
}

public struct Bottle {
    public let name: String
    public let prefix: URL
    public var config: BottleConfig
    /// bottles/<name>.sparsebundle for image-backed bottles, nil for folder bottles.
    public let image: URL?
    /// Why the bottle cannot be used: its disk image could not be mounted, or it lives
    /// on a drive that is not connected (listed anyway, not usable).
    public let storageError: String?
    /// Where the bottle's data really is when it is not in the bottles folder: the
    /// folder or the .sparsebundle the registry entry links to (Location.swift).
    public let location: URL?

    public init(name: String, prefix: URL, config: BottleConfig, image: URL? = nil, storageError: String? = nil,
                location: URL? = nil) {
        self.name = name
        self.prefix = prefix
        self.config = config
        self.image = image
        self.storageError = storageError
        self.location = location
    }

    public static let configFile = "cross.json"
    public static let legacyRuntimeFile = ".runtime"   // written by the retired scripts/bottle.sh; still read as a fallback

    /// Windows profile under drive_c/users. GetUserName() in the CrossOver tree
    /// always returns "crossover" (CX hack 12735).
    public var windowsUser: String { Runtime.isKnown(config.runtime) ? "crossover" : NSUserName() }
    public var driveC: URL { prefix.appendingPathComponent("drive_c") }
    public var userProfile: URL { driveC.appendingPathComponent("users/\(windowsUser)") }
    public var steamDir: URL { driveC.appendingPathComponent("Program Files (x86)/Steam") }

    public static func validate(name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.hasSuffix(".\(imageExtension)"),
              !name.hasSuffix(".\(locationExtension)") else {
            throw CrossError("invalid bottle name '\(name)'")
        }
    }

    /// Loads an existing bottle. Falls back to `.runtime` + defaults when there is
    /// no cross.json yet (bottles created by the retired scripts/bottle.sh).
    /// An image-backed bottle is mounted first when it is not (after a reboot). A bottle
    /// that lives elsewhere is reached through its link in bottles/ (Location.swift).
    public static func load(name: String, in project: Project) throws -> Bottle {
        try validate(name: name)
        let bottle = open(name: name, in: project, mountEjected: true)
        guard let bottle else { throw CrossError("no bottle '\(name)' in \(project.bottles.path)") }
        if let error = bottle.storageError { throw CrossError(error) }
        return bottle
    }

    /// The bottle `name` as found in bottles/, nil when there is none. Problems that
    /// keep it from being used (image not mountable, drive not connected) come back as
    /// `storageError` (`load` throws it). An ejected image (Location.swift) is mounted
    /// again only with `mountEjected` (load: the bottle is being used).
    static func open(name: String, in project: Project, mountEjected: Bool = false) -> Bottle? {
        let fm = FileManager.default
        let prefix = project.bottles.appendingPathComponent(name)
        let image = imageURL(name: name, in: project)
        let location = recordedLocation(name: name, in: project)
        let hasImage = isEntry(image)
        let hasFolder = isEntry(prefix)
        guard hasImage || hasFolder || location != nil else { return nil }
        func unusable(_ error: String, image isImage: Bool = hasImage) -> Bottle {
            Bottle(name: name, prefix: prefix, config: BottleConfig(), image: isImage ? image : nil,
                   storageError: error, location: location)
        }
        if let location, let error = unreachableError(name: name, target: location) {
            return unusable(error, image: location.pathExtension == imageExtension)
        }
        if hasImage {
            if let error = danglingLinkError(name: name, link: image) { return unusable(error) }
            let flag = ejectedFlag(name: name, in: project)
            if FileManager.default.fileExists(atPath: flag.path) {
                guard mountEjected else { return unusable(ejectedMessage(name: name)) }
                try? FileManager.default.removeItem(at: flag)
            }
            do {
                try mount(image: image, at: prefix)
                return Bottle(name: name, prefix: prefix, config: try readConfig(prefix: prefix), image: image, location: location)
            } catch {
                return unusable("\(error)")
            }
        }
        guard hasFolder else {
            return unusable("'\(name)' is recorded at \(location?.path ?? "?") but its entry \(prefix.path) is missing; move the bottle back or remove \(locationURL(name: name, in: project).lastPathComponent)", image: false)
        }
        if let error = danglingLinkError(name: name, link: prefix) ?? missingImageError(prefix: prefix) {
            return unusable(error)
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: prefix.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        do {
            return Bottle(name: name, prefix: prefix, config: try readConfig(prefix: prefix, folder: true), location: location)
        } catch {
            return unusable("\(error)")
        }
    }

    /// A mount point whose image is gone: only the marker is left in bottles/<name>.
    static func missingImageError(prefix: URL) -> String? {
        let marker = prefix.appendingPathComponent(mountMarker)
        guard FileManager.default.fileExists(atPath: marker.path),
              !FileManager.default.fileExists(atPath: prefix.appendingPathComponent(configFile).path) else { return nil }
        let image = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "the disk image of '\(prefix.lastPathComponent)' (\(image ?? "?")) is missing from \(prefix.deletingLastPathComponent().path)"
    }

    /// `folder`: the bottle has no image, so a `storage` entry left in cross.json (a
    /// copy taken out of an image by hand) is dropped.
    public static func readConfig(prefix: URL, folder: Bool = false) throws -> BottleConfig {
        let url = prefix.appendingPathComponent(configFile)
        if let data = try? Data(contentsOf: url) {
            do {
                var config = try JSONDecoder().decode(BottleConfig.self, from: data)
                if folder { config.storage = nil }
                return config
            } catch { throw CrossError("cannot parse \(url.path): \(error)") }
        }
        var config = BottleConfig()
        if let rt = try? String(contentsOf: prefix.appendingPathComponent(legacyRuntimeFile), encoding: .utf8) {
            config.runtime = rt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return config
    }

    public func saveConfig() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try enc.encode(config)
        data.append(0x0a)
        try data.write(to: prefix.appendingPathComponent(Bottle.configFile))
        // legacy marker, kept so older tooling can still tell the runtime
        try (config.runtime + "\n").write(to: prefix.appendingPathComponent(Bottle.legacyRuntimeFile),
                                          atomically: true, encoding: .utf8)
    }

    /// Every bottle: directories in bottles/ (or links to directories elsewhere) plus
    /// `<name>.sparsebundle` images (mounted here when they are not) and bottles recorded
    /// in a `<name>.location` file. One that cannot be used is listed with `storageError`.
    public static func list(in project: Project) throws -> [Bottle] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: project.bottles.path) else { return [] }
        var names = Set<String>()
        for entry in entries where !entry.hasPrefix(".") {
            let url = project.bottles.appendingPathComponent(entry)
            let ext = url.pathExtension
            if ext == locationExtension || ext == imageExtension {
                guard ext == imageExtension ? isEntry(url) : !isDirectory(url) else { continue }
                names.insert(url.deletingPathExtension().lastPathComponent)
            } else if isEntry(url) {
                names.insert(entry)
            }
        }
        return names.sorted().compactMap { name in
            guard (try? validate(name: name)) != nil else { return nil }
            return open(name: name, in: project)
        }
    }
}
