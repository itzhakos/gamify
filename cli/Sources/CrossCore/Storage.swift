import Foundation

/// Per-bottle disk allocation. A bottle is either a plain folder (`bottles/<name>`, no
/// limit, the original layout) or backed by an APFS sparse bundle disk image
/// `bottles/<name>.sparsebundle` mounted at `bottles/<name>`. The image is the bottle's
/// own volume, so Windows reports C: as a drive of the allocated size and installers
/// (Steam included) see the real free space. Sparse: the image only takes the space
/// that was actually written.
///
/// Layout of an image-backed bottle `foo`:
///   bottles/foo.sparsebundle   the image (`hdiutil create -type SPARSEBUNDLE -fs APFS`)
///   bottles/foo/               its mount point (`hdiutil attach -nobrowse -noautoopen
///                              -mountpoint`); while unmounted it holds only the marker
///                              file `.gamify-disk-image` (the image's file name), so a
///                              bottle whose image went missing is told apart from an
///                              empty folder bottle
///   bottles/foo/cross.json     inside the image, with "storage": {"image", "sizeGB"}
/// The bottle is image-backed exactly when the image exists; it is mounted lazily by
/// `Bottle.load` and `Bottle.list` (after a reboot, or after `hdiutil detach`).
/// Sizes are whole GiB, called GB as hdiutil (`-size 64g`) and Windows do.
public struct BottleStorage: Codable, Equatable {
    /// File name of the image next to the bottle, "<name>.sparsebundle".
    public var image: String
    /// Allocation set by `cross` / Gamify. The mounted volume's size is the live value.
    public var sizeGB: Int

    public init(image: String, sizeGB: Int) {
        self.image = image
        self.sizeGB = sizeGB
    }

    public static let minimumGB = 8
    public static let defaultGB = 64
    public static let gib: Int64 = 1 << 30
}

/// Size and use of a bottle's volume (image-backed bottles) from statfs.
public struct StorageUsage: Equatable {
    public var total: Int64
    public var used: Int64
    public var available: Int64

    public var fraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
}

/// Formats a byte count the way the UI and `cross bottle list` show it ("3.4 GB").
public func formatGB(_ bytes: Int64) -> String {
    let gb = Double(bytes) / Double(BottleStorage.gib)
    return gb >= 100 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
}

/// Thin wrapper around /usr/bin/hdiutil (still the tool for this on macOS 27: it prints a
/// deprecation warning pointing at `diskutil image`, which these calls filter out).
public enum DiskImage {
    static let hdiutilPath = "/usr/bin/hdiutil"
    static let dittoPath = "/usr/bin/ditto"

