# Performance features research: upscaling, frame generation and other levers (2026-10-22)

What exists in the Mac/Wine ecosystem for DLSS-style upscaling, frame generation and
general game performance, what our stack (winecx = CrossOver 25.1 Wine 10.0 under Rosetta,
D3DMetal 3.0 from GPTK) already contains, and what Gamify could implement. Research only;
nothing was changed in the runtime or the app. Verified facts are marked **verified**
(checked on this machine today); the rest is from sources listed at the end.

## Status (2026-10-22, evening)

Stages 1 and 2 of the plan below are merged into `main` and live:
- Per-bottle Performance settings (`performance` in cross.json, `cross bottle show|set`,
  Performance box in the app, `cross cache clear`) and the DLSS→MetalFX plumbing: nvngx
  names in `runtimes/d3dmetal`, `nvngx.dll`+`nvapi64.dll` in system32, `NGXCore\FullPath`,
  `D3DM_ENABLE_METALFX=1`, `D3DM_VENDOR_ID=0x10DE` (metalfx is on by default for D3DMetal
  bottles). docs/app.md "Performance settings".
- `runtimes/winecx` and `runtimes/winecx-full` were rebuilt with three new `src/patches`
  (HAGS reporting, XGETBV emulation, Game Mode plist keys) and swapped in; the previous
  trees are kept as `runtimes/winecx-old` / `winecx-full-old` for rollback.
  docs/codeweavers-patches.md "Ported from CrossOver 26.1", docs/runtime-full.md.
- Verified on the new runtime: `hagstest` reports HwSchSupported/Enabled/EnabledByDefault
  = 1 with D3DMetal (0 with `WINE_DISABLE_HARDWARE_SCHEDULING=1`); `d3d11test` reports
  vendor 0x10de; msync runs; d3d12test FL 12_2 / SM 6.6 at ~120 fps.
- Corrections to the text below: on macOS 27 Rosetta executes `XGETBV` itself (returns
  xcr0 = 0x7 even with `ROSETTA_ADVERTISE_AVX=1`, and a 256-bit AVX add still works), so
  the XGETBV patch only matters on older macOS; and the Game Mode plist keys are ignored
  because macOS registers Wine processes as "wine" without a bundle id (Game Mode daemon
  logs "Ignoring"), so Game Mode needs the loader inside a real .app bundle (not done).
