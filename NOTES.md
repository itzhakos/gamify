# Cross — notes

## Current state (2026-10-19)
What is live, in one place; everything below it is the chronological log (dead ends included).
- **2026-10-22 CrossOver 26.1 ports** (branch claude/wine-hags-avx-5bfccc): `src/patches/`
  `win32u-d3dkmt-hwsched.patch` (CW HACK 24905: `D3DKMTQueryAdapterInfo(KMTQAITYPE_WDDM_2_7_CAPS)`
  reports HAGS when `WINECX_GRAPHICS=d3dmetal`, opt-out `WINE_DISABLE_HARDWARE_SCHEDULING=1`;
  needed for DLSS Frame Generation), `ntdll-emulate-xgetbv.patch` (CW HACK 23427; on macOS 27
  Rosetta runs XGETBV itself, so `ROSETTA_ADVERTISE_AVX=1` already works on the old runtime),
  `loader-plist-gamemode.patch` (Game Mode keys in wineloader's embedded plist; LaunchServices
  ignores that plist, so no Game Mode yet). Built into `runtimes/winecx-next` /
  `winecx-full-next`, verified (`src/hagstest`: NOT_IMPLEMENTED -> 1/1/1; `src/avxtest`; d3d11/12,
  ver, notepad), **not swapped yet**: docs/runtime-full.md "Ported from CrossOver 26.1".
- **Runtime**: `runtimes/winecx` (CrossOver 25.1 Wine 10.0, x86_64 under Rosetta, built by
  `scripts/build-winecx-deps.sh` + `scripts/build-winecx.sh`) and `runtimes/winecx-full`
  (same + GStreamer, SDL2, MoltenVK; `scripts/build-winecx-full-deps.sh` + `scripts/build-winecx-full.sh`).
  Since 2026-10-17 both build the i386 PE side with `i386_CFLAGS="-g -O2 -msse2 -mfpmath=sse"`
  (was x87: dsound 1761 -> 61 x87 ops, wined3d 6707 -> 134, ucrtbase 7051 -> 750; 32-bit
  DirectSound mixer 53% -> 6% of a core) and apply `src/patches/*.patch` before configure.
  User confirmed Portal 2 audio clean and Worms working on it; the old x87 builds were deleted.
  Details: docs/runtime-full.md "i386 PE side built with SSE".
- **Graphics**: `runtimes/d3dmetal` = Apple D3DMetal 3.0 from GPTK (default; the .so files are
  symlinks to libd3dshared.dylib). `runtimes/d3dmetal-2.1` = CrossOver's copy, local-only fallback.
- **Tools**: `cli/` (`cross`, Swift, with the `CrossCore` library) and `app/` (Cross.app, SwiftUI,
  `app/build.sh`). `scripts/winecx-env.sh` is the shell reference for the environment;
  `scripts/bottle.sh` was retired on 2026-10-17 (the CLI covers it).
- **Steam**: needs `src/webhelper-shim` (built with `make`) and `-noverifyfiles -no-cef-sandbox`.
- **Disk allocation** (2026-10-19, branch claude/storage-allocation): a bottle can live in its
  own APFS sparse bundle `bottles/<name>.sparsebundle` mounted (`hdiutil attach -nobrowse
  -noautoopen -mountpoint`) at `bottles/<name>`, so Windows sees C: as a drive of the chosen
  size (default 64 GB for new bottles, `--storage unlimited` / "Unlimited" = the old folder).
  Lazy mount on load/list, resize (detach + `hdiutil resize` + `compact`), move folder <->
  image (ditto + tree compare + swap), delete ejects. `cross bottle create --storage`,
  `cross bottle set <name> storage <GB>|unlimited`; app: New Bottle sheet Disk section, Disk
  row + Change… on the bottle page. Existing folder bottles unchanged. docs/app.md "Disk
  allocation".
- **Stores and programs** (2026-10-20, branch claude/game-stores-d0ee9a): `Store` model in
  CrossCore (Store.swift) with Steam (own code paths unchanged), **Epic Games Store** (MSI,
  works: sign-in window renders), **GOG Galaxy** (Inno Setup; installs and opens, but its Qt
  WebEngine window stays blank) and **Battle.net** (hands-off bootstrapper; installs and opens
  "Battle.net Login", but only its spinner: 32-bit CEF without a GPU path, needs DXVK).
  Installers cached in downloads/<store>/. Programs list per bottle: Start Menu/Desktop .lnk
  targets + programs.json (Programs.swift); `cross store list|install|launch`, `cross install`,
  `cross programs`; app: Stores box + Programs box (Install a Program…, Add a Program…),
  installers opened with the app are offered Install. docs/app.md "Stores and programs".
- **Steam licences** (2026-10-20, branch claude/steam-ownership-084773): games get correct
  ownership answers from Steam under our Wine (probe `src/steam-probe`, run in the user's
  bottle). Split Fiction runs as its Friend's Pass because the account's only licence for
  2001120 is the free Friend's Pass package; Dishonored 2 is owned. Fixed: Launch Steam on
  a running Steam zeroed `ActiveProcess\pid`, which made old-SDK games fail SteamAPI_Init
  (likely the Dishonored 2 "demo"). New: `cross steam check <bottle>` / Check… on the
  Steam row; Run .exe / Programs start Steam games through `steam://rungameid/<appid>`.
  docs/app.md "Steam check and licences".
- **Bottles on other drives** (2026-10-20, branch claude/bottle-location-8beb4b, for 0.6): a
  bottle can live outside the bottles folder (external drive): bottles/<name> (folder) or
  bottles/<name>.sparsebundle (image) is a symlink to it and bottles/<name>.location records
  the target, so a bottle whose drive is unplugged is listed as "lives on /Volumes/X which is
  not connected" (Try Again) instead of vanishing. Folder bottles only on APFS/HFS+, images
  anywhere (exFAT verified). `cross bottle create --location`, `set <name> location
  <folder>|default` (verified copy + swap), `eject` (an image on a drive blocks ejecting the
  drive), `find` / `add` (bottles on a drive from another Mac), `forget`. App: Location in New
  Bottle, Move to… / Eject on the bottle page, Find Bottles… + a banner when a drive with
  unlisted bottles is connected, Settings > Paths "Bottles folder" (CROSS_BOTTLES, which now
  moves only the bottles, not downloads). docs/app.md "Bottles on other drives".