    /// Runs a tool to completion; stdout as data, stderr as text without hdiutil's
    /// "is deprecated" warnings.
    @discardableResult
    static func run(_ program: String, _ arguments: [String]) throws -> (status: Int32, output: Data, errors: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: program)
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        // stderr on its own thread, so neither pipe can fill up and block the child
        var errData = Data()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        done.wait()
        let errors = String(decoding: errData, as: UTF8.self)
            .split(separator: "\n")
            .filter { !$0.contains("is deprecated") }
            .joined(separator: "\n")
        return (p.terminationStatus, outData, errors)
    }

    static func hdiutil(_ arguments: [String], what: String) throws -> Data {
        let r = try run(hdiutilPath, arguments)
        guard r.status == 0 else {
            let detail = r.errors.isEmpty ? "exit \(r.status)" : r.errors
            throw CrossError("\(what): \(detail)")
        }
        return r.output
    }

    /// hdiutil create + resize to the same size: a fresh image's APFS volume comes out
    /// ~200 MB short of `-size`; after the resize it is exactly `sizeGB` GiB.
    public static func create(_ image: URL, sizeGB: Int, volumeName: String) throws {
        _ = try hdiutil(["create", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-size", "\(sizeGB)g",
                         "-volname", volumeName, image.path], what: "cannot create \(image.lastPathComponent)")
        try resize(image, sizeGB: sizeGB)
    }

    /// Mounts `image` at `mountPoint` without a Finder sidebar entry or a window.
    /// Attaching an image that is already mounted at this mount point is a no-op.
    public static func attach(_ image: URL, at mountPoint: URL) throws {
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        _ = try hdiutil(["attach", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint.path, image.path],
                        what: "cannot mount \(image.lastPathComponent)")
    }

    /// Unmounts and ejects the image mounted at `mountPoint` (or a /dev/diskN entry).
    public static func detach(_ target: String, force: Bool = false) throws {
        _ = try hdiutil(["detach"] + (force ? ["-force"] : []) + [target], what: "cannot unmount \(target)")
    }

    /// Grows or shrinks the image (and its APFS container and volume). The image must
    /// not be attached: hdiutil refuses with EAGAIN, by path and by device.
    public static func resize(_ image: URL, sizeGB: Int) throws {
        _ = try hdiutil(["resize", "-size", "\(sizeGB)g", image.path], what: "cannot resize \(image.lastPathComponent)")
    }

    /// Gives the host the bands of space freed inside the image back (deleting files in
    /// the bottle does not shrink the image by itself). Detached only; fast (~0.2 s).
    public static func compact(_ image: URL) throws {
        _ = try hdiutil(["compact", image.path], what: "cannot compact \(image.lastPathComponent)")
    }

    /// Smallest size the (detached) image can be shrunk to, from `hdiutil resize -limits`.
    public static func minimumBytes(_ image: URL) throws -> Int64 {
        let out = try hdiutil(["resize", "-limits", image.path], what: "cannot read the limits of \(image.lastPathComponent)")
        let fields = String(decoding: out, as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard let sectors = fields.first.flatMap({ Int64($0) }) else { throw CrossError("unexpected hdiutil resize -limits output") }
        return sectors * 512
    }

    /// Where `image` is attached right now (whole-disk device and mount point, if any),
    /// from `hdiutil info -plist`; nil when it is not attached.
    public static func attachment(of image: URL) -> (device: String, mountPoint: String?)? {
        guard let data = try? hdiutil(["info", "-plist"], what: "hdiutil info"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }
        let wanted = realPath(image)
        for entry in images {
            guard let path = entry["image-path"] as? String, realPath(URL(fileURLWithPath: path)) == wanted else { continue }
            let entities = entry["system-entities"] as? [[String: Any]] ?? []
            let devices = entities.compactMap { $0["dev-entry"] as? String }.sorted { $0.count < $1.count }
            guard let device = devices.first else { continue }
            return (device, entities.compactMap { $0["mount-point"] as? String }.first)
        }
        return nil
    }

    /// True when `url` is the root of a mounted volume (other than the one it lives on).
    public static func isMountPoint(_ url: URL) -> Bool {
        guard let fs = volume(of: url) else { return false }
        return fs.mountedOn == realPath(url)
    }

    /// statfs of the volume `url` is on.
    static func volume(of url: URL) -> (mountedOn: String, usage: StorageUsage)? {
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return nil }
        let mountedOn = withUnsafePointer(to: &s.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let block = Int64(s.f_bsize)
        let usage = StorageUsage(total: Int64(s.f_blocks) * block,
                                 used: Int64(s.f_blocks - s.f_bfree) * block,
                                 available: Int64(s.f_bavail) * block)
        return (mountedOn, usage)
    }

    /// realpath(3); unlike URL.resolvingSymlinksInPath it keeps /private on /private/tmp.
    static func realPath(_ url: URL) -> String {
        guard let p = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(p) }
        return String(cString: p)
    }

    /// Free space for new data on the disk that holds `url` (or its nearest existing
    /// parent), as Finder counts it (volumeAvailableCapacityForImportantUsage).
    public static func hostFreeBytes(at url: URL) -> Int64 {
        var dir = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: dir.path), dir.path != "/" {
            dir = dir.deletingLastPathComponent()
        }
        let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                       .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }
}

