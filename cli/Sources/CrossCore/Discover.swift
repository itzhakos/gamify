import Foundation

/// Bottles on other drives: Eject (so a drive holding a mounted bottle image can be
/// disconnected), Find (search connected drives or a folder for bottles that are not in
/// the bottles folder, e.g. a drive brought over from another Mac) and Add (list one
/// through a link + .location file, like a bottle created there; Location.swift).

/// A bottle found on a drive by `Bottle.find`.
public struct FoundBottle: Equatable, Identifiable {
    public var id: String { url.path }
    /// The bottle's folder or its .sparsebundle (real path).
    public let url: URL
    public let isImage: Bool
    /// Its cross.json (nil when it has none: an old bottle, or an image that could not
    /// be looked into).
    public let config: BottleConfig?
    /// The name it is listed under in the bottles folder, nil when it is not listed.
    public let registeredAs: String?

    /// The bottle's folder name without .sparsebundle, the name it is added under.
    public var suggestedName: String { url.deletingPathExtension().lastPathComponent }
}

extension Bottle {
    /// bottles/.<name>.ejected: set by Eject, so listing the bottles does not mount the
    /// image again (the app lists them every time it comes to the front); using the
    /// bottle (load) mounts it and removes the flag.
    static func ejectedFlag(name: String, in project: Project) -> URL {
        project.bottles.appendingPathComponent(".\(name).ejected")
    }

    static func ejectedMessage(name: String) -> String {
        "'\(name)' is ejected, so its drive can be disconnected; mount it again to use it"
    }

    /// True for an image-backed bottle that was ejected and not used since.
    public var isEjected: Bool {
        FileManager.default.fileExists(atPath: prefix.deletingLastPathComponent().appendingPathComponent(".\(name).ejected").path)
    }