- DXVK 1.10.3 and DXMT 0.80 are built (`scripts/build-dxvk.sh`, `scripts/build-dxmt.sh`) and
  selectable as `graphics` dxvk / dxmt per bottle (docs/dxmt-dxvk.md, docs/app.md "Graphics
  backends"). Battle.net's 32-bit CEF now gets a GPU path on DXVK, but its login page still
  shows the spinner because of a renderer-process CHECK that is not graphics related.
- Not done: DLSS/Frame Generation in a real game (no DLSS game installed; Split Fiction is
  the candidate); real-game comparisons of D3DMetal vs DXMT vs DXVK; lsfg-metal and
  D3DMetal 4.0 beta trials.

## TL;DR

1. **DLSS -> MetalFX, including Frame Generation, is already inside the D3DMetal 3.0 we
   ship.** Apple's `nvngx-on-metalfx.dll` is an `nvngx.dll` replacement: a game that
   supports DLSS calls NVIDIA's NGX API, D3DMetal maps DLSS Super Resolution to
   `MTLFXTemporalScaler` and DLSS Frame Generation (DLSS-G) to `MTLFXFrameInterpolator`
   (macOS 26+). Nothing new has to be downloaded. What is missing on our side is plumbing:
   rename two files, two DLLs in `system32`, one registry value, `D3DM_ENABLE_METALFX=1`,
   an NVIDIA vendor id, and one Wine patch (hardware GPU scheduling) for frame generation.
   This is the biggest, cheapest win and the thing to build first.
2. **A per-bottle "Performance" settings layer** (env vars + registry) is the prerequisite
   for everything else: msync, AVX advertising, DXR on/off, FPS cap, Metal HUD, Retina,
   MetalFX. `BottleConfig` today has only `runtime` and `graphics`.
3. **Two CrossOver 26 Wine hacks to port into `src/patches`**: CW HACK 24905 (report
   hardware-accelerated GPU scheduling, needed by DLSS-G) and CW HACK 23427 (emulate
   `XGETBV` under Rosetta so AVX games start). Both are small and in the LGPL sources we
   already download.
4. **Frame generation for games without DLSS**: `lsfg-metal` (MIT, works on top of
   D3DMetal; the user must own Lossless Scaling, 7 USD) is the only working option. Writing
   our own MetalFX frame interpolator at present time is possible but the one existing
   attempt (DXMT iOS fork) tripled GPU time; not recommended.
5. **Long term**: Rosetta ends after macOS 27 (Apple keeps it only for "certain older,
   unmaintained games"). CodeWeavers' answer is native ARM64 Wine + FEX (CrossOver Preview,
   2026-07-31, macOS 26.5+, no D3DMetal yet). Nothing to do now except watch the CrossOver
   27 sources.

## What is impossible on a Mac (so we do not chase it)

| Technology | Why not |
|---|---|
| Real DLSS (NVIDIA neural upscaler) | Needs NVIDIA tensor cores and NVIDIA's driver. `nvngx.dll` is replaced by Apple's MetalFX bridge instead. |
| FSR 4 | Needs RDNA4 FP8 matrix hardware; even Linux needs a hacked DLL. FSR 1/2/3 are plain compute shaders and already run through D3DMetal. |
| XeSS with XMX | Intel-only; the DP4a fallback path is plain shaders and runs. |
| Lossless Scaling (the Windows app) | Uses DXGI desktop duplication and Windows compositor; `lsfg-vk`/`lsfg-metal` reimplement only its shaders. |
| NVIDIA Reflex, DLSS 4 transformer model, Ray Reconstruction | Not in Apple's bridge (Skyfire Works' analysis of GPTK 4; `SuperSamplingDenoising` strings exist in 3.0 but nothing confirms it works). |

## 1. DLSS -> MetalFX (upscaling + frame generation)

### Evidence that it is in our D3DMetal 3.0 (verified)

- `runtimes/d3dmetal/x86_64-unix/D3DMetal.framework` links `MetalFX.framework` and
  references `MTLFXTemporalScalerDescriptor`, `MTLFXSpatialScalerDescriptor`,
  `MTLFXTemporalDenoisedScalerDescriptor` and **`MTLFXFrameInterpolatorDescriptor`**
  (`newFrameInterpolatorWithDevice:`).
- It contains the full DLSS-G parameter table (`DLSSG.MVecs`, `DLSSG.Depth`,
  `DLSSG.HUDLess`, `DLSSG.UI`, `DLSSG.OutputInterpolated`, ...), shader entry points
  `applyAdditiveUIForFrameInterpolation`, `generateUIForFrameInterpolation`,
  `bidirectionalDistortionFieldDepthForFrameInterpolationFS`, and the log line
  `Unsupported API: Frame interpolation not present on this OS` (macOS < 26).
- It reads the registry paths `Software\Nvidia Corporation\Global\NGXCore` (`FullPath`)
  and `SYSTEM\CurrentControlSet\Control\GraphicsDrivers` (`HwSchMode`), and the env vars
  `D3DM_ENABLE_METALFX`, `D3DM_NVNGX_PATH`, `D3DM_VENDOR_ID`, `D3DM_DEVICE_ID`,
  `D3DM_DEVICE_DESCRIPTION`, `D3DM_SUPPORT_DXR`, `D3DM_SHOW_HUD_STATS`,
  `D3DM_ENABLE_ASYNC_COMMIT`, `D3DM_MULTITHREADED_INTERFACE_ENABLE` (full list from
  `strings`; only five are documented by Apple, see below).
