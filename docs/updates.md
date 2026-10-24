# Auto-update (2026-10-17)

Gamify checks for a new version on every launch (Settings > General can turn that off) and
from **Gamify > Check for Updates…**. An available update shows as a pull-down button in the
main window's toolbar, *"Gamify 0.9.1 available"*, whose menu holds the details and *Install
Now / Release Notes / Later* (until 0.9 it was a banner in a top `safeAreaInset`, which
macOS 27 drew under the unified toolbar: text clipped, Install Now unreachable; insets at the
bottom of the split view or of a column broke the columns' layout, see 0.9.1 below). Install downloads,
verifies, installs and relaunches the app. Nothing else is sent anywhere: the only network
requests are one GET of `latest.json` and, when the user clicks Install, the GET of one asset.
No analytics, no identifiers, no GitHub API calls.

## Release channel

The source repository (`itzhakos/gamify`) is private, and a private repository cannot serve
downloads without a token. Releases therefore live in a separate **public** repository,
**https://github.com/itzhakos/gamify-releases**, which holds only:

- `README.md` (what it is, how to install, Gatekeeper note, free/non-commercial terms),
- `THIRD_PARTY_NOTICES.md` (copy of docs/LICENSING.md, the same file that is in the bundle),
- `SOURCE_OFFER.md` (LGPL source offer for the Wine build and its libraries),
- GitHub Releases, one per version, tag `v<version>` (e.g. `v0.2`), with these assets:

| Asset | What | Size |
|---|---|---|
| `Gamify-<ver>.dmg` | the full app (drag to Applications) | ~520 MB |
| `Gamify-app-<ver>.zip` | the **app layer** only: `Contents/MacOS`, `Contents/Resources`, `Contents/Info.plist`, `Contents/PkgInfo`, and the two loose text files in the root (`THIRD_PARTY_NOTICES.md`, `scripts/winecx-env.sh`) | ~2 MB |
| `Gamify-<ver>-source.tar.gz` | our Wine patches, build scripts and webhelper shim source (see SOURCE_OFFER.md) | <1 MB |
| `latest.json` | the update manifest (below) | <1 KB |

The feed URL the app fetches is GitHub's "latest release" redirect, which is not one of the
rate-limited API endpoints:

    https://github.com/itzhakos/gamify-releases/releases/latest/download/latest.json

("latest" = the newest release that is neither a draft nor a pre-release, so a release can be
staged as a draft or pre-release without reaching users.)

### latest.json
```json
{
  "schema": 1,
  "version": "0.2",
  "build": "3",
  "published": "2026-10-17T18:00:00Z",
  "minimumSystemVersion": "14.0",
  "runtimeVersion": "winecx-full-3f9a2c41d0be",
  "notesURL": "https://github.com/itzhakos/gamify-releases/releases/tag/v0.2",
  "app":  { "url": "https://github.com/itzhakos/gamify-releases/releases/download/v0.2/Gamify-app-0.2.zip",
            "size": 2210345, "sha256": "…" },
  "full": { "url": "https://github.com/itzhakos/gamify-releases/releases/download/v0.2/Gamify-0.2.dmg",
            "size": 540984149, "sha256": "…" }
}
```

## Two layers, two versions

The bundle is 1.4 GB, of which the app itself is ~2 MB; the rest is
`Contents/SharedSupport/root` (Wine runtime, D3DMetal, Steam shim), which changes rarely.
So the runtime has **its own version**: `scripts/package-app.sh` writes
`Contents/SharedSupport/root/runtime-version`, `<runtime name>-<12 hex digits>`, a SHA-256
over every file under `root/runtimes` and `root/src` (relative path, type, symlink target or
contents; after relocation and signing). Identical runtime trees give the same version, so
nobody has to remember to bump it. The two loose text files in the root are not part of the
hash; the app layer carries them instead.

Update decision in the app:

1. `latest.json` `version` > `CFBundleShortVersionString` (numeric compare, `0.10` > `0.9`,
   `0.2` = `0.2.0`), otherwise "up to date".
2. `minimumSystemVersion` > the running macOS: shown, not installable.
3. `runtimeVersion` == the installed `root/runtime-version`: **app update** (the zip).
   Otherwise (different, or the installed app has no runtime-version file): **full update**
   (the DMG).

## Install

The app cannot replace itself while running, so the last step happens in a **detached helper**
(a `/bin/sh` script the updater writes next to the download and starts with `posix_spawn` in its
own process group, so it survives the app quitting). Before quitting, the app does everything
that can fail without touching the installed bundle, so errors show in the toolbar control and the
installed app stays as it was:

1. Download into `~/Library/Caches/Gamify/Updates/<version>/`, check size and SHA-256.
2. Stage:
   - app update: `ditto -x -k` the zip into `<App>.app/Contents/.gamify-update/` (same volume,
     so the swap is renames only);
   - full update: `hdiutil attach -nobrowse -readonly` the DMG, `ditto` its `Gamify.app` to
     `<parent>/.gamify-update-<ver>/Gamify.app` (same volume as the installed app), detach.
3. Start the helper with the app's pid, then quit the app.

The helper (log: `~/Library/Logs/Gamify/update.log`):

1. Waits for the app's pid to exit (60 s max).
2. Swaps, each step a `rename(2)`:
   - app update: `Contents/MacOS` and `Contents/Resources` are moved to `Contents/.gamify-old/`
     and the staged directories moved in; `Info.plist`, `PkgInfo` and the loose root files are
     replaced with `mv -f` (atomic replace of a file).
   - full update: `<App>.app` -> `<parent>/.gamify-old-<pid>.app`, staged app -> `<App>.app`.
   Any failure rolls the renames back and relaunches the old app.
3. `xattr -dr com.apple.quarantine <App>.app`, then the same ad-hoc signature as
   package-app.sh: `codesign --force --sign - -r='designated => identifier "local.gamify.app"'`
   (the app layer changes the bundle's sealed resources, so the outer signature must be redone;
   the designated requirement keeps the TCC grants). If codesign fails, roll back.
4. Removes the old layer and the staging directory, re-registers the bundle with
   LaunchServices, and relaunches with `open`.

Where updates are refused (the banner says why, nothing is downloaded):
- running from the checkout (`Project.bundled == false`), silently on launch; set
  `GAMIFY_UPDATE_FORCE=1` in the environment (or the `updateForce` user default) to test there;
- the bundle is not writable: running from the DMG, from App Translocation (an app started
  from Downloads with the quarantine flag), or an /Applications copy owned by another user;
- full update while games or Steam started from this app are still running (the runtime
  they run from is replaced).

Developer-ID builds (not used yet): the helper's ad-hoc re-sign would replace the Developer ID
signature. Such builds should ship full updates only, or sign on the build machine and ship
`_CodeSignature` with the layer.

## Settings and debug switches

| Key (user default) / env | Default | Meaning |
|---|---|---|
| `checkForUpdatesOnLaunch` | true | Settings > General > "Check for updates on launch" |
| `installUpdatesAutomatically` | false | Settings > General > "Install updates automatically": a launch check that finds an update installs it without waiting for Install Now (the banner still shows the progress) |
| `updateFeedURL` / `GAMIFY_UPDATE_FEED` | the URL above | another feed (a local `python3 -m http.server` for tests) |
| `updateForce` / `GAMIFY_UPDATE_FORCE=1` | off | allow checks and installs from a checkout build |

## Releasing

    scripts/release.sh 0.2              # bump, package, publish
    scripts/release.sh 0.2 --draft      # same, release left as a draft (users do not see it)
    scripts/release.sh 0.2 --no-publish # build everything in dist/release-0.2, upload nothing

What it does, in order:
1. Checks: `gh` logged in, no uncommitted changes under app/ cli/ scripts/ src/
   (`RELEASE_ALLOW_DIRTY=1` overrides), the version is newer than the latest published one.
2. Sets `CFBundleShortVersionString` to the version and increments `CFBundleVersion` in
   app/Info.plist.
3. Runs scripts/package-app.sh (stage + DMG), then copies both out of dist/stage into
   `dist/release-<ver>/` right away (other sessions may re-run package-app.sh).
4. Builds `Gamify-app-<ver>.zip` from the staged bundle and `Gamify-<ver>-source.tar.gz`
   (`git archive` of src/patches, src/webhelper-shim, the build scripts and docs/LICENSING.md).
5. Writes `latest.json` (sizes, SHA-256, runtime version from the staged bundle).
6. Commits app/Info.plist ("Release 0.2"), tags `v0.2`, pushes main and the tag to the
   private repository.
7. Syncs README/THIRD_PARTY_NOTICES/SOURCE_OFFER into the public repository
   (`scripts/releases-repo/`, cloned to `dist/gamify-releases`), then
   `gh release create v0.2 --repo itzhakos/gamify-releases` with the four assets.
8. Unless `--draft`: sets `version` and `sha256` (of the DMG) in `Casks/gamify.rb` of the
   Homebrew tap `itzhakos/homebrew-gamify` (cloned to `dist/homebrew-gamify`), commits
   "gamify 0.2" and pushes.

The public repository was created once with
`gh repo create itzhakos/gamify-releases --public`.

## Homebrew tap

`brew install --cask itzhakos/gamify/gamify` installs the release DMG. The cask lives in
the public repo `itzhakos/homebrew-gamify` (`Casks/gamify.rb`), created 2026-10-22 for 0.6.
It declares `auto_updates true` (so `brew upgrade` leaves Gamify to its own updater unless
`--greedy`), `depends_on arch: :arm64` and `macos: :sonoma`, and a `zap` of
~/Library/Application Support/Gamify, Caches/Gamify and the `local.gamify.app` preferences
and saved state. It does **not** clear the quarantine flag: Homebrew's policy is that casks
never bypass Gatekeeper, so the caveats print the same `xattr` / Open Anyway step as the
README. Once the app is notarized, drop that caveat.

Verified 2026-10-22 (Homebrew 7.0.9): `brew style` and `brew audit --cask --online` clean;
`brew tap itzhakos/gamify` from GitHub, then `brew install --cask --appdir=<temp>` downloaded
and installed 0.6 (Info.plist 0.6, `codesign --verify --strict` OK, quarantine set as
expected); `brew uninstall` removed it and left ~/Library/Application Support/Gamify alone.
The release.sh sed was tested on a copy (0.7 + a dummy SHA: `brew style` clean). Not yet run
inside a real release.

## Verified on GitHub (2026-10-17)

`itzhakos/gamify-releases` was created and 0.1 and 0.2 were published with
`scripts/release.sh` (private repo: commits "Release 0.1"/"Release 0.2", tags v0.1/v0.2).
0.1 was downloaded from the public release with curl (SHA-256 matched latest.json), installed
into ~/Applications, quarantine cleared as the README says, and launched with default settings:
it fetched latest.json from github.com, downloaded Gamify-app-0.2.zip
(`update-github-downloading.png`), the helper swapped and re-signed in 1 s, and 0.2 relaunched
with "Gamify was updated to 0.2." (`update-github-done.png`); `codesign --verify --strict` OK.

Notes from the run:
- After `gh release create`, `releases/latest/download/latest.json` kept serving the previous
  release for about a minute (GitHub's cache), then switched. Harmless: apps see the new
  version on their next launch.
- The install started without a click from the test: the Install Now button was the
  window's default button, so a Return pressed while `open` brought the app to the front
  can trigger it. Removed after 0.2 (the banner has no default button now); ships with the
  next release.

## Verified (2026-10-17, local feed)

Before the public repository existed, the end-to-end test used a local feed with the same layout: `scripts/release.sh 0.1 --local` and `0.2 --local`
with `RELEASE_URL_BASE=http://127.0.0.1:8765/<ver>`, a small Python server that delays
`latest.json` and throttles downloads, and the `updateFeedURL` default pointing at it.
0.1 was installed from its DMG into ~/Applications.

| Test | Result |
|---|---|
| Launch 0.1, same runtime in 0.2 | banner "Gamify 0.2 is available (1.7 MB)" (`update-available.png`) |
| App-layer update (auto-install on), bundle marked quarantined while running | download with progress (`update-downloading.png`), "Restarting Gamify…" (`update-installing.png`), helper swap + `codesign` took 1 s, 0.2 relaunched by itself and says "Gamify was updated to 0.2." (`update-done.png`); 0 files left with `com.apple.quarantine`, `codesign --verify --strict` OK, designated requirement `identifier "local.gamify.app"`, no `.gamify-update`/old layer left |
| Full update (manifest with a different runtimeVersion) | 540 MB DMG downloaded and verified, copied out of the mounted image (~9 s), whole bundle replaced (new inode), image detached, re-signed, relaunched as 0.2 |
| Package determinism | three package-app.sh runs gave the same runtime-version `winecx-full-7f45d5cc85c1` |
| Logic checks | version compare (`0.10 > 0.9`, `0.2 == 0.2.0`), layer choice, minimum macOS, App Translocation refusal |

Not exercised by hand: the Later / Install Now buttons and the menu item (the test could
not click in the app; the automatic-install path runs the same `install()`), a failing
install (rollback path), and downloads from github.com itself.

Installs from before this feature (the first 0.1 DMG) have no updater: reinstall them once
from a DMG built with it.

## 0.7 (2026-10-23): first full-DMG update

The runtime changed (rebuilt Wine with the CrossOver 26.1 hacks, nvngx names in D3DMetal,
`runtimes/dxvk` and `runtimes/dxmt`, the `lib/wined3d` layout for both PE arches), so
`runtime-version` went from `winecx-full-c97307d8a598` (0.4-0.6) to `winecx-full-b06c9dee8503`
and installed copies fetch `Gamify-0.7.dmg` (575 MB) instead of the 2.3 MB app zip. Published
with `RELEASE_NOTES` set (feature list) by `scripts/release.sh 0.7`; the Homebrew cask was
bumped by the script. Not verified yet: an installed 0.6 updating itself to 0.7 through the DMG
path (the app-zip path was verified for 0.1 -> 0.2).

## 0.8 (2026-10-23): app-layer update again

Hover help (`HelpText.swift`) and the Debugging box (`DebugView.swift`, CrossCore `Debug.swift`)
change only the app layer: `runtime-version` stayed `winecx-full-b06c9dee8503`, so an installed
0.7 takes `Gamify-app-0.8.zip` (2.5 MB); older installs take the DMG. Published with
`scripts/release.sh 0.8`.

## 0.9 (2026-10-24): app-layer update

MSync by default (`performance.sync` `auto`, Performance.swift) changes only the app layer:
`runtime-version` stayed `winecx-full-b06c9dee8503`, so installed 0.7/0.8 copies take
`Gamify-app-0.9.zip` (2.5 MB). Published with `scripts/release.sh 0.9` while the user's game
was running; the `releases/latest/download/latest.json` redirect served 0.8 for about a minute
after the publish, then 0.9.

## 0.9.1 (2026-10-24): the update control moved into the toolbar

On macOS 27 the update banner (`UpdateBanner`, a top `safeAreaInset` on the
`NavigationSplitView`) was drawn under the unified toolbar: the user saw only the top of its
text behind the title bar and could not click Install Now, so 0.8 could not update itself to
0.9 from the UI (Settings > General > "Install updates automatically" + a relaunch still
worked, as does the DMG). Tried and rejected, each checked on a test copy of the app
(`app/build/Gamify.app` with its bundle id changed to `local.gamify.test`, launched with `open
-n --env GAMIFY_UPDATE_FEED=http://127.0.0.1:8765/latest.json --env GAMIFY_UPDATE_FORCE=1`
against a copy of `dist/release-0.9/latest.json` that says 0.9.1, screenshots through the
desktop app's window capture): a top inset on the detail column (also under the toolbar), a
`VStack` with the banner above the split view (same), a bottom inset on the split view (never
shown), a bottom inset on the detail column or the sidebar (the columns' content was laid out
taller than the window and clipped at the top). What works: a `ToolbarItem(placement:
.primaryAction)` on the split view holding a `Menu` whose label is the short state ("Gamify
0.9.1 available", "Downloading 0.9.1…" with a small progress bar, "Installing…", "Up to date",
"Updated to 0.9.1", "Update problem") and whose items are the full text, then Install Now /
Release Notes / Later, Cancel while downloading, OK otherwise. The window never changes
layout for it. Not clicked through on screen (the menu cannot be opened in the background);
the actions are the same `UpdateController` calls as before.
