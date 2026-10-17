import CryptoKit
import Foundation

/// Self-update of the packaged app from the public release feed (docs/updates.md).
///
/// The only network traffic: one GET of `latest.json` per check and, on install, the GET of
/// one asset. The feed is a GitHub "latest release" download URL, not the GitHub API.
///
/// Flow: `check()` -> `download(_:progress:)` (size + SHA-256 verified) -> `stage(_:file:)`
/// (everything that can fail, without touching the installed bundle) -> `launchHelper(_:)`,
/// then the caller quits; the detached helper swaps the bundle, re-signs it and relaunches.
public struct Updater {
    public static let defaultFeed = URL(string: "https://github.com/itzhakos/gamify-releases/releases/latest/download/latest.json")!
    /// Same designated requirement as app/build.sh and scripts/package-app.sh (keeps TCC grants).
    public static let designatedRequirement = #"designated => identifier "local.gamify.app""#

    /// User defaults / environment switches (docs/updates.md).
    public static let checkOnLaunchKey = "checkForUpdatesOnLaunch"
    public static let autoInstallKey = "installUpdatesAutomatically"
    public static let feedKey = "updateFeedURL"
    public static let forceKey = "updateForce"

    /// The .app being updated.
    public let bundle: URL
    /// CFBundleShortVersionString of `bundle`.
    public let currentVersion: String
    /// `Contents/SharedSupport/root/runtime-version`, nil in a checkout build or an old bundle.
    public let runtimeVersion: String?
    public let feed: URL
    /// Downloads and the helper script: ~/Library/Caches/Gamify/Updates.
    public let cacheDir: URL
    /// The helper's log: ~/Library/Logs/Gamify/update.log.
    public let logFile: URL