- `runtimes/d3dmetal/x86_64-windows/nvngx-on-metalfx.dll` exports the whole
  `NVSDK_NGX_D3D11_*` / `NVSDK_NGX_D3D12_*` surface (Init, CreateFeature,
  EvaluateFeature, GetCapabilityParameters, Shutdown1, ...).
- Apple's Read Me shipped in `runtimes/d3dmetal/notices/Read Me.rtf` (it is the 4.0 beta 2
  text) documents exactly five variables: `D3DM_SUPPORT_DXR`, `ROSETTA_ADVERTISE_AVX`,
  `D3DM_ENABLE_METALFX` ("On macOS 26 Tahoe ... causes DLSS functions to be converted to
  MetalFX where possible"), `D3DM_MTL4` (macOS 27+, Metal 4 backend, default on; not in
  3.0), `D3DM_MAX_FPS`. And the setup: rename `nvngx-on-metalfx.{so,dll}` to
  `nvngx.{so,dll}`, copy `nvngx.dll` + `nvapi64.dll` into `windows\system32`.

### What the ecosystem does

- **CrossOver 26** (Wine 11, D3DMetal 3.0, DXMT 0.72): a per-bottle "DLSS" toggle,
  "Enable DLSS powered by MetalFX. Only takes effect if DLSS is enabled in the in-game
  settings, only for D3DMetal and DXMT". Frame generation is not mentioned by CodeWeavers.
- **Heroic Games Launcher PR #5984** (GPTK 3.0-3, M4 Max, Hellblade II): swaps the runner's
  `nvngx.dll` for the MetalFX build, copies `nvngx.dll` + `nvapi64.dll` into the prefix,
  sets `HKLM\Software\NVIDIA Corporation\Global\NGXCore\FullPath`, `D3DM_ENABLE_METALFX=1`
  (D3DMetal) or `DXMT_ENABLE_NVEXT=1` (DXMT). **Frame generation additionally needed a
  patched `gdi32.dll`** that answers `D3DKMTQueryAdapterInfo(KMTQAITYPE_WDDM_2_7_CAPS)`
  with hardware scheduling enabled, because DLSS-G (NVIDIA Streamline) refuses to run
  without HAGS.
- **CrossOver 26.1 Wine 11 sources** (downloaded today, `scratchpad/cx26`): `CW HACK 24905`
  in `dlls/win32u/d3dkmt.c` does exactly that: when `CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal`,
  `KMTQAITYPE_WDDM_2_7_CAPS` returns `HwSchEnabled = HwSchSupported =
  HwSchEnabledByDefault = 1`. Proton's Wine has the same hack (`WINE_DISABLE_HARDWARE_SCHEDULING`
  opt-out). **Our Wine 10.0 (CrossOver 25.1) has only a stub** that returns
  `STATUS_NOT_IMPLEMENTED` for every type (verified in
  `upstream/crossover-sources-25.1.0/sources/wine/dlls/win32u/d3dkmt.c:334`).
- **Bridgeplay** (GPTK 4.0b3 + WineCX 11.17) advertises "DLSS Frame Generation runs on
  MetalFX frame interpolation". **Skyfire Works** claims Cyberpunk 2077 at ~45 fps rendered /
  ~90 fps presented with DLSS Quality + FG on an M3 Max (GPTK 4; unverified vendor claim).
- **Streamline games check the GPU vendor.** webmonarch/crossover-dx12-fix (Satisfactory,
  UE 5.6, GPTK 4 in CrossOver 26.3) reports DLSS SR/RR `= 0` and DLSS-G unsupported
  because D3DMetal presents an "AMD Compatibility Mode" adapter and NGX requires NVIDIA.
  UE5's own DLSS plugin (Hellblade II) does not check the vendor and works.

### Our experiment today (verified, bottle `steamtest`, `src/d3dtest/d3d11test.exe`)

