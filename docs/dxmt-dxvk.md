# DXVK and DXMT for winecx-full (2026-10-22)

Two more graphics backends next to D3DMetal and wined3d, built from source on this Mac and
selectable by **environment only** (no files in the bottle except one DLL, see below):

| Backend | Folder | Covers | Built from |
|---|---|---|---|
| **DXVK 1.10.3** | `runtimes/dxvk` | D3D9, D3D10 (via Wine's d3d10.dll), D3D11; **32- and 64-bit**; over Vulkan = winevulkan -> MoltenVK 1.4.2 (winecx-full only) | CrossOver 25.1's DXVK tree (`upstream/crossover-sources-25.1.0/sources/dxvk`) + 3 small patches |
| **DXMT v0.80** | `runtimes/dxmt` | D3D10/D3D11 directly on Metal; **32- and 64-bit**; HDR; NVAPI/NGX (DLSS -> MetalFX) with `DXMT_ENABLE_NVEXT=1`; MetalFX spatial upscaling of the swap chain | github.com/3Shain/dxmt tag v0.80 (MIT) + 2 small patches, LLVM 15.0.7 static libs built here |

Not touched: `runtimes/winecx*`, `runtimes/d3dmetal`, `cli/`, `app/`, `src/patches/`. All tests ran
in a scratch bottle (`build/dxtest/bottles/dx`, `CROSS_BOTTLES`) on an APFS clone of
winecx-full with the proposed layout (below).

## TL;DR for the main session

**Status (2026-10-22, main session):** wired. `Graphics` has `dxvk` and `dxmt`
(`cli/Sources/CrossCore/Backends.swift`), the build scripts carry the layout change (the
proposed patch was applied and removed), the live `runtimes/winecx*` were re-laid-out with the
`mv` below, and all four backends were re-verified through `cross` (docs/app.md "Graphics
backends: DXVK and DXMT"). The "how to wire" notes below are kept as the design record.

1. The backends work: `d3d11test` 64-bit and 32-bit on DXVK and DXMT, `d3d9test` 32/64-bit on
   DXVK: real frames (screenshots), FL 11_0, "Apple M4 Max".
2. Wiring needs **one runtime layout change** (Wine's i386 d3d DLLs and d3d9 must move to
   `lib/wined3d` like the x86_64 ones already do): `docs/proposed/build-winecx-wined3d-layout.patch`
   for `scripts/build-winecx*.sh` (owned by the Wine session), or the same `mv` on an existing
   runtime. After that **every** backend, D3DMetal included, uses
   `WINEDLLPATH=<backend>:<runtime>/lib/wined3d:<runtime>/lib/wine`.
3. DXMT needs `winemetal.dll` copied into the bottle's `system32` and `syswow64` once.
4. DXVK needs `WINEDLLOVERRIDES=vulkan-1=b` (Battle.net hung without it, see Battle.net).
5. Battle.net: DXVK fixes its GPU path, but the login page still shows only the spinner,
   because CEF's **renderer process** hits a Chromium CHECK (int3 in libcef.dll) on every
   backend, wined3d included. That is a separate, non-graphics bug.
6. No Wine patch is needed for DXMT: our CrossOver 25.1 `winemac.drv/d3dmetal.c` already
   exports the `macdrv_functions` table DXMT's `winemetal.so` looks up.

## Build

```
brew install glslang                 # DXVK's shader compiler (meson, ninja, mingw-w64 were there)
scripts/build-dxvk.sh                # ~1 min 45 s (M4 Max), both arches -> runtimes/dxvk
git clone https://github.com/3Shain/dxmt.git upstream/dxmt && git -C upstream/dxmt checkout v0.80
git -C upstream/dxmt submodule update --init --recursive
git clone --depth 1 --branch llvmorg-15.0.7 https://github.com/llvm/llvm-project.git upstream/llvm-project-15.0.7
scripts/build-dxmt.sh                # LLVM 2 min 25 s (once) + DXMT 1 min 20 s -> runtimes/dxmt
```

### DXVK (`scripts/build-dxvk.sh`)

- Source: CrossOver's fork of 1.10.3 (`RELEASE` = 1.10.3), meson + ninja with its own
  `build-win32.txt` / `build-win64.txt` cross files (Homebrew mingw-w64, GCC 16.2), options as in
  its `package-release.sh` (release, `--strip`, no tests).
- Built from a copy in `build/dxvk/src` with `scripts/dxvk-patches/*.patch` applied:
  - `0001`, `0002`: mingw-w64 14 now declares `D3DDEVINFO_RESOURCEMANAGER` and the
    `ID3D10StateBlock` UUID itself (redefinition errors); plus `-include cstdint` (GCC 13+).
  - `0003`: **geometry shaders, cull distance and tessellation made optional** (d3d11 and d3d9).
    CrossOver's tree requires them unconditionally because CodeWeavers' own MoltenVK fork
    provides them; upstream MoltenVK 1.4.2 has no geometry shaders or cull distance, so the
    unpatched DLLs refuse every feature level ("Missing feature: geometryShader"). Same change
    as Gcenx's DXVK-macOS (`f8470ed7`), which only did it for d3d11 (its README says D3D10/11
    only); d3d9's meta ops do not need GS when `VK_EXT_shader_viewport_index_layer` exists,
    which MoltenVK has. A game that really uses a geometry shader fails at pipeline creation.
- Why not upstream DXVK or DXVK-macOS: CrossOver's tree builds with the fixes above and
  already carries CodeWeavers' MoltenVK workarounds (no direct image mapping, render-area
  trimming, `VK_DRIVER_ID_MOLTENVK` checks); DXVK-macOS 1.10.3-20230507 (cloned to
  `upstream/dxvk-macos` for comparison) still requires GS in d3d9. CrossOver's tree has **no
  async shader compilation** (`dxvk.enableAsync` is the dxvk-async patch DXVK-macOS ships).
