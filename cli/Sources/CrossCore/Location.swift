import Foundation

/// Per-bottle location: a bottle can keep its data outside the bottles folder, e.g. on an
/// external drive. The bottles folder stays the registry: every bottle has its entry
/// there, and one that lives elsewhere is reached through a symlink, so every other code
/// path (Bottle.list/load, processes by cwd, Programs, Stores, Storage) works unchanged.
///
///   folder bottle `foo` kept in /Volumes/Ext/Games:
///     bottles/foo                -> /Volumes/Ext/Games/foo                 (symlink)
///     bottles/foo.location          "/Volumes/Ext/Games/foo"
///   image-backed bottle `bar` kept in /Volumes/Ext/Games:
///     bottles/bar.sparsebundle   -> /Volumes/Ext/Games/bar.sparsebundle    (symlink)
///     bottles/bar                   its mount point, local like every image bottle's
///     bottles/bar.location          "/Volumes/Ext/Games/bar.sparsebundle"
///
/// The `.location` file (the target's real path) names the target even when the link
/// dangles, so a bottle whose drive is unplugged is listed as unavailable ("'foo' lives
/// on /Volumes/Ext which is not connected") instead of vanishing; nothing is recreated
/// or deleted automatically. cross.json stays inside the bottle.
///
/// File systems: a folder bottle needs APFS or Mac OS Extended (HFS+). A Wine prefix holds
/// symlinks (dosdevices/c: -> ../drive_c, z: -> /) and relies on Unix permissions, which
/// exFAT, FAT and NTFS do not have. A disk image works on any writable file system: a
/// sparse bundle is a folder of 8 MB band files with APFS inside.
extension Bottle {
    public static let locationExtension = "location"

    /// bottles/<name>.location
    public static func locationURL(name: String, in project: Project) -> URL {
        project.bottles.appendingPathComponent("\(name).\(locationExtension)")
    }

