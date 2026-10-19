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

    public init(runtime: String = Runtime.defaultName, graphics: Graphics = .d3dmetal, storage: BottleStorage? = nil) {
        self.runtime = runtime
        self.graphics = graphics
        self.storage = storage
    }
}

public struct Bottle {
    public let name: String
    public let prefix: URL
    public var config: BottleConfig
    /// bottles/<name>.sparsebundle for image-backed bottles, nil for folder bottles.
    public let image: URL?
    /// Why an image-backed bottle could not be mounted (listed anyway, not usable).
    public let storageError: String?

    public init(name: String, prefix: URL, config: BottleConfig, image: URL? = nil, storageError: String? = nil) {
        self.name = name
        self.prefix = prefix
        self.config = config
        self.image = image
        self.storageError = storageError
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
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.hasSuffix(".\(imageExtension)") else {
            throw CrossError("invalid bottle name '\(name)'")
        }
    }

    /// Loads an existing bottle. Falls back to `.runtime` + defaults when there is
    /// no cross.json yet (bottles created by the retired scripts/bottle.sh).
    /// An image-backed bottle is mounted first when it is not (after a reboot).
    public static func load(name: String, in project: Project) throws -> Bottle {
        try validate(name: name)
        let prefix = project.bottles.appendingPathComponent(name)
        let image = imageURL(name: name, in: project)
        if FileManager.default.fileExists(atPath: image.path) {
            try mount(image: image, at: prefix)
            return Bottle(name: name, prefix: prefix, config: try readConfig(prefix: prefix), image: image)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: prefix.path, isDirectory: &isDir), isDir.boolValue else {
            throw CrossError("no bottle '\(name)' in \(project.bottles.path)")
        }
        if let error = missingImageError(prefix: prefix) { throw CrossError(error) }
        return Bottle(name: name, prefix: prefix, config: try readConfig(prefix: prefix, folder: true))
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

    /// Every bottle: directories in bottles/ plus `<name>.sparsebundle` images (mounted
    /// here when they are not; one that cannot be mounted is listed with `storageError`).
    public static func list(in project: Project) throws -> [Bottle] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: project.bottles, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        let dirs = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let suffix = ".\(imageExtension)"
        let imageNames = Set(dirs.map(\.lastPathComponent).filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) })
        let folderNames = Set(dirs.map(\.lastPathComponent).filter { !$0.hasSuffix(suffix) })
        return try imageNames.union(folderNames).sorted().compactMap { name in
            let prefix = project.bottles.appendingPathComponent(name)
            guard imageNames.contains(name) else {
                if let error = missingImageError(prefix: prefix) {
                    return Bottle(name: name, prefix: prefix, config: BottleConfig(), storageError: error)
                }
                return Bottle(name: name, prefix: prefix, config: try readConfig(prefix: prefix, folder: true))
            }
            let image = imageURL(name: name, in: project)
            guard (try? validate(name: name)) != nil else { return nil }
            do {
                try mount(image: image, at: prefix)
                return Bottle(name: name, prefix: prefix, config: try readConfig(prefix: prefix), image: image)
            } catch {
                return Bottle(name: name, prefix: prefix, config: BottleConfig(), image: image, storageError: "\(error)")
            }
        }
    }
}