extension Bottle {
    public static let imageExtension = "sparsebundle"
    /// Left in the mount point directory while the image is not mounted (hidden by the
    /// volume once it is); holds the image's file name.
    public static let mountMarker = ".gamify-disk-image"
    /// Files the system may leave in an unmounted mount point or at a volume's root.
    static let ignorableNames: Set<String> = [mountMarker, ".DS_Store", ".fseventsd", ".Spotlight-V100",
                                              ".metadata_never_index", ".Trashes", ".TemporaryItems"]

    public static func imageURL(name: String, in project: Project) -> URL {
        project.bottles.appendingPathComponent("\(name).\(imageExtension)")
    }

    public var isImageBacked: Bool { image != nil }

    /// Size and use of an image-backed bottle's volume; nil for folder bottles and when
    /// the image is not mounted.
    public var storageUsage: StorageUsage? {
        guard image != nil, let fs = DiskImage.volume(of: prefix), fs.mountedOn == DiskImage.realPath(prefix) else { return nil }
        return fs.usage
    }

    /// True while a wineserver serves this prefix: Wine's server directory is
    /// /tmp/.wine-<uid>/server-<dev>-<inode> of the prefix (hex), and its socket only
    /// accepts connections while the server runs (a stale socket file is refused).
    public var hasRunningServer: Bool {
        var st = stat()
        guard stat(prefix.path, &st) == 0 else { return false }
        let path = String(format: "/tmp/.wine-%u/server-%llx-%llx/socket", getuid(), UInt64(st.st_dev), UInt64(st.st_ino))
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
        }
    }

    /// Mounts `image` at `prefix` unless it already is. Handles an image mounted
    /// somewhere else (Finder double-click, an old mount point): that mount is ejected
    /// first, which fails cleanly while something there is in use.
    static func mount(image: URL, at prefix: URL) throws {
        if DiskImage.isMountPoint(prefix) { return }
        guard FileManager.default.fileExists(atPath: image.path) else {
            throw CrossError("disk image \(image.path) is missing")
        }
        if let other = DiskImage.attachment(of: image) {
            do { try DiskImage.detach(other.device) }
            catch {
                throw CrossError("\(image.lastPathComponent) is already mounted at \(other.mountPoint ?? other.device) and cannot be ejected (\(error)); eject it and try again")
            }
        }
        let fm = FileManager.default
        if let leftovers = try? fm.contentsOfDirectory(atPath: prefix.path).filter({ !ignorableNames.contains($0) }),
           !leftovers.isEmpty {
            throw CrossError("\(prefix.path) holds files of its own (\(leftovers.prefix(3).joined(separator: ", "))) while its disk image is not mounted; move them out of the way first")
        }
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
        try writeMarker(image: image, in: prefix)   // under the volume, seen again once it is ejected
        try DiskImage.attach(image, at: prefix)
        guard DiskImage.isMountPoint(prefix) else {
            throw CrossError("hdiutil attached \(image.lastPathComponent) but \(prefix.path) is not a mount point")
        }
    }

    static func writeMarker(image: URL, in prefix: URL) throws {
        try (image.lastPathComponent + "\n").write(to: prefix.appendingPathComponent(mountMarker),
                                                   atomically: true, encoding: .utf8)
    }

    /// Ejects an image-backed bottle's volume and leaves the marker in its mount point.
    /// Plain `detach` first; `force` (delete) falls back to -force.
    func unmount(force: Bool = false) throws {
        guard let image else { return }
        if DiskImage.isMountPoint(prefix) {
            var lastError: Error?
            for attempt in 0..<3 {
                do { try DiskImage.detach(prefix.path); lastError = nil; break }
                catch { lastError = error }
                if attempt < 2 { Thread.sleep(forTimeInterval: 1) }   // fseventsd / Spotlight letting go
            }
            if let lastError {
                guard force else {
                    throw CrossError("\(lastError) - a program (Finder, Terminal, a game) still has files open in '\(name)'")
                }
                try DiskImage.detach(prefix.path, force: true)
            }
        }
        try? FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try? Bottle.writeMarker(image: image, in: prefix)
    }
}