- **Split Fiction test** (2026-10-22/23, user's Steam bottle, docs/perf-research.md "Real-game
  test"): the game has **no DLSS** (FSR 3.1 only), so DLSS->MetalFX is still untested on a real
  game (candidates owned: Cyberpunk 2077, Portal with RTX; no disk space). Measured on the 3D
  "Play Local" menu (capped at 60 fps by the game; GPU time is the comparable number): D3DMetal
  DX11 11.9 ms, DXMT DX11 12.7 ms (first real game on DXMT), D3DMetal DX12 13.3 ms; title screen
  uncapped 174 fps. FSR 3 frame generation produced alternating 12.3 ms / 0.96 ms frames in one
  run. Side effect found: the NVIDIA vendor spoof makes UE show "Known issues with graphics
  driver" (opens Safari); `metalfx`/vendor should become per-program or DLSS-detected. Tools:
  scripts/gamekey.swift (keys to a Wine game), full-screen `screencapture -x` works.
- **Graphics backends wired** (2026-10-22, main): `graphics` is now d3dmetal|wined3d|dxvk|dxmt
  (CrossCore `Backends.swift`: homes, `checkGraphics`, per-backend env, `prepareBackend`);
  WINEDLLPATH is `<backend>:<rt>/lib/wined3d:<rt>/lib/wine` for every backend, the build
  scripts and the live runtimes move d3d9 + all i386 d3d DLLs to lib/wined3d; CLI usage, app
  pickers, Settings paths, package-app.sh (ships dxvk/dxmt when built), winecx-env.sh updated.
  Verified all four with d3d11test 32/64 and d3d9test (docs/app.md "Graphics backends").
- **DXVK + DXMT** (2026-10-22, branch claude/dxmt-dxvk-6b922e (wired, see above)):
  `runtimes/dxvk` = DXVK 1.10.3 from CrossOver's tree (`scripts/build-dxvk.sh`, mingw-w64,
  patches in scripts/dxvk-patches: GS/cull/tess optional for upstream MoltenVK) for D3D9/10/11
  32+64-bit over winecx-full's MoltenVK; `runtimes/dxmt` = DXMT v0.80 (last MIT, `scripts/build-dxmt.sh`
  incl. LLVM 15 x86_64 built here) for D3D10/11 32+64-bit on Metal, no Wine patch needed (our
  winemac.drv exports `macdrv_functions`). Both are Wine builtins selected by
  `WINEDLLPATH=<backend>:<rt>/lib/wined3d:<rt>/lib/wine` once Wine's i386 d3d DLLs and d3d9 move
  to lib/wined3d too (docs/proposed/build-winecx-wined3d-layout.patch; then d3dmetal needs
  lib/wined3d in its path as well); DXMT also needs winemetal.dll in system32/syswow64, DXVK
  `vulkan-1=b`. d3d11test 32/64-bit FL 11_0 on both, d3d9test on DXVK, all at the 120 Hz cap
  like D3DMetal. Battle.net: DXVK fixes the GPU side (+ `--in-process-gpu`), the spinner stays
  because CEF's renderer hits a CHECK on every backend. docs/dxmt-dxvk.md, `scripts/test-dxbackends.sh`.
- **Runtimes rebuilt and swapped** (2026-10-22): `runtimes/winecx` and `runtimes/winecx-full` now
  carry the three `src/patches` ported from CrossOver 26.1 (`win32u-d3dkmt-hwsched.patch` = HAGS
  for DLSS Frame Generation, `ntdll-emulate-xgetbv.patch`, `loader-plist-gamemode.patch`); the
  previous trees are `runtimes/winecx-old` / `winecx-full-old` (delete when 0.7 is out). Verified
  after the swap: hagstest HwSch 1/1/1, d3d11test vendor 0x10de, msync, d3d12test FL 12_2.
  Game Mode keys have no effect (macOS sees Wine processes as "wine" without a bundle id);
  XGETBV emulation never runs on macOS 27 (Rosetta handles it). Status summary at the top of
  docs/perf-research.md. DXMT/DXVK (branch claude/dxmt-dxvk-6b922e) still in progress.
- **Performance settings** (2026-10-22, branch claude/perf-settings-e1520b, stage 1 of
  docs/perf-research.md): `performance` in cross.json (sync esync|msync, metalfx default on,
  avx, raytracing, maxFPS, hud, retina, vendorID) mapped to env vars in Runtime.environment
  and to registry/files by `Runtime.applyPerformance` (create, change, before every launch).
  DLSS -> MetalFX plumbing: runtimes/d3dmetal gets nvngx.dll + nvngx.so -> libd3dshared.dylib
  (also in package-app.sh), system32 nvngx.dll + nvapi64.dll, NGXCore\FullPath,
  D3DM_ENABLE_METALFX=1 + D3DM_VENDOR_ID=0x10DE (d3d11test then reports vendor 0x10de).
  `cross bottle show|set`, `cross cache clear`; app: Performance box, Clear Shader Cache….
  No DLSS game was available to test MetalFX itself. docs/app.md "Performance settings".
- **Performance research** (2026-10-22, docs/perf-research.md): the D3DMetal 3.0 we ship already
  bridges DLSS to MetalFX, including DLSS Frame Generation -> `MTLFXFrameInterpolator`
  (binary evidence; macOS 26+). Missing on our side: `nvngx-on-metalfx.{dll,so}` renamed to
  `nvngx`, `nvngx.dll`+`nvapi64.dll` in system32, `NGXCore\FullPath` registry value,
  `D3DM_ENABLE_METALFX=1`, `D3DM_VENDOR_ID=0x10DE` (verified: vendor becomes 0x10de), and
  CrossOver 26's CW HACK 24905 (HAGS in win32u d3dkmt.c; our Wine 10 stub returns
  NOT_IMPLEMENTED) for frame generation. msync verified working on our wineserver. Nothing
  changed yet; the doc has the staged plan (per-bottle performance settings first).
- **Bottles**: `cx` (Steam signed in, Order of the Sinking Star at 60 fps) and `full` (winecx-full).
  On 2026-10-19 the checkout's bottles/ held only `steamtest` (winecx-full, 21 GB, folder) and
  the installed 0.3 app's ~/Library/Application Support/Gamify/bottles held `Steam` (folder,
  created that day); cx, full and games were not on disk.
- **Reference material**: `upstream/crossover-sources-25.1.0` (+ dep sources), `downloads/crossover`
  (CrossOver 25.1 trial, unpacked, CLI-driven), `src/patches/` (diff over Wine 10.0).