- The DLLs are marked `winebuild --builtin` (ntdll ignores a non-builtin DLL found through
  WINEDLLPATH: "found in WINEDLLPATH but not a builtin, ignoring", ntdll/unix/virtual.c).
- `GIT_CEILING_DIRECTORIES` keeps DXVK's `git describe` version stamp from reading our own repo
  (it said "v0.6-...").
- `scripts/dxvk.conf` -> `runtimes/dxvk/dxvk.conf` (read via `DXVK_CONFIG_FILE`): async off
  (not available; anti-cheat caveat written there), `dxgi.numBackBuffers = 3` as CrossOver,
  state cache on.

### DXMT (`scripts/build-dxmt.sh`)

- `upstream/dxmt` at **v0.80 = commit 589adb780354b461645b29999cefaf533594ee99** (2026-04-23);
  its `LICENSE` is MIT (the script refuses to build if it is not, or if HEAD is not the tag).
- **LLVM 15 x86_64 was not a blocker.** DXMT's shader converter (airconv) links LLVM 15.0.7
  static libs into `winemetal.so`. Built exactly like DXMT's CI (no targets, no tools,
  assertions on) with Apple clang `-arch x86_64` from arm64 cmake/ninja (tablegen runs under
  Rosetta), plus `CMAKE_POLICY_VERSION_MINIMUM=3.5` for CMake 4, into
  `build/dxmt/llvm-15-x86_64` (224 MB, 2 min 25 s). No x86_64 Homebrew needed, and no
  GitHub Actions artifacts were used.
- Built from an APFS clone (`build/dxmt/src`, keeps `.git` so the version stamp says v0.80)
  with `scripts/dxmt-patches/*.patch`:
  - `0001`: Xcode 27's `metal` changed the `__metal_atomic_fetch_add_explicit` builtin's
    signature (`air_tessellation.metal`: "too few arguments"); use the public
    `atomic_fetch_add_explicit`.
  - `0002`: `#include <iomanip>` in `com_guid.cpp` (GCC 16).
  Upstream fixed both after v0.80 (commits 0606575, 75bd4da, which come after the licence
  change); our patches are our own one-liners.
