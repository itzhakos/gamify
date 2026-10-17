import Foundation

/// Where the runtimes live. In the checkout this is the project root (runtimes/,
/// bottles/, src/webhelper-shim all under it). In a packaged Cross.app the root is
/// `Contents/Resources/root` inside the bundle (runtimes + shim only) and the
/// user's data (bottles, downloads) lives in ~/Library/Application Support/Gamify.
/// (SharedSupport, not Resources: codesign refuses nested code and frameworks such as
/// D3DMetal.framework under Resources; CrossOver uses the same layout.)
public struct Project {
    public let root: URL
    /// True when `root` is inside an app bundle (scripts/package-app.sh layout).
    public let bundled: Bool
    /// Where bottles and downloads go (the checkout itself, or Application Support).
    public let dataDir: URL

    public init(root: URL, bundled: Bool = false, dataDir: URL? = nil) {
        self.root = root
        self.bundled = bundled
        self.dataDir = dataDir ?? (bundled ? Project.applicationSupport : root)
    }

    public static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Gamify")
    }

    public var runtimes: URL { root.appendingPathComponent("runtimes") }
    public var bottles: URL { dataDir.appendingPathComponent("bottles") }
    public var downloads: URL { dataDir.appendingPathComponent("downloads") }
    public var webhelperShimDir: URL { root.appendingPathComponent("src/webhelper-shim") }
    public var webhelperShim: URL { webhelperShimDir.appendingPathComponent("steamwebhelper.exe") }
    /// Third-party notices shipped with a packaged app (docs/LICENSING.md in the checkout).
    public var notices: URL {
        bundled ? root.appendingPathComponent("THIRD_PARTY_NOTICES.md") : root.appendingPathComponent("docs/LICENSING.md")
    }

    /// `CROSS_ROOT` wins; then a bundled root next to the executable
    /// (`<App>.app/Contents/SharedSupport/root`); otherwise walk up from the executable,
    /// then from the current directory, until a directory that contains `runtimes/`
    /// and `scripts/` (or `cli/Package.swift`) is found. `CROSS_BOTTLES` overrides
    /// where bottles are kept (its parent becomes the data dir).
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Project {
        var dataDir: URL? = nil
        if let b = environment["CROSS_BOTTLES"], !b.isEmpty {
            dataDir = URL(fileURLWithPath: b).standardizedFileURL.deletingLastPathComponent()
        }
        if let explicit = environment["CROSS_ROOT"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit).standardizedFileURL
            guard looksLikeRoot(url) else { throw CrossError("CROSS_ROOT=\(explicit) is not a Cross checkout") }
            return Project(root: url, bundled: isInsideBundle(url), dataDir: dataDir)
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let exeDir = exe.deletingLastPathComponent()
        // Contents/MacOS/CrossApp -> Contents/SharedSupport/root
        if exeDir.lastPathComponent == "MacOS" {
            let bundledRoot = exeDir.deletingLastPathComponent().appendingPathComponent("SharedSupport/root")
            if looksLikeRoot(bundledRoot) { return Project(root: bundledRoot, bundled: true, dataDir: dataDir) }
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for start in [exeDir, cwd] {
            var dir = start.standardizedFileURL
            while true {
                if looksLikeRoot(dir) { return Project(root: dir, bundled: false, dataDir: dataDir) }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        throw CrossError("cannot find the Cross project root (set CROSS_ROOT)")
    }

    private static func isInsideBundle(_ url: URL) -> Bool {
        url.pathComponents.contains { $0.hasSuffix(".app") } && url.path.contains("/Contents/SharedSupport/")
    }

    private static func looksLikeRoot(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let hasRuntimes = fm.fileExists(atPath: dir.appendingPathComponent("runtimes").path)
        let hasScripts = fm.fileExists(atPath: dir.appendingPathComponent("scripts").path)
        let hasCli = fm.fileExists(atPath: dir.appendingPathComponent("cli/Package.swift").path)
        return (hasRuntimes && hasScripts) || hasCli
    }
}

public struct CrossError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}
