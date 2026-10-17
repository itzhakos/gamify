# D3DMetal 3.0 on winecx (2026-10-16)

## Result

**D3DMetal 3.0 (GPTK 3.0, `runtimes/d3dmetal`) works on our unmodified winecx build
(CrossOver 25.1.0 Wine 10.0).** No Wine source change, no newer CrossOver sources and no
newer `winemac.drv/d3dmetal.c` are needed.

The crash was **not** a hook-table mismatch. It was the **file layout of
`runtimes/d3dmetal/x86_64-unix`**: there, `d3d10.so d3d11.so d3d12.so dxgi.so
nvngx-on-metalfx.so` are five full *copies* of `libd3dshared.dylib` (same md5
`7a660992...`). In GPTK (and in CrossOver's `lib64/apple_gptk`, and in our
`runtimes/d3dmetal-2.1`) they are *symlinks* to the one `libd3dshared.dylib`.

dyld de-duplicates images by real path, so with symlinks ntdll's `dlopen` of
`d3d11.so`, `dxgi.so`, ... and `CX_APPLEGPTK_LIBD3DSHARED_PATH` all return the **same**
image with one set of globals. With copies, every `.so` is a separate image with its own
globals. D3DMetal 3.0 relies on the shared globals:

- In 3.0 only `dxgi.dll` imports user32/kernelbase. It hands those Win32 function pointers to
  the unix side with unix call 1 (`Win32DispatchInit`, copies 0x158 bytes into the global
  `gWin32Dispatch`). `d3d11.dll` 3.0 no longer imports any user32/kernelbase function itself
  (2.1's d3d11.dll did, and called its own Win32DispatchInit).
- With copies, `gWin32Dispatch` is filled in `dxgi.so`'s copy only. `D3D11CreateDevice` runs
  `InitSharedState()` in `d3d11.so`'s copy, which calls `*(gWin32Dispatch+0x30)` = **NULL**
  (`libd3dshared` offset `0x2826`, return address `d3d11.so+0x282c`, found with a vectored
  exception handler + `vmmap`).
- The PE unwinder then walks into native code without PE unwind info and finds a garbage
  "handler" `0x0020019008070c10`: that is the "jump to a garbage address" seen before. The
  earlier `c0000005` "ignored in a user callback" is the same NULL call, earlier.
- In Steam the same thing shows up as steamwebhelper's GPU process crashing in a thread
  started by dxgi.dll.

### Fix (one-liner, not applied to `runtimes/d3dmetal`, which this task must not touch)

```bash
cd runtimes/d3dmetal/x86_64-unix && for n in d3d10 d3d11 d3d12 dxgi nvngx-on-metalfx atidxx64 nvapi64; do ln -sf libd3dshared.dylib $n.so; done
```

(GPTK also has `atidxx64.so`, `nvapi64.so`, `nvngx.so` -> libd3dshared; our copy has no
`atidxx64.so`/`nvapi64.so` although it has `atidxx64.dll`/`nvapi64.dll`.)

Until someone decides to fix `runtimes/d3dmetal` in place, a working symlinked layout is in
**`runtimes/winecx-d3dm3/d3dmetal`** (all symlinks into `runtimes/d3dmetal`, nothing copied):
`x86_64-windows/*.dll -> ../../../d3dmetal/x86_64-windows/*.dll`,
`x86_64-unix/libd3dshared.dylib -> ../../../d3dmetal/x86_64-unix/libd3dshared.dylib`,
`x86_64-unix/D3DMetal.framework -> ../../../d3dmetal/x86_64-unix/D3DMetal.framework`,
`x86_64-unix/{d3d10,d3d11,d3d12,dxgi,nvngx-on-metalfx,atidxx64,nvapi64}.so -> libd3dshared.dylib`.
Use it with `D3DMETAL_HOME=$PWD/runtimes/winecx-d3dm3/d3dmetal` (winecx-env.sh and bottle.sh
honour a caller's D3DMETAL_HOME). The mapped files resolve to `runtimes/d3dmetal/...` (checked
with `vmmap`/`lsof`: one libd3dshared image, D3DMetal.framework 3.0).

**Takeaway for the app/CLI:** when installing D3DMetal from the user's GPTK, copy with
symlinks preserved (`cp -R` / `ditto`, never `cp -L` or a per-file copy that dereferences),
or recreate the `.so -> libd3dshared.dylib` links ourselves.

## Measurements (winecx, macOS 27.0.1, M4 Max)

| Test | D3DMetal 2.1 | D3DMetal 3.0 (copies) | D3DMetal 3.0 (symlinks) |
|---|---|---|---|
| `src/d3dtest/d3d11test.exe` | AMD Compatibility Mode, FL 11_0, 117 fps | factory+adapter OK, crash in D3D11CreateDevice | AMD Compatibility Mode, FL 11_0 (0xb000), 120 frames 87.5 fps; 2000 frames 56.5 fps (vsync) |
| `src/d3dtest/d3d12test.exe` (new) | FL 12_2, SM 6.6, 300 frames 68 fps | - | FL 12_2 (0xc200), SM 6.6, 300 frames 60.4 fps |
| `WINEDEBUG=+seh` access violations | - | 2 (+ endless nested handler loop) | **0** |
| Order of the Sinking Star (DX12), GAME mode | mean 16.72 ms, stddev 1.76, max 85 ms | - | **mean 16.69 ms (~60 fps), stddev 1.53, max 35 ms** |

Game run: bottle `bottles/d3dm3-steam` (APFS clone of `bottles/cx` made right after its Steam
had shut down, so Steam's remembered login carried over: "Logged On" in 1 s, no sign-in
needed), `D3DMETAL_HOME=runtimes/winecx-d3dm3/d3dmetal scripts/bottle.sh steam d3dm3-steam`, then
`bottle.sh run d3dm3-steam .../steam.exe steam://rungameid/499170`. Game log: "Max D3D Feature
level _12_2, Max Shader Model _6_6, Agility SDK 618". `lsof` on sinking_star.exe:
`runtimes/d3dmetal/x86_64-windows/{d3d12,dxgi}.dll`, `runtimes/d3dmetal/x86_64-unix/libd3dshared.dylib`,
`D3DMetal.framework` 3.0 (+ libdxccontainer, libmetalirconverter, Rosetta AOT files), nothing
from 2.1 or `lib/wined3d`. Screenshot: `docs/d3dmetal3-sinking-star.jpg` (level renders
correctly at 3440x1440). First minute: mean 18.31 ms with one 5.4 s shader-compile stall,
same pattern as 2.1. Steam was shut down with `steam.exe -shutdown` afterwards.

Baseline: GPTK's own Wine 7.7 with the same 3.0 files (`bottles/test`):
d3d11test FL 11_0, 120 frames 68.8 fps. So 3.0 itself is fine on macOS 27.

## Step 1: the Wine-facing contract of D3DMetal (2.1 vs 3.0)

Everything Wine-facing goes through `libd3dshared.dylib` (and the 4 PE DLLs).
`D3DMetal.framework` talks only to libd3dshared, through versioned C++ interfaces
(`GFXTOSInterface`, `GFXT*Interface`, "Unsupported API: libd3dshared out of date"); its only
Wine touch is `getenv("WINEPREFIX")`. libd3dshared has **no** link-time Wine imports
(`llvm-nm -u`: only libSystem/libc++/objc/Foundation, plus CoreGraphics in 3.0); everything is
`dlsym(RTLD_DEFAULT, ...)` at run time.

| Interface | 2.1 | 3.0 | Provided by (CrossOver 25.1.0) |
|---|---|---|---|
| `dlsym(RTLD_DEFAULT, "macdrv_functions")` | yes | yes | winemac.so `DECLSPEC_EXPORT struct macdrv_functions_t macdrv_functions` (24 entries) |
| `dlsym(RTLD_DEFAULT, "os_sync_wait_on_address"/"..._wake_by_address_any/_all")` | no | yes (falls back to `SyncHelper_Old` = libc++ `std::atomic` wait/notify when absent) | libSystem, macOS 14.4+ |
| `/usr/lib/libRosetta.dylib` `rosetta_get_runtime_version` | yes | yes | macOS (gates `supports_non_native_code_regions`) |
| exports `__wine_unix_call_funcs` (2 entries: `D3DRMDispatch_Init`, `Win32DispatchInit`) | yes | yes | looked up by ntdll for `NtQueryVirtualMemory(MemoryWineUnixFuncs)` |
| exports `register_non_native_code_region`, `supports_non_native_code_regions` | yes | yes | called by ntdll, CW HACK 22434 (`CX_APPLEGPTK_LIBD3DSHARED_PATH`) |
| PE side: ntdll `__wine_unix_call` | `GetProcAddress` with `fallback__wine_unix_call` | **imported** | ntdll.spec, CW HACK 22435 |
| PE side: ntdll `NtQueryVirtualMemory(MemoryWineUnixFuncs)` | yes | yes | upstream Wine |
| PE side: kernel32 `wine_get_unix_file_name`, `wine_get_dos_file_name` | no | yes, via `GetModuleHandleA("KERNEL32")` + `GetProcAddress` through the PE-supplied dispatch table (`WinePaths`) | kernel32.spec (upstream Wine 10, PE export) |

So `wine_get_dos_file_name`/`wine_get_unix_file_name` are **not** unix-side lookups: they are
resolved as kernel32 PE exports, which Wine 10 still has. GPTK's Wine 7.7 has no unix export
of them either (checked every `.so` in GPTK).

### `macdrv_functions` layout

Used only by `WineSwapchainCallbacks` (`CreateSwapchainInterface` stores the table pointer;
`InitializeForHWND` calls it). Offsets called, identical in 2.1 and 3.0:

| Offset | Index | CrossOver 25.1.0 entry |
|---|---|---|
| 0x00 | 0 | `macdrv_init_display_devices(BOOL)` |
| 0x08 | 1 | `get_win_data(HWND)` |
| 0x10 | 2 | `release_win_data(data)` |
| 0x20 | 4 | `macdrv_create_metal_device(void)` |
| 0x30 | 6 | `macdrv_view_create_metal_view(view, device)` |
| 0x38 | 7 | `macdrv_view_get_metal_layer(metal_view)` |

Entries 3, 5, 8-23 (get_cocoa_window, release_metal_device, release_metal_view, OnMainThread,
the Reg*/user32 wrappers) are **not called by either version**: window/registry work goes
through Win32 function pointers supplied by the PE DLLs instead. GPTK 3.0's own Wine 7.7
`winemac.drv.so` exports a table of the same 24 slots (0x953c0..0x95478). **Table diff vs
CrossOver 25.1.0: none that matters.** The `d3dmetal_macdrv_win_data` struct (120 bytes,
fields read: `cocoa_view`/`client_cocoa_view` etc.) is likewise unchanged.

### Internal tables (Apple PE DLL <-> libd3dshared, both shipped together, not Wine's business)

| | 2.1 | 3.0 |
|---|---|---|
| `gGFXTDispatch` copied to PE by unix call 0 | 0x60 bytes (12 ptrs) | 0x160 bytes (44 ptrs) |
| `gWin32Dispatch` copied from PE by unix call 1 | 0x88 bytes (17 ptrs) | 0x158 bytes (43 ptrs) |
| which PE DLLs import user32/kernelbase | d3d11, d3d12, dxgi | dxgi only |
| new interfaces | - | WineAdapters, WinePaths, WineAllocations, WineLibraries, WineEventCallbacks2_0, SyncHelper |

The PE side calls the GFXT pointers *directly* (no syscall transition) and the unix side calls
the Win32 pointers directly; both versions do this, it works on CrossOver's Wine 10 because
on macOS the TEB is reachable through `%gs` from native code too.

## Step 2: sources (checked, nothing downloaded: not needed)

- `media.codeweavers.com/pub/crossover/source/`: newer than 25.1.0 exist:
  `crossover-sources-25.1.1` (2025-09-15), `26.0.0` (2026-02-10), `26.1.0` (2026-04-09),
  `26.2.0` (2026-06-09), **`26.3.0` (2026-07-21, newest found)**; 26.0.1/26.1.1/26.2.1/26.3.1/
  26.4.0/27.0.0 are 404. Useful for other work (e.g. a later D3DMetal), not for 3.0.
- `apple/homebrew-apple` formula `game-porting-toolkit` is the old GPTK 1.1 recipe
  (`crossover-sources-22.1.1.tar.gz`); GPTK 3.0's Wine (Gcenx cask) is 7.7-based and its
  winemac table has the same 24 slots, so it would not have shown anything new either.

## Step 3: not needed

No port, no `build/x86_64-d3dm3` build: the stock `runtimes/winecx` (used read-only) runs
3.0. `runtimes/winecx-d3dm3/` only holds the symlinked D3DMetal layout above.

## Artifacts

- `runtimes/winecx-d3dm3/d3dmetal/` - symlinked 3.0 layout (safe to delete once
  `runtimes/d3dmetal` is fixed in place).
- `src/d3dtest/d3d12test.c` (+ Makefile target, `make -C src/d3dtest`): D3D12 device, queue,
  flip-model swap chain, RTV clear + present with a fence per frame; prints adapter, max FL
  and shader model.
- `bottles/d3dm3` (fresh winecx prefix for the d3dtests), `bottles/d3dm3-steam` (APFS clone of
  cx with Steam logged in; shares blocks with cx, delete with `rm -rf` when done).
- `docs/d3dmetal3-sinking-star.jpg`.

## Follow-ups (not done here: outside this task's write scope)

- Replace the copies in `runtimes/d3dmetal/x86_64-unix` with symlinks (command above), then
  make 3.0 the default in `scripts/winecx-env.sh` and `cli` (`Runtime.swift` points at
  `runtimes/d3dmetal-2.1`), and correct the "hook-table mismatch" statements in NOTES.md.
- The Steam webhelper GPU-process crash under 3.0 should be gone too (same cause); not
  re-checked with Valve's unshimmed webhelper.
