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

    public init(runtime: String = Runtime.defaultName, graphics: Graphics = .d3dmetal) {
        self.runtime = runtime
        self.graphics = graphics
    }
}

public struct Bottle {
    public let name: String
    public let prefix: URL
    public var config: BottleConfig

    public init(name: String, prefix: URL, config: BottleConfig) {
        self.name = name
        self.prefix = prefix
        self.config = config
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
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else {
            throw CrossError("invalid bottle name '\(name)'")
        }
    }

    /// Loads an existing bottle. Falls back to `.runtime` + defaults when there is
    /// no cross.json yet (bottles created by the retired scripts/bottle.sh).
    public static func load(name: String, in project: Project) throws -> Bottle {
        try validate(name: name)
        let prefix = project.bottles.appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: prefix.path, isDirectory: &isDir), isDir.boolValue else {
            throw CrossError("no bottle '\(name)' in \(project.bottles.path)")
        }
        return Bottle(name: name, prefix: prefix, config: try readConfig(prefix: prefix))
    }

    public static func readConfig(prefix: URL) throws -> BottleConfig {
        let url = prefix.appendingPathComponent(configFile)
        if let data = try? Data(contentsOf: url) {
            do { return try JSONDecoder().decode(BottleConfig.self, from: data) }
            catch { throw CrossError("cannot parse \(url.path): \(error)") }
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

    public static func list(in project: Project) throws -> [Bottle] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: project.bottles, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        return try entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { Bottle(name: $0.lastPathComponent, prefix: $0, config: try readConfig(prefix: $0)) }
    }
}