    /// The target recorded in bottles/<name>.location, nil for a bottle in the bottles folder.
    static func recordedLocation(name: String, in project: Project) -> URL? {
        guard let text = try? String(contentsOf: locationURL(name: name, in: project), encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }

    /// Writes bottles/<name>.location, or removes it (`target` nil).
    static func recordLocation(_ target: URL?, name: String, in project: Project) throws {
        let url = locationURL(name: name, in: project)
        guard let target else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try (target.path + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// The folder that holds the bottle's data (folder or disk image): the location's
    /// parent, or the bottles folder.
    public func home(in project: Project) -> URL {
        location?.deletingLastPathComponent() ?? project.bottles
    }

    /// True when the bottle lives somewhere that cannot be reached now (drive not
    /// connected). Deleting such a bottle only removes its entry in the bottles folder.
    public var isUnreachable: Bool {
        guard let location else { return false }
        return !FileManager.default.fileExists(atPath: location.path)
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// A directory, following symlinks (URL's isDirectoryKey is false for a link).
    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// A bottle entry in bottles/: a directory, a link to one, or a link that dangles.
    static func isEntry(_ url: URL) -> Bool {
        isDirectory(url) || (isSymlink(url) && !FileManager.default.fileExists(atPath: url.path))
    }

    /// Why a bottle kept at `target` cannot be reached now; nil when it can.
    static func unreachableError(name: String, target: URL) -> String? {
        guard !FileManager.default.fileExists(atPath: target.path) else { return nil }
        let parts = target.standardizedFileURL.pathComponents
        if parts.count > 2, parts[1] == "Volumes" {
            let volume = URL(fileURLWithPath: "/Volumes/\(parts[2])")
            if !DiskImage.isMountPoint(volume) {
                return "'\(name)' lives on \(volume.path) which is not connected"
            }
        }
        return "'\(name)' is missing from \(target.deletingLastPathComponent().path) (there is no \(target.lastPathComponent))"
    }

    /// An entry in bottles/ that links to something that is not there.
    static func danglingLinkError(name: String, link: URL) -> String? {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
              !FileManager.default.fileExists(atPath: link.path) else { return nil }
        let target = dest.hasPrefix("/") ? URL(fileURLWithPath: dest)
                                         : link.deletingLastPathComponent().appendingPathComponent(dest)
        return unreachableError(name: name, target: target) ?? "\(link.path) points to \(dest), which does not exist"
    }

    /// Points the link at `target`, replacing an existing link in one rename(2).
    static func replaceLink(_ link: URL, to target: URL) throws {
        let fm = FileManager.default
        let temporary = link.deletingLastPathComponent().appendingPathComponent(".\(link.lastPathComponent).link")
        try? fm.removeItem(at: temporary)
        try fm.createSymbolicLink(at: temporary, withDestinationURL: target)
        guard rename(temporary.path, link.path) == 0 else {
            let error = String(cString: strerror(errno))
            try? fm.removeItem(at: temporary)
            throw CrossError("cannot point \(link.path) at \(target.path): \(error)")
        }
    }

    /// Deletes `._*` files (exFAT's extended attribute files, copied as plain files) in a
    /// disk image bundle that now lives on APFS or Mac OS Extended.
    static func removeAppleDouble(in bundle: URL) {
        for dir in [bundle, bundle.appendingPathComponent("bands")] {
            guard let d = opendir(dir.path) else { continue }
            var names: [String] = []
            while let entry = readdir(d) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                if name.hasPrefix("._") { names.append(name) }
            }
            closedir(d)
            names.forEach { unlink(dir.appendingPathComponent($0).path) }
        }
    }

    /// Removes a bottle's data at `url`: for a link, its target and then the link.
    static func removeData(at url: URL) throws {
        let fm = FileManager.default
        if isSymlink(url) {
            let target = URL(fileURLWithPath: DiskImage.realPath(url))
            if fm.fileExists(atPath: target.path), target.path != url.path { try fm.removeItem(at: target) }
        }
        if fm.fileExists(atPath: url.path) || isSymlink(url) { try fm.removeItem(at: url) }
    }
}

extension DiskImage {
    /// statfs of `url` (or its nearest existing parent): the file system type as macOS
    /// names it ("apfs", "hfs", "exfat", "msdos", "ntfs", "smbfs", ...) and its mount point.
    public static func fileSystem(at url: URL) -> (type: String, volume: String)? {
        var dir = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: dir.path), dir.path != "/" {
            dir = dir.deletingLastPathComponent()
        }
        var s = statfs()
        guard statfs(dir.path, &s) == 0 else { return nil }
        func text<T>(_ field: inout T) -> String {
            withUnsafePointer(to: &field) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
            }
        }
        return (text(&s.f_fstypename), text(&s.f_mntonname))
    }

    /// The name Disk Utility shows for a statfs file system type.
    public static func fileSystemName(_ type: String) -> String {
        switch type {
        case "apfs": return "APFS"
        case "hfs": return "Mac OS Extended"
        case "exfat": return "exFAT"
        case "msdos": return "MS-DOS (FAT)"
        case "ntfs": return "NTFS"
        case "smbfs": return "a network share (SMB)"
        case "nfs": return "a network share (NFS)"
        default: return type
        }
    }
}

extension Runtime {
    /// File systems a folder bottle can live on (statfs f_fstypename).
    public static let folderFileSystems: Set<String> = ["apfs", "hfs"]

    /// Nil when a folder bottle can live in `folder`, else why not.
    public static func folderBottleProblem(at folder: URL) -> String? {
        guard let fs = DiskImage.fileSystem(at: folder) else { return "cannot read the file system of \(folder.path)" }
        guard !folderFileSystems.contains(fs.type) else { return nil }
        return "\(fs.volume) is formatted as \(DiskImage.fileSystemName(fs.type)), which cannot hold a folder bottle (Wine needs symbolic links and Unix permissions, which only APFS and Mac OS Extended have); give the bottle its own disk image instead, which works on any drive"
    }

    static func checkFolderBottle(at folder: URL) throws {
        if let problem = folderBottleProblem(at: folder) { throw CrossError(problem) }
    }

    /// Checks a folder chosen as a bottle's location and returns its real path; nil for
    /// no folder or the bottles folder itself (the default location).
    public func checkLocation(_ folder: URL?) throws -> URL? {
        guard let folder else { return nil }
        let fm = FileManager.default
        guard Bottle.isDirectory(folder) else {
            throw CrossError("\(folder.path) is not a folder that exists (is its drive connected?)")
        }
        let real = URL(fileURLWithPath: DiskImage.realPath(folder))
        let registry = DiskImage.realPath(project.bottles)
        if real.path == registry { return nil }
        guard !real.path.hasPrefix(registry + "/") else {
            throw CrossError("choose a folder outside the bottles folder \(project.bottles.path) (or that folder itself)")
        }
        // not inside a bottle that lives elsewhere (or its disk image)
        for entry in (try? fm.contentsOfDirectory(atPath: project.bottles.path)) ?? [] {
            let url = project.bottles.appendingPathComponent(entry)
            guard Bottle.isSymlink(url) else { continue }
            let target = DiskImage.realPath(url)
            if real.path == target || real.path.hasPrefix(target + "/") {
                throw CrossError("\(folder.path) is inside the bottle '\(url.deletingPathExtension().lastPathComponent)'")
            }
        }
        guard fm.isWritableFile(atPath: real.path) else { throw CrossError("\(real.path) is not writable") }
        return real
    }

