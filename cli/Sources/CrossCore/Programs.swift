import Foundation

/// A Windows program in a bottle that can be launched from the bottle page or with
/// `cross programs <bottle> launch <name>`: found through a Start Menu (or Desktop)
/// shortcut, added after an install that left no shortcut, or added by hand.
public struct Program: Codable, Equatable, Identifiable {
    public enum Source: String, Codable {
        case shortcut    // a .lnk in the bottle (scanned every time, not stored)
        case installed   // an exe that appeared under Program Files during an install
        case manual      // added by hand ("Add a program…", `cross programs add`)
    }

    public var name: String
    /// Windows path of the exe, `C:\Program Files\7-Zip\7zFM.exe`.
    public var exe: String
    /// The rest of the command line, as Windows writes it ("" when none).
    public var arguments: String
    public var source: Source
    /// For `.shortcut`: the .lnk file (unix path), so the list can say where it came from.
    public var shortcut: String?

    public init(name: String, exe: String, arguments: String = "", source: Source, shortcut: String? = nil) {
        self.name = name
        self.exe = exe
        self.arguments = arguments
        self.source = source
        self.shortcut = shortcut
    }

    public var id: String { Programs.key(exe: exe, arguments: arguments) }

    /// `arguments` split like a Windows command line (double quotes group words).
    public var argumentList: [String] { Programs.splitArguments(arguments) }
}

/// The programs of a bottle: scanned shortcuts plus `programs.json` next to cross.json
/// (kept apart from cross.json so the bottle's settings and its program list do not
/// churn each other):
/// `{"programs": [{name, exe, arguments, source}], "hidden": ["c:\\…\\setup.exe|"]}`.
/// `hidden` holds shortcuts the user removed from the list (the .lnk itself stays).
public enum Programs {
    public static let file = "programs.json"

    struct Stored: Codable {
        var programs: [Program] = []
        var hidden: [String] = []
    }

    static func key(exe: String, arguments: String) -> String {
        exe.lowercased() + "|" + arguments.trimmingCharacters(in: .whitespaces)
    }

    static func load(_ bottle: Bottle) -> Stored {
        guard let data = try? Data(contentsOf: bottle.prefix.appendingPathComponent(file)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return Stored() }
        return stored
    }