extension Runtime {
    /// Ranges the UI and the CLI accept, in GB. `currentUse` is what the data already
    /// takes inside the bottle (0 for a new one); the maximum is that plus the host's
    /// free space, so a full bottle can never need more than the disk has. `home` is the
    /// folder the image lives in (another drive for a bottle kept elsewhere; nil: the
    /// bottles folder).
    public static func storageRange(project: Project, currentUse: Int64 = 0, home: URL? = nil) -> ClosedRange<Int> {
        let free = DiskImage.hostFreeBytes(at: home ?? project.bottles)
        let low = max(BottleStorage.minimumGB, Int((currentUse + BottleStorage.gib / 2) / BottleStorage.gib) + 1)
        let high = Int((free + currentUse) / BottleStorage.gib)
        return low...max(low, high)
    }

    /// The default for a new image-backed bottle: 64 GB, less when the disk has less free.
    public static func defaultStorageGB(project: Project, home: URL? = nil) -> Int? {
        let free = Int(DiskImage.hostFreeBytes(at: home ?? project.bottles) / BottleStorage.gib)
        guard free >= BottleStorage.minimumGB else { return nil }
        return min(BottleStorage.defaultGB, free)
    }

    static func checkSize(_ sizeGB: Int, in range: ClosedRange<Int>, what: String) throws {
        guard sizeGB >= range.lowerBound else {
            throw CrossError("\(what): \(sizeGB) GB is below the minimum of \(range.lowerBound) GB")
        }
        guard sizeGB <= range.upperBound else {
            throw CrossError("\(what): \(sizeGB) GB is more than the disk can hold (at most \(range.upperBound) GB free)")
        }
    }

    /// Creates `bottles/<name>.sparsebundle` of `sizeGB` and mounts it at bottles/<name>.
    /// With `location` (a checked folder elsewhere, Location.swift) the image is created
    /// there and bottles/<name>.sparsebundle links to it. Returns the image's entry in
    /// the bottles folder.
    func createImage(for name: String, prefix: URL, sizeGB: Int, location: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let image = Bottle.imageURL(name: name, in: project)
        let target = location.map { $0.appendingPathComponent(image.lastPathComponent) } ?? image
        for url in Set([image, target]) where fm.fileExists(atPath: url.path) || Bottle.isSymlink(url) {
            throw CrossError("\(url.path) already exists")
        }
        try fm.createDirectory(at: project.bottles, withIntermediateDirectories: true)
        try DiskImage.create(target, sizeGB: sizeGB, volumeName: name)
        do {
            if location != nil {
                try fm.createSymbolicLink(at: image, withDestinationURL: target)
                try Bottle.recordLocation(target, name: name, in: project)
            }
            try Bottle.mount(image: image, at: prefix)
            // keep Spotlight out of the bottle's volume (it would also hold it busy on eject)
            fm.createFile(atPath: prefix.appendingPathComponent(".metadata_never_index").path, contents: nil)
        } catch {
            if DiskImage.isMountPoint(prefix) { try? DiskImage.detach(prefix.path, force: true) }
            try? fm.removeItem(at: target)
            if location != nil {
                try? fm.removeItem(at: image)
                try? Bottle.recordLocation(nil, name: name, in: project)
            }
            throw error
        }
        return image
    }