    /// Connected drives worth searching: local, writable volumes under /Volumes other
    /// than the startup disk (network shares are searched only when chosen as a folder).
    public static func searchableVolumes() -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") else { return [] }
        return names.sorted().compactMap { name in
            let url = URL(fileURLWithPath: "/Volumes").appendingPathComponent(name)
            guard !name.hasPrefix("."), name != "Recovery", !isSymlink(url), DiskImage.isMountPoint(url) else { return nil }
            var s = statfs()
            guard statfs(url.path, &s) == 0 else { return nil }
            let flags = Int32(bitPattern: s.f_flags)
            guard flags & MNT_LOCAL != 0, flags & MNT_RDONLY == 0, flags & MNT_ROOTFS == 0 else { return nil }
            return url
        }
    }

    /// Real path -> name of every bottle in the bottles folder (links resolved).
    static func registeredPaths(in project: Project) -> [String: String] {
        var paths: [String: String] = [:]
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: project.bottles.path)) ?? [] where !entry.hasPrefix(".") {
            let url = project.bottles.appendingPathComponent(entry)
            guard isDirectory(url) else { continue }
            paths[DiskImage.realPath(url)] = url.pathExtension == imageExtension ? url.deletingPathExtension().lastPathComponent : entry
        }
        return paths
    }

    /// A Wine prefix: drive_c next to system.reg or cross.json.
    static func looksLikePrefix(_ url: URL) -> Bool {
        let fm = FileManager.default
        return isDirectory(url.appendingPathComponent("drive_c"))
            && (fm.fileExists(atPath: url.appendingPathComponent("system.reg").path)
                || fm.fileExists(atPath: url.appendingPathComponent(configFile).path))
    }

    /// Searches `folders` (and folders in them, `maxDepth` levels down) for bottle
    /// folders and .sparsebundle images holding a bottle. Images are looked into
    /// read-only (attached at a temporary mount point for a moment); ones without a
    /// cross.json are not bottles and are left out.
    public static func find(in folders: [URL], project: Project, maxDepth: Int = 3) -> [FoundBottle] {
        let fm = FileManager.default
        let registered = registeredPaths(in: project)
        var found: [FoundBottle] = []
        var seen = Set<String>()
        var visited = 0
        func consider(_ url: URL) -> Bool {
            let real = DiskImage.realPath(url)
            guard !seen.contains(real) else { return true }
            let realURL = URL(fileURLWithPath: real)
            if url.pathExtension == imageExtension {
                seen.insert(real)
                let name = registered[real]
                // an image that is listed and not mounted (ejected) is not looked into
                let config = name != nil && DiskImage.attachment(of: realURL) == nil ? nil : probeImage(realURL)
                if config != nil || name != nil {
                    found.append(FoundBottle(url: realURL, isImage: true, config: config, registeredAs: name))
                }
                return true
            }
            guard looksLikePrefix(url) else { return false }
            seen.insert(real)
            let hasConfig = fm.fileExists(atPath: url.appendingPathComponent(configFile).path)
            found.append(FoundBottle(url: realURL, isImage: false,
                                     config: hasConfig ? try? readConfig(prefix: url, folder: true) : nil,
                                     registeredAs: registered[real]))
            return true
        }
        var queue: [(URL, Int)] = []
        for folder in folders where isDirectory(folder) {
            if !consider(folder) { queue.append((folder, 0)) }
        }
        while !queue.isEmpty, visited < 20_000 {
            let (dir, depth) = queue.removeFirst()
            visited += 1
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let child = dir.appendingPathComponent(name)
                guard !isSymlink(child), isDirectory(child) else { continue }
                if consider(child) { continue }
                // plain folders only: not into packages (.app, .photoslibrary, ...)
                if depth + 1 < maxDepth, child.pathExtension.isEmpty { queue.append((child, depth + 1)) }
            }
        }
        return found
    }

    /// cross.json of the bottle inside an image: read where it is mounted, or attach it
    /// read-only at a temporary mount point for a moment. nil when it holds none.
    static func probeImage(_ image: URL) -> BottleConfig? {
        func read(_ mountPoint: URL) -> BottleConfig? {
            guard let data = try? Data(contentsOf: mountPoint.appendingPathComponent(configFile)) else { return nil }
            return try? JSONDecoder().decode(BottleConfig.self, from: data)
        }
        if let attached = DiskImage.attachment(of: image) {
            return attached.mountPoint.flatMap { read(URL(fileURLWithPath: $0)) }
        }
        let fm = FileManager.default
        let mountPoint = fm.temporaryDirectory.appendingPathComponent("gamify-probe-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)) != nil else { return nil }
        defer {
            if DiskImage.isMountPoint(mountPoint) { try? DiskImage.detach(mountPoint.path, force: true) }
            try? fm.removeItem(at: mountPoint)
        }
        guard (try? DiskImage.hdiutil(["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint.path, image.path],
                                      what: "probe")) != nil else { return nil }
        return read(mountPoint)
    }
}

extension Runtime {
    /// `cross bottle eject` / Eject in the app: unmounts an image-backed bottle's volume
    /// so the drive that holds the image can be disconnected, and keeps it unmounted
    /// until the bottle is used again (listing it does not mount it).
    public func ejectBottle(_ bottle: Bottle) throws {
        guard bottle.image != nil else {
            throw CrossError("'\(bottle.name)' is a folder bottle: there is nothing to eject; quit its programs, then eject the drive in Finder")
        }
        if bottle.isEjected { return }
        if let error = bottle.storageError { throw CrossError(error) }
        try requireIdle(bottle, for: "eject the bottle")
        try bottle.unmount()
        FileManager.default.createFile(atPath: Bottle.ejectedFlag(name: bottle.name, in: project).path, contents: nil)
    }

    /// `cross bottle add` / Add in Find Bottles: lists a bottle that lives elsewhere (a
    /// folder or a .sparsebundle, e.g. on a drive from another Mac) in the bottles folder
    /// under `name` (default: its folder name), the way `createBottle(location:)` does.
    /// The bottle itself is not changed, except an image's cross.json "storage.image"
    /// when it is added under another name.
    public func addBottle(at url: URL, name: String? = nil) throws -> Bottle {
        let fm = FileManager.default
        let real = URL(fileURLWithPath: DiskImage.realPath(url))
        let isImage = real.pathExtension == Bottle.imageExtension
        guard Bottle.isDirectory(real) else { throw CrossError("\(url.path) is not a bottle folder or disk image that exists") }
        let name = name ?? real.deletingPathExtension().lastPathComponent
        try Bottle.validate(name: name)
        if let listed = Bottle.registeredPaths(in: project)[real.path] {
            throw CrossError("\(real.path) is already listed as '\(listed)'")
        }
        guard DiskImage.realPath(real.deletingLastPathComponent()) != DiskImage.realPath(project.bottles) else {
            throw CrossError("\(real.path) is in the bottles folder itself; rename it there instead")
        }
        let prefix = project.bottles.appendingPathComponent(name)
        let image = Bottle.imageURL(name: name, in: project)
        for entry in [prefix, image, Bottle.locationURL(name: name, in: project)]
        where fm.fileExists(atPath: entry.path) || Bottle.isSymlink(entry) {
            throw CrossError("a bottle named '\(name)' already exists; add this one under another name")
        }
        try fm.createDirectory(at: project.bottles, withIntermediateDirectories: true)
        if !isImage {
            guard Bottle.looksLikePrefix(real) else { throw CrossError("\(real.path) does not look like a bottle (no drive_c with system.reg or cross.json)") }
            try Runtime.checkFolderBottle(at: real)
            try Runtime.checkOwnership(of: real)
            try fm.createSymbolicLink(at: prefix, withDestinationURL: real)
            do {
                try Bottle.recordLocation(real, name: name, in: project)
                return try Bottle.load(name: name, in: project)
            } catch {
                try? fm.removeItem(at: prefix)
                try? Bottle.recordLocation(nil, name: name, in: project)
                throw error
            }
        }
        try fm.createSymbolicLink(at: image, withDestinationURL: real)
        do {
            try Bottle.recordLocation(real, name: name, in: project)
            var bottle = try Bottle.load(name: name, in: project)
            guard FileManager.default.fileExists(atPath: bottle.prefix.appendingPathComponent(Bottle.configFile).path) else {
                throw CrossError("\(real.lastPathComponent) holds no bottle (no cross.json inside)")
            }
            if let storage = bottle.config.storage, storage.image != image.lastPathComponent {
                bottle.config.storage?.image = image.lastPathComponent
                try bottle.saveConfig()
            }
            return bottle
        } catch {
            if DiskImage.isMountPoint(prefix) { try? DiskImage.detach(prefix.path, force: true) }
            if Bottle.isDirectory(prefix), !DiskImage.isMountPoint(prefix) { try? fm.removeItem(at: prefix) }
            try? fm.removeItem(at: image)
            try? Bottle.recordLocation(nil, name: name, in: project)
            throw error
        }
    }

    /// `cross bottle forget` / Remove from List: takes a bottle that lives elsewhere out of
    /// the bottles folder (link, .location file, mount point) and leaves its data where
    /// it is, so it can be added again later or on another Mac.
    public func forgetBottle(_ bottle: Bottle) throws {
        guard bottle.location != nil else {
            throw CrossError("'\(bottle.name)' lives in the bottles folder itself; only a bottle kept elsewhere can be removed from the list")
        }
        if bottle.storageError == nil || bottle.isEjected {
            if bottle.storageError == nil { try requireIdle(bottle, for: "remove the bottle from the list") }
            try bottle.unmount()
        }
        let fm = FileManager.default
        for link in [bottle.prefix, Bottle.imageURL(name: bottle.name, in: project)] where Bottle.isSymlink(link) {
            try fm.removeItem(at: link)
        }
        if Bottle.isDirectory(bottle.prefix), !Bottle.isSymlink(bottle.prefix), !DiskImage.isMountPoint(bottle.prefix),
           ((try? fm.contentsOfDirectory(atPath: bottle.prefix.path)) ?? []).allSatisfy(Bottle.ignorableNames.contains) {
            try fm.removeItem(at: bottle.prefix)
        }
        try Bottle.recordLocation(nil, name: bottle.name, in: project)
        try? fm.removeItem(at: Bottle.ejectedFlag(name: bottle.name, in: project))
    }

    /// Wine refuses a prefix that belongs to another user ("not owned by you"). A drive
    /// from another Mac keeps that Mac's user id unless the volume ignores ownership
    /// (the default for most external drives; Finder > Get Info > "Ignore ownership on
    /// this volume").
    static func checkOwnership(of folder: URL) throws {
        var st = stat()
        guard stat(folder.path, &st) == 0, st.st_uid != getuid() else { return }
        var s = statfs()
        guard statfs(folder.path, &s) == 0, Int32(bitPattern: s.f_flags) & MNT_IGNORE_OWNERSHIP == 0 else { return }
        throw CrossError("\(folder.path) belongs to another user account (uid \(st.st_uid)), which Wine refuses; in Finder select \(DiskImage.fileSystem(at: folder)?.volume ?? "the drive"), File > Get Info, check \"Ignore ownership on this volume\", then try again")
    }
}