    static func save(_ stored: Stored, in bottle: Bottle) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try enc.encode(stored)
        data.append(0x0a)
        try data.write(to: bottle.prefix.appendingPathComponent(file), options: .atomic)
    }

    /// Everything to show: shortcuts (minus hidden ones) and stored entries, one per exe +
    /// arguments, sorted by name. Shortcuts whose exe is gone are skipped.
    public static func list(in bottle: Bottle) -> [Program] {
        let stored = load(bottle)
        let hidden = Set(stored.hidden)
        var seen = Set<String>()
        var out: [Program] = []
        for p in stored.programs where seen.insert(p.id).inserted {
            out.append(p)
        }
        for p in scanShortcuts(in: bottle) where !hidden.contains(p.id) && seen.insert(p.id).inserted {
            out.append(p)
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Adds (or replaces, same exe + arguments) a stored entry.
    public static func add(_ program: Program, to bottle: Bottle) throws {
        var stored = load(bottle)
        stored.programs.removeAll { $0.id == program.id }
        stored.hidden.removeAll { $0 == program.id }
        stored.programs.append(program)
        try save(stored, in: bottle)
    }

    /// Stored entries are deleted; a shortcut is hidden from the list.
    public static func remove(_ program: Program, from bottle: Bottle) throws {
        var stored = load(bottle)
        let before = stored.programs.count
        stored.programs.removeAll { $0.id == program.id }
        if stored.programs.count == before || program.source == .shortcut, !stored.hidden.contains(program.id) {
            stored.hidden.append(program.id)
        }
        try save(stored, in: bottle)
    }

    /// By name (case-insensitive), else by exe file name ("7zFM", "7zfm.exe").
    public static func find(_ text: String, in bottle: Bottle) -> Program? {
        let all = list(in: bottle)
        let t = text.lowercased()
        return all.first { $0.name.lowercased() == t }
            ?? all.first { exeName($0.exe).lowercased() == t || exeName($0.exe).lowercased() == t + ".exe" }
    }

    static func exeName(_ windowsPath: String) -> String {
        windowsPath.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? windowsPath
    }

    // MARK: - Paths

    /// `C:\Program Files\x.exe` -> <prefix>/dosdevices/c:/Program Files/x.exe with the drive
    /// symlink resolved (c: -> drive_c, z: -> /). nil for paths that are not drive paths.
    public static func unixURL(of windowsPath: String, in bottle: Bottle) -> URL? {
        let path = windowsPath.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let chars = Array(path)
        guard chars.count >= 2, chars[0].isLetter, chars[1] == ":" else { return nil }
        let drive = bottle.prefix.appendingPathComponent("dosdevices/\(chars[0].lowercased()):")
        var url = drive.resolvingSymlinksInPath()
        if chars[0].lowercased() == "c", !FileManager.default.fileExists(atPath: drive.path) { url = bottle.driveC }
        for part in path.dropFirst(2).split(whereSeparator: { $0 == "\\" || $0 == "/" }) where !part.isEmpty {
            url.appendPathComponent(String(part))
        }
        return url
    }

    /// A file inside drive_c as `C:\…`, anything else through Z: (Wine maps z: to /).
    public static func windowsPath(of url: URL, in bottle: Bottle) -> String {
        let file = url.resolvingSymlinksInPath().standardizedFileURL.path
        let driveC = bottle.driveC.resolvingSymlinksInPath().standardizedFileURL.path
        if file.lowercased().hasPrefix(driveC.lowercased() + "/") {
            return "C:\\" + file.dropFirst(driveC.count + 1).replacingOccurrences(of: "/", with: "\\")
        }
        return "Z:" + file.replacingOccurrences(of: "/", with: "\\")
    }

    /// Splits a Windows command-line tail: spaces separate, double quotes group.
    public static func splitArguments(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for ch in text {
            if ch == "\"" { inQuotes.toggle(); hasToken = true; continue }
            if ch.isWhitespace && !inQuotes {
                if hasToken { out.append(current); current = ""; hasToken = false }
                continue
            }
            current.append(ch)
            hasToken = true
        }
        if hasToken { out.append(current) }
        return out
    }

    // MARK: - Shortcuts

    /// The Start Menu folders (all users and the bottle's user) and both Desktops.
    public static func shortcutFolders(in bottle: Bottle) -> [URL] {
        let c = bottle.driveC
        return [c.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs"),
                bottle.userProfile.appendingPathComponent("AppData/Roaming/Microsoft/Windows/Start Menu/Programs"),
                c.appendingPathComponent("users/Public/Desktop"),
                bottle.userProfile.appendingPathComponent("Desktop")]
    }

    /// Every .lnk in the shortcut folders that points at an existing .exe, without
    /// uninstallers and without the stores' own launchers (they have the Stores area,
    /// and Steam started without its flags would undo the webhelper shim).
    /// Name = the shortcut's file name.
    public static func scanShortcuts(in bottle: Bottle) -> [Program] {
        let fm = FileManager.default
        let storeExes = Set(Store.all.flatMap(\.executables).map { "c:\\" + $0.replacingOccurrences(of: "/", with: "\\").lowercased() })
        var out: [Program] = []
        for folder in shortcutFolders(in: bottle) {
            guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension.lowercased() == "lnk" {
                guard let data = try? Data(contentsOf: url), let link = ShellLink(data: data),
                      let target = link.target, target.lowercased().hasSuffix(".exe"),
                      !isUninstaller(target), !storeExes.contains(target.lowercased()),
                      let unix = unixURL(of: target, in: bottle), fm.fileExists(atPath: unix.path) else { continue }
                out.append(Program(name: url.deletingPathExtension().lastPathComponent, exe: target,
                                   arguments: link.arguments ?? "", source: .shortcut, shortcut: url.path))
            }
        }
        return out
    }

    static func isUninstaller(_ path: String) -> Bool {
        let name = exeName(path).lowercased()
        return name.hasPrefix("unins") || name.hasPrefix("uninst") || name.contains("uninstall")
    }

    // MARK: - After an install

    /// What a bottle held before an installer ran: its shortcut targets and the exe
    /// files under Program Files / Program Files (x86).
    public struct Snapshot {
        public var shortcuts: Set<String>
        public var executables: Set<String>
    }

    public static func snapshot(of bottle: Bottle) -> Snapshot {
        Snapshot(shortcuts: Set(scanShortcuts(in: bottle).map(\.id)), executables: programFilesExecutables(in: bottle))
    }

    /// Lower-cased paths relative to drive_c of every .exe up to four levels below
    /// Program Files and Program Files (x86).
    static func programFilesExecutables(in bottle: Bottle) -> Set<String> {
        let fm = FileManager.default
        var out = Set<String>()
        for root in ["Program Files", "Program Files (x86)"] {
            let dir = bottle.driveC.appendingPathComponent(root)
            guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                if walker.level > 4 { walker.skipDescendants(); continue }
                if url.pathExtension.lowercased() == "exe" {
                    out.insert(root.lowercased() + "/" + url.path.dropFirst(dir.path.count + 1).lowercased())
                }
            }
        }
        return out
    }

    /// Runs after an installer: shortcuts it created show up in `list` by themselves.
    /// When it created none, the exes it added under Program Files are stored as
    /// `.installed` entries instead (at most three, shallowest first, no uninstallers,
    /// updaters or crash reporters). Returns the new programs either way.
    @discardableResult
    public static func recordInstall(since before: Snapshot, in bottle: Bottle) -> [Program] {
        let newShortcuts = scanShortcuts(in: bottle).filter { !before.shortcuts.contains($0.id) }
        if !newShortcuts.isEmpty { return newShortcuts }
        let skip = ["unins", "uninst", "update", "crash", "report", "helper", "setup", "install", "service"]
        let added = programFilesExecutables(in: bottle).subtracting(before.executables)
            .filter { path in
                let name = (path as NSString).lastPathComponent
                return !skip.contains { name.contains($0) }
            }
            .sorted { a, b in
                let da = a.split(separator: "/").count, db = b.split(separator: "/").count
                return da == db ? a < b : da < db
            }
            .prefix(3)
        var programs: [Program] = []
        for rel in added {
            // the real spelling from disk, not the lower-cased key
            guard let url = realURL(relative: rel, in: bottle.driveC) else { continue }
            let program = Program(name: url.deletingPathExtension().lastPathComponent,
                                  exe: windowsPath(of: url, in: bottle), source: .installed)
            if (try? add(program, to: bottle)) != nil { programs.append(program) }
        }
        return programs
    }

    /// Finds `rel` (lower-cased, '/'-separated) under `root` with the names as stored on disk.
    static func realURL(relative rel: String, in root: URL) -> URL? {
        var url = root
        for part in rel.split(separator: "/") {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            guard let name = names.first(where: { $0.lowercased() == part }) else { return nil }
            url.appendPathComponent(name)
        }
        return url
    }
}

