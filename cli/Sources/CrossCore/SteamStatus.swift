import Darwin
import Foundation

/// What Steam is doing in a bottle right now, read without talking to Wine: the
/// Windows processes of the bottle (libproc, by their working directory inside the
/// prefix) and the newest state line of Steam's own logs/connection_log.txt.
/// Used by the GUI's status line, its "Steam looks stuck" check and Restart Steam.
extension Steam {
    /// The connection state Steam prints in square brackets on every line of
    /// connection_log.txt that comes from its CM interface, e.g.
    /// `[2026-10-17 13:23:40] [Logged On, 4, 7] [U:1:1] RecvMsgClientLogOnResponse() : processing complete`.
    public enum ConnectionState: Equatable {
        case loggedOn
        /// Connecting / Connected / Logging On: on its way, normal for a few seconds after a start.
        case connecting
        /// Logged Off, No Connection, Logging Off or any state we do not know: no session.
        case loggedOff(String)

        public var isOnline: Bool { self == .loggedOn }

        init(stateName: String) {
            switch stateName {
            case "Logged On": self = .loggedOn
            case "Connecting", "Connected", "Logging On": self = .connecting
            default: self = .loggedOff(stateName)
            }
        }
    }

    /// The newest state line of connection_log.txt.
    public struct Connection: Equatable {
        public var state: ConnectionState
        /// Timestamp of that line (local time, as Steam writes it).
        public var date: Date
        /// Why the session ended when the log says so ("Session Replaced", "Disconnected By Remote Host",
        /// "user initiated logoff").
        public var reason: String?
        /// The account the line is about ("[U:1:12345]"), nil at the sign-in window ("[U:1:0]").
        public var account: String?

        /// Logged off because nobody is signed in, or because the user signed out: Steam
        /// is showing its sign-in window, not stuck.
        public var isSignedOut: Bool {
            account == nil || reason?.lowercased().contains("user initiated") == true
        }
    }

    public static func connectionLog(in bottle: Bottle) -> URL {
        bottle.steamDir.appendingPathComponent("logs/connection_log.txt")
    }

    /// Parses the tail of connection_log.txt (Steam rotates it on start, so the newest
    /// session is always in this file). nil when there is no log or no state line yet.
    public static func connection(in bottle: Bottle) -> Connection? {
        connection(logText: tail(of: connectionLog(in: bottle), bytes: 128 * 1024))
    }

