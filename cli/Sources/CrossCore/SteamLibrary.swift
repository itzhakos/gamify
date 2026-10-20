import Foundation

/// What Steam itself keeps on disk about the games and the account of a bottle, read
/// without Wine: the installed apps (steamapps/appmanifest_*.acf in every library of
/// steamapps/libraryfolders.vdf), the signed-in account (config/loginusers.vdf) and
/// the licences the client cached at its last logon (appcache/packageinfo.vdf).
/// Used by `cross steam check` and by the launch of Steam games through Steam.
extension Steam {
    // MARK: - Text KeyValues (.acf / .vdf)

    /// Valve's text KeyValues: `"key" "value"` pairs and `"key" { ... }` blocks.
    public struct KeyValues: Equatable {
        public var value: String?
        public var children: [(key: String, value: KeyValues)] = []

        /// Case-insensitive, like Steam (manifests mix "AppState" and "appstate").
        public subscript(key: String) -> KeyValues? {
            children.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
        }

        public static func == (a: KeyValues, b: KeyValues) -> Bool {
            a.value == b.value && a.children.count == b.children.count
                && zip(a.children, b.children).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        }

        /// Parses the whole text; unknown syntax ends the parse with what was read so far.
        public static func parse(_ text: String) -> KeyValues {
            var tokens: [String?] = []   // nil = "{", "\u{0}" = "}"
            var chars = Array(text.unicodeScalars)[...]
            while let c = chars.first {
                if c == "\"" {
                    chars = chars.dropFirst()
                    var s = String.UnicodeScalarView()
                    while let d = chars.first, d != "\"" {
                        chars = chars.dropFirst()
                        if d == "\\", let e = chars.first {
                            chars = chars.dropFirst()
                            switch e {
                            case "n": s.append("\n")
                            case "t": s.append("\t")
                            default: s.append(e)
                            }
                        } else {
                            s.append(d)
                        }
                    }
                    chars = chars.dropFirst()
                    tokens.append(String(s))
                } else if c == "{" {
                    tokens.append(nil); chars = chars.dropFirst()
                } else if c == "}" {
                    tokens.append("\u{0}"); chars = chars.dropFirst()
                } else if c == "/", chars.dropFirst().first == "/" {
                    while let d = chars.first, d != "\n" { chars = chars.dropFirst() }
                } else {
                    chars = chars.dropFirst()
                }
            }
            var i = 0
            func block() -> KeyValues {
                var kv = KeyValues()
                while i < tokens.count {
                    guard let key = tokens[i], key != "\u{0}" else { i += 1; return kv }
                    i += 1
                    guard i < tokens.count else { break }
                    if let value = tokens[i], value != "\u{0}" {
                        kv.children.append((key, KeyValues(value: value)))
                        i += 1
                    } else if tokens[i] == nil {
                        i += 1
                        kv.children.append((key, block()))
                    } else {
                        break
                    }
                }
                return kv
            }
            return block()
        }