/// The parts of a Windows shortcut (.lnk, [MS-SHLLINK]) needed to launch its target:
/// the target from LinkInfo's local base path (+ common path suffix), else from the
/// environment-variable block, else the relative path; plus arguments and working dir.
/// Wine's IShellLink writes LinkInfo with the local path (no ID list is needed).
public struct ShellLink: Equatable {
    public var target: String?
    public var arguments: String?
    public var workingDirectory: String?
    public var name: String?

    public init?(data: Data) {
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int? { o + 2 <= bytes.count ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int? {
            o + 4 <= bytes.count ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 : nil
        }
        func cString(_ o: Int) -> String? {
            guard o >= 0, o < bytes.count else { return nil }
            var end = o
            while end < bytes.count && bytes[end] != 0 { end += 1 }
            return String(bytes: bytes[o..<end], encoding: .windowsCP1252)
        }
        func wString(_ o: Int, count: Int? = nil) -> String? {
            guard o >= 0, o < bytes.count else { return nil }
            var units: [UInt16] = []
            var i = o
            while i + 1 < bytes.count {
                let u = UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
                if count == nil && u == 0 { break }
                units.append(u)
                i += 2
                if let count, units.count == count { break }
            }
            return String(decoding: units, as: UTF16.self)
        }

        // ShellLinkHeader: size 0x4C, CLSID 00021401-0000-0000-C000-000000000046
        guard bytes.count >= 0x4C, u32(0) == 0x4C, bytes[4] == 0x01, bytes[5] == 0x14, bytes[6] == 0x02,
              let flags = u32(0x14) else { return nil }
        let hasIDList = flags & 0x1 != 0, hasLinkInfo = flags & 0x2 != 0, hasName = flags & 0x4 != 0
        let hasRelativePath = flags & 0x8 != 0, hasWorkingDir = flags & 0x10 != 0
        let hasArguments = flags & 0x20 != 0, hasIcon = flags & 0x40 != 0, unicode = flags & 0x80 != 0
        var p = 0x4C
        if hasIDList {
            guard let size = u16(p) else { return nil }
            p += 2 + size
        }
        if hasLinkInfo {
            guard let size = u32(p), let headerSize = u32(p + 4), let infoFlags = u32(p + 8) else { return nil }
            if infoFlags & 0x1 != 0 {   // VolumeIDAndLocalBasePath
                var base: String?
                var suffix: String?
                if headerSize >= 0x24, let o = u32(p + 28), o > 0 { base = wString(p + o) }
                if base == nil || base!.isEmpty, let o = u32(p + 16) { base = cString(p + o) }
                if headerSize >= 0x24, let o = u32(p + 32), o > 0 { suffix = wString(p + o) }
                if suffix == nil, let o = u32(p + 24), o > 0 { suffix = cString(p + o) }
                if let base, !base.isEmpty {
                    var t = base
                    if let suffix, !suffix.isEmpty {
                        if !t.hasSuffix("\\") { t += "\\" }
                        t += suffix
                    }
                    target = t
                }
            }
            p += max(size, 4)
        }
        func readString() -> String? {
            guard let count = u16(p) else { return nil }
            p += 2
            if unicode {
                defer { p += count * 2 }
                return wString(p, count: count)
            }
            defer { p += count }
            guard p + count <= bytes.count else { return nil }
            return String(bytes: bytes[p..<(p + count)], encoding: .windowsCP1252)
        }
        // some writers (NSIS) count a terminating NUL in the string: "\0" as arguments
        let junk = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{0}"))
        func readClean() -> String? { readString()?.trimmingCharacters(in: junk) }
        if hasName { name = readClean() }
        var relativePath: String?
        if hasRelativePath { relativePath = readClean() }
        if hasWorkingDir { workingDirectory = readClean() }
        if hasArguments { arguments = readClean() }
        if hasIcon { _ = readString() }
        // ExtraData: EnvironmentVariableDataBlock (0xA0000001) holds the target with
        // %VARIABLES%; used when there is no LinkInfo.
        if target == nil {
            while let size = u32(p), size >= 8, let sig = u32(p + 4), p + size <= bytes.count {
                if sig == 0xA000_0001, size >= 0x314 {
                    let wide = wString(p + 8 + 260)
                    target = (wide?.isEmpty == false ? wide : cString(p + 8)).map(ShellLink.expand)
                    break
                }
                p += size
            }
        }
        if target == nil, let relativePath, !relativePath.isEmpty, let workingDirectory, !workingDirectory.isEmpty,
           !relativePath.hasPrefix(".") {
            target = relativePath
        }
        if let t = target, t.isEmpty { target = nil }
    }

    /// The few variables installers use in shortcut targets, as this runtime sets them.
    static func expand(_ path: String) -> String {
        let vars = ["%programfiles%": "C:\\Program Files", "%programfiles(x86)%": "C:\\Program Files (x86)",
                    "%systemroot%": "C:\\windows", "%windir%": "C:\\windows", "%programdata%": "C:\\ProgramData",
                    "%userprofile%": "C:\\users\\crossover", "%localappdata%": "C:\\users\\crossover\\AppData\\Local",
                    "%appdata%": "C:\\users\\crossover\\AppData\\Roaming"]
        var out = path
        for (k, v) in vars {
            if let r = out.range(of: k, options: .caseInsensitive) { out.replaceSubrange(r, with: v) }
        }
        return out
    }
}