    /// The copy needs the bottle's size plus 1 GB of headroom on the target's disk.
    func requireFree(_ bytes: Int64, at folder: URL, for name: String) throws {
        let free = DiskImage.hostFreeBytes(at: folder)
        guard bytes + BottleStorage.gib <= free else {
            throw CrossError("moving '\(name)' needs \(formatGB(bytes + BottleStorage.gib)) free for the copy; \(DiskImage.fileSystem(at: folder)?.volume ?? folder.path) has \(formatGB(free))")
        }
    }

    /// `cross bottle set <name> location <folder>|default` / Move to… in the app: copies
    /// the bottle (its folder, or its whole .sparsebundle after ejecting it) to `folder`
    /// (nil: the bottles folder), verifies the copy, swaps the entry in the bottles folder
    /// over to it and only then deletes the original. Refused while programs run.
    public func moveBottle(_ bottle: Bottle, to folder: URL?, progress: @escaping (String) -> Void = { _ in }) throws -> Bottle {
        if let error = bottle.storageError { throw CrossError(error) }
        let destination = try checkLocation(folder)
        let home = destination ?? project.bottles
        guard DiskImage.realPath(home) != DiskImage.realPath(bottle.home(in: project)) else {
            throw CrossError("'\(bottle.name)' already lives in \(home.path)")
        }
        if !bottle.isImageBacked { try Runtime.checkFolderBottle(at: home) }
        try requireIdle(bottle, for: "move the bottle")
        return bottle.isImageBacked
            ? try moveImage(bottle, to: destination, progress: progress)
            : try moveFolder(bottle, to: destination, progress: progress)
    }

    /// Runs `steps` in order; when one throws, the undo actions recorded so far run in
    /// reverse and the error is rethrown.
    private func undoable(_ steps: (inout [() -> Void]) throws -> Void) throws {
        var undo: [() -> Void] = []
        do {
            try steps(&undo)
        } catch {
            undo.reversed().forEach { $0() }
            throw error
        }
    }