| Environment | Adapter reported |
|---|---|
| default | `AMD Compatibility Mode`, vendor `0x1002`, device `0x66af` |
| `D3DM_ENABLE_METALFX=1` | same (no visible change in a non-DLSS app, runs fine) |
| `D3DM_VENDOR_ID=0x10DE` | vendor **`0x10de`**, description and device id unchanged |
| `D3DM_DEVICE_ID=9860 D3DM_DEVICE_DESCRIPTION=...` | no effect in that form (needs more probing: hex? spaces?) |

So the vendor id can be spoofed to NVIDIA with one env var. Also seen: wineboot already
copied `nvapi64.dll` and `nvngx-on-metalfx.dll` into
`bottles/steamtest/drive_c/windows/system32` (Wine populates `system32` from
`WINEDLLPATH`), so renaming the file in `runtimes/d3dmetal/x86_64-windows` to `nvngx.dll`
would put the right name in every new bottle automatically.

### What Gamify would implement (stage 1, no Wine rebuild)

1. `runtimes/d3dmetal`: `nvngx-on-metalfx.dll -> nvngx.dll`, `nvngx-on-metalfx.so ->
   nvngx.so` (keep the symlink-to-`libd3dshared.dylib` layout, see docs/d3dmetal3.md). The
   packaging script and the "install D3DMetal from the user's GPTK" path do the same.
2. Bottle setting `metalfx` (default on for D3DMetal bottles once tested): when on,
   `D3DM_ENABLE_METALFX=1`, `D3DM_VENDOR_ID=0x10DE`, ensure `system32\nvngx.dll` +
   `nvapi64.dll` exist, write `HKLM\Software\NVIDIA Corporation\Global\NGXCore\FullPath =
   C:\windows\system32` (REG_SZ) via `cross cfg`/`reg add` at bottle create and on toggle.
3. Verification: `MTL_HUD_ENABLED=1` shows "MetalFX" and the GPTK version in the Metal HUD
   when DLSS is active (mybyways). A DLSS game is needed; nothing in `steamtest` has DLSS
   (Portal 2, Worms W.M.D). Split Fiction (DLSS 3 SR + FG, DX12) and Dishonored 2 (no DLSS)
   were installed earlier in bottle `cx`; Split Fiction is the natural test.

### Stage 2 (Wine rebuild): frame generation

- Port `CW HACK 24905` into `src/patches` (make it unconditional or keyed on our
  `WINECX_GRAPHICS=d3dmetal`), rebuild winecx with `scripts/build-winecx*.sh`. Without it
  Streamline reports HAGS off and hides/greys Frame Generation.
- Then test DLSS-G in Split Fiction: expect the HUD to show roughly double the presented
  frames, plus some input latency and possible HUD artifacts (MetalFX FI gets the game's
  motion vectors/depth/UI mask through DLSS-G parameters, so quality should be far better
  than motion-estimated solutions).

### Known failure modes to document for users

- Games that detect Wine and disable DLSS (The Witcher 3 checks `wine_get_version`).
- Games that verify the `nvngx.dll` signature: DXMT's wiki suggests copying the game's own
  `nvngx_dlss.dll` next to the executable as `nvngx.dll` (a non-signed-check path); not
  needed with CrossOver 26 per the same wiki, so some Wine-side change exists there too.
- DLSS 4 (transformer) and Ray Reconstruction are not bridged; games fall back to DLSS 3
  behaviour. Frame generation needs macOS 26+; on older macOS D3DMetal logs "Frame
  interpolation not present on this OS".
- Apple calls the whole MetalFX integration "experimental".

## 2. Per-bottle performance settings (the plumbing everything needs)

Today `cli/Sources/CrossCore/Runtime.swift` sets `WINEESYNC=1` and `MTL_HUD_ENABLED=0`
and passes `WINEMSYNC` through from the caller only; the app exposes just the Graphics
picker (`d3dmetal` | `wined3d`). CrossOver 25+ has a per-game database for this. Proposed
`BottleConfig.performance` fields and what they map to:

| Setting | Maps to | Notes |
|---|---|---|
| `sync: esync \| msync` | `WINEESYNC=1` / `WINEMSYNC=1` | **msync verified working today** on our wineserver ("msync: up and running", `cmd /c ver` fine). CodeWeavers: "some applications run with better performance with MSync enabled", others no difference; CrossOver 26 has the toggle. Needs per-game A/B; default stays esync until measured. |
| `metalfx: Bool` | see section 1 | |
| `avx: Bool` | `ROSETTA_ADVERTISE_AVX=1` | Rosetta translates AVX/AVX2 since macOS 15 (BMI/F16C since 15.4) but hides them from `cpuid` unless this is set. Compatibility first (Alan Wake 2, Horizon Forbidden West, TLOU2, Spider-Man 2 need AVX), sometimes speed (AVX code paths). Needs CW HACK 23427 (section 3) to be safe. |
| `raytracing: Bool?` | `D3DM_SUPPORT_DXR=0/1` | Default on for M3+, off on M1/M2. Turning it off on M3+ is a known performance/stability lever for DX12 games that auto-enable RT. |
| `maxFPS: Int?` | `D3DM_MAX_FPS` | Frame cap inside D3DMetal: cooler laptops, steadier pacing, pairs well with frame generation. |
| `hud: Bool` | `MTL_HUD_ENABLED=1` | Already an env passthrough; expose in UI. `D3DM_SHOW_HUD_STATS` exists in the binary, undocumented. |
| `retina: Bool` | `HKCU\Software\Wine\Mac Driver\RetinaMode` | winemac.drv (`macdrv_main.c:415`). Off = Wine renders at half the backing resolution and Core Animation scales it up (a free 2x spatial upscale, the default today); on = native pixels, sharper, roughly 4x the pixels to render. CrossOver calls it "High Resolution Mode". |
| `vendorID: UInt32?` | `D3DM_VENDOR_ID` | Advanced; 0x10DE when `metalfx` is on. |

Also useful, no setting needed: **"Clear shader cache"** per game. D3DMetal keeps
`$(getconf DARWIN_USER_CACHE_DIR)/d3dm/<exe name>/shaders.cache` (869 MB on this machine
today, one folder per executable). Apple's Read Me recommends deleting it when a game stops
booting. The first launch of a game and the first minutes (a 5.4 s stall was measured in
docs/d3dmetal3.md) are shader compilation; the cache is per-exe and survives bottle moves,
which we should mention in docs and never delete on bottle delete.

## 3. Wine patches to port from CrossOver 26.1 (Wine 11.0 sources)

Both are macOS-only, self-contained and in the sources we already fetch
(`crossover-sources-26.1.0.tar.gz`, 149 MB, published 2026-04-09).

| Hack | File | What | Why for us |
|---|---|---|---|
| CW HACK 24905 | `dlls/win32u/d3dkmt.c` `NtGdiDdDDIQueryAdapterInfo` | Answer `KMTQAITYPE_WDDM_2_7_CAPS` with hardware scheduling on (also `KMTQAITYPE_CHECKDRIVERUPDATESTATUS`, `KMTQAITYPE_DRIVERVERSION = WDDM 1.3`) | DLSS Frame Generation (Streamline requires HAGS). Our Wine 10 returns `STATUS_NOT_IMPLEMENTED` for every type. |
| CW HACK 23427 | `dlls/ntdll/unix/signal_x86_64.c` `emulate_xgetbv` | Rosetta has no `XGETBV`; emulate it in the SIGILL handler and report xcr0 = fpu/sse/avx/avx-512 on Sequoia+ | Games that take the AVX path after `ROSETTA_ADVERTISE_AVX=1` execute `xgetbv` and die with an illegal instruction otherwise. Absent from our 25.1 tree (verified by grep). |

Not worth porting: CrossOver 26's winemac.drv moved to Wine 11's client-surface model
(`d3dmetal.c` diff), which is a large refactor, not a feature.

## 4. Frame generation for games without DLSS

