import Foundation

/// 64-bit DirectX 10/11/12 backend for a bottle. Exactly one of the two
/// directories goes first in WINEDLLPATH (see Runtime.environment).
public enum Graphics: String, Codable, CaseIterable {
    case d3dmetal   // Apple D3DMetal 3.0 (runtimes/d3dmetal), the default
    case wined3d    // Wine's own d3d*/dxgi, moved to runtimes/winecx/lib/wined3d
}

/// Per-bottle settings, stored as `bottles/<name>/cross.json`.
public struct BottleConfig: Codable, Equatable {
    public var runtime: String = Runtime.defaultName
    public var graphics: Graphics = .d3dmetal
    /// Set for bottles backed by a disk image (Storage.swift); absent for folder bottles.
    public var storage: BottleStorage?
    /// Sync, DLSS via MetalFX, AVX, ray tracing, FPS cap, HUD, Retina (Performance.swift).
    public var performance = PerformanceSettings()

    public init(runtime: String = Runtime.defaultName, graphics: Graphics = .d3dmetal, storage: BottleStorage? = nil,
                performance: PerformanceSettings = PerformanceSettings()) {
        self.runtime = runtime
        self.graphics = graphics
        self.storage = storage
        self.performance = performance
    }

    /// Missing keys take their defaults (cross.json files written before a key existed).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime) ?? Runtime.defaultName
        graphics = try c.decodeIfPresent(Graphics.self, forKey: .graphics) ?? .d3dmetal
        storage = try c.decodeIfPresent(BottleStorage.self, forKey: .storage)
        performance = try c.decodeIfPresent(PerformanceSettings.self, forKey: .performance) ?? PerformanceSettings()
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