    /// Fails while Windows programs run in the bottle. Programs are found by their
    /// working directory (inside the prefix) and, for those started from elsewhere (cross
    /// cmd from a shell), by the bottle's wineserver still answering; a server that only
    /// lingers after its last program (a few seconds, it writes the registry on exit)
    /// is waited for, so the volume can be ejected safely.
    public func requireIdle(_ bottle: Bottle, for what: String) throws {
        let running = Steam.bottleProcesses(in: bottle)
        guard running.isEmpty else {
            let names = Set(running.map(\.program)).sorted().prefix(4).joined(separator: ", ")
            throw CrossError("cannot \(what) while programs run in '\(bottle.name)' (\(names)); quit them or kill the bottle first")
        }
        let deadline = Date().addingTimeInterval(10)
        while bottle.hasRunningServer {
            guard Date() < deadline else {
                throw CrossError("cannot \(what) while programs run in '\(bottle.name)' (its wineserver is still up); quit them or kill the bottle first")
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// `cross bottle set <name> storage <GB>` on an image-backed bottle: detach, hdiutil
    /// resize, hdiutil compact, attach. Shrinking must leave room above what the bottle
    /// already uses. The same size only compacts (returns freed space to the host).
    public func resizeStorage(_ bottle: Bottle, to sizeGB: Int) throws -> Bottle {
        guard let image = bottle.image else { throw CrossError("'\(bottle.name)' is a folder bottle; convert it first") }
        guard let usage = bottle.storageUsage else { throw CrossError("'\(bottle.name)' is not mounted") }
        try Runtime.checkSize(sizeGB, in: Runtime.storageRange(project: project, currentUse: usage.used, home: bottle.home(in: project)),
                              what: "'\(bottle.name)' uses \(formatGB(usage.used))")
        try requireIdle(bottle, for: "resize the disk")
        try bottle.unmount()
        var resizeError: Error?
        do {
            if Int64(sizeGB) * BottleStorage.gib < usage.total {
                let minimum = try DiskImage.minimumBytes(image)
                guard Int64(sizeGB) * BottleStorage.gib >= minimum else {
                    throw CrossError("'\(bottle.name)' cannot shrink below \(formatGB(minimum))")
                }
            }
            if Int64(sizeGB) * BottleStorage.gib != usage.total {
                try DiskImage.resize(image, sizeGB: sizeGB)
            }
            try? DiskImage.compact(image)
        } catch {
            resizeError = error
        }
        try Bottle.mount(image: image, at: bottle.prefix)   // also after a failed resize
        if let resizeError { throw resizeError }
        var resized = try Bottle.load(name: bottle.name, in: project)
        resized.config.storage = BottleStorage(image: image.lastPathComponent, sizeGB: sizeGB)
        try resized.saveConfig()
        return resized
    }

    /// Copies a folder bottle into a new image of `sizeGB` and swaps it in: ditto into
    /// the image (mounted at a hidden temporary mount point), compare the two trees,
    /// rename the folder to a hidden backup, mount the image at the bottle's path,
    /// then delete the backup. Any failure before the swap leaves the folder as it was.
    /// A bottle kept elsewhere gets its image next to its folder (same drive), linked
    /// from bottles/<name>.sparsebundle.
    public func moveToImage(_ bottle: Bottle, sizeGB: Int, progress: @escaping (String) -> Void = { _ in }) throws -> Bottle {
        guard bottle.image == nil else { throw CrossError("'\(bottle.name)' already lives in a disk image") }
        if let error = bottle.storageError { throw CrossError(error) }
        try requireIdle(bottle, for: "move the bottle")
        progress("Measuring \(bottle.name)…")
        let home = bottle.home(in: project)
        let folder = URL(fileURLWithPath: DiskImage.realPath(bottle.prefix))
        let source = try TreeSummary(of: folder)
        try requireFree(source.allocated, at: home, for: bottle.name)
        try Runtime.checkSize(sizeGB, in: Runtime.storageRange(project: project, currentUse: source.allocated, home: home),
                              what: "'\(bottle.name)' holds \(formatGB(source.allocated))")

        let fm = FileManager.default
        let staging = project.bottles.appendingPathComponent(".\(bottle.name).moving")
        let backup = project.bottles.appendingPathComponent(".\(bottle.name).folder")
        guard !fm.fileExists(atPath: backup.path) else { throw CrossError("\(backup.path) is left over from an earlier move; remove it first") }
        progress("Creating a \(sizeGB) GB disk image…")
        let image = Bottle.imageURL(name: bottle.name, in: project)
        let located = bottle.location != nil
        let target = located ? home.appendingPathComponent(image.lastPathComponent) : image
        for url in Set([image, target]) where fm.fileExists(atPath: url.path) || Bottle.isSymlink(url) {
            throw CrossError("\(url.path) already exists")
        }
        if DiskImage.isMountPoint(staging) { try? DiskImage.detach(staging.path, force: true) }
        try? fm.removeItem(at: staging)
        let cleanUp = {
            if DiskImage.isMountPoint(staging) { try? DiskImage.detach(staging.path, force: true) }
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: target)
        }
        do {
            try DiskImage.create(target, sizeGB: sizeGB, volumeName: bottle.name)
            try DiskImage.attach(target, at: staging)
            fm.createFile(atPath: staging.appendingPathComponent(".metadata_never_index").path, contents: nil)
            try copyTree(from: folder, to: staging, total: source.allocated, progress: progress)
            progress("Verifying the copy…")
            try source.verify(against: TreeSummary(of: staging))
            try DiskImage.detach(staging.path)
            try? fm.removeItem(at: staging)
        } catch {
            cleanUp()
            throw error
        }
        progress("Switching \(bottle.name) to the disk image…")
        try fm.moveItem(at: bottle.prefix, to: backup)   // the folder, or the link to it
        do {
            if located {
                try fm.createSymbolicLink(at: image, withDestinationURL: target)
                try Bottle.recordLocation(target, name: bottle.name, in: project)
            }
            try fm.createDirectory(at: bottle.prefix, withIntermediateDirectories: false)
            try Bottle.mount(image: image, at: bottle.prefix)
            var moved = try Bottle.load(name: bottle.name, in: project)
            moved.config.storage = BottleStorage(image: image.lastPathComponent, sizeGB: sizeGB)
            try moved.saveConfig()
            progress("Removing the old folder…")
            try Bottle.removeData(at: backup)
            return moved
        } catch {
            if DiskImage.isMountPoint(bottle.prefix) { try? DiskImage.detach(bottle.prefix.path, force: true) }
            try? fm.removeItem(at: bottle.prefix)
            try? fm.moveItem(at: backup, to: bottle.prefix)
            if located {
                try? fm.removeItem(at: image)
                try? Bottle.recordLocation(bottle.location, name: bottle.name, in: project)
            }
            try? fm.removeItem(at: target)
            throw error
        }
    }

    /// The reverse of `moveToImage`: copy the volume's contents into a plain folder,
    /// verify, eject, swap the folder in and delete the image. A bottle kept elsewhere
    /// gets its folder next to its image (that drive must be APFS or Mac OS Extended).
    public func moveToFolder(_ bottle: Bottle, progress: @escaping (String) -> Void = { _ in }) throws -> Bottle {
        guard let image = bottle.image else { throw CrossError("'\(bottle.name)' already is a folder bottle") }
        guard bottle.storageUsage != nil else { throw CrossError("'\(bottle.name)' is not mounted") }
        let home = bottle.home(in: project)
        try Runtime.checkFolderBottle(at: home)
        try requireIdle(bottle, for: "move the bottle")
        progress("Measuring \(bottle.name)…")
        let source = try TreeSummary(of: bottle.prefix)
        try requireFree(source.allocated, at: home, for: bottle.name)
        let fm = FileManager.default
        let located = bottle.location != nil
        let target = home.appendingPathComponent(bottle.name)
        if located, fm.fileExists(atPath: target.path) || Bottle.isSymlink(target) {
            throw CrossError("\(target.path) already exists")
        }
        let staging = home.appendingPathComponent(".\(bottle.name).moving")
        guard !fm.fileExists(atPath: staging.path) else { throw CrossError("\(staging.path) is left over from an earlier move; remove it first") }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            try copyTree(from: bottle.prefix, to: staging, total: source.allocated, progress: progress)
            progress("Verifying the copy…")
            try source.verify(against: TreeSummary(of: staging))
            try? fm.removeItem(at: staging.appendingPathComponent(".metadata_never_index"))
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        progress("Switching \(bottle.name) to a folder…")
        do {
            try bottle.unmount()
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        // the image goes aside first: while it exists the bottle counts as image-backed
        // (for a bottle kept elsewhere this moves the link; the image stays where it is)
        let oldImage = project.bottles.appendingPathComponent(".\(bottle.name).\(Bottle.imageExtension)")
        try? fm.removeItem(at: oldImage)
        try fm.moveItem(at: image, to: oldImage)
        try? fm.removeItem(at: bottle.prefix.appendingPathComponent(Bottle.mountMarker))
        try fm.removeItem(at: bottle.prefix)   // the empty mount point
        if located {
            try fm.moveItem(at: staging, to: target)
            try fm.createSymbolicLink(at: bottle.prefix, withDestinationURL: target)
            try Bottle.recordLocation(target, name: bottle.name, in: project)
        } else {
            try fm.moveItem(at: staging, to: bottle.prefix)
        }
        var moved = try Bottle.load(name: bottle.name, in: project)
        moved.config.storage = nil
        try moved.saveConfig()
        progress("Removing the disk image…")
        try Bottle.removeData(at: oldImage)
        return moved
    }

    /// `cross bottle delete` / Delete Bottle: wineserver -k, eject the image (forced if
    /// need be), then remove the image and the prefix.
    public func deleteBottle(_ bottle: Bottle) throws {
        _ = try? runWaiting(try kill(bottle), quiet: true)
        if bottle.image != nil {
            _ = try? runWaiting(try waitForBottle(bottle), quiet: true)
        }
        try Bottle.delete(bottle, in: project)
    }

    /// ditto (keeps symlinks such as dosdevices/z: -> /, modes, extended attributes),
    /// reporting progress from the target volume's use while it runs (when the target is
    /// a volume of its own or on another drive than the source). `options` go to ditto.
    func copyTree(from source: URL, to target: URL, total: Int64, progress: @escaping (String) -> Void,
                  options: [String] = []) throws {
        let start = DiskImage.volume(of: target)?.usage.used ?? 0
        let measureTarget = DiskImage.isMountPoint(target)
            || DiskImage.volume(of: target)?.mountedOn != DiskImage.volume(of: source)?.mountedOn
        let finished = DispatchSemaphore(value: 0)
        if measureTarget && total > 0 {
            Thread.detachNewThread {
                while finished.wait(timeout: .now() + 1) == .timedOut {
                    let now = DiskImage.volume(of: target)?.usage.used ?? start
                    let done = min(total, max(0, now - start))
                    progress("Copying \(formatGB(done)) of \(formatGB(total))…")
                }
            }
        } else {
            progress("Copying \(formatGB(total))…")
        }
        defer { finished.signal() }
        let r = try DiskImage.run(DiskImage.dittoPath, options + [source.path, target.path])
        guard r.status == 0 else {
            throw CrossError("copying \(source.lastPathComponent) failed: \(r.errors.isEmpty ? "exit \(r.status)" : r.errors)")
        }
    }
}

extension Bottle {
    /// Ejects (if image-backed) and removes the bottle from disk. No process check. A
    /// bottle kept elsewhere loses its data there, its link and its .location file; one
    /// whose drive is not connected only its entries in the bottles folder (its data
    /// cannot be reached, so it is left alone).
    static func delete(_ bottle: Bottle, in project: Project) throws {
        let fm = FileManager.default
        if bottle.isUnreachable {
            for link in [bottle.prefix, imageURL(name: bottle.name, in: project)] where isSymlink(link) {
                try fm.removeItem(at: link)
            }
            // an image bottle's mount point: only when it holds nothing but the marker
            if isDirectory(bottle.prefix), !isSymlink(bottle.prefix), !DiskImage.isMountPoint(bottle.prefix),
               ((try? fm.contentsOfDirectory(atPath: bottle.prefix.path)) ?? []).allSatisfy(ignorableNames.contains) {
                try fm.removeItem(at: bottle.prefix)
            }
            try recordLocation(nil, name: bottle.name, in: project)
            try? fm.removeItem(at: ejectedFlag(name: bottle.name, in: project))
            return
        }
        if let image = bottle.image {
            if DiskImage.isMountPoint(bottle.prefix) {
                try bottle.unmount(force: true)
            } else if let other = DiskImage.attachment(of: image) {
                try DiskImage.detach(other.device, force: true)
            }
            guard !DiskImage.isMountPoint(bottle.prefix) else {
                throw CrossError("\(bottle.prefix.path) is still mounted")
            }
            if fm.fileExists(atPath: bottle.prefix.path) { try fm.removeItem(at: bottle.prefix) }
            try removeData(at: image)
        } else {
            try removeData(at: bottle.prefix)
        }
        try recordLocation(nil, name: bottle.name, in: project)
        try? fm.removeItem(at: ejectedFlag(name: bottle.name, in: project))
    }
}

/// Every entry under a directory (relative path -> kind and size, symlinks by target),
/// to check a copy before the original goes away.
struct TreeSummary {
    enum Entry: Equatable {
        case directory
        case file(Int64)
        case link(String)
    }
    var entries: [String: Entry] = [:]
    /// Bytes the regular files take on disk.
    var allocated: Int64 = 0

    init(of root: URL) throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        var failures: [String] = []
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                         errorHandler: { url, error in
                                             if !Bottle.ignorableNames.contains(url.lastPathComponent) {
                                                 failures.append("\(url.path): \(error.localizedDescription)")
                                             }
                                             return true
                                         }) else {
            throw CrossError("cannot read \(root.path)")
        }
        let base = root.standardizedFileURL.path.count + 1
        for case let url as URL in walker {
            let rel = String(url.standardizedFileURL.path.dropFirst(base))
            let v = try url.resourceValues(forKeys: Set(keys))
            if !rel.contains("/") && Bottle.ignorableNames.contains(rel) {
                // only for a directory: after a file, skipDescendants() skips the
                // directory returned before it (drive_c, next to .metadata_never_index)
                if v.isDirectory == true && v.isSymbolicLink != true { walker.skipDescendants() }
                continue
            }
            if v.isSymbolicLink == true {
                entries[rel] = .link((try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? "")
            } else if v.isDirectory == true {
                entries[rel] = .directory
            } else {
                entries[rel] = .file(Int64(v.fileSize ?? 0))
                allocated += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
            }
        }
        if !failures.isEmpty {
            throw CrossError("cannot read \(failures.count) entries under \(root.path): \(failures.prefix(3).joined(separator: "; "))")
        }
    }

    func verify(against copy: TreeSummary) throws {
        guard entries != copy.entries else { return }
        let missing = entries.keys.filter { copy.entries[$0] == nil }.sorted()
        let differing = entries.keys.filter { copy.entries[$0] != nil && copy.entries[$0] != entries[$0] }.sorted()
        let extra = copy.entries.keys.filter { entries[$0] == nil }.sorted()
        var parts: [String] = []
        if !missing.isEmpty { parts.append("\(missing.count) missing (\(missing.prefix(3).joined(separator: ", ")))") }
        if !differing.isEmpty { parts.append("\(differing.count) differ (\(differing.prefix(3).joined(separator: ", ")))") }
        if !extra.isEmpty { parts.append("\(extra.count) extra (\(extra.prefix(3).joined(separator: ", ")))") }
        throw CrossError("the copy does not match the original: " + parts.joined(separator: "; "))
    }
}