| Option | How | State | Verdict |
|---|---|---|---|
| **lsfg-metal** (github.com/namo-2938/lsfg-metal, MIT, Rust) | A `libMoltenVK.dylib` shim for DXVK/vkd3d, plus a Metal front end injected with `DYLD_INSERT_LIBRARIES` + `LSFGM_METAL=1` that swizzles `CAMetalLayer nextDrawable` and runs Lossless Scaling's frame-gen shaders (loaded from the user's own Lossless Scaling install, `lsfg-vk` beta branch). Explicitly lists D3DMetal and DXMT as supported renderers; 2x/3x/4x, fixed or adaptive pacing, HDR. | "Very early release", one Mac, few titles, one 60 Hz display. Output capped at 60·m/(m−1) fps on a 60 Hz panel by MoltenVK's 3-image swapchain / one drawable per refresh. Needs x86_64 Wine (ours) and a Wine not hardened against `DYLD_INSERT_LIBRARIES` (ours is ad-hoc signed; to verify). | Best candidate for an optional "Frame generation (Lossless Scaling)" feature: bring-your-own DLL, we ship nothing proprietary. Try it manually first. |
| **Own MetalFX frame interpolator at present time** | Like DXMT's iOS fork PR #15 (`MADEIRA_FRAMEGEN=1`): copy drawable, estimate motion on GPU (block matching), run `MTLFXFrameInterpolator` with flat depth, present generated frame then real frame half a frame later. | On an iPhone 17 Pro Max GPU time per frame went 8–10 ms -> 23–33 ms and the game's own rate fell from 30 to 20 fps; HUD and edge artifacts without depth/UI mask. | Not recommended. Without the game's motion vectors/depth it is lsfg-metal with worse quality and we would own all the bugs. |
| **OptiScaler** (GPL-3, Windows DLL, Proton-CachyOS 11 integrates it) | Injected as `dxgi.dll`/`winmm.dll` next to the game; turns DLSS/FSR/XeSS inputs into FSR 3.1 or XeSS, adds FSR 3 frame generation ("OptiFG", DX12 only) to games that lack it. Everything is HLSL compute, which D3DMetal can run. | Zero macOS reports; FSR 4 paths impossible here; OptiFG described as crash-prone. | A cheap experiment for games that have FSR/XeSS but no DLSS; low priority because on a Mac the DLSS->MetalFX bridge is the better path and FSR 3 FG in games that ship it already runs (webmonarch saw FSR 3.1.5 initialise under D3DMetal). |

## 5. Upscaling for games without DLSS

- **Games that ship FSR 2/3 or XeSS** already upscale through D3DMetal (plain shaders).
- **Retina off** is a free spatial 2x upscale by the compositor (section 2).
- **Proton-style fullscreen hack** (add a fake low resolution, upscale with MetalFX Spatial
  at present): D3DMetal owns the `CAMetalLayer` (winemac.drv only hands it the layer via
  `macdrv_view_get_metal_layer`), so this would mean a `CAMetalLayer` swizzle (what
  lsfg-metal does) or a change inside D3DMetal we cannot make. DXMT has this built in
  (`d3d11.metalSpatialUpscaleFactor` 1.0–2.0). Medium effort, moderate value; after the
  DLSS work.

## 6. Other backends (DX11 / DX9 / 32-bit)