        public static func load(_ url: URL) -> KeyValues? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return parse(String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: - Installed apps

    public struct InstalledApp: Equatable, Identifiable {
        public var appID: Int
        public var name: String
        /// steamapps/common/<installDir>
        public var installDir: String
        /// The library's steamapps folder (unix path).
        public var steamapps: URL
        /// appmanifest StateFlags: 4 = fully installed; other bits = updating, downloading, ...
        public var stateFlags: Int

        public var id: Int { appID }
        public var folder: URL { steamapps.appendingPathComponent("common").appendingPathComponent(installDir) }
        public var isFullyInstalled: Bool { stateFlags & 4 != 0 }
        /// What `steam.exe` is given to start the game the way the library's Play button does.
        public var runURL: String { "steam://rungameid/\(appID)" }
    }

    /// The steamapps folders of every library (libraryfolders.vdf), the Steam dir's own first.
    public static func libraries(in bottle: Bottle) -> [URL] {
        let main = bottle.steamDir.appendingPathComponent("steamapps")
        var out = [main]
        if let folders = KeyValues.load(main.appendingPathComponent("libraryfolders.vdf"))?["libraryfolders"] {
            for (_, library) in folders.children {
                guard let path = library["path"]?.value,
                      let url = Programs.unixURL(of: path, in: bottle)?.appendingPathComponent("steamapps") else { continue }
                if !out.contains(where: { $0.standardizedFileURL.path.lowercased() == url.standardizedFileURL.path.lowercased() }) {
                    out.append(url)
                }
            }
        }
        return out
    }

    /// Every appmanifest_*.acf of every library, sorted by name.
    public static func installedApps(in bottle: Bottle) -> [InstalledApp] {
        var out: [InstalledApp] = []
        for steamapps in libraries(in: bottle) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: steamapps.path)) ?? []
            for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let state = KeyValues.load(steamapps.appendingPathComponent(file))?["AppState"],
                      let appID = state["appid"]?.value.flatMap({ Int($0) }) else { continue }
                out.append(InstalledApp(appID: appID, name: state["name"]?.value ?? "app \(appID)",
                                        installDir: state["installdir"]?.value ?? "",
                                        steamapps: steamapps,
                                        stateFlags: state["StateFlags"]?.value.flatMap { Int($0) } ?? 0))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The installed Steam game an exe belongs to: it lies inside steamapps/common/<installdir>.
    public static func installedApp(containing exe: URL, in bottle: Bottle) -> InstalledApp? {
        let path = DiskImage.realPath(exe).lowercased()
        return installedApps(in: bottle).first { app in
            !app.installDir.isEmpty && path.hasPrefix(DiskImage.realPath(app.folder).lowercased() + "/")
        }
    }

    // MARK: - Account

    public struct Account: Equatable {
        public var steamID64: UInt64
        public var accountName: String
        public var personaName: String
        public var wantsOfflineMode: Bool
        public var mostRecent: Bool
    }

    /// config/loginusers.vdf: the accounts that signed in on this Steam (no passwords in it).
    public static func accounts(in bottle: Bottle) -> [Account] {
        guard let users = KeyValues.load(bottle.steamDir.appendingPathComponent("config/loginusers.vdf"))?["users"] else { return [] }
        return users.children.compactMap { key, user in
            guard let id = UInt64(key) else { return nil }
            return Account(steamID64: id, accountName: user["AccountName"]?.value ?? "",
                           personaName: user["PersonaName"]?.value ?? "",
                           wantsOfflineMode: user["WantsOfflineMode"]?.value == "1",
                           mostRecent: user["MostRecent"]?.value == "1")
        }
    }

    /// The account of the connection log's newest line ("[U:1:<n>]"), else the most recent one.
    public static func currentAccount(in bottle: Bottle, connection: Connection?) -> Account? {
        let all = accounts(in: bottle)
        if let account = connection?.account, let n = account.split(separator: ":").last.flatMap({ UInt64($0) }),
           let match = all.first(where: { $0.steamID64 == 76561197960265728 + n }) {
            return match
        }
        return all.first(where: \.mostRecent) ?? (all.count == 1 ? all.first : nil)
    }

    // MARK: - Licences (appcache/packageinfo.vdf)

    /// One Steam package ("sub") the account holds, as the client caches it.
    public struct License: Equatable {
        public var packageID: Int
        /// EBillingType: 0 no cost, 1 store purchase, 3 CD key, 4 guest pass, 6 gift,
        /// 10 purchase or CD key, 12 free on demand (free to play), ...
        public var billingType: Int
        /// EPackageStatus: 0 available, 1 pre-order, 2 unavailable, 3 invalid.
        public var status: Int
        public var appIDs: [Int]
        /// The package's "extended" keys as text (freeplaytogether, freeweekend, expirytime, ...).
        public var extended: [String: String]

        public enum Kind: String {
            case purchased      // bought, a key, a gift: the full game
            case friendsPass    // free package for playing together with an owner (Friend's Pass)
            case freeWeekend
            case freePromotion  // a free giveaway (keep it, or time limited)
            case freeToPlay
            case free           // any other no-cost licence (package 0 = Steam's own free apps)
        }

        public var kind: Kind {
            if extended["freeplaytogether"] == "1" { return .friendsPass }
            if extended["freeweekend"] == "1" { return .freeWeekend }
            if extended["freepromotion"] == "1" { return .freePromotion }
            switch billingType {
            case 12: return .freeToPlay
            case 0: return .free
            default: return .purchased
            }
        }

