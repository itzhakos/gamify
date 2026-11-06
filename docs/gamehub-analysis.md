# GameHub for Mac 0.8.613: what is inside, and what Gamify can borrow (2026-11-06)

Static analysis of `GameHub_en_0.8.613.dmg` (GameSir's Windows-games launcher for Apple Silicon),
done with REA (`open_binary` + `inspect_artifact`, inventory Evidence
`ev_339971f716f427cacadd37fbb29c1afa743a73b4061955df6bc196969eeb1d57`, DMG SHA-256
`4936b01923f17c59e7144853f9737f7a10bcb9267d2f257227c496e373a1f28a`) plus `strings`, `otool`,
`codesign` and `plutil` on a read-only mount. Nothing was executed. "Observed" below means a
string, symbol, plist key or file in the DMG; "inferred" means a conclusion from those; unknowns
are listed at the end.

## 1. What the DMG contains

| Item | Observed |
|---|---|
| App | `GameHub.app` 0.8.613, bundle id `com.gamemac.www`, Developer ID team `2V8DDU6RFC`, min macOS 14, 39 files, ~150 MB |
| Main binary | 138 MB arm64 Mach-O: a **Tauri** app (Rust backend, WebKit webview; `tauri://localhost`, 442 frontend JS chunks). Rust crates seen in paths: `wine-engine-sdk/{wine-engine-core,wine-engine-tauri,wine-engine-monitor}`, `app_lib::steam_client`, `gog_core` |
| Wine / GPTK / DXMT | **Not in the DMG.** Engine "components" are downloaded at runtime (`get_wine_engine_downloads_dir`, `.tar.zst`, `components.json`, `dxmtNightlyUpdater`). Apple's D3DMetal is **imported from the user's own GPTK DMG** (`import_gptk_component dmgPath`, "Imported from official Apple GPTK dmg", nested "evaluation environment" DMG, `WINE_GPTK_LIBD3DSHARED_PATH`) |
| `Frameworks/libwine_engine_monitor.dylib` | Rust, universal x86_64+arm64, 2.4 MB. Injected into Wine processes (`DYLD_INSERT_LIBRARIES`). FPS heartbeat over a UNIX socket; a native in-game overlay; the GPTK DXGI/NvAPI/NGX spoof (section 3) |
| `Resources/assets/metalduck/libMetalDuck.dylib` | ObjC++/C++, universal, 1.7 MB, links Metal, MetalFX, MetalPerformanceShaders, MetalKit. Hooks `CAMetalLayer` (`nextDrawable`, `setDrawableSize:`), `MTLCommandBuffer` and `MTLRenderCommandEncoder`. Frame generation, spatial upscaling, FPS limit, HUD, settings over a socket (section 4). Source path `/Users/swift/CLionProjects/MetalDuck/`; no public repository found |
| `Resources/assets/rosetta_x87/` | `runtime_loader` (arm64, C++: `MachoLoader`, `MuhDebugger` with task port + breakpoints, `OffsetFinder` over `/Library/Apple/usr/libexec/oah/libRosettaRuntime`) and `libRuntimeRosettax87` (the x87 handler payload: `x87_fadd_f32` … `x87_fsincos`, "Installing JIT Translation Hook"). Built from `/Users/gamesir/work/rosettax87_jit/` = GameSir's build of **Lifeisawful/rosettax87_jit (MIT)**. No entitlements on either binary |
| `Resources/assets/gamepad/lib/libgamepad_sdl.dylib` | x86_64 only, 183 KB, "C++ SDL injection dylib" (its README). Connects to `GAMEPAD_SOCK_PATH` + shared memory, creates **virtual SDL joysticks inside the Wine process**, forwards rumble back. The HID server is Rust, in-process in the app (hence the Input Monitoring permission in Info.plist) |
| `Resources/libsandboxfs{,-arm64}.dylib` | libc interposer (`open/openat/opendir/fopen/dlopen/rename/chmod/symlink`), "SandboxFS v2 manifest: layers, mounts, aliases, writable layer". Implements **virtual containers**: many games share one base prefix with a per-game writable overlay (`base_container_id`, `virtual_container`, `switch_base_container`) |
| `PlugIns/QuickLookExtension.appex`, `ThumbnailExtension.appex` | Quick Look preview + Finder thumbnails for `com.microsoft.windows-executable`: architecture, company, product version, ".NET program", "Has manifest", "Can launch with GameHub", icon from PE resources |
| `Resources/ios2mac/` | PlayCover-style IPA → Mac app converter with keymaps. Out of scope for us |
| `Resources/assets/firebase-bridge/bridge.js` | Firebase analytics. Out of scope |

Info.plist asks for Accessibility (global mouse events), Input Monitoring (gamepad), Microphone
(team voice chat), Documents/Downloads (detect removable disks). Entitlements on the main app:
allow-jit, allow-unsigned-executable-memory, disable-library-validation, audio-input,
downloads/user-selected read-write, network client+server.

## 2. The per-game settings model (observed keys)

This is the most useful map of what they expose, taken from the serde struct field names:

- **compatibility_layer** (which Wine installation; families `x86`, `x64`, `wow64`, `arm64ec`)
  and **translation_layer**: `rosetta_x64` | **`arm64ec`** (Wine ARM64X + **FEX**:
  `gamehub-fex`, `FEX_APP_CONFIG`, `C:\gamehub\fex\Config.json`, `FEX_GAMEHUB_PROFILE`,
  `GAMEHUB_ARM64EC_USE_GAMESCOPE`; "ARM64EC Wine runtime is incomplete: framework=",
  `arm64ec_macos_version_unsupported` / `upgrade_macos_or_switch_compatibility_layer`).
- **fex_profile** + **fex_custom_config**: `multiblock`, `max_inst`, `small_tsc_scale`,
  `smc_checks`, **`x87_reduced_precision`**, `silent_log`, `mono_hacks`, `hide_hypervisor_bit`.
- **graphics_stack**: `d3d_metal` | `dxmt` | `dxvk` | `vkd3d_proton` | `wine_d3d`, plus
  `molten_vk` config, `open_gl` config, per-game `graphics_stack_exceptions` and server-side
  `runtime_graphics_profiles`. `libvulkan_gamehub_disabled.dylib` via `WINE_SONAME_LIBVULKAN`
  hides Vulkan from Wine when a stack does not want it; `VK_DRIVER_FILES`/`VK_LAYER_PATH` pick MoltenVK.
- **sync_mode**: `Esync` | `Fsync` | `Msync`. **avx_enabled**. **metal_hud_enabled** (also
  `defaults write … MetalForceHudEnabled -bool`). **metal4_enabled** → `D3DM_MTL4`.
  **dlss_mode** → `D3DM_ENABLE_METALFX` / `DXMT_ENABLE_NVEXT`. **ray_tracing_mode**.
  **dxmt_experimental_dx12_support** → `DXMT_EXPERIMENT_DX12_SUPPORT`. `DXMT_LOG_LEVEL`.
- **retina_mode**, **resolution** + `GAMEHUB_WINDOW_WIDTH/HEIGHT`, window centering,
  `activate_wine_window` / `activate_app_by_pid` / `raise_steam_overlay_window`.
- **bypass_av_decode** → `MEDIACONV_BLANK_AUDIO_FILE` / `MEDIACONV_BLANK_VIDEO_FILE`
  (`blank.ptna`, `blank.mkv`) merged into `WINEDLLOVERRIDES` (Proton's blank-media trick for
  games whose videos hang).
- **gamepad_compat_mode** → `WINEENGINE_STEAM_GAMEPAD_COMPAT_MODE`, `WINE_ENGINE_GAMEPAD_PLUGIN_PATH`.
- **metalduck**: `enabled`, `upscaling`, `upscale_ratio`, `framegen`, `framegen_mode`,
  `framegen_model`, `framegen_quality`, `flow_scale`, `native_fps_limit`, `framegen_vsync`,
  `color_mode`, `hud`, `log_level`, `settings_socket_path`.
- `cmdline_hack_dir`, `env_hack_dir`, `process_env_hacks` (per-game hack directories),
  `language`, `start_parameters`, Discord rich presence, shader cache dir + "clear all caches".
- Steam launch block (29 fields): `offline_mode`, `cloud_enable`, `no_verify_file`,
  `steam_input` vdf/presets, `cm_accel`/`cm_proxy`/`cm_datacenter`/`cm_fallback_enabled`
  (China CM mirrors), `steam_agent_path`/`steam_agent_mode`.

**Dependency manager** (winetricks-like, YAML-defined, checksum-verified): step kinds
`DownloadArchive, InstallExe, InstallMsi, CabExtract, ArchiveExtract, GetFromCab, DeleteDlls,
CopyDll, LinkDir, OverrideDll, RegisterDll, RegisterFont, ReplaceFont, SetRegisterKey,
PatchRegister, InstallFonts, SetWindows, UseWindows, Uninstall`, with the usual verb inventory
(`d3dcompiler_33…47`, `d3dx9/10/11`, `x3daudio`, …).

**Stores**: their own Rust Steam client (QR login, Steam Guard, CM list from Valve or a
`youwo.com` mirror, depot/chunk manifests, `appmanifest_*.acf` writing, DLC plans, workshop,
cloud saves, family sharing, friends/chat/stickers, discussions) and a **`SteamAgent.vmp.exe`**
(VMProtect-packed) that is symlinked in place of `Steam.exe` with its own
`steamclient.dll/steamclient64.dll/Steam.dll/SteamUI.dll` layout and an RPC endpoint
(`STEAM_AGENT_SERVER_HOST`, `STEAMAGENT_PORT`), next to an "official mode" that uses the real
client. Epic (own auth, manifests, Rockstar-launcher wrapper) and GOG (Galaxy client credentials,
content-system v2, cloud saves) are also native. Cloud gaming (Haima/Tingyu), team rooms, voice,
Bilibili, Alipay/WeChat login: Chinese-market features.

## 3. The GPTK DXGI / NvAPI / NGX spoof (in `libwine_engine_monitor.dylib`)

Observed hook targets (mangled C++ exports of D3DMetal's `libd3dshared.dylib`, located through
`WINE_GPTK_LIBD3DSHARED_PATH`): `DXGIAdapter::GetDesc/GetDesc1/GetDesc2/GetDesc3`,
`DXGIAdapter::CheckInterfaceSupport`, `CreateDXGIFactory2`, `DXGIFactory::CheckFeatureSupport`
(PRESENT_ALLOW_TEARING), `D3D12Device::CheckFeatureSupport` (depth bounds test),
`NvAPI_GetDisplayDriverVersion`, `NvAPI_SYS_GetDriverAndBranchVersion`, and the NGX entry points
`NVSDK_NGX_D3D11/12_{AllocateParameters,GetCapabilityParameters,GetParameters}` with the
parameter names `FrameGeneration.Available`, `FrameGeneration.NeedsUpdatedDriver`,
`FrameInterpolation.*`, `SuperSampling.MinDriverVersionMajor/Minor`,
`SuperSampling.NeedsUpdatedDriver`, `DLSS.Enable.Output.Subrects`, `DLSS.Exposure.Scale`.
Env knobs: `WINEENGINE_GPTK_DXGI_SPOOF_{ENABLED,DESCRIPTION,DRIVER_VERSION,VENDOR_ID,DEVICE_ID,
NVAPI_DRIVER_VERSION,NVAPI_BUILD_BRANCH,NVNGX_HACKS_ENABLED,DXGI_PRESENT_ALLOW_TEARING,
D3D12_DEPTH_BOUNDS_TEST_SUPPORTED}`.

Inferred purpose: make DLSS / DLSS Frame Generation menus appear in games that check more than
the vendor id (adapter description "GeForce RTX …", device id, driver version, NvAPI branch,
NGX "needs updated driver"). This is the missing half of our docs/perf-research.md plan: Gamify
sets `D3DM_VENDOR_ID=0x10DE` + `D3DM_ENABLE_METALFX` + nvngx/nvapi in system32, which was enough
for d3d11test but made UE show "known issues with graphics driver" on Split Fiction.

## 4. MetalDuck (frame generation, upscaling, FPS limit, HUD)

Observed: env `METALDUCK_{FRAMEGEN,FRAMEGEN_MODE,FRAMEGEN_QUALITY,FRAMEGEN_VSYNC,FRAMEGEN_MAX_FPS,
FLOW_SCALE,UPSCALING,UPSCALE_RATIO,NATIVE_FPS_LIMIT,HUD,COLOR_MODE,LOG_LEVEL,SETTINGS_SOCKET_PATH,
TEXTURE_POOL_SIZE,DEBUG_MV,DEBUG_DEPTH,…}`; `MTLFXSpatialScaler` ("MetalFX Spatial Scaler
support", bilinear fallback); a `SwapChainProxy` with a fake drawable, a presentation loop with a
frame queue, pacing/backpressure diagnostics ("FrameGenDiag: mode raw pacing debiased target …");
"MV sniffing" and a "Depth Sniffer" on `renderCommandEncoderWithDescriptor:` (candidate motion
vector / depth textures scored by format and size); frame-gen pipelines `model_a` / `model_c`
(MPS is linked; the model itself is not identifiable from strings); a HUD renderer with its own
font texture; a JSON settings server on `/tmp/metalduck.sock`. The app's per-game settings reach
it via `metalduck_runtime_get/set/reload_shaders` over that socket.

Inferred: this is GameSir's "proprietary AI frame interpolation". It works for any Metal-presenting
game (D3DMetal, DXMT, DXVK), independent of DLSS, by interpolating between presented frames with
sniffed motion vectors/depth when it finds them. Licensing: closed, GameSir-signed; no source.

## 5. What Gamify can borrow, ranked

### Tier 1: directly addresses our open problem (Ori's x87 stutter, M1 MacBook)

1. **x87 acceleration on the Rosetta path: `x87sidecar` (MIT).** GameHub ships a build of
   `Lifeisawful/rosettax87_jit`; its maintained successor is
   [athei/x87sidecar](https://github.com/athei/x87sidecar): a hook in Rosetta's `translate_insn`
   sends x87 instructions to an out-of-process arm64 translator that returns ARM64 code
   (binary64 arithmetic instead of 80-bit; README: 6x-247x on 179 x87 micro-benchmarks, mean
   61x, on an M5 Max / macOS 27; CI on macOS 15/26/27). Our measured gap is ~97x
   (NOTES, 2026-11-06), so this is the lever for Ori and every 32-bit Unity/Mono game.
   Two modes: `x87sidecar --cooperative` (no root, no entitlement, the target hands over its
   own task port; Wine's loader launches each 32-bit process through it when
   `ROSETTA_X87_PATH` is set, which needs a small loader patch from athei's Wine tree) or
   `x87sidecar_entitled` (attach to any process; one developer-tools authorization per login
   or root). GameHub's `runtime_loader` has no entitlements, so it most likely relies on the
   same cooperative hand-over or on the debugging authorization prompt (unknown).
   **Plan:** port the loader patch to winecx, bundle `x87sidecar`, per-bottle
   `performance.x87 = sidecar|off` (32-bit processes only), measure Ori's menu-hover stalls and
   frame-time distribution before/after on the Mac Studio, then the M1. Caveats: precision (53-bit
   results; `fyl2x`-based `pow` sequences differ), a memory fault inside translated x87 code
   aborts the process unless `X87_PRECISE_FAULTS=1`, and the loader refuses Rosetta runtimes it
   does not recognise (probe with `--probe`).

2. **A second translation layer: Wine ARM64X + FEX (GameHub's `arm64ec`).** Open-source
   equivalents exist: [MetalSharp-Wine](https://github.com/metalsharp/MetalSharp-Wine) 3.0/4.0
   (Wine 11.20 ARM64X, FEX fork, `libarm64ecfex.dll` for x86_64, `libwow64fex.dll` for i386,
   msync on, `FEX_X87REDUCEDPRECISION` on by default; scripts AGPL-3.0, Wine LGPL, FEX MIT) and
   [athei/mach9](https://github.com/athei/mach9) (zlib). MetalSharp's 1.0.0 notes say
   "Ori and the Blind Forest: Definitive Edition no longer stutters" under FEX. Constraints:
   D3DMetal is x86_64 and **cannot run under FEX** (DX12 goes to VKD3D-Proton/MoltenVK or
   Mullion, a DXMT fork with DX12 support — note GameHub's `DXMT_EXPERIMENT_DX12_SUPPORT`);
   32-bit programs need **macOS 26.4+ and a Developer-ID-signed, notarized app with Apple's
   cross-architecture entitlement** for the low 4 GB (Gamify is ad-hoc signed; GameHub is
   Developer-ID signed, which fits). So this is the long-term route for 32-bit games, but it
   needs an Apple developer account and a second runtime (~GBs). **Cheapest experiment first:**
   run Ori with MetalSharp-Wine's notarized app on the Mac Studio (macOS 27.2 satisfies 26.4+)
   and compare with the x87sidecar numbers before deciding.

### Tier 2: performance and graphics

3. **Finish the DLSS enablement (section 3).** A small injected dylib of our own that hooks the
   same `libd3dshared` exports (adapter description/device id/driver version, NvAPI driver
   version, NGX `NeedsUpdatedDriver`/`FrameGeneration.Available`) would let games that gate DLSS
   on more than the vendor id show the option, and would fix the UE "known issues with graphics
   driver" warning. Needs a DLSS game to validate (Cyberpunk 2077 or Portal with RTX, both owned).

4. **Render-scale + MetalFX spatial upscaling and an FPS limiter for any game** (the public-API
   half of MetalDuck): hook `CAMetalLayer` in the Wine process, give the game a smaller drawable,
   upscale with `MTLFXSpatialScaler` on present, pace presents for the FPS cap and draw a tiny
   HUD. Helps the M1 most. Frame generation itself (MetalDuck's `model_*`, sniffed motion
   vectors) is a research project; D3DMetal 3.0 already maps DLSS-FG to `MTLFXFrameInterpolator`
   for DLSS games, so the gap is only non-DLSS games.

5. **Newer DXMT.** GameHub follows DXMT nightlies and exposes `DXMT_EXPERIMENT_DX12_SUPPORT`
   and `DXMT_ENABLE_NVEXT`; MetalSharp ships Mullion (DXMT fork, LGPL-2.1+). We pinned v0.80
   (last MIT). Re-check the license situation and what DX12-on-DXMT buys us versus D3DMetal
   before moving.

6. **`D3DM_MTL4` (Metal 4) and ray-tracing toggles** for D3DMetal 3.0: cheap per-bottle
   experimental toggles; effect unknown, test with d3d12test and Sinking Star.

### Tier 3: cheap polish

7. **Bring the game window to front after launch** (`activate_app_by_pid`): Ori pauses render
   and logic whenever its window is not key (NOTES 2026-11-06); `NSRunningApplication.activate`
   on the wine64-preloader pid after `cross run` / Steam launch is a few lines.
8. **Install Rosetta from the app** (`osascript … softwareupdate --install-rosetta
   --agree-to-license with administrator privileges`, receipt check via
   `pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto`) instead of only telling the user.
9. **Quick Look + Finder thumbnails for `.exe`, and PE icons/version info in the Programs list**
   (we only parse `.lnk` targets today): a PE resource parser (icon group, VS_VERSION_INFO,
   CLR header for ".NET") in CrossCore plus two small appex targets.
10. **"Skip videos" per bottle** (`bypass_av_decode`): blank media + `WINEDLLOVERRIDES` for
    games whose intro videos hang on mfplat/GStreamer.
11. **Dependency installer** (winetricks-like, declarative steps): start with vcrun2022,
    d3dcompiler_47/d3dx9, dotnet48, corefonts from the official installers; our Stores code
    already caches installers and runs them in a bottle.
12. **Gamepad compat mode** (virtual SDL joysticks fed by a host HID server): solves Bluetooth
    DS4 visibility and moves the Input Monitoring prompt to the app, but it is an IPC + SDL
    virtual-device project. First check the cheap path: winecx-full's SDL2 winebus with a USB DS4
    and `SDL_JOYSTICK_HIDAPI`, as planned in NOTES.
13. **Virtual containers (base prefix + per-game overlay)**: elegant but a libc-interposer
    project; APFS clones (`cp -c`) give a "Duplicate bottle" for 20 lines if we want cheap copies.

### Not worth copying

`SteamAgent.vmp.exe` (a Steam client replacement; Steam ToS and anti-cheat risk; GameHub even has
an "ACE risk confirmation" flow), the own Steam depot downloader (we use the real client), cloud
gaming / team rooms / voice / social, Firebase analytics, Chinese CDN mirrors, ios2mac.

One hygiene point: GameHub does **not** redistribute D3DMetal; the user imports Apple's GPTK DMG
and the app unpacks it. Our DMG ships D3DMetal 3.0 from GPTK (see docs/LICENSING.md); if Gamify
ever goes public, their import flow is the safe model.

## 6. Unknowns

- The engine payloads (Wine/CrossOver base, DXMT and FEX versions, Mullion or not) are downloaded
  from `api-cn-gamehub.xiaoji.com` and were not inspected.
- How `runtime_loader` obtains the task port of the Wine process (no entitlement; cooperative
  hand-over, debugging authorization, or something else).
- MetalDuck's frame-generation model (`model_a`/`model_c`) and its quality; whether the "MV
  sniffing" works on D3DMetal-translated games.
- Licenses of MetalDuck, SandboxFS and the monitor (closed; GameSir-signed; no notices found).