- 64-bit: `meson setup --cross-file build-win64.txt -Dnative_llvm_path=... -Dwine_install_path=runtimes/winecx-full -Denable_nvapi=true -Denable_nvngx=true --buildtype release --strip`;
  32-bit: same with `build-win32.txt`, no LLVM, no nvapi/nvngx (as DXMT's CI). DLLs are
  builtins (`wine_builtin_dll=true` default). Wine headers, import libs and `winebuild` come
  from our own `runtimes/winecx-full` (DXMT's CI uses 3Shain's Wine 8.16).

### What Wine interface DXMT needs (answered: we have it)

`winemetal.so` (unix side, x86_64, also serves the 32-bit DLLs through WoW64 thunks) needs:
- `dlsym(RTLD_DEFAULT, "macdrv_functions")` with the layout `{init_display_devices,
  get_win_data, release_win_data, get_cocoa_window, create_metal_device,
  release_metal_device, view_create_metal_view, view_get_metal_layer,
  view_release_metal_view, on_main_thread, ...}` and `win_data->client_cocoa_view` at the 4th
  pointer. Our `dlls/winemac.drv/d3dmetal.c` (CrossOver 25.1, written for D3DMetal) exports
  exactly that table (`nm`: `_macdrv_functions` in `winemac.so`), so **no Wine patch**.
- `NtSetEvent` and the unix-call dispatcher from `ntdll.so` (exported). It links
  `@rpath/winemac.so` and `@rpath/ntdll.so`; dyld resolves them through
  `DYLD_FALLBACK_LIBRARY_PATH` = the runtime's `lib/wine/x86_64-unix`, which `Runtime.environment`
  already sets. `lsof` on a running test shows one copy each, from the runtime in use.
- ntdll loads `winemetal.so` from `<WINEDLLPATH entry>/x86_64-unix/` next to the PE DLL, so no
  extra DYLD path for DXMT itself.

## File layout

```
runtimes/dxvk/                                   22 MB
  x86_64-windows/{d3d9,d3d10core,d3d11,dxgi}.dll  (builtin-marked)
  i386-windows/{d3d9,d3d10core,d3d11,dxgi}.dll
  dxvk.conf  LICENSE (zlib)  VERSION
runtimes/dxmt/                                   51 MB
  x86_64-windows/{d3d10core,d3d11,dxgi,winemetal,nvapi64,nvngx}.dll
  i386-windows/{d3d10core,d3d11,dxgi,winemetal}.dll
  x86_64-unix/winemetal.so                       (30 MB, LLVM inside)
  dxmt.conf  LICENSE (MIT)  LICENSE.LLVM.txt  LICENSE.nvapi.txt  VERSION
```
Neither ships d3d10.dll / d3d10_1.dll (Wine's are used and call d3d10core/d3d11) or d3d12.dll
(D3DMetal only). SHA-256 of this build:

```
c5fc4935b8e80b3a3d15055f0a282f920d722f4610c5dbec6153102cbbc996b1  dxvk/i386-windows/d3d10core.dll
a12079f50b0fea53bdb5f3073abd1b631dfd3c11092e887a62f27270b255bab7  dxvk/i386-windows/d3d11.dll
5d42a683f6d37e1ebe8162946e9cf2b4ee129fbcd30582c55027cdac684250c6  dxvk/i386-windows/d3d9.dll
b9f1a0dd0a84307d9e75f57ab92eddff9d0b58d75f130b7e4b2548e84587a4e4  dxvk/i386-windows/dxgi.dll
4ab9df9318a93c88242277a1654c27e4fb5aecc7f27f6290e835ca672f105368  dxvk/x86_64-windows/d3d10core.dll
373b8f5af5e913355de8dfc29d456e5de2eaf4332b1fb692858d08008219ff89  dxvk/x86_64-windows/d3d11.dll
8c409f6945d0721f89abae237c868e8bd215c22d2d5681a8b87527be55a69689  dxvk/x86_64-windows/d3d9.dll
d991a4eab43fd4845a16a2234432f0eb61bf9266d990f60538fb84ec4f675d88  dxvk/x86_64-windows/dxgi.dll
9fea60f4965617797271db8438d8d1d6f67a0165efb3e29fa5f467161081d444  dxmt/i386-windows/d3d10core.dll
ea1de584de302d493397f845ebe6ec57a13fa93ea8de0f814f149a76a7ea3c60  dxmt/i386-windows/d3d11.dll
38a3fadb0528863547a90920eabffb611466a171a71c4f6756bbb3acb0bbca8d  dxmt/i386-windows/dxgi.dll
a3640859717312d8ff2d17efb391e2e273489b804202a6539ed4ee8831bebefe  dxmt/i386-windows/winemetal.dll
1ce2eb3c8a18e2d635acbc1ba15134a858d8d5098e9b675e1b560adfa3ff5d7a  dxmt/x86_64-unix/winemetal.so
b2cd2ac71c3928116456d47f7babb29d3e0552fb4f72c46183d5b43b4d1e1e05  dxmt/x86_64-windows/d3d10core.dll
816bd4f433e9865b80fc030ae63449f6ca4cc3735db467d71b0c54f1aaaa09d9  dxmt/x86_64-windows/d3d11.dll
2dc35a52ffd960c08076decb745e0c95ef6a451e36a30ab5eea55db35041d2bb  dxmt/x86_64-windows/dxgi.dll
8789c4551385229e87b2102b1fcfef2a18dda1e24426c9d1df7a2bc0d7500bba  dxmt/x86_64-windows/nvapi64.dll
a00832f834559f3eb39ff7457816ede9c8ce1666060fd9c901535d0536a82077  dxmt/x86_64-windows/nvngx.dll
3a495f9cf89f2cd62157cbdee5f7ad6bef4ba4f7385bb03c1bf004c3fa239712  dxmt/x86_64-windows/winemetal.dll
```
(Reproducible from the scripts but not bit-identical across rebuilds: PE link timestamps.)

## Runtime layout (needed before wiring)

ntdll searches its own `lib/wine` **before** every WINEDLLPATH entry (`set_dll_path`:
`dll_paths[0] = dll_dir`). That is why the build already moves Wine's x86_64
`d3d10*/d3d11/d3d12/dxgi` to `lib/wined3d/x86_64-windows`. For DXVK/DXMT the same must happen
for **`d3d9` (x86_64)** and for **all of them on i386**; otherwise 32-bit apps and d3d9 always
get Wine's DLLs whatever WINEDLLPATH says (`scripts/test-dxbackends.sh` warns about this).

- Build scripts: `git apply docs/proposed/build-winecx-wined3d-layout.patch` (touches only the
  moving-aside loop in `scripts/build-winecx.sh` and `scripts/build-winecx-full.sh`; checked
  with `git apply --check` on this branch). Not applied here because the Wine session owns
  those scripts.
- Existing runtime, no rebuild (what the tests used, on a `cp -Rc` clone):
  ```
  R=runtimes/winecx-full; mkdir -p $R/lib/wined3d/i386-windows
  mv $R/lib/wine/x86_64-windows/d3d9.dll $R/lib/wined3d/x86_64-windows/
  for d in d3d9 d3d10 d3d10_1 d3d10core d3d11 d3d12 dxgi; do mv $R/lib/wine/i386-windows/$d.dll $R/lib/wined3d/i386-windows/; done
  ```
- **Consequence for D3DMetal**: its WINEDLLPATH must then also list `lib/wined3d`
  (`runtimes/d3dmetal:<rt>/lib/wined3d:<rt>/lib/wine`), or 32-bit apps lose d3d9/d3d11 and
  64-bit apps lose d3d9. Verified: with that path, 32-bit `d3d11test32` on "d3dmetal" gets
  wined3d (FL 9_3) and d3d9 gets wined3d, exactly as today.
- The packaged app (`scripts/package-app.sh`) must carry `lib/wined3d/i386-windows` too.

## Environment recipe per backend

Start from what `Runtime.environment(for:)` sets today; only these change
(`<rt>` = the runtime home, e.g. `runtimes/winecx-full`):

| | WINEDLLPATH | extra | not set |
|---|---|---|---|
| d3dmetal | `runtimes/d3dmetal:<rt>/lib/wined3d:<rt>/lib/wine` | `CX_APPLEGPTK_LIBD3DSHARED_PATH` (as now) | |
| wined3d | `<rt>/lib/wined3d:<rt>/lib/wine` | | `CX_APPLEGPTK_LIBD3DSHARED_PATH` |
| dxvk | `runtimes/dxvk:<rt>/lib/wined3d:<rt>/lib/wine` | `DXVK_CONFIG_FILE=runtimes/dxvk/dxvk.conf`, `WINEDLLOVERRIDES` += `vulkan-1=b`; suggested `DXVK_STATE_CACHE_PATH=<bottle>/cache/dxvk`, `DXVK_LOG_PATH=none` or the bottle's log dir (default: logs and state cache next to the game's .exe) | `CX_APPLEGPTK_LIBD3DSHARED_PATH` |
| dxmt | `runtimes/dxmt:<rt>/lib/wined3d:<rt>/lib/wine` | optional: `DXMT_CONFIG_FILE` / `DXMT_CONFIG`, `DXMT_ENABLE_NVEXT=1`, `DXMT_METALFX_SPATIAL_SWAPCHAIN=1`, `DXMT_LOG_PATH` | `CX_APPLEGPTK_LIBD3DSHARED_PATH` |

`DYLD_FALLBACK_LIBRARY_PATH` stays as it is (`<rt>/lib`, d3dmetal's x86_64-unix,
`<rt>/lib/wine/x86_64-unix`, ...); DXMT needs exactly the `x86_64-unix` entry of the **same**
runtime it runs on (it is how `@rpath/ntdll.so` resolves). DXVK needs winecx-full (MoltenVK);
on plain winecx there is no Vulkan, so offer dxvk only for runtimes with
`lib/libMoltenVK.dylib`. DXMT works on either runtime (it only needs winemac.drv), but was
only tested on winecx-full.

**Prefix setup (DXMT)**: copy `runtimes/dxmt/x86_64-windows/winemetal.dll` to
`drive_c/windows/system32/` and `runtimes/dxmt/i386-windows/winemetal.dll` to
`drive_c/windows/syswow64/`. Reason: Wine only loads a builtin DLL whose file exists in the
prefix (`find_builtin_without_file` in ntdll/loader.c works during prefix bootstrap only);
d3d11/dxgi/d3d9 already have their files from wineboot, `winemetal.dll` is new
("Library winemetal.dll (which is needed by dxgi.dll) not found", c0000135). Because the file
is builtin-marked, Wine loads it from WINEDLLPATH, so it stays harmless for the other
backends. With `DXMT_ENABLE_NVEXT=1` also copy `nvapi64.dll` and `nvngx.dll` to `system32`
(DXMT points NGX at `C:\Windows\System32\nvngx.dll` in the registry). `wineboot -u` with the
DXMT dir in WINEDLLPATH would do the same, slower. `scripts/test-dxbackends.sh` does the copy.

### How to wire into CrossCore (for the session that owns `cli/`)

1. `Graphics` gets `dxvk` and `dxmt` (raw values = `WINECX_GRAPHICS`), with homes
   `runtimes/dxvk` / `runtimes/dxmt` next to `d3dmetalHome` (bundled app: next to D3DMetal in
   `SharedSupport/root/runtimes`).
2. `environment(for:)`: `WINEDLLPATH = [graphicsDir, home/lib/wined3d, dllDir]` for **all**
   four (wined3d: just the last two), the extras from the table, and
   `CX_APPLEGPTK_LIBD3DSHARED_PATH` only for d3dmetal. The reference implementation in shell is
   `backend_env` in `scripts/test-dxbackends.sh`.
3. Before launching with dxmt (or when a bottle is switched to it): the prefix setup above.
4. Only offer dxvk when the runtime has MoltenVK; d3dmetal stays the default for 64-bit
   DX11/12. Good uses: dxvk for DX9 and 32-bit DX10/11 (and per-game when D3DMetal misbehaves),
   dxmt as a per-game alternative for DX10/11 (32- and 64-bit) and for DLSS->MetalFX via
   NVEXT. DX12 stays D3DMetal (neither covers it; DXVK's dxgi has no D3D12 swap chain support).
5. The runtime layout change above has to land first (or the moves on the existing runtime).

## Test results

Programs: `src/d3dtest/d3d11test.exe` (64-bit, new optional 2nd argument = sync interval),
`src/d3dtest32/d3d11test32.exe` (same source, i686), `src/d3d9test/d3d9test.exe` (32-bit) and
`d3d9test64.exe`: adapter, feature level, clear (+ one triangle for d3d9) and Present.
`CROSS_BOTTLES=build/dxtest/bottles WINECX_HOME=<clone> scripts/test-dxbackends.sh dx`
(results: `build/dxtest/logs/matrix2.txt`). Mac: M4 Max, macOS 27.0.1, 120 Hz display.

| Test | D3DMetal 3.0 | wined3d | DXVK 1.10.3 | DXMT v0.80 |
|---|---|---|---|---|
| d3d11 64-bit, adapter | "AMD Compatibility Mode" 0x1002 | Apple M4 Max 0x106b | Apple M4 Max 0x106b (64 GB) | Apple M4 Max 0x106b (26 GB) |
| d3d11 64-bit, FL | 11_0 | 9_3 (Vulkan renderer, docs/runtime-full.md) | 11_0 | 11_0 (max 11_1) |
| d3d11 64-bit fps (vsync / sync 0) | 119.4 / 120.0 | 121.1 / 120.0 | 121.0 / 119.8 | 122.6 / 120.3 |
| d3d11 32-bit | n/a: falls back to wined3d (FL 9_3, 120.1 / 120.1) | FL 9_3, 122.1 / 120.1 | **FL 11_0**, 113.5 / 120.1 | **FL 11_0**, 123.3 / 116.2 |
| d3d9 32-bit | n/a (wined3d) | "GeForce 8800 GTX", 1967 / 3497 | **Apple M4 Max**, 119.2 / 119.8 | n/a (wined3d) |
| d3d9 64-bit | n/a (wined3d) | 2034 / 3718 | **Apple M4 Max**, 118.5 / 119.9 | n/a (wined3d) |

(fps = 120 frames with vsync / 1000 frames with sync interval 0, `build/dxtest/logs/matrix2.txt`;
an earlier run, `matrix1.txt`, is within ~10 fps.)

Reading the numbers: a clear-only test is **capped by the 120 Hz display on every backend**,
also with sync interval 0 (CAMetalLayer drawable pacing), so these fps say "presents every
refresh", not which backend is faster; a real game is the next benchmark. wined3d's d3d9
numbers above 120 fps mean its GL path does not wait for the display at all. Screenshots
(`build/dxtest/shots/`): DXVK d3d9 draws the RGB triangle on the animated green clear; DXVK and
DXMT d3d11 (32- and 64-bit) show the green clear.

DXMT extras checked: `DXMT_ENABLE_NVEXT=1` -> DXMT logs "Vendor extension enabled: NVEXT" and
the adapter reports vendor 0x10de (NVIDIA), as games expect before they look for DLSS (NGX
itself not exercised, no DLSS game was run). `DXMT_METALFX_SPATIAL_SWAPCHAIN=1` runs fine
(upscaling not measurable with a clear). HDR: DXMT's swap chain answers
`CheckColorSpaceSupport` from CoreGraphics and turns on EDR on the CAMetalLayer for
PQ/scRGB; `dxgi.forceSDR` turns it off. Not tested with an HDR game.

Not tested: D3D10 apps (Wine's d3d10.dll on DXVK/DXMT d3d10core), DXVK on plain winecx
(no Vulkan there), any real game (Portal 2 in `bottles/steamtest` left alone as asked).

### Battle.net (32-bit Qt + CEF 108)

Installed with `cross store install dx battlenet` (47 s). Default backend: "Battle.net Login"
with only the spinner, CEF log `eglInitialize: No available renderers` (ANGLE D3D11 on 32-bit
wined3d). With DXVK (`--run dx dxvk ".../Battle.net Launcher.exe"`):

1. **Hang** first: the main process froze at 0% CPU. Cause: Battle.net ships the Khronos
   loader `Battle.net.17952/vulkan-1.dll`; DXVK's d3d11/dxgi import `vulkan-1.dll`, Wine picks
   the app-dir copy, that loader enumerates adapters through `CreateDXGIFactory1` = DXVK's dxgi
   again -> ~204 nested DXVK instances -> stack overflow in the main thread while it holds the
   heap lock (`RtlpWaitForCriticalSection ... main process heap section`). Fix:
   `WINEDLLOVERRIDES=vulkan-1=b` (part of the dxvk recipe; correct for every app, Wine's
   vulkan-1 is the only loader that can reach MoltenVK).
2. Then the window opens, Qt and the CEF GPU process create D3D11 devices on DXVK (FL 11_0,
   MoltenVK), but ANGLE's swap chain fails: `SwapChain11 ... 0x80070057`,
   `eglCreateWindowSurface: EGL_BAD_ALLOC`, DXVK "Failed to create surface". The GPU process
   draws into a window owned by the browser process, and winemac.drv cannot give another
   process's window a Vulkan/Metal surface. `Battle.net.exe --from-launcher --in-process-gpu`
   (Battle.net passes Chromium switches through) removes that: no GPU process, no CEF errors,
   DXVK presents to the window.
3. Still the spinner: CEF's **renderer** process dies at start with a breakpoint
   (0x80000003, a Chromium CHECK, at the same offset in libcef.dll) on **wined3d too**, and
   with `--single-process` the same CHECK takes down the whole app (BlizzardError dialog,
   `AppData/Local/Battle.net/Errors/*Crash.txt`: 13 libcef.dll frames, no symbols). So the
   NOTES.md "needs DXVK" was half the story: DXVK (plus `vulkan-1=b` and `--in-process-gpu`)
   fixes the graphics side, the remaining blocker is a renderer-process CHECK under Wine.
   Next step (separate task): CEF 108.0.5359.125 symbols (Spotify's CEF symbol server, if
   Blizzard's build is stock) or `+relay` on the renderer to find which CHECK; then decide
   between a Wine fix and a launcher flag. Screenshots: `build/dxtest/shots/battlenet-*.png`.

## Blockers and caveats

- **Geometry shaders**: MoltenVK has none. DXVK now starts anyway (patch 0003) but games that
  use GS or transform feedback (`transformFeedback: 0` in the DXVK log) render wrong or fail.
  DXMT emulates GS/tessellation in Metal and is the better DX11 path for such games.
- MoltenVK warns "Metal does not support disabling primitive restart" on every DXVK run;
  harmless for the tests.
- DXVK's state cache and logs go next to the game's .exe unless `DXVK_STATE_CACHE_PATH` /
  `DXVK_LOG_PATH` are set (the Program Files folder of a game). DXMT caches in
  `$(getconf DARWIN_USER_CACHE_DIR)/dxmt/<exe>`.
- `wineboot -u` on a bottle would not remove `winemetal.dll`; nothing else is left behind in
  the bottle.
- Licences: DXVK zlib, DXMT MIT (v0.80; later releases are LGPL, the build script refuses
  them), LLVM Apache-2.0 with LLVM exception statically inside `winemetal.so` (ship its
  LICENSE.TXT), see docs/LICENSING.md.
- Not done (other sessions' code): CLI/app wiring, the build-script layout patch.
