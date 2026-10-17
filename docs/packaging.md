# Packaging Gamify as an installable app (2026-10-17)

Product name: **Gamify** (renamed from Cross on 2026-10-17; the project folder, the `cross` CLI and the
`CrossCore` library keep their names). Bundle id `local.gamify.app`.

`scripts/package-app.sh` produces a self-contained `dist/stage/Gamify.app` and
`dist/Gamify-<version>.dmg` (drag to Applications). Nothing from the checkout is needed on the
target Mac.

## What goes into the bundle
```
Gamify.app/Contents/MacOS/CrossApp                      the SwiftUI app (app/build.sh)
Gamify.app/Contents/SharedSupport/root/
    runtimes/winecx-full/                              our CrossOver-lineage Wine 10.0 (x86_64) + GStreamer, SDL2, MoltenVK
    runtimes/d3dmetal/                                 Apple D3DMetal 3.0 (+ notices/License.rtf, Acknowledgements.rtf, Read Me.rtf)
    src/webhelper-shim/steamwebhelper.exe              our Steam webhelper shim
    scripts/winecx-env.sh                              reference only (Project.looksLikeRoot wants runtimes/ + scripts/)
    THIRD_PARTY_NOTICES.md                             copy of docs/LICENSING.md
```
`CROSS_RUNTIME=winecx scripts/package-app.sh` bundles the smaller runtime instead.
Sizes: app 1.4 GB, DMG 508 MB (UDZO).

## How the app finds things when bundled
- `Project.locate()` checks `<exe>/../../SharedSupport/root` first; `Project.bundled` is then true.
- Bottles and downloads go to `~/Library/Application Support/Gamify/{bottles,downloads}`
  (`Project.dataDir`); logs to `~/Library/Logs/Gamify`. `CROSS_BOTTLES` overrides the bottle dir
  (its parent becomes the data dir), `CROSS_ROOT` overrides the root.
- `Runtime.preferred(in:)` picks the bundled runtime for new bottles when `winecx` is absent.
- The root lives in **SharedSupport**, not Resources: codesign refuses nested code/frameworks
  (D3DMetal.framework) under Resources. Same layout as CrossOver.app.

## Relocation
Our x86_64 dylibs were linked with absolute install names into the checkout
(`/Users/.../runtimes/winecx-full/lib/...`), as were the GStreamer plugins and the Wine unix
libs that use them (winegstreamer.so, winevulkan.so, ...). The script rewrites every such
reference with `install_name_tool -change` to `@loader_path/<relative path>` and the ids to
`@rpath/<name>` (no new load commands, so no headerpad problems), then verifies with `otool -L`
that nothing points into the checkout, and re-signs every Mach-O (install_name_tool invalidates
signatures). Verified by copying the staged app to a scratch dir, pointing the CLI at it
(`CROSS_ROOT=.../Gamify.app/Contents/SharedSupport/root CROSS_BOTTLES=.../data/bottles`),
creating a bottle, running cmd, and checking with `DYLD_PRINT_LIBRARIES=1` that every library
came from the bundle (0 from the checkout).

## Signing and Gatekeeper
Ad-hoc signature with the designated requirement `identifier "local.gamify.app"` (so the TCC
grant for ~/Desktop survives rebuilds). An ad-hoc signed app downloaded by someone else is
blocked by Gatekeeper ("Gamify is damaged" / "cannot be opened"): the recipient must right-click
> Open once, or run `xattr -dr com.apple.quarantine /Applications/Gamify.app`. To make it
double-click friendly for a friend, sign with a Developer ID (`CROSS_SIGN_IDENTITY="Developer
ID Application: ..."`, the script then adds `--options runtime`) and notarize the DMG
(`xcrun notarytool submit`, `xcrun stapler staple`); that needs an Apple Developer account.
Hardened runtime + Rosetta: the x86_64 Wine binaries run through Rosetta and D3DMetal JITs,
which may need the `com.apple.security.cs.allow-unsigned-executable-memory` /
`allow-jit` entitlements under the hardened runtime. Not tested yet (no Developer ID here).

## First launch on another Mac
Requirements: Apple Silicon, macOS 14+, Rosetta 2 (the tutorial's Rosetta step installs it
with `softwareupdate --install-rosetta --agree-to-license`, admin password required), ~2 GB
disk for the app plus whatever the games need. The first-run tutorial (docs/app.md) creates the
first bottle and installs Steam.

## Licensing of the bundle
Free, non-commercial distribution only while it contains Apple D3DMetal (docs/LICENSING.md,
section on EA18380). THIRD_PARTY_NOTICES.md and Apple's notices are inside the bundle. The Wine
sources (LGPL) must be published alongside: `upstream/crossover-sources-25.1.0` + our
`scripts/build-winecx*.sh` and `src/patches`.