    public init(bundle: URL, feed: URL = Updater.defaultFeed) {
        self.bundle = bundle
        self.feed = feed
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        currentVersion = info?["CFBundleShortVersionString"] as? String ?? "0"
        runtimeVersion = (try? String(contentsOf: Updater.runtimeVersionFile(in: bundle), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let home = FileManager.default.homeDirectoryForCurrentUser
        cacheDir = home.appendingPathComponent("Library/Caches/Gamify/Updates")
        logFile = home.appendingPathComponent("Library/Logs/Gamify/update.log")
    }

    public static func runtimeVersionFile(in bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/SharedSupport/root/runtime-version")
    }

    /// `GAMIFY_UPDATE_FEED`, then the `updateFeedURL` default, then `defaultFeed`.
    public static func feedURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                               defaults: UserDefaults = .standard) -> URL {
        for value in [environment["GAMIFY_UPDATE_FEED"], defaults.string(forKey: feedKey)] {
            if let value, !value.isEmpty, let url = URL(string: value) { return url }
        }
        return defaultFeed
    }

    /// `GAMIFY_UPDATE_FORCE=1` or the `updateForce` default: allow updates in a checkout build.
    public static func forced(environment: [String: String] = ProcessInfo.processInfo.environment,
                              defaults: UserDefaults = .standard) -> Bool {
        environment["GAMIFY_UPDATE_FORCE"] == "1" || defaults.bool(forKey: forceKey)
    }

    // MARK: - Check

    /// Fetches the manifest and decides. Throws on network/HTTP/JSON errors.
    public func check() async throws -> UpdateCheck {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 404 { throw CrossError("no release is published yet (\(feed.host ?? feed.absoluteString) answered 404)") }
            throw CrossError("the update server answered HTTP \(http.statusCode)")
        }
        let manifest: UpdateManifest
        do {
            manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch {
            throw CrossError("the update manifest is not valid (\(error.localizedDescription))")
        }
        return decide(manifest)
    }

    /// Pure decision (unit-testable): newer version? which layer? does this macOS qualify?
    public func decide(_ manifest: UpdateManifest,
                       system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> UpdateCheck {
        guard let latest = AppVersion(manifest.version), let current = AppVersion(currentVersion), latest > current else {
            return .upToDate(latest: manifest.version)
        }
        let kind: Update.Kind = (runtimeVersion != nil && runtimeVersion == manifest.runtimeVersion) ? .app : .full
        let update = Update(manifest: manifest, kind: kind)
        if let minimum = manifest.minimumSystemVersion, let min = AppVersion(minimum),
           AppVersion(parts: [system.majorVersion, system.minorVersion, system.patchVersion]) < min {
            return .requiresNewerSystem(update, minimum: minimum)
        }
        return .available(update)
    }

    /// Why this bundle cannot be updated in place, or nil.
    public func installBlockedReason(for kind: Update.Kind) -> String? {
        let fm = FileManager.default
        if bundle.path.contains("/AppTranslocation/") {
            return "macOS is running Gamify from a temporary read-only copy (App Translocation). Move Gamify to the Applications folder, open it from there, then update."
        }
        if bundle.path.hasPrefix("/Volumes/") && !fm.isWritableFile(atPath: bundle.path) {
            return "Gamify is running from the disk image. Drag it to the Applications folder, open it from there, then update."
        }
        let contents = bundle.appendingPathComponent("Contents")
        if !fm.isWritableFile(atPath: contents.path) {
            return "Gamify cannot write to its own app bundle (\(bundle.path)). It may belong to another user; reinstall it from the latest disk image instead."
        }
        if kind == .full, !fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path) {
            return "This update replaces the whole app, and Gamify cannot write to \(bundle.deletingLastPathComponent().path). Reinstall it from the latest disk image instead."
        }
        return nil
    }

    /// True while a process runs from this bundle's runtime (wineserver, Steam, games): a
    /// full update replaces the files they run from.
    public func runtimeInUse() -> Bool {
        let prefix = bundle.appendingPathComponent("Contents/SharedSupport/root/runtimes").path
        guard let ps = try? Self.tool("/bin/ps", ["-axww", "-o", "command="]) else { return false }
        return ps.split(separator: "\n").contains { $0.hasPrefix(prefix) || $0.contains(" " + prefix) }
    }

    // MARK: - Download

    /// Downloads `update.asset` into cacheDir/<version>/ and verifies size and SHA-256.
    /// An already downloaded, valid file is reused. `progress(received, expected)`.
    public func download(_ update: Update, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let asset = update.asset
        let dir = cacheDir.appendingPathComponent(update.version)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(asset.url.lastPathComponent)
        if Self.fileSize(file) == asset.size, (try? Self.sha256(of: file)) == asset.sha256.lowercased() {
            progress(asset.size, asset.size)
            return file
        }
        try? FileManager.default.removeItem(at: file)
        try await Downloader(destination: file, progress: progress).run(asset.url)
        let size = Self.fileSize(file)
        guard size == asset.size else {
            try? FileManager.default.removeItem(at: file)
            throw CrossError("the download is incomplete (\(size) of \(asset.size) bytes)")
        }
        let digest = try Self.sha256(of: file)
        guard digest == asset.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: file)
            throw CrossError("the download is damaged (SHA-256 \(digest.prefix(12))…, expected \(asset.sha256.prefix(12))…)")
        }
        return file
    }

    // MARK: - Stage

    /// Unpacks the verified download next to the installed bundle (same volume, so the
    /// helper only renames). Blocking: run it off the main thread (a full update copies
    /// ~1.4 GB out of the disk image).
    public func stage(_ update: Update, file: URL) throws -> StagedUpdate {
        if let reason = installBlockedReason(for: update.kind) { throw CrossError(reason) }
        let fm = FileManager.default
        switch update.kind {
        case .app:
            let dir = bundle.appendingPathComponent("Contents/.gamify-update")
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.tool("/usr/bin/ditto", ["-x", "-k", file.path, dir.path])
            let contents = dir.appendingPathComponent("Contents")
            try Self.checkStagedApp(contents: contents, version: update.version)
            Self.clearQuarantine(dir)
            // Directories are swapped whole; every other file is replaced on its own.
            var items: [String] = []
            for name in ["MacOS", "Resources"] where fm.fileExists(atPath: contents.appendingPathComponent(name).path) {
                items.append(name)
            }
            let enumerator = fm.enumerator(at: contents, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            while let url = enumerator?.nextObject() as? URL {
                let rel = String(url.path.dropFirst(contents.path.count + 1))
                if rel == "MacOS" || rel == "Resources" { enumerator?.skipDescendants(); continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isRegularFile == true || values?.isSymbolicLink == true { items.append(rel) }
            }
            return StagedUpdate(kind: .app, version: update.version, staged: dir, items: items)

        case .full:
            let mount = cacheDir.appendingPathComponent(update.version).appendingPathComponent("mnt")
            try? fm.createDirectory(at: mount, withIntermediateDirectories: true)
            try Self.tool("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-noautoopen",
                                               "-mountpoint", mount.path, file.path])
            defer { _ = try? Self.tool("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
            let apps = (try? fm.contentsOfDirectory(atPath: mount.path))?.filter { $0.hasSuffix(".app") } ?? []
            guard let name = apps.first(where: { $0 == "Gamify.app" }) ?? apps.first else {
                throw CrossError("the disk image has no app in it")
            }
            let source = mount.appendingPathComponent(name)
            try Self.checkStagedApp(contents: source.appendingPathComponent("Contents"), version: update.version)
            let dir = bundle.deletingLastPathComponent().appendingPathComponent(".gamify-update-\(update.version)")
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let staged = dir.appendingPathComponent(bundle.lastPathComponent)
            do {
                try Self.tool("/usr/bin/ditto", [source.path, staged.path])
            } catch {
                try? fm.removeItem(at: dir)
                throw error
            }
            Self.clearQuarantine(staged)
            return StagedUpdate(kind: .full, version: update.version, staged: staged, items: [])
        }
    }

    /// Removes a staged update that will not be installed (Later after staging, errors).
    public func discard(_ staged: StagedUpdate) {
        let dir = staged.kind == .app ? staged.staged : staged.staged.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Install

    /// Starts the detached helper that waits for this process to exit, installs `staged`,
    /// re-signs and relaunches. The caller must quit right after (NSApp.terminate).
    public func launchHelper(_ staged: StagedUpdate) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = cacheDir.appendingPathComponent("update-helper.sh")
        try Self.helperScript.write(to: script, atomically: true, encoding: .utf8)
        try? fm.removeItem(at: resultFile)
        let args = [script.path, staged.kind.rawValue, String(getpid()), bundle.path, staged.staged.path,
                    resultFile.path, Self.designatedRequirement, staged.version] + staged.items
        let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                   "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        try spawnDetached(Invocation(program: "/bin/sh", arguments: args, environment: env), output: logFile)
    }

    /// What the last helper run reported ("ok" / "failed: ..."), consumed on read.
    public func takeLastResult() -> UpdateResult? {
        guard let text = try? String(contentsOf: resultFile, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: resultFile)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { return nil }
        if lines[0] == "ok" {
            // installed: the downloads (a DMG is ~500 MB) are no longer needed
            for item in (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
            where item.hasDirectoryPath {
                try? FileManager.default.removeItem(at: item)
            }
        }
        return UpdateResult(succeeded: lines[0] == "ok", version: lines[1],
                            message: lines.dropFirst(2).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var resultFile: URL { cacheDir.appendingPathComponent("last-result") }

    // MARK: - Helpers

    static func checkStagedApp(contents: URL, version: String) throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: contents.appendingPathComponent("MacOS/CrossApp").path) else {
            throw CrossError("the update has no app executable in it")
        }
        let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == "local.gamify.app" else {
            throw CrossError("the update is not a Gamify app")
        }
        let staged = info?["CFBundleShortVersionString"] as? String ?? "?"
        guard staged == version else {
            throw CrossError("the update contains version \(staged), the manifest says \(version)")
        }
    }

    static func clearQuarantine(_ url: URL) {
        _ = try? runWaiting(program: "/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", url.path],
                            environment: [:], quiet: true)
    }

    /// Runs a system tool; throws with its output when it fails.
    @discardableResult
    static func tool(_ program: String, _ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: program)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0 else {
            throw CrossError("\((program as NSString).lastPathComponent) failed: \(output.isEmpty ? "exit \(p.terminationStatus)" : output)")
        }
        return output
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The detached installer. Arguments: mode (app|full), pid to wait for, the installed
    /// .app, the staged update (Contents/.gamify-update or <parent>/.gamify-update-<v>/X.app),
    /// result file, designated requirement, version, then (app mode) the paths under
    /// Contents/ to replace. Every step is a rename; any failure rolls back and relaunches
    /// the old app. Output goes to ~/Library/Logs/Gamify/update.log.
    static let helperScript = #"""
    #!/bin/sh
    # Gamify update helper, written and started by CrossCore's Updater (docs/updates.md).
    MODE="$1"; PID="$2"; APP="$3"; STAGED="$4"; RESULT="$5"; REQ="$6"; VERSION="$7"
    shift 7
    C="$APP/Contents"
    # The old layer is kept outside the bundle (codesign would seal anything left inside it).
    OLD="$(dirname "$RESULT")/old-app-layer"
    OLDAPP="$(dirname "$APP")/.gamify-old-$$.app"
    say() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
    finish() {  # finish ok|failed message
      printf '%s\n%s\n%s\n' "$1" "$VERSION" "$2" > "$RESULT"
      say "$1: $2"
      /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1
      open "$APP"
      [ "$1" = ok ] && exit 0 || exit 1
    }
    rollback_app() {
      for rel in "$@"; do
        if [ -e "$OLD/$rel" ] || [ -L "$OLD/$rel" ]; then
          rm -rf "$C/$rel"; mkdir -p "$(dirname "$C/$rel")"; mv -f "$OLD/$rel" "$C/$rel"
        elif grep -qxF "$rel" "$OLD/.added" 2>/dev/null; then
          rm -rf "$C/$rel"
        fi
      done
      rm -rf "$OLD" "$STAGED"
    }

    say "installing Gamify $VERSION ($MODE update) into $APP; waiting for pid $PID to quit"
    n=0
    while kill -0 "$PID" 2>/dev/null; do
      n=$((n + 1))
      if [ $n -gt 600 ]; then
        printf 'failed\n%s\n%s\n' "$VERSION" "Gamify did not quit within 60 seconds." > "$RESULT"
        say "the app did not quit; nothing changed"; exit 1
      fi
      sleep 0.1
    done

    if [ "$MODE" = app ]; then
      rm -rf "$OLD" && mkdir -p "$OLD" || finish failed "cannot write to $OLD"
      : > "$OLD/.added"
      for rel in "$@"; do
        src="$STAGED/Contents/$rel"; dst="$C/$rel"
        mkdir -p "$(dirname "$OLD/$rel")" "$(dirname "$dst")"
        if [ -d "$src" ] && [ ! -L "$src" ]; then
          # whole directory (MacOS, Resources): move the old one aside, move the new one in
          if [ -e "$dst" ]; then mv "$dst" "$OLD/$rel" || { rollback_app "$@"; finish failed "cannot move $dst aside"; }; fi
          [ -e "$OLD/$rel" ] || echo "$rel" >> "$OLD/.added"
          mv "$src" "$dst" || { rollback_app "$@"; finish failed "cannot move the new $rel into place"; }
        else
          # single file: keep a hard link of the old one, then replace atomically
          if [ -e "$dst" ]; then ln "$dst" "$OLD/$rel" 2>/dev/null || cp -p "$dst" "$OLD/$rel"; else echo "$rel" >> "$OLD/.added"; fi
          mv -f "$src" "$dst" || { rollback_app "$@"; finish failed "cannot replace $rel"; }
        fi
      done
      rm -rf "$STAGED"
      xattr -dr com.apple.quarantine "$APP" 2>/dev/null
      if ! codesign --force --sign - -r="$REQ" "$APP"; then
        rollback_app "$@"
        finish failed "codesign failed; the previous version was restored"
      fi
      rm -rf "$OLD"
    else
      mv "$APP" "$OLDAPP" || finish failed "cannot move $APP aside"
      if ! mv "$STAGED" "$APP"; then
        mv "$OLDAPP" "$APP"
        finish failed "cannot move the new app into place"
      fi
      rmdir "$(dirname "$STAGED")" 2>/dev/null
      xattr -dr com.apple.quarantine "$APP" 2>/dev/null
      if ! codesign --force --sign - -r="$REQ" "$APP"; then
        rm -rf "$APP"; mv "$OLDAPP" "$APP"
        finish failed "codesign failed; the previous version was restored"
      fi
      rm -rf "$OLDAPP"
    fi
    finish ok "Gamify $VERSION installed"
    """#
}

/// Numeric dotted version (`0.2`, `0.10.1`, an optional leading `v`); missing parts are 0.
public struct AppVersion: Comparable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") { s.removeFirst() }
        let comps = s.split(separator: ".", omittingEmptySubsequences: false)
        var parts: [Int] = []
        for c in comps {
            guard let n = Int(c), n >= 0 else { return nil }
            parts.append(n)
        }
        guard !parts.isEmpty else { return nil }
        self.parts = parts
    }

    public init(parts: [Int]) { self.parts = parts }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    private func part(_ i: Int) -> Int { i < parts.count ? parts[i] : 0 }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) where a.part(i) != b.part(i) {
            return a.part(i) < b.part(i)
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// `latest.json`, attached to every release (written by scripts/release.sh).
public struct UpdateManifest: Codable, Equatable {
    public struct Asset: Codable, Equatable {
        public let url: URL
        public let size: Int64
        public let sha256: String
    }
    public let schema: Int?
    public let version: String
    public let build: String?
    public let published: String?
    public let minimumSystemVersion: String?
    /// The runtime the app layer needs (`root/runtime-version` of the full bundle).
    public let runtimeVersion: String
    public let notesURL: URL?
    /// Gamify-app-<ver>.zip: Contents/MacOS, Resources, Info.plist, PkgInfo + loose root files.
    public let app: Asset
    /// Gamify-<ver>.dmg: the whole bundle.
    public let full: Asset
}

public struct Update: Equatable {
    public enum Kind: String { case app, full }
    public let manifest: UpdateManifest
    /// `.app` when the installed runtime matches the manifest's, else `.full`.
    public let kind: Kind

    public var version: String { manifest.version }
    public var asset: UpdateManifest.Asset { kind == .app ? manifest.app : manifest.full }
}

public enum UpdateCheck: Equatable {
    case upToDate(latest: String)
    case available(Update)
    case requiresNewerSystem(Update, minimum: String)
}

public struct StagedUpdate {
    public let kind: Update.Kind
    public let version: String
    /// app: <App>.app/Contents/.gamify-update (holds Contents/...); full: the new .app.
    public let staged: URL
    /// app: paths under Contents/ that the helper replaces.
    public let items: [String]
}

public struct UpdateResult {
    public let succeeded: Bool
    public let version: String
    public let message: String
}

/// URLSession download with progress, moved to `destination` when done.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var lastReport = Date.distantPast

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func run(_ url: URL) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                continuation = c
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // at most ~10 reports a second (each one is a UI update)
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 0.1 || totalBytesWritten == totalBytesExpectedToWrite else { return }
        lastReport = now
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            failure = CrossError("the download server answered HTTP \(http.statusCode)")
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? failure {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