| Backend | Covers | Why it matters for performance | Cost |
|---|---|---|---|
| **DXMT** (3Shain, v0.80 2026-04; MIT until 0.80, LGPL after) | D3D10/11 natively on Metal, WoW64 32-bit | Reports of smoother DX11 than D3DMetal and DXVK; one Apple forum post measured a 42% frame-time penalty from D3DMetal's GPU sync in a DX12 title (single report). Has DLSS SR via `DXMT_ENABLE_NVEXT=1`, MetalFX spatial upscale option, Metal PSO + AIR shader cache. CrossOver 26 ships 0.72. | Needs its `winemetal.so` and winemac hooks. CrossOver 26.1's `d3dmetal.c` says "D3DMetal/DXMT both call" the same hook table, so our existing D3DMetal hook path may be enough; unverified. |
| **DXVK 1.10.3** (in `upstream/crossover-sources-25.1.0/sources/dxvk`, zlib) over our MoltenVK 1.4.2 | D3D9/10/11, 32-bit | Not faster than D3DMetal in general, but the only path for DX9 and 32-bit DX11 (Battle.net's 32-bit CEF needs it, NOTES.md). Async shader compilation (`dxvk.conf`) hides stutter but is an anti-cheat risk. | mingw build from the sources we have; winecx-full already has MoltenVK and Vulkan verified. |

## 7. Game Mode (macOS)

Game Mode gives the frontmost full-screen game top CPU/GPU priority and doubles Bluetooth
polling (lower controller/AirPods latency). Eligibility is read from the app bundle's
Info.plist: `GCSupportsGameMode = true` (macOS 14+), `LSSupportsGameMode = true`
(macOS 26+) and `LSApplicationCategoryType = public.app-category.games`. **Our
`wineloader` has an embedded `__info_plist` (CrossOver Hack 10913, bundle id
`com.codeweavers.CrossOver.wineloader`, `LSUIElement`) without any of these keys
(verified).** Adding them to the loader's plist in the winecx build is a few lines; whether
macOS honours them for a Wine process is unverified (an Apple forum thread reports Game
Mode not activating for a launcher's child process). Cheap experiment: add the keys, run a
full-screen game, look for the Game Mode icon in the menu bar.

## 8. D3DMetal 4.0 beta (GPTK 4)

- Metal 4 backend for DX12 (`D3DM_MTL4`, on by default on macOS 27, which this machine
  runs), two-phase shader compilation (fast transpile first, optimised version in the
  background) and a restorable shader cache, shared-storage resources, better bindless
  descriptor handling. Press: +10% Cyberpunk 2077, up to +66% GTA V (M4 Pro, Macworld).
  Frame generation wired to the Metal 4 interpolator (Skyfire Works). "Apple Silicon
  only"; GPTK 4 omits `atidxx64`.
- webmonarch's script swaps it into CrossOver 26.3 with no Wine-side change. For our Wine
  10 it is untested (3.0 worked unchanged, see docs/d3dmetal3.md). Same licence situation
  as 3.0: the user installs GPTK; we may not redistribute.
- Worth one afternoon on this Mac: `D3DMETAL_HOME` already lets us point a bottle at
  another D3DMetal tree.

## 9. Strategic: Rosetta's end

- Apple developer news: "macOS 27: final release to support Rosetta ... Rosetta
  functionality for older, unmaintained gaming titles that rely on Intel-based frameworks
  will continue to be supported" (macOS 28, fall 2027). Whether an x86_64 Wine counts as
  such a game is unknown; assume not.
- CodeWeavers' CrossOver Preview (2026-07-31): native ARM64 Wine + their FEX port for
  x86/x86-64 via ARM64EC, macOS 26.5+, needs restricted entitlements (Apple developer
  account), no D3DMetal in the first preview, launchers broken, bottles not convertible.
  The ARM64 macOS Wine patches are not upstream; they will appear in CrossOver's LGPL
  source tarball when it ships. DXMT already builds ARM64EC DLLs; D3DMetal for arm64 is
  Apple's call. Community efforts (Neutron, FEX-darwin) exist but are unverified.
- Action: none now. Re-check when CrossOver 27 sources are published; our build scripts
  are the asset that makes the switch possible.

## Suggested order of work

1. **Stage 1 (app + CLI, no rebuild)**: `BottleConfig.performance` + `cross bottle set
   <name> <setting>`, env mapping in `Runtime.environment`, Performance box in the bottle
   page; nvngx rename in `runtimes/d3dmetal` + packaging; NGXCore registry on create/toggle;
   msync/avx/dxr/maxfps/hud/retina toggles; "Clear shader cache" on a program. Test DLSS SR
   in Split Fiction with the Metal HUD.
2. **Stage 2 (winecx rebuild)**: port CW HACK 24905 + 23427 into `src/patches`, rebuild,
   test DLSS Frame Generation in Split Fiction; Game Mode plist keys in the same rebuild.
3. **Stage 3**: lsfg-metal manual trial on top of D3DMetal, then an optional
   bring-your-own-Lossless-Scaling feature; D3DMetal 4.0 beta trial via `D3DMETAL_HOME`.
4. **Stage 4**: DXMT and DXVK as selectable `graphics` backends (DX11 alternatives, DX9,
   32-bit Battle.net); fullscreen spatial upscaling only if DXMT does not cover the need.

## Sources

- Apple, Read Me shipped in `runtimes/d3dmetal/notices/Read Me.rtf` (evaluation environment 4.0 beta 2); MetalFX docs: https://developer.apple.com/documentation/metalfx , https://developer.apple.com/documentation/metalfx/mtlfxframeinterpolatordescriptor (`supportsDevice`, macOS 26.0+)
- Apple developer news on Rosetta: https://developer.apple.com/news/?id=w5ngl9k2 ; support note: https://support.apple.com/en-gb/102527
- Apple forum, Game Mode keys: https://developer.apple.com/forums/thread/782343
- CodeWeavers, Advanced Settings in CrossOver Mac 26: https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26 ; changelog: https://www.codeweavers.com/crossover/changelog ; ARM64 preview: https://www.codeweavers.com/blog/mjohnson/2026/7/31/crossover-preview-the-right-to-bear-arm64-on-mac ; sources: https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.1.0.tar.gz
- Heroic PR, DLSS via MetalFX + frame generation on GPTK 3: https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/pull/5984
- mybyways, GPTK 3.0 in CrossOver (setup, Metal HUD check): https://mybyways.com/blog/updating-crossover-to-gameporting-toolkit-3-0
- webmonarch/crossover-dx12-fix (D3DMetal 4 swap, Streamline vendor check): https://github.com/webmonarch/crossover-dx12-fix
- Skyfire Works on GPTK 4 (vendor analysis, unverified): https://skyfireworks.io/velocity/gptk4 ; Macworld on GPTK 4 numbers: https://www.macworld.com/article/3189951/apples-latest-game-porting-toolkit-beta-changed-how-i-think-about-mac-gaming.html
- Bridgeplay feature list: https://bridgeplay.dev/
- lsfg-metal: https://github.com/namo-2938/lsfg-metal ; lsfg-vk: https://lsfg-vk.dev/
- DXMT: https://github.com/3Shain/dxmt , releases https://github.com/3Shain/dxmt/releases , Vendor Extensions wiki https://github.com/3Shain/dxmt/wiki/Vendor-Extensions ; iOS frame-gen experiment: https://github.com/willfaust/dxmt/pull/15
- DXVK-macOS: https://github.com/Gcenx/DXVK-macOS/releases
- OptiScaler: https://github.com/OptiScaler/OptiScaler ; Proton-CachyOS integration: https://www.gamingonlinux.com/2026/05/proton-cachyos-11-adds-initial-optiscaler-integration-and-lots-of-other-fixes/
- Proton Wine HAGS hack: https://raw.githubusercontent.com/ValveSoftware/wine/bleeding-edge/dlls/win32u/d3dkmt.c ; NVIDIA Streamline DLSS-G requirements: https://github.com/NVIDIA-RTX/Streamline/blob/main/docs/ProgrammingGuideDLSS_G.md
- Witcher 3 Wine detection gist: https://gist.github.com/gabrielmaialva33/33ebb2542f0513d55100b22aa2149ff5
- Apple forum on D3DMetal sync overhead (single report): https://developer.apple.com/forums/thread/821733
- Post-Rosetta migration analysis (community): https://github.com/macgameport/cities-skylines-2-macos/issues/16