        public var isUsable: Bool { status == 0 || status == 1 }
    }

    public static func packageInfo(in bottle: Bottle) -> URL {
        bottle.steamDir.appendingPathComponent("appcache/packageinfo.vdf")
    }

    /// The account's licences from the binary packageinfo.vdf the client writes after logon
    /// (one entry per package of the account's licence list, plus package 0). Empty when
    /// the file is missing or in a format we do not know.
    public static func licenses(in bottle: Bottle) -> [License] {
        guard let data = try? Data(contentsOf: packageInfo(in: bottle)) else { return [] }
        return licenses(packageInfo: [UInt8](data))
    }

    public static func licenses(packageInfo b: [UInt8]) -> [License] {
        func u32(_ o: Int) -> UInt32? {
            o + 4 <= b.count ? UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 : nil
        }
        // magic 0x06565527/28 ("'UV\x06", "(UV\x06"): v27 has no PICS token per entry
        guard let magic = u32(0), magic & 0xFFFF_FF00 == 0x0656_5500, magic & 0xFF >= 0x27 else { return [] }
        let hasToken = magic & 0xFF >= 0x28
        var pos = 8
        var out: [License] = []
        while let id = u32(pos), id != 0xFFFF_FFFF {
            pos += 4 + 20 + 4 + (hasToken ? 8 : 0)   // id, sha1, change number, PICS token
            guard let (kv, next) = binaryKeyValues(b, at: pos) else { break }
            pos = next
            guard let package = kv.children.first?.value else { continue }
            func int(_ key: String) -> Int { package[key]?.value.flatMap { Int($0) } ?? 0 }
            var extended: [String: String] = [:]
            for (k, v) in package["extended"]?.children ?? [] { extended[k.lowercased()] = v.value }
            out.append(License(packageID: Int(id), billingType: int("billingtype"), status: int("status"),
                               appIDs: (package["appids"]?.children ?? []).compactMap { $0.value.value.flatMap { Int($0) } },
                               extended: extended))
        }
        return out
    }

    /// Binary KeyValues with NUL-terminated keys: type byte (0 block, 1 string, 2 int32,
    /// 3 float, 7 uint64, 10 int64, 8 end of block), key, value. Numbers become text.
    static func binaryKeyValues(_ b: [UInt8], at start: Int) -> (KeyValues, Int)? {
        var pos = start
        func cString() -> String? {
            guard let end = b[pos...].firstIndex(of: 0) else { return nil }
            defer { pos = end + 1 }
            return String(decoding: b[pos..<end], as: UTF8.self)
        }
        func le(_ n: Int) -> UInt64? {
            guard pos + n <= b.count else { return nil }
            var v: UInt64 = 0
            for i in 0..<n { v |= UInt64(b[pos + i]) << (8 * UInt64(i)) }
            pos += n
            return v
        }
        func block() -> KeyValues? {
            var kv = KeyValues()
            while pos < b.count {
                let type = b[pos]; pos += 1
                if type == 8 { return kv }
                guard let key = cString() else { return nil }
                switch type {
                case 0:
                    guard let child = block() else { return nil }
                    kv.children.append((key, child))
                case 1:
                    guard let s = cString() else { return nil }
                    kv.children.append((key, KeyValues(value: s)))
                case 2:
                    guard let v = le(4) else { return nil }
                    kv.children.append((key, KeyValues(value: String(Int32(truncatingIfNeeded: v)))))
                case 3:
                    guard let v = le(4) else { return nil }
                    kv.children.append((key, KeyValues(value: String(Float(bitPattern: UInt32(v))))))
                case 7:
                    guard let v = le(8) else { return nil }
                    kv.children.append((key, KeyValues(value: String(v))))
                case 10:
                    guard let v = le(8) else { return nil }
                    kv.children.append((key, KeyValues(value: String(Int64(bitPattern: v)))))
                default:
                    return nil
                }
            }
            return nil
        }
        guard let kv = block() else { return nil }
        return (kv, pos)
    }
}