    public static func connection(logText text: String) -> Connection? {
        var newest: Connection?
        // The log has CRLF line endings; "\r\n" is one Character in Swift, so split on isNewline.
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            // "[yyyy-MM-dd HH:mm:ss] [State, n, n] ..."
            guard line.hasPrefix("["), line.count > 22,
                  let dateEnd = line.firstIndex(of: "]") else { continue }
            let dateText = line[line.index(after: line.startIndex)..<dateEnd]
            let rest = line[line.index(after: dateEnd)...].drop(while: { $0 == " " })
            guard rest.hasPrefix("["), let comma = rest.firstIndex(of: ","),
                  let close = rest.firstIndex(of: "]"), comma < close else { continue }
            let stateName = String(rest[rest.index(after: rest.startIndex)..<comma])
            guard !stateName.isEmpty, stateName.allSatisfy({ $0.isLetter || $0 == " " }),
                  let date = logDateFormatter.date(from: String(dateText)) else { continue }
            var account: String?
            let afterState = rest[rest.index(after: close)...].drop(while: { $0 == " " })
            if afterState.hasPrefix("[U:"), let end = afterState.firstIndex(of: "]") {
                let id = String(afterState[afterState.index(after: afterState.startIndex)..<end])
                if !id.hasSuffix(":0") { account = id }
            }
            var reason: String?
            if let r = line.range(of: "not auto reconnecting due to ") {
                reason = String(line[r.upperBound...])
            } else if let r = line.range(of: "RecvMsgClientLoggedOff('"), let end = line[r.upperBound...].firstIndex(of: "'") {
                reason = String(line[r.upperBound..<end])
            }
            if let prev = newest, prev.date == date, reason == nil { reason = prev.reason }
            newest = Connection(state: ConnectionState(stateName: stateName), date: date, reason: reason, account: account)
        }
        return newest
    }

    private static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func tail(of url: URL, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let from = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: from)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Processes

    /// A Windows process running in a bottle, found through libproc: Wine keeps the
    /// unix working directory inside the prefix (steam.exe runs in its Steam dir) and
    /// argv[0] is the Windows command line (`steam.exe`, `C:\...\steamwebhelper.exe`).
    /// Environment variables of Rosetta processes are not readable, hence the cwd.
    public struct BottleProcess: Equatable {
        public var pid: pid_t
        public var arguments: [String]
        public var cwd: String
        public var started: Date?

        /// Lower-cased file name of the program ("steam.exe").
        public var program: String {
            guard let first = arguments.first else { return "" }
            let name = first.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? first
            return name.lowercased()
        }
    }

    /// Steam's processes in a bottle.
    public struct Processes: Equatable {
        /// steam.exe itself (a `steam.exe -shutdown` request is not counted).
        public var steam: [BottleProcess] = []
        /// steamwebhelper.exe (our shim) and steamwebhelper_real.exe.
        public var webhelper: [BottleProcess] = []

        public var isRunning: Bool { !steam.isEmpty }
        /// The browser processes outlived steam.exe (crash or kill): the next launch
        /// cannot attach to a client, and wineserver -k is the only way out.
        public var hasOrphanWebhelper: Bool { steam.isEmpty && !webhelper.isEmpty }
        /// When the oldest steam.exe started (nil when none runs or libproc has no date).
        public var steamStarted: Date? { steam.compactMap(\.started).min() }
    }

    public static func processes(in bottle: Bottle) -> Processes {
        var result = Processes()
        for p in bottleProcesses(in: bottle) {
            switch p.program {
            case "steam.exe":
                if !p.arguments.dropFirst().contains(where: { $0.lowercased() == "-shutdown" }) {
                    result.steam.append(p)
                }
            case "steamwebhelper.exe", "steamwebhelper_real.exe":
                result.webhelper.append(p)
            default:
                break
            }
        }
        return result
    }

    /// Every process whose working directory is inside the bottle's prefix.
    public static func bottleProcesses(in bottle: Bottle) -> [BottleProcess] {
        let prefix = bottle.prefix.standardizedFileURL.path + "/"
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var out: [BottleProcess] = []
        for pid in pids.prefix(Int(max(got, 0))) where pid > 0 {
            guard let dir = workingDirectory(of: pid), (dir + "/").hasPrefix(prefix) else { continue }
            let args = commandLine(of: pid)
            guard !args.isEmpty else { continue }
            out.append(BottleProcess(pid: pid, arguments: args, cwd: dir, started: startDate(of: pid)))
        }
        return out
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    private static func startDate(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
    }

    /// argv of a process (KERN_PROCARGS2: argc, exec path, then the NUL-separated argv).
    private static func commandLine(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buf[0]) | Int(buf[1]) << 8 | Int(buf[2]) << 16 | Int(buf[3]) << 24
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }   // exec path
        while i < size && buf[i] == 0 { i += 1 }
        var out: [String] = []
        var start = i
        while i < size && out.count < argc {
            if buf[i] == 0 {
                out.append(String(decoding: buf[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return out
    }

    // MARK: - Health

    /// The whole picture for one bottle, as the GUI shows and judges it.
    public struct Status: Equatable {
        public var installed: Bool
        public var processes: Processes
        public var connection: Connection?
        public var checked: Date

        public var isRunning: Bool { processes.isRunning }

        /// Seconds a freshly started Steam gets before an old "Logged Off" line in the
        /// (not yet rotated) log counts against it, and the longest "Connecting" that
        /// is still considered normal.
        public static let startupGrace: TimeInterval = 90

        /// Why Steam should be restarted, in plain words, or nil when it looks fine.
        /// Stuck means: the browser processes survived steam.exe, or Steam has been
        /// running for a while and its newest connection state is not "Logged On".
        public var stuckReason: String? {
            if processes.hasOrphanWebhelper {
                return "Steam's window process is still running, but Steam itself has quit."
            }
            guard let started = processes.steamStarted ?? (processes.isRunning ? Date.distantPast : nil) else { return nil }
            let runningFor = checked.timeIntervalSince(started)
            guard let connection, runningFor > Status.startupGrace else { return nil }
            switch connection.state {
            case .loggedOn:
                return nil
            case .connecting:
                if connection.account == nil { return nil }   // sign-in window: connected, waiting for a login
                guard checked.timeIntervalSince(connection.date) > Status.startupGrace else { return nil }
                return "Steam has been trying to connect since \(Status.timeText(connection.date))."
            case .loggedOff:
                if connection.date < started { return nil }   // an old line about the previous session
                if connection.isSignedOut { return nil }      // sign-in window, not a lost session
                var text = "Steam lost its connection at \(Status.timeText(connection.date))"
                if let reason = connection.reason { text += " (\(reason))" }
                return text + "."
            }
        }

        public static func timeText(_ date: Date) -> String {
            let f = DateFormatter()
            f.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
            f.timeStyle = .short
            return f.string(from: date)
        }
    }

    public static func status(in bottle: Bottle) -> Status {
        let installed = isInstalled(in: bottle)
        return Status(installed: installed,
                      processes: installed ? processes(in: bottle) : Processes(),
                      connection: installed ? connection(in: bottle) : nil,
                      checked: Date())
    }
}