    private func moveFolder(_ bottle: Bottle, to destination: URL?, progress: @escaping (String) -> Void) throws -> Bottle {
        let fm = FileManager.default
        let name = bottle.name
        let home = destination ?? project.bottles
        let source = URL(fileURLWithPath: DiskImage.realPath(bottle.prefix))
        let target = home.appendingPathComponent(name)
        let staging = home.appendingPathComponent(".\(name).moving")
        if destination != nil, fm.fileExists(atPath: target.path) || Bottle.isSymlink(target) {
            throw CrossError("\(target.path) already exists")
        }
        guard !fm.fileExists(atPath: staging.path) else { throw CrossError("\(staging.path) is left over from an earlier move; remove it first") }
        progress("Measuring \(name)…")
        let summary = try TreeSummary(of: source)
        try requireFree(summary.allocated, at: home, for: name)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            try copyTree(from: source, to: staging, total: summary.allocated, progress: progress)
            progress("Verifying the copy…")
            try summary.verify(against: TreeSummary(of: staging))
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        progress("Switching \(name) to \(home.path)…")
        let backup = project.bottles.appendingPathComponent(".\(name).folder")
        do {
            try undoable { undo in
                if let old = bottle.location {
                    if destination != nil {
                        try fm.moveItem(at: staging, to: target)
                        undo.append { try? fm.moveItem(at: target, to: staging) }
                        try Bottle.replaceLink(bottle.prefix, to: target)
                        undo.append { try? Bottle.replaceLink(bottle.prefix, to: old) }
                    } else {
                        try fm.removeItem(at: bottle.prefix)   // the link
                        undo.append { try? fm.createSymbolicLink(at: bottle.prefix, withDestinationURL: old) }
                        try fm.moveItem(at: staging, to: bottle.prefix)
                        undo.append { try? fm.moveItem(at: bottle.prefix, to: staging) }
                    }
                } else {
                    guard !fm.fileExists(atPath: backup.path) else { throw CrossError("\(backup.path) is left over from an earlier move; remove it first") }
                    try fm.moveItem(at: bottle.prefix, to: backup)
                    undo.append { try? fm.moveItem(at: backup, to: bottle.prefix) }
                    try fm.moveItem(at: staging, to: target)
                    undo.append { try? fm.moveItem(at: target, to: staging) }
                    try fm.createSymbolicLink(at: bottle.prefix, withDestinationURL: target)
                    undo.append { try? fm.removeItem(at: bottle.prefix) }
                }
                try Bottle.recordLocation(destination == nil ? nil : target, name: name, in: project)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        progress("Removing the old copy…")
        try fm.removeItem(at: bottle.location ?? backup)
        return try Bottle.load(name: name, in: project)
    }

    private func moveImage(_ bottle: Bottle, to destination: URL?, progress: @escaping (String) -> Void) throws -> Bottle {
        guard let link = bottle.image else { throw CrossError("'\(bottle.name)' has no disk image") }
        let fm = FileManager.default
        let name = bottle.name
        let home = destination ?? project.bottles
        let source = URL(fileURLWithPath: DiskImage.realPath(link))
        let target = destination.map { $0.appendingPathComponent(link.lastPathComponent) } ?? link
        let staging = home.appendingPathComponent(".\(name).moving.\(Bottle.imageExtension)")
        if destination != nil, fm.fileExists(atPath: target.path) || Bottle.isSymlink(target) {
            throw CrossError("\(target.path) already exists")
        }
        guard !fm.fileExists(atPath: staging.path) else { throw CrossError("\(staging.path) is left over from an earlier move; remove it first") }
        let backup = project.bottles.appendingPathComponent(".\(name).\(Bottle.imageExtension).old")
        guard bottle.location != nil || !fm.fileExists(atPath: backup.path) else {
            throw CrossError("\(backup.path) is left over from an earlier move; remove it first")
        }
        progress("Ejecting \(name)…")
        try bottle.unmount()
        try undoable { undo in
            undo.append { try? Bottle.mount(image: link, at: bottle.prefix) }   // the original, again
            undo.append { try? fm.removeItem(at: staging) }
            progress("Measuring \(name)…")
            let summary = try TreeSummary(of: source)
            try requireFree(summary.allocated, at: home, for: name)
            // a sparse bundle needs no extended attributes; macOS keeps them in ._ files on
            // exFAT, which ditto copies as plain files (FileManager does not list them, so
            // the comparison does not see them either); they are dropped on APFS
            try copyTree(from: source, to: staging, total: summary.allocated, progress: progress,
                         options: ["--norsrc", "--noextattr", "--noacl", "--noqtn"])
            if Runtime.folderBottleProblem(at: home) == nil { Bottle.removeAppleDouble(in: staging) }
            progress("Verifying the copy…")
            try summary.verify(against: TreeSummary(of: staging))
            progress("Switching \(name) to \(home.path)…")
            if let old = bottle.location {
                if destination != nil {
                    try fm.moveItem(at: staging, to: target)
                    undo.append { try? fm.moveItem(at: target, to: staging) }
                    try Bottle.replaceLink(link, to: target)
                    undo.append { try? Bottle.replaceLink(link, to: old) }
                } else {
                    try fm.removeItem(at: link)
                    undo.append { try? fm.createSymbolicLink(at: link, withDestinationURL: old) }
                    try fm.moveItem(at: staging, to: link)
                    undo.append { try? fm.moveItem(at: link, to: staging) }
                }
            } else {
                try fm.moveItem(at: link, to: backup)
                undo.append { try? fm.moveItem(at: backup, to: link) }
                try fm.moveItem(at: staging, to: target)
                undo.append { try? fm.moveItem(at: target, to: staging) }
                try fm.createSymbolicLink(at: link, withDestinationURL: target)
                undo.append { try? fm.removeItem(at: link) }
            }
            try Bottle.recordLocation(destination == nil ? nil : target, name: name, in: project)
            undo.append { try? Bottle.recordLocation(bottle.location, name: name, in: self.project) }
            try Bottle.mount(image: link, at: bottle.prefix)
        }
        progress("Removing the old disk image…")
        try fm.removeItem(at: bottle.location ?? backup)
        return try Bottle.load(name: name, in: project)
    }
}