- **Product name**: Gamify (2026-10-17, user's icon in app/icon/AppIcon.png); folder, `cross` CLI and
  CrossCore keep the old name. Bundle id local.gamify.app, data in ~/Library/Application Support/Gamify.
- **Installer**: `scripts/package-app.sh` -> self-contained `dist/stage/Gamify.app` (runtime +
  D3DMetal + shim under Contents/SharedSupport/root, install names relocated, ad-hoc signed)
  and `dist/Gamify-<ver>.dmg` (~515 MB). Bundled app keeps bottles in ~/Library/Application
  Support/Gamify. See docs/packaging.md. First-run tutorial in the app: docs/app.md.
- **Updates**: the app updates itself from GitHub Releases of a public repo
  (itzhakos/gamify-releases, feed `releases/latest/download/latest.json`): app-only zip when
  `SharedSupport/root/runtime-version` matches, else the DMG; detached helper swaps, re-signs,
  relaunches. `scripts/release.sh <ver>` publishes. 0.1-0.3 are published (2026-10-17/18), 0.4 (per-bottle disk allocation) on 2026-10-19, 0.5/0.6
  on 2026-10-20 and **0.7 on 2026-10-23** (Performance settings, DLSS->MetalFX plumbing, rebuilt
  runtime with the CrossOver 26.1 hacks, DXVK + DXMT backends; runtime-version
  winecx-full-b06c9dee8503, so installed copies take the full 575 MB DMG, not the app zip); a
  0.1 installed from GitHub updated itself to 0.2. docs/updates.md.
- **Repository**: https://github.com/itzhakos/gamify (private, since 2026-10-17). Sources, scripts
  and docs only; runtimes/bottles/downloads/upstream/dist are rebuilt locally (see README.md).
- **Docs**: README.md, docs/app.md, docs/packaging.md, docs/runtime-full.md, docs/d3dmetal3.md, docs/perf-research.md,
  docs/LICENSING.md, docs/codeweavers-patches.md, docs/portal2-audio.md.
- Retired on 2026-10-17: build trees (`build/`, 7 GB, regenerable), source tarballs, test .exe
  files (`make` rebuilds them), scripts/bottle.sh. Deleted the same day with the user's OK: the
  gptk/wine11/sikarugir runtimes (runtimes/Wine Staging.app, sikarugir11, sikarugir-template,
  SteamWrapper.app) and bottles test, steam11, steamcx, d3dm3, d3dm3-steam, apptest, plus the
  CrossOver trial bottles in ~/Library/Application Support/CrossOver. downloads/crossover stays
  as reference. Remaining bottles: cx, full, games.

## Goal
A CrossOver-like app for running Windows games on macOS (Apple Silicon).

## Stack decision (2026-10-16)
Two runtimes side by side, chosen per bottle via `bottles/<name>/.runtime`:
- `gptk`: **Game Porting Toolkit 3.0-3** as packaged by Gcenx
  (`brew install --cask gcenx/wine/game-porting-toolkit`).
  Wine 7.7 from the CrossOver lineage, x86_64 (Rosetta 2), with Apple's
  **D3DMetal.framework** for DirectX 11/12 -> Metal. **Cannot run Steam 2026**:
  the client calls `BCryptGenRandom` with the pseudo-handle `BCRYPT_RNG_ALG_HANDLE`
  (0x81), which Wine 7.7 dereferences -> page fault in bcrypt.dll. Verified by disassembly.
- `wine11`: **WineHQ Staging 11.16** (Gcenx build, `runtimes/Wine Staging.app`,
  downloaded by hand, not linked in Homebrew to avoid the cask conflict).
  Runs Steam. Ships MoltenVK but no D3DMetal, so DX11/12 games need DXVK/DXMT or
  a D3DMetal-capable Wine (CrossOver lineage) later.
- The old `wine-crossover` cask no longer exists; GPTK replaced it in the tap.
- CrossOver's own Wine sources (LGPL) are published at
  `https://media.codeweavers.com/pub/crossover/source/crossover-sources-25.1.0.tar.gz`
  (verified reachable). Download into `upstream/` when we need to read them.
- Install location: `/Applications/Game Porting Toolkit.app/Contents/Resources/wine`
  with `wine64`, `wineserver` linked into `/opt/homebrew/bin`.

## Verified on this machine (macOS 27.0.1, M4 Max, 64 GB, Metal 4)
- `wineboot --init` creates a prefix in ~15 s (335 MB).
- `cmd /c ver` reports Windows 10.0.19043, `PROCESSOR_ARCHITECTURE=AMD64`.
- `notepad.exe` launches with a window and shows up in `tasklist`.
- The bundled d3d11/d3d12/dxgi DLLs are built from Apple's D3DMetal sources (D3DMetalDLLsBase-17.12).
- wineserver supports WINEESYNC only (no WINEMSYNC in this build).

## Steam on wine11 (working 2026-10-16)
- Installer: official `SteamSetup.exe` (NSIS, Valve-signed), silent install `/S`.
- Steam's CEF (Chromium 126) paints every window black on Wine/macOS and its
  out-of-process NetworkService fails on Wine winsock (`net::ERR_FAILED 10045`).
  Fix (same approach as github.com/notpop/steam-on-m1-wine): replace
  `bin/cef/cef.win64/steamwebhelper.exe` with our shim `src/webhelper-shim/`
  that execs `steamwebhelper_real.exe --disable-gpu --single-process`.
- Steam's own `-cef-disable-gpu` is already passed by default; `-cef-single-process`
  is NOT honoured, hence the shim.
- Steam restores the original webhelper on start ("Verifying installation") unless
  launched with `-noverifyfiles`. We also pass `-no-cef-sandbox`.
- Stale `htmlcache/Singleton*` locks make Steam start `-silent` with no window.
- `scripts/bottle.sh steam steam11` does all of the above. Login window renders.
- Build the shim with Homebrew `mingw-w64` (`make -C src/webhelper-shim`).

## Reference: CrossOver 25.1.0 trial (downloaded 2026-10-16, downloads/crossover/)
Unpacked, not installed in /Applications. Driven purely from its CLI, no GUI needed:
- `CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxbottle --bottle X --create --template win10_64`
- `.../bin/wine --bottle X --cx-app "C:\\...\\steam.exe"` (bin/wine is a Perl script that builds the env)
- Bottles: `~/Library/Application Support/CrossOver/Bottles/<name>`; Windows user is `crossover`.
- Layout: `lib/wine/{x86_64-unix,x86_64-windows,i386-windows}` (+ empty i386-unix), dylibs in `lib64/`, loaders in
  `CrossOver-Hosted Application/{wine,wineloader,wineserver}` (x86_64 Mach-O).
- D3DMetal lives in `lib64/apple_gptk/{wine/x86_64-unix,wine/x86_64-windows,external}`
  (D3DMetal **2.1**, older than GPTK 3.0's 3.0 and Sikarugir's 4.0b3). Only
  d3d11/d3d12/dxgi/atidxx64 there.
- Hooks (from crossover-sources-25.1.0): ntdll exports `__wine_unix_call` (CW HACK 22435,
  the D3DMetal PE DLLs import it), ntdll/unix/loader.c dlopens `$CX_APPLEGPTK_LIBD3DSHARED_PATH`
  (CW HACK 22434, non-native code regions), winemac.drv/d3dmetal.c for the Metal surface.
- Per-bottle toggle in the GUI writes `[EnvironmentVariables] "WINED3DMETAL" = "1"` /
  `CX_GRAPHICS_BACKEND=d3dmetal`, but NOTHING in the shipped binaries reads those (checked
  with strings on ntdll.so, win32u.so, winemac.so, d3d11/dxgi.dll, wineloader, the GUI app).
  What actually selects D3DMetal is the DLL search order: the D3DMetal PE DLLs must come
  first in WINEDLLPATH. From the CLI the clean way is `[Wine] "DllPath" = "<CX>/lib64/apple_gptk/wine/x86_64-windows:<CX>/lib/wine/x86_64-windows:<CX>/lib/wine/i386-windows:<CX>/lib/wine"`
  in cxbottle.conf (bin/wine honours it). Verified WINEDLLPATH inside the bottle.
- Bottle `steam64` (win10_64) now has: Steam + Order of the Sinking Star copied in, D3DMetal
  DllPath set. Steam login window renders; login still needed (different Windows user).
- Steam (copied from our steam11 prefix incl. the 11GB game) starts on macOS 27 with
  Valve's unmodified webhelper, no shim needed.

## Dead end: Sikarugir engine outside its wrapper (2026-10-16)
- `WS12WineSikarugir11.0_1` (Wine 11.0 Sikarugir) + Template 1.0.23 (ships D3DMetal 4.0b3
  under `SharedSupport/renderer/d3dmetal/`, GStreamer, ffmpeg, libinotify).
- Every process exits 1 in ntdll `load_ntdll()`: `open_builtin_pe_file(x86_64-windows/ntdll.dll)`
  fails (the open is done by wineserver on the client's behalf). Same in a fresh prefix and
  via the official launcher (`WineAppInitializationError 1`). Likely macOS 27 incompatibility.
- Found with DYLD_INSERT_LIBRARIES interposers (exit/open/write) in scratchpad; the engine
  prints nothing because the fatal path never reaches stderr.

## Layout
- `cli/` — Swift Package, the `cross` command (winecx bottles: create/list/set/delete, run/cmd/cfg/steam/kill/env). See the cli section.
- `scripts/bottle.sh` — retired 2026-10-17, replaced by `cli/` (`cross`).
- `scripts/build-winecx-deps.sh`, `scripts/build-winecx.sh`, `scripts/winecx-env.sh` — our Wine build (see winecx section).
- `build/` — out-of-tree build dirs + logs (git-ignored).
- `scripts/listwindows.swift` — lists on-screen windows (id, owner, title) so we can
  `screencapture -l <id>` a Wine window for verification.
- `src/webhelper-shim/` — the steamwebhelper shim (C, mingw-w64).
- `bottles/<name>` — Wine prefixes (git-ignored). `test` = gptk, `steam11` = wine11 + Steam.
- `runtimes/` — hand-downloaded Wine builds (git-ignored).
- `downloads/` — installers (git-ignored).
- `upstream/` — third-party sources (git-ignored).

## Licensing to keep in mind
- Wine / CrossOver sources: LGPL 2.1. If we ship a modified Wine we must publish it.
- D3DMetal: Apple's GPTK license restricts redistribution. Whisky/Kegworks let
  the user install it themselves; we should do the same if we distribute.
- Kernel-level anti-cheat games will not run under any Wine-based solution.

## RESULT 2026-10-16: Order of the Sinking Star (DX12-only) runs on macOS 27
- Stack: CrossOver 25.1 trial (Wine 10.0 CrossOver lineage) + D3DMetal 2.1 from its
  `lib64/apple_gptk`, selected via `[Wine] DllPath` in cxbottle.conf, bottle `steam64`.
- Launched with `bin/wine --bottle steam64 --cx-app steam.exe steam://rungameid/499170`.
  Direct exe launch relaunches itself through Steam (SteamAPI_RestartAppIfNecessary).
- A "Steam Service Error" dialog appears (steamservice.exe cannot register as a service
  under Wine); Cancel is fine, the game still launches.
- Game log: levels load, voiceover plays. In GAME mode frame time mean 16.73 ms (~60 fps,
  stddev 1.41 ms, max 48.85 ms); in MENU mean 17.5 ms with
  stddev 31.8 (spikes up to 1.3 s on level load), saves written, clean SteamAPI_Shutdown.
  User played it and reported it works well. (Cyberpunk 2077 was running at the same time.)
- Same game on WineHQ 11.16 (vkd3d over MoltenVK): window but no frames. So D3DMetal is
  the differentiator, as expected for DX12.

## winecx: our own CrossOver-lineage Wine build (2026-10-16)
Built from `upstream/crossover-sources-25.1.0/sources/wine` (Wine 10.0 + CodeWeavers hacks),
x86_64, runs under Rosetta like CrossOver. Installed in `runtimes/winecx/`:
`bin/{wine,wineloader,wineserver,...}`, `lib/wine/{x86_64-unix,x86_64-windows,i386-windows}`,
`lib/wined3d/x86_64-windows` (see below), `lib/lib{gmp,nettle,hogweed,gnutls,freetype}*.dylib`.
Scripts: `scripts/build-winecx-deps.sh` (deps), `scripts/build-winecx.sh` (configure/make/install),
`scripts/winecx-env.sh` (runtime env), `scripts/bottle.sh create <name> winecx`.

### Toolchain / dependencies (no x86_64 Homebrew possible)
- `/usr/local` is root-owned and there is no sudo; Homebrew publishes NO x86_64 bottles for
  macOS 27 any more (only `arm64_golden_gate`, plus stale `sonoma` for a few formulas), so an
  x86_64 Homebrew under Rosetta would have to build everything from source anyway. Dropped.
- Instead: native arm64 `/usr/bin/clang -arch x86_64` for the unix side (fast), with
  `--host=x86_64-apple-darwin`; autoconf runs the x86_64 test binaries through Rosetta so
  `cross_compiling=no`. Wine's own tools (makedep, widl, wrc, winebuild) come out x86_64 and
  run under Rosetta during the build. PKG_CONFIG_LIBDIR is pinned to our prefix + the SDK so
  arm64 Homebrew libs can never leak in.
- Host tools from arm64 Homebrew: `bison` 3.8.2 (Apple's 2.3 is too old), `autoconf`,
  `automake`, `libtool`, `pkg-config`, `mingw-w64` 16.2 (`i686-` and `x86_64-w64-mingw32-gcc`
  cross compilers for the PE side; host arch irrelevant). Apple `flex` 2.6.4 is fine.
- Native deps built as x86_64 dylibs into `runtimes/winecx` (total ~2.5 min):
  gmp 6.3 (from the CrossOver tarball, `--disable-assembly`), nettle 4.0, gnutls 3.8.13
  (`--with-included-libtasn1 --with-included-unistring --without-p11-kit --without-idn
  --without-brotli --without-zstd --disable-hardware-acceleration ...`), freetype 2.15.0
  (`--without-png --without-harfbuzz --without-brotli --without-bzip2`).
  The CrossOver tarball's nettle has no `Makefile.in` and its gnutls/freetype are git
  checkouts whose Makefiles run `git submodule update` (fails outside git), so the release
  tarballs fetched by `brew fetch -s nettle|gnutls|freetype` (sha256-checked by Homebrew) are
  unpacked in `upstream/{nettle,gnutls,freetype}-src/`. nettle 4.0 needs gnutls >= 3.8.10.
- Not built yet: gstreamer (`--without-gstreamer`, video/mfplat), SDL2 (`--without-sdl`,
  winebus uses IOHID on macOS anyway), MoltenVK (`--without-vulkan`; D3DMetal does not need
  it, but DXVK/DXMT would). CrossOver ships all three in `lib64/`.
- `programs/winedbg/distversion.h` is generated by CodeWeavers' packaging and missing from
  the tarball; build-winecx.sh writes one (two WINDEBUG_* message macros).

### Configure (exact, from scripts/build-winecx.sh)
`configure --host=x86_64-apple-darwin --prefix=runtimes/winecx --enable-win64
--enable-archs=i386,x86_64 --disable-tests --without-x --without-gstreamer --without-sdl
--without-vulkan --with-freetype --with-gnutls i386_CC=i686-w64-mingw32-gcc
x86_64_CC=x86_64-w64-mingw32-gcc` with `CC="clang -arch x86_64"`,
`PKG_CONFIG_LIBDIR=runtimes/winecx/lib/pkgconfig:$SDK/usr/lib/pkgconfig`.
`--enable-archs=i386,x86_64` = new-style WoW64 (32-bit PE DLLs, one 64-bit unix side), which
is what CrossOver 25 uses on macOS (steam.exe is 32-bit). Other notices: no inotify, sane,
usb, v4l2, gphoto, pulse, ffmpeg, udev, capi, krb5, netapi, Wayland - all irrelevant here.
**Build time: 3 min 26 s** (`make -j16`, M4 Max) + 1.5 min install. 30 unix .so, 987 x86_64
PE, 1047 i386 PE files; prefix ~1.8 GB after wineboot (fake DLLs are full copies).

### Things the CrossOver tree needs at runtime (found the hard way)
- ntdll hardcodes the loader name **`wineloader`** (CW HACK 22144, dlls/ntdll/unix/loader.c).
  Plain `make install` leaves only `bin/wine`, so every child process fails to spawn
  (`run_wineboot failed to start wineboot 1`, then `could not load kernel32.dll c0000135`
  because the prefix never bootstraps). build-winecx.sh adds `bin/wineloader -> wine`.
- **`WINEDLLPATH` cannot put D3DMetal in front of Wine's own d3d11/d3d12/dxgi**: ntdll always
  searches its own `lib/wine` first (`set_dll_path`: `dll_paths[0] = dll_dir`), WINEDLLPATH
  entries only come after. Verified with `WINEDEBUG=+module`: the mapped d3d12.dll had Wine's
  section layout (.text 0x1fb0), not D3DMetal's (.text 0x356, `.eh_fram`). So build-winecx.sh
  moves Wine's `d3d10*.dll d3d11.dll d3d12.dll dxgi.dll` (x86_64 only) to
  `lib/wined3d/x86_64-windows`, and winecx-env.sh puts exactly one of
  `runtimes/d3dmetal/x86_64-windows` / `lib/wined3d/x86_64-windows` first in WINEDLLPATH
  (`WINECX_GRAPHICS=d3dmetal|wined3d`). After that D3DMetal's DLLs really load (checked).
  This also means the earlier claim that `[Wine] DllPath` selected D3DMetal 2.1 in the
  CrossOver trial bottle `steam64` is doubtful: CrossOver's `lib/wine/x86_64-windows` does
  ship vkd3d-based d3d12.dll/dxgi.dll, and its system32 copies are those. Unverified.
- GetUserName() returns **"crossover"** (CX hack 12735, unless `CX_REPORT_REAL_USERNAME` is
  set), so the Windows profile is `drive_c/users/crossover`, not `users/$USER`
  (bottle.sh's Steam lock cleanup uses that).
- `CX_APPLEGPTK_LIBD3DSHARED_PATH` is only dlopened lazily, on the first *native* (non-builtin)
  PE module load (CW HACK 22434 in ntdll/loader.c `pe_module_loaded`), so notepad never maps
  libd3dshared; steam.exe does.
- CrossOver-only `cxcompatdb.so` is not in the sources; ntdll warns and continues.
- gnutls/freetype are dlopened by leaf name (`libgnutls.30.dylib`), so
  `DYLD_FALLBACK_LIBRARY_PATH=runtimes/winecx/lib:...` in winecx-env.sh is required.

### Results in bottle `cx` (winecx)
- `wineboot --init` 38 s. `cmd /c ver` = Windows 10.0.19043, AMD64. notepad opens with a
  proper window (freetype fonts OK). Steam (cloned from steam11 with `cp -Rc`, APFS clone)
  starts, reaches the login server (gnutls OK, `libgnutls.30.dylib` + `libd3dshared.dylib`
  mapped in steam.exe).
- Valve's unmodified steamwebhelper paints **black** on winecx too (both backends), so the
  `src/webhelper-shim` (`--disable-gpu --single-process`) is used for every runtime now; with
  it the sign-in window renders.
- **WINEDLLPATH entries must be the parent of `x86_64-windows`/`x86_64-unix`**: ntdll
  appends `/x86_64-windows/<name>.dll` and looks for the unix half at
  `<entry>/x86_64-unix/<name>.so`. With the `x86_64-windows` dir itself as the entry the
  DLL is found but the .so is searched next to it -> `d3d11.dll failed to initialize,
  status c0000142`. (So the CrossOver bottle's DllPath pointing at `.../x86_64-windows`
  could never have loaded D3DMetal's unix side either.)
- `src/d3dtest/d3d11test.exe` (mingw, `make -C src/d3dtest`): DXGI adapter enumeration +
  D3D11 device + swap chain + 120 cleared frames, independent of Steam. Results on winecx:
  - wined3d: adapter "NVIDIA GeForce 8800 GTX" (GL path), feature level 10_1, 87 fps.
  - **D3DMetal 2.1** (`runtimes/d3dmetal-2.1`, from the trial's `lib64/apple_gptk`; its
    `d3d*.so` are symlinks to `libd3dshared.dylib`): adapter **"AMD Compatibility Mode"**,
    feature level **11_0**, 117 fps. Works.
  - **D3DMetal 3.0** (`runtimes/d3dmetal`, GPTK 3.0): adapter "AMD Compatibility Mode",
    feature level **11_0**; `d3d12test.exe` FL **12_2**, SM 6.6; 0 access violations under
    `WINEDEBUG=+seh`. Works on unmodified winecx and is **the default** (winecx-env.sh,
    `Runtime.defaultD3DMetal`). It first crashed in D3D11CreateDevice only because
    `x86_64-unix/d3d*.so` were *copies* of `libd3dshared.dylib` instead of symlinks (separate
    dyld images, so `gWin32Dispatch` filled by dxgi.so stayed NULL in d3d11.so); now symlinked.
    Not a hook-table mismatch: see docs/d3dmetal3.md.
- **RESULT: Order of the Sinking Star renders on winecx + D3DMetal 2.1** (bottle `cx`, launched
  with `bottle.sh run cx .../steam.exe steam://rungameid/499170` while Steam was running):
  `lsof` on sinking_star.exe shows `runtimes/d3dmetal-2.1/x86_64-windows/{d3d12,dxgi}.dll`,
  `libd3dshared.dylib` and `D3DMetal.framework` (+ libmetalirconverter) mapped, nothing from
  `lib/wined3d`; `WINEDEBUG=+loaddll` lists d3d12.dll/dxgi.dll as builtin. Game log:
  "AMD Compatibility Mode, Max D3D Feature level _12_2, Shader Model 6_6, Agility SDK 618".
  Frame times: first minute mean 18.00 ms (max 4.6 s = shader compile), then
  **GAME mean 16.72 ms (~60 fps, stddev 1.76, max 85 ms)**, MENU mean 16.67 ms (stddev 0.47).
  Same as the CrossOver trial run. 3120x1440 render target. No "Steam Service Error" dialog
  showed up this time.
- Steam's remembered login did not carry over (`cached creds not available` even with
  `AutoLoginUser` + `AppData/Local/Steam/local.vdf` copied); manual login needed once.

## cli: the `cross` command (2026-10-16)
Swift Package in `cli/` (swift-tools 5.9, macOS 14, no dependencies), `cd cli && swift build -c release`
-> `cli/.build/release/cross`. Replaces `scripts/winecx-env.sh` + `scripts/bottle.sh` for the
winecx runtime only (other runtimes still go through bottle.sh; both scripts stay until the CLI
is proven). Source layout: `Project.swift` (root lookup), `Runtime.swift` (= winecx-env.sh as a
type), `Bottle.swift` (cross.json), `Steam.swift` (shim install, ActiveProcess reset, lock
cleanup), `Process.swift` (execve / run-and-wait), `main.swift` (commands).
- Commands: `cross bottle create <name> [--runtime winecx] [--graphics d3dmetal|wined3d]`,
  `bottle list`, `bottle set <name> graphics <d3dmetal|wined3d>`, `bottle delete <name>`,
  `run <bottle> <exe> [args]` (cwd = exe dir), `cmd <bottle> ...`, `cfg <bottle>`,
  `steam <bottle> [args]`, `kill <bottle>`, `env <bottle> [--export]`.
- Project root: `CROSS_ROOT`, else walk up from the binary (then from cwd) to a dir with
  `runtimes/` + `scripts/` or `cli/Package.swift`. All paths are derived from it.
- Per-bottle settings in `bottles/<name>/cross.json`: `{"runtime":"winecx","graphics":"d3dmetal"}`.
  `graphics` picks which dir goes first in WINEDLLPATH (`$D3DMETAL_HOME`, default `runtimes/d3dmetal`, or
  `runtimes/winecx/lib/wined3d`). `.runtime` is still written so bottle.sh keeps working; a
  bottle without cross.json falls back to `.runtime` + d3dmetal.
- Environment precedence is the script's: `WINEDEBUG` (default `-all`), `WINEESYNC` (`1`),
  `MTL_HUD_ENABLED` (`0`), `D3DMETAL_HOME`, `WINECX_GRAPHICS` (overrides cross.json) and the
  two `DYLD_FALLBACK_*` tails are taken from the caller when set. `WINEMSYNC` is never set
  (esync-only wineserver), only passed through. `DOTNET_EnableWriteXorExecute=0` always.
- Verified: `cross env cx` is byte-identical to `source scripts/winecx-env.sh` with
  WINEPREFIX set, for d3dmetal and wined3d. Caveat when diffing yourself: `/bin/bash` and
  `/usr/bin/env` are SIP-protected, so dyld strips `DYLD_FALLBACK_*` from THEIR environment;
  compare via an unprotected printenv (the CLI, unprotected, keeps them and execve passes them
  to wine). Same reason the script can never see a caller's DYLD value when run under bash.
  `cross cmd cx /c ver` = Windows 10.0.19043, `%USERNAME%` = crossover. `cross steam cx`
  installed the shim (no-op, already there), showed "Sign in to Steam" after 10 s, then
  auto-logged in (remembered session) and rendered the store.
- Stop a running Wine Steam with `cross run <b> ".../Steam/steam.exe" -shutdown` (exits in
  ~3 s, keeps the remembered login); `cross kill` is the hard wineserver -k.
- `run`/`cmd`/`cfg`/`steam` execve wine directly (exit code and signals flow through);
  `bottle create` runs `wineboot --init` and waits.

## Next
- Build gstreamer (video/mfplat), SDL2 and MoltenVK for x86_64 into runtimes/winecx
  (CrossOver ships them in lib64/); then rebuild Wine without the three `--without-*`.
- `cli/` (`cross`) now replaces winecx-env.sh + bottle.sh for winecx; retire the scripts once
  it has been used for a while, then the SwiftUI app on top of `Runtime`/`Bottle`.
- Map the CodeWeavers patches over upstream Wine 10.0 (diff the tarball against wine-10.0).
- Licensing of every component (Wine LGPL, gmp/nettle/gnutls/freetype, Apple D3DMetal non-commercial only, CrossOver D3DMetal 2.1 local-only, Steam shim, our MIT proposal, release checklist): see docs/LICENSING.md.
- CodeWeavers patches over Wine 10.0 (module sizes, all 125 CW/CX hack numbers, what matters for us; raw diff src/patches/crossover-25.1.0-over-wine-10.0.diff, 948 KB): see docs/codeweavers-patches.md.
- D3DMetal 3.0 WORKS on stock winecx (DX11 test, DX12 test, Order of the Sinking Star at ~60 fps): the crash was runtimes/d3dmetal/x86_64-unix holding COPIES of libd3dshared.dylib as d3d*.so instead of symlinks (separate dyld images, NULL gWin32Dispatch), not a hook-table mismatch. Fixed in place (symlinks) and 3.0 is now the default D3DMETAL_HOME; when installing D3DMetal from a user's GPTK, preserve the symlinks. Contract, table diff and fix: see docs/d3dmetal3.md.
- GUI: `app/` SwiftUI app (`app/build.sh` -> app/build/Cross.app) on top of the new `CrossCore` library (cli/Sources/CrossCore: Project, Runtime, Bottle, Steam, Process, Commands; `cross` itself is now only cli/Sources/cross/main.swift, output byte-identical): see docs/app.md.
- Full runtime `runtimes/winecx-full` = winecx + GStreamer 1.24.2 (37 plugins, vtdec/atdec video via mfplat+quartz verified), SDL2 2.32.10, MoltenVK 1.4.2 (Vulkan verified), all x86_64; `scripts/build-winecx-full-deps.sh` + `scripts/build-winecx-full.sh`, `bottle.sh create <n> winecx-full`, bottle `full`: see docs/runtime-full.md.
- 2026-10-17: `cross` and Cross.app drive both runtimes. `Runtime` takes a name (`Runtime.known` = winecx, winecx-full; `Runtime.loadBottle(_:in:)` picks it from cross.json, `Runtime.available(in:)` lists the builds present), `cross bottle create --runtime winecx-full`, the app's New Bottle sheet has a Runtime picker and Settings lists both homes. For winecx-full the environment also carries `GST_PLUGIN_SYSTEM_PATH_1_0` / `GST_PLUGIN_SCANNER_1_0`, exactly like winecx-env.sh. `cross env cx` is unchanged (diffed against the script, non-DYLD keys identical). Verified: `cross cmd full /c ver` on winecx-full. runtimes/d3dmetal symlink fix done by the d3dmetal3 follow-up session (all seven .so -> libd3dshared.dylib).
- 2026-10-17 Portal 2 audio ticks = Wine dsound FIR resampler (44.1->48 kHz) built as x87 in our i386 PE DLLs, emulated slowly by Rosetta (50% of a core per buffer vs 1.5% with SSE). steamtest uses an SSE i386 dsound.dll (`scripts/dsound-sse.sh`); real fix = rebuild runtimes with i386_CFLAGS="-g -O2 -msse2 -mfpmath=sse". See docs/portal2-audio.md.
- 2026-10-17 Worms W.M.D (Qt5 + OpenGL) startup crash = winemac.drv refused SetPixelFormat on Qt's message-only GL dummy window; also needs a 4.1 core context for GLSL 330 and vertex inputs bound in declaration order. All three fixed in `src/patches/winemac-qt5-opengl.patch` (options on by default for Worms W.M.D.exe), main menu verified; still open: WMV3/WMA Pro intro videos need FFmpeg/gst-libav in the runtime, otherwise the game stays black after the logos. See docs/worms-opengl.md.
- 2026-10-17 WMV/WMA video (Worms W.M.D intros: WMV3 + WMA Pro) plays on winecx-full: minimal LGPL FFmpeg 6.1.6 (Windows Media decoders only) + gst-libav 1.24.2 in section 6 of scripts/build-winecx-full-deps.sh; winegstreamer picks avdec_wmv3/avdec_wmapro itself (winedmo/--with-ffmpeg is only a demuxer in Wine 10, no help). Worms started from Steam plays its logos and reaches the menu. See docs/runtime-full.md "Windows Media decoders" and docs/worms-opengl.md section 4.
- 2026-10-19 Per-bottle disk allocation: image-backed bottles = `hdiutil create -type SPARSEBUNDLE -fs APFS -size <N>g -volname <name> bottles/<name>.sparsebundle` + `hdiutil resize -size <N>g` (without it the volume is ~200 MB short), mounted with `hdiutil attach -nobrowse -noautoopen -mountpoint bottles/<name>`; marker `.gamify-disk-image` under the mount point, cross.json `"storage": {"image","sizeGB"}` inside the volume. `hdiutil resize` fails on an attached image (EAGAIN), so resize = detach, resize, `hdiutil compact` (returns space freed inside the bottle, 0.2 s), attach; shrink only above use. Attaching an image that is attached elsewhere fails "Resource busy" (handled: eject, remount). Busy check = cwd scan + connect to /tmp/.wine-<uid>/server-<dev>-<ino>/socket. Verified with a test exe: C: total 10.00 GB in a 10 GB bottle, ERROR_DISK_FULL past the end, 20 GB after a resize, remount after detach, folder<->image moves (5.7 GB in 8.6 s). All of hdiutil prints "deprecated, use diskutil image" on macOS 27 and still works. See docs/app.md "Disk allocation".
- 2026-10-20 Game stores and non-store programs (branch claude/game-stores-d0ee9a). Installer URLs checked with curl on 2026-10-19: Epic `launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi` (-> EpicInstaller-20.3.3.msi, 264 MB), GOG via `remote-config.gog.com/components/webinstaller?component_version=2.0.0` (-> content-system.gog.com setup_galaxy_2.1.10.56.exe, 342 MB), Battle.net `downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe` (-> 1.0.66, 4.9 MB). Results on winecx-full + D3DMetal: Epic installs in 28 s (msiexec /passive) and renders "Sign in to Epic Games" after a self-update; GOG installs in ~20 s (/VERYSILENT) but the Galaxy window stays blank (Wine's d3dcompiler_47 lacks `isinf` for ANGLE; Microsoft's DLL from mozilla/fxc2 fixes the shader errors but not the blank window; Qt/Chromium flags, software Qt Quick and wined3d did not help); after a kill Galaxy quits on its own stale lock until ProgramData/GOG.com/Galaxy/lock-files is emptied (done before every launch); Battle.net-Setup.exe hands off to a copy of itself and finishes in 45 s with no clicks, but the 32-bit app's CEF has no working GL (ANGLE D3D11 on 32-bit wined3d: "No available renderers") and shows only its spinner, also with HardwareAcceleration off. Workarounds applied are CrossOver 25's per-store overrides from crossover.tie (GalaxyOverlay.exe, systemsurvey.exe disabled). `cross store install <b> steam` now also does the client bootstrap (48 s). Non-store: `cross install` 7-Zip 23.01 /S in 2 s, shortcut found, launched; fallback (no shortcut) stores the new windowed exes. App verified through AppModel calls from an uncommitted launch hook (no assistive access for clicks). See docs/app.md "Stores and programs".
- 2026-10-20 Steam ownership under Wine (branch claude/steam-ownership-084773; user's `Steam` bottle of the installed 0.5 app, read-only except the probe dir C:\ProgramData\Gamify\steam-probe and the ActiveProcess pid repair; IDs masked here). **Split Fiction is in Friend's Pass mode because the account does not own it**: appcache/packageinfo.vdf (the client's cache of the account's 102 licence packages, parsed with a binary-KeyValues reader) has exactly one package with app 2001120, sub 1084787: billingtype 0 (no cost), extended `freeplaytogether=1`, `dontgrantifappidowned=2001120`, `disablegamecount=1`, `excludefromsharing=1` = the Friend's Pass, which grants the same app and depot 2001121 (hence the full 83 GB download); GetEarliestPurchaseUnixTime(2001120) = 2026-10-19 19:39. Buying the game adds a paid package; nothing in Gamify needs to change. (2371090, the app whose stats were fetched at launch, is "Steam Game Notes", not a Friend's Pass app; listofdlc 3050960 is not in the cache.) The launch was from the Steam library (console_log: GameAction LaunchApp, SynchronizingCloud, SiteLicenseSeatCheckout, CreatingProcess; gameprocess_log tracked SplitFiction.exe 21:05-22:25, exit 0), the client was Logged On the whole time (connection_log 19:58:42 -> 22:26:25 "Session Replaced"). The game's own folder has only settings/save data (SaveData.Split: EULA accepted, furthest chapter), no licensing log. Dishonored 2 (403640) is owned: package 183038 (billing 10, with Death of the Outsider), purchased 2019-07-24. **Probe** (`src/steam-probe/steam-probe.exe`, mingw-w64, flat C API of a steam_api64.dll copied from Split Fiction, steam_appid.txt 480) run with `cross run Steam ...` while Steam ran: init ok, logged on 1, appid 480, BIsSubscribedApp 480/228980/2001120/403640/499170/620/1091500 = 1 (purchase dates match the licences), 1245620/271590/292030 = 0: correct answers. **Steam Client Service**: service_log in the Steam dir shows "Failed to load Steam Service (GLE 126)" / BOpenService GLE 1060 on the very first start (2026-10-19 19:57, before the service existed), but Common Files/Steam/service_log shows the service files installed at 19:57:59 and "Startup" when Steam started on 2026-10-20 12:48; `tasklist` listed steamservice.exe, system.reg has the "Steam Client Service" key (Start=3). CrossOver 25.1 does nothing special for it (no steamservice in crossover.tie or the Wine sources); licences do not go through it. **Bug found and fixed**: `Runtime.steam` reset `HKCU\Software\Valve\Steam\ActiveProcess\pid` to 0 on every launch, also when Steam was already running (a second Launch, `steam://` URLs); the running client writes it only at start. With pid 0, Split Fiction's new steam_api64.dll still inits (SteamAPI_InitSafe) but SteamAPI_IsSteamRunning = 0, and Portal 2's old steam_api64.dll (SteamUser019 era, reads ActiveProcess) fails SteamAPI_Init; with the pid restored (216 = steam.exe) it inits and answers the same licences. Old-SDK games (Dishonored 2 is from 2016) would start without a Steam session: trial/demo mode or "Steam must be running". Fix: reset and lock cleanup only when no steam.exe runs; the probe's `--fix` (used by the check) repairs a bottle that still has a zero pid. Also new: `cross steam check` / Check… sheet (docs/app.md "Steam check and licences"), and Steam games launched from Run .exe / Programs go through `steam.exe steam://rungameid/<appid>` (cloud sync, overlay, app id from Steam). Not verified: a game actually launched through the new path (would have started a 90 GB game in the user's bottle), the Dishonored 2 demo itself (not installed anywhere, 12 GB free), the app sheet on screen.

- 2026-10-20 Bottles on other drives (branch claude/bottle-location-8beb4b). Registry stays bottles/: a link per located bottle + `<name>.location` (real target path) so a dangling link still has a name and a message; `Bottle.list` follows links (`isDirectoryKey` is false for a symlink). Tested with an APFS sparse bundle attached at /Volumes/TestDrive and an exFAT one at /Volumes/TestExFAT (both `hdiutil attach -mountpoint /Volumes/...` without sudo). Findings: a mounted bottle image on a drive makes `hdiutil detach`/Finder refuse to eject the drive ("dissented by diskimages-helper"), and the app re-lists (re-mounts) on every activation, hence Eject + `bottles/.<name>.ejected`; FileManager hides `._*` AppleDouble files, which ditto copies off exFAT as plain files (removed with readdir/unlink after a move to APFS); exFAT refuses folder bottles by design (no symlinks/permissions; statfs type check), sparse bundles work there and boot. Find attaches unlisted .sparsebundle images read-only at a temp mount point to read cross.json. Process detection (store list running) works through the link since SteamStatus already compares real paths. See docs/app.md "Bottles on other drives".
