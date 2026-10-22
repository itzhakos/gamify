# runtimes/winecx-full: winecx + GStreamer, SDL2, MoltenVK (2026-10-16)

Same CrossOver-lineage Wine 10.0 as `runtimes/winecx` (crossover-sources-25.1.0, x86_64 under
Rosetta, `clang -arch x86_64`, mingw-w64 PE side, new-style WoW64), built **with** gstreamer,
SDL2 and Vulkan instead of `--without-gstreamer --without-sdl --without-vulkan`.
`runtimes/winecx` was not touched.

## How to build / use

```
scripts/build-winecx-full-deps.sh   # deps -> runtimes/winecx-full   (~5.5 min of build steps)
scripts/build-winecx-full.sh        # Wine  -> runtimes/winecx-full  (3 min 28 s make + 1.5 min install)
scripts/bottle.sh create <name> winecx-full     # .runtime = winecx-full
WINECX_HOME=$PWD/runtimes/winecx-full . scripts/winecx-env.sh   # by hand
```

- `scripts/winecx-env.sh` now honours `WINECX_HOME` from the caller (default unchanged:
  `runtimes/winecx`). When `$WINECX_HOME/lib/gstreamer-1.0` exists it also exports
  `GST_PLUGIN_SYSTEM_PATH_1_0` and `GST_PLUGIN_SCANNER_1_0` (paths are compiled in absolute,
  this keeps the tree movable). For plain winecx the output is byte-identical to before.
- `scripts/bottle.sh`: runtime `winecx-full` (same branch as `winecx`, with
  `WINECX_HOME=runtimes/<runtime>` set explicitly, so a stray caller `WINECX_HOME` can't switch
  a winecx bottle).
- NOT done: `cli/` (`cross`, `CrossCore/Runtime.swift`) only knows `runtimes/winecx`; it needs a
  `winecx-full` runtime (other home + the two GST variables) to use this runtime.
- Build dirs: `build/x86_64-full/<dep>`, `build/x86_64-full/wine` (3.1 GB), logs
  `build/x86_64-full/*.log`, step times `build/x86_64-full/times.log`.

## Dependencies (all x86_64 Mach-O dylibs, checked with `file`)

| Component | Version | Source | Build |
|---|---|---|---|
| gmp | 6.3 | CrossOver tarball | autotools, same flags as winecx |
| nettle / gnutls / freetype | 4.0 / 3.8.13 / 2.15.0 | `brew fetch -s` (as winecx) | same flags as winecx |
| libffi | 3.8.0 | `brew fetch -s libffi` | autotools `--disable-docs` |
| pcre2 | 10.49 | `brew fetch -s pcre2` | 8-bit only, no JIT (like CrossOver's libpcre2-8) |
| glib (+gobject/gmodule/gio/gthread) | **2.78.0** | CrossOver tarball | meson, see notes |
| proxy-libintl | 0.4 | glib's meson wrap (GitHub tag) | installs `libintl.8.dylib` (CrossOver ships one too) |
| gvdb | commit 0854af0f | glib's meson wrap (gitlab.gnome.org) | static, inside gio |
| libogg / libvorbis / libtheora | 1.3.6 / 1.3.7 / 1.2.0 | `brew fetch -s` | autotools |
| GStreamer core + base/good/bad/ugly | **1.24.2** | CrossOver tarball (monorepo subprojects) | meson, one project each, `--wrap-mode=nodownload` |
| SDL2 | 2.32.10 | GitHub release, sha256 = the one Homebrew recorded (`5f5993c5...`) | CMake `-DCMAKE_OSX_ARCHITECTURES=x86_64` |
| MoltenVK | **1.4.2** | `brew fetch -s molten-vk` + its `fetchDependencies` (pinned commits) | Xcode universal -> `lipo -thin x86_64` |
| FFmpeg (avutil/avcodec/avformat/avfilter) | **6.1.6**, LGPL 2.1+ | `brew fetch -s ffmpeg@6` | own configure, `--disable-everything`, Windows Media decoders only (see below) |
| gst-libav | 1.24.2 | CrossOver tarball (monorepo) | meson, `--wrap-mode=nodownload` |

Host tools from arm64 Homebrew: meson 1.12.1, ninja, cmake (installed for this), python 3.14,
pkg-config, bison, nasm 3.02 (FFmpeg's x86 SIMD; it emits macho64 objects); meson uses a cross file (`build/x86_64-full/x86_64-darwin.ini`, host
x86_64-darwin, `needs_exe_wrapper = false` because Rosetta runs the test binaries).
All dylibs get absolute install names in `runtimes/winecx-full/lib` (MoltenVK via
`install_name_tool -id` + ad-hoc re-sign).

GStreamer plugin set (38 plugins in `lib/gstreamer-1.0`, 6.1 MB) = everything CrossOver 25.1
ships in `lib64/gstreamer-1.0` (applemedia, asf, audioconvert, audioparsers, audioresample,
avi, coreelements, deinterlace, id3demux, isomp4, opengl, playback, typefindfunctions,
videoconvertscale, videofilter, videoparsersbad, wavparse) plus app, apetag, audiorate,
audiotestsrc, autodetect, coretracers, flv, gio, matroska, mpegtsdemux, ogg, osxaudio, pbtypes,
rawparse, subparse, theora, videorate, videotestsrc, volume, vorbis, and **libav** (gst-libav, added
2026-10-17 for WMV/WMA, see "Windows Media decoders" below). `applemedia` gives
`vtdec`/`vtdec_hw` (VideoToolbox H.264/HEVC) and `atdec` (AudioToolbox AAC/MP3); it needs
gst-plugins-base's GL lib (`-Dgl=enabled -Dgl_api=opengl -Dgl_platform=cgl -Dgl_winsys=cocoa`).
Tools `gst-inspect-1.0` / `gst-launch-1.0` are installed in `bin/`.

### Problems hit (and the fix in the script)
- **glib 2.78.0 from the tarball has an empty `subprojects/gvdb`** (git submodule) -> meson
  refuses it. Built from an APFS clone (`build/x86_64-full/glib-src`, `upstream/` stays
  pristine) with the empty dir removed, so meson fetches the gvdb + proxy-libintl wraps there.
- **glib 2.78.0's gdbus-codegen imports `distutils`** (gone since Python 3.12): the script
  patches `utils.py` in the clone to compare versions as int tuples (what later glib does).
- **CrossOver's MoltenVK (1.2.10 + CodeWeavers changes) can't be built from the tarball**: its
  `MoltenVKShaderConverter` calls `needs_xfb_buffer()`, `needs_texture_offset_buffer()`,
  `can_compile_with_fast_math()` from CodeWeavers' SPIRV-Cross fork (pinned commit
  `d52dc12d`). The tarball's `External/SPIRV-Cross` is plain Khronos and lacks them, and the
  commit is in neither KhronosGroup/SPIRV-Cross nor cdavis5e/SPIRV-Cross (not public). So we
  use upstream MoltenVK 1.4.2. (Also: Xcode 27 rejects MoltenVK 1.2.10's
  `MACOSX_DEPLOYMENT_TARGET = 10.15`; the script bumps any 10.15 to 12.0 in the copied projects,
  a no-op for 1.4.2.) xcodebuild treats env vars as build settings, so MoltenVK runs with
  `CC/CXX/CFLAGS/...` unset.
- Homebrew's `sdl2` formula is now **sdl2-compat** (needs SDL3), hence the direct GitHub
  download of real SDL2 2.32.10.
- libvorbis: drop `-force_cpusubtype_ALL` from configure (same as Homebrew).

### Windows Media decoders: FFmpeg + gst-libav (2026-10-17)
Games with `.wmv` intro videos (Worms W.M.D: WMV3 video + WMA Pro audio) stayed black: our
GStreamer has `asfdemux` but no decoder for WMV/VC-1/WMA, and CrossOver 25.1 ships none either
(winegstreamer logged `Missing decoder: Windows Media Video 9 (video/x-wmv, wmvversion=3, WMV3)`).
Section 6 of `scripts/build-winecx-full-deps.sh` adds:
- **FFmpeg 6.1.6** (the series GStreamer 1.24 pins in `subprojects/FFmpeg.wrap`), configured
  with `--disable-everything --disable-autodetect` and only the decoders
  `wmv1 wmv2 wmv3 wmv3image vc1 vc1image msmpeg4v1/v2/v3 wmav1 wmav2 wmapro wmavoice wmalossless`
  + the `vc1` parser; no programs, avdevice, swscale, swresample, postproc or network. No
  `--enable-gpl`/`--enable-nonfree`; the script aborts unless configure reports
  `License: LGPL version 2.1 or later`. Links only libSystem + CoreFoundation/CoreVideo/CoreMedia.
  libavcodec 2.2 MB, avutil 0.8 MB, avformat 0.2 MB, avfilter 0.1 MB.
- **gst-libav 1.24.2** (`lib/gstreamer-1.0/libgstlibav.dylib`, 0.3 MB, plugin license LGPL):
  `avdec_wmv1/2/3`, `avdec_vc1`, `avdec_wmav1/2`, `avdec_wmapro`, `avdec_wmavoice`,
  `avdec_wmalossless`, `avdec_msmpeg4*` (+ `avdec_h263`, pulled in by msmpeg4).
- winegstreamer builds `decodebin` pipelines for quartz (DirectShow), mfplat (Media Foundation),
  wmvcore and the WMV/WMA DMOs, so the new decoders are used without any Wine change.
- **winedmo (Wine `--with-ffmpeg`) is no alternative in Wine 10.0**: `dlls/winedmo` is only a
  demuxer (libavformat) behind `mfsrcsnk`'s byte stream handlers, and even those default to the
  GStreamer handler (`use_gst_byte_stream_handler()`, opt-out
  `HKCU\Software\Wine\MediaFoundation\DisableGstByteStreamHandler`). Every decoder is still a
  winegstreamer `wg_transform`, i.e. GStreamer. Note: since libav*.pc are now in the prefix, a
  Wine reconfigure of winecx-full will detect FFmpeg and build `winedmo.so` against our libs;
  harmless (no demuxers are built, `winedmo_demuxer_check` fails, GStreamer is used anyway).
- Build time: FFmpeg 16 s, gst-libav 3 s.

## Wine configure (from scripts/build-winecx-full.sh)
Identical to `scripts/build-winecx.sh` except prefix/build dir and
`--with-gstreamer --with-sdl --with-vulkan` instead of the three `--without-*` (the script
aborts if configure prints "GStreamer/SDL2/Vulkan won't be supported"). Result in config.h:
`SONAME_LIBVULKAN "libMoltenVK.dylib"`, `SONAME_LIBSDL2 "libSDL2-2.0.0.dylib"`,
`HAVE_SDL_H`; `GSTREAMER_LIBS` links gstvideo/audio/tag/base/gstreamer/gobject/glib/intl.
Same post-install steps (`bin/wineloader -> wine`, d3d10*/d3d11/d3d12/dxgi moved to
`lib/wined3d/x86_64-windows`, generated `distversion.h`).

## i386 PE side built with SSE float math (both runtimes, 2026-10-17)
Both `scripts/build-winecx.sh` and `scripts/build-winecx-full.sh` now pass
`i386_CFLAGS="-g -O2 -msse2 -mfpmath=sse"`. Before, the i386 DLLs used mingw gcc's default
(`-g -O2` = x87 float math), which Rosetta 2 emulates slowly; the 32-bit DirectSound mixer
alone ate a core in Portal 2 (docs/portal2-audio.md). x86_64 is SSE by ABI and stays default
(`x86_64_CFLAGS` unset). No `i386_LDFLAGS` or per-DLL flags are needed: Wine links its PE DLLs
without the mingw CRT, and its i386 flags already include `-mpreferred-stack-boundary=2`, so gcc
realigns the stack itself where SSE needs 16 bytes.

The scripts also apply `src/patches/*.patch` to the CrossOver tree before configure (idempotent:
a patch that already reverses cleanly is skipped), so our own fixes, currently
`winemac-qt5-opengl.patch` (docs/worms-opengl.md) and since 2026-10-22 the three CrossOver 26.1
ports (section "Ported from CrossOver 26.1" below), are part of every build.
`src/patches/crossover-25.1.0-over-wine-10.0.diff` is reference only and never applied.
`WINECX_PREFIX` / `WINECX_BUILD` build a second copy next to the live runtime; the prefix must
already hold the deps (clone the live runtime with `cp -Rc`; the deps' install names then
point to the final location).

x87 / scalar-SSE instruction counts (objdump mnemonics; the residual x87 is the i386 ABI's
float return in st(0), `long double` and musl's x87 asm in the CRTs):

| i386 DLL | x87 build: x87 / SSE | SSE build: x87 / SSE | CrossOver 25.1: x87 / SSE |
|---|---|---|---|
| dsound.dll | 1761 / 0 | 61 / 1417 | 54 / 1438 |
| wined3d.dll | 6707 / 0 | 134 / 4152 | 47 / 3579 |
| ucrtbase.dll | 7051 / 1 | 750 / 5400 | 697 / 5375 |
| msvcrt.dll | 3745 / 1 | 396 / 2767 | 391 / 2788 |
| ntdll.dll | 1224 / 0 | 99 / 897 | 95 / 902 |
| xaudio2_7.dll | 1581 / 0 | 92 / 1498 | 76 / 1551 |
| user32.dll / gdi32.dll | 785 / 677 x87 | 78 / 2 x87 | 20 / 2 x87 |
| x86_64 dsound / wined3d | 0 / 989, 0 / 3223 | identical | — |

CrossOver's i386 DLLs (GCC 13.2) also use SSE3/SSSE3 (`fisttpll`, `movddup`, `pshufb`
across many DLLs, no SSE4.1), i.e. something like `-march=core2`. The remaining gap (e.g. 13
`fnstcw/fldcw` + `fistpll` pairs in wined3d for float->int64) would close with `-msse3`
(`fisttp`); not done, the SSE2 build is the one the user tested.

`src/dsbench` (32-bit DirectSound, 10 s, process CPU; scratch prefixes, same machine, 18:15):

| case | x87 runtime | SSE runtime | hand-built SSE dsound (`scripts/dsound-sse.sh`) |
|---|---|---|---|
| 1 buffer @ 44100 Hz (resampled) | 53.5% | 5.5–5.8% | 5.8–6.0% |
| 4 buffers @ 44100 Hz | 100.4% (saturated) | 16.5% | 16.6% |
| 1 buffer @ 48000 Hz (no resampling) | 4.3% | 2.2% | — |

(Same in winecx: 54.9% -> 5.8%. Absolute numbers are higher than the 1.5% in
docs/portal2-audio.md, measured under different load; the runtime build and the hand-built DLL
are identical in every case.) In bottle `steamtest` after the swap: 4.0%.

Build: both trees built from scratch into `runtimes/winecx-sse` / `winecx-full-sse`
(`build/x86_64-sse`, `build/x86_64-full-sse`). winecx: make 92 min 53 s + install 6 min 48 s
under `taskpolicy -b` (E-cores + throttled I/O, so a running Portal 2 test was not disturbed;
not recommended otherwise). winecx-full: configure 81 s, make ~30 min under `taskpolicy -b`,
then resumed at normal priority: 2 min 35 s, install 1 min 24 s. At normal priority a full
build is the ~3.5 min above.

Swap (2026-10-17, runtimes idle, Steam in steamtest shut down with the user's OK):
`rsync -a --ignore-existing <old>/ <new>/` first (carries files added to the live runtime after
the clone: FFmpeg + gst-libav in winecx-full), then `winecx -> winecx-x87`,
`winecx-sse -> winecx`, same for `-full`. No path of the build prefix is embedded in the
installed tree (`grep -rl winecx-sse` empty; unix .so use `@rpath`). Checked: `cross cmd
steamtest /c ver` and a fresh winecx bottle: Windows 10.0.19043. Bottle steamtest: the
hand-installed `syswow64/dsound.dll`, its `.wine-x87.bak` and `DllOverrides "dsound"` removed,
`wineboot --update` reinstalled the runtime's DLL (byte-identical to
`lib/wine/i386-windows/dsound.dll`, 61 x87 ops). Shipped in Gamify 0.3. The user confirmed
Portal 2 audio clean and Worms working; `runtimes/winecx-x87` / `winecx-full-x87` deleted.

## Ported from CrossOver 26.1: rebuild and swap (both runtimes, 2026-10-22)
**Swapped in on 2026-10-22 (main session):** `winecx-next` -> `winecx`, `winecx-full-next` ->
`winecx-full`; the previous trees are `winecx-old` / `winecx-full-old`; `build/x86_64-next` and
`build/x86_64-full-next` were deleted (regenerable). Re-verified through the real project root.

Three new `src/patches` (HAGS for D3DMetal, XGETBV emulation, Game Mode plist keys; details in
docs/codeweavers-patches.md "Ported from CrossOver 26.1"). Built side by side, the live
runtimes untouched:

```
cp -Rc runtimes/winecx runtimes/winecx-next              # APFS clone: deps + old Wine
cp -Rc runtimes/winecx-full runtimes/winecx-full-next
WINECX_PREFIX=$PWD/runtimes/winecx-next WINECX_BUILD=$PWD/build/x86_64-next \
  sh -c 'scripts/build-winecx-deps.sh && scripts/build-winecx.sh'
WINECX_PREFIX=$PWD/runtimes/winecx-full-next WINECX_BUILD=$PWD/build/x86_64-full-next \
  sh -c 'scripts/build-winecx-full-deps.sh && scripts/build-winecx-full.sh'
```

- Both deps scripts now honour `WINECX_PREFIX` / `WINECX_BUILD` like the Wine scripts. Every
  dep is skipped when its dylib is already in the prefix, so on the clone they did nothing
  (the deps keep their install names under `runtimes/winecx*/lib`, i.e. the final location
  after the swap). Everything else (configure flags, i386 SSE flags, post-install steps) is
  unchanged.
- The patches are applied **in place** to `upstream/crossover-sources-25.1.0/sources/wine`
  (as every `src/patches/*.patch`), so that tree now carries them. To build without them:
  `patch -p1 -R -d upstream/crossover-sources-25.1.0/sources/wine < src/patches/<name>.patch`.
- Times (M4 Max, another session building in parallel, load ~100): winecx configure 28 s,
  make 4 min 28 s, install 2 min 38 s; winecx-full configure 38 s, make 3 min 56 s, install
  1 min 54 s. Sizes: 1.5 GB per runtime, 3.1 GB per build dir.
- Checks on the installed trees: `otool -s __TEXT __info_plist bin/wine` contains the three
  Game Mode keys (live runtime: none); `ntdll.so` has `emulate_xgetbv`, `win32u.so` reads
  `WINECX_GRAPHICS`, `CX_ACTIVE_GRAPHICS_BACKEND`, `WINE_DISABLE_HARDWARE_SCHEDULING`;
  `grep -rl winecx-next` / `winecx-full-next`: nothing, so the trees can be renamed. (The
  build ran from this branch's worktree, whose `upstream` is a symlink to the main checkout's,
  so 327 widl-generated headers under `include/wine` name the worktree in their "generated
  from" comment; the live runtime has the same 327 with the main checkout's path. Comments
  only.)

### Verification (scratch bottles `old` on the live winecx, `new` on winecx-next, `newfull` on winecx-full-next; D3DMetal 3.0)
Bottles created with `cross bottle create --storage unlimited` under `CROSS_BOTTLES=<scratch>`;
the new runtimes reached through `CROSS_ROOT=<scratch root>` whose `runtimes/winecx` and
`runtimes/winecx-full` are symlinks to the `-next` trees.

`src/hagstest/hagstest.exe` (gdi32 `D3DKMTEnumAdapters2` -> `D3DKMTQueryAdapterInfo`):

| Runtime, environment | DRIVERVERSION | CHECKDRIVERUPDATESTATUS | WDDM_2_7_CAPS |
|---|---|---|---|
| winecx (live), d3dmetal or wined3d | `0xc0000002` | `0xc0000002` | `0xc0000002` (STATUS_NOT_IMPLEMENTED) |
| winecx-next, `WINECX_GRAPHICS=d3dmetal` (default) | 1300 | 0 | HwSchSupported=1 HwSchEnabled=1 HwSchEnabledByDefault=1 |
| winecx-next, + `WINE_DISABLE_HARDWARE_SCHEDULING=1` | 1300 | 0 | status 0, all three 0 |
| winecx-next, `WINECX_GRAPHICS=wined3d` | 1300 | 0 | `0xc0000002` |
| winecx-next, wined3d + `CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal` | 1300 | 0 | 1 / 1 / 1 |
| winecx-full-next, d3dmetal (and with the opt-out) | 1300 | 0 | 1 / 1 / 1 (0 / 0 / 0) |

Adapter: one, handle 0x1, LUID `00000000:000003f4`, on both runtimes (also on winecx, which has
no Vulkan).

`src/avxtest/avxtest.exe` (identical on winecx, winecx-next and winecx-full-next):

| Environment | cpuid 1 ecx | cpuid 7 ebx | xgetbv(0) | 256-bit `vaddps` |
|---|---|---|---|---|
| default | `0298220f` (no XSAVE/OSXSAVE/AVX) | `0` | not executed (no OSXSAVE); with `force`: `0x7`, no fault | — |
| `ROSETTA_ADVERTISE_AVX=1` | `7ed8320f` (XSAVE, OSXSAVE, AVX) | `0x128` (AVX2, no AVX-512) | `0x7` | 16 (works) |

So on macOS 27 Rosetta executes `XGETBV` itself, also on the old runtime; nothing crashes and
the emulation is never entered (`WINEDEBUG=+seh` shows no "emulated an XGETBV instruction").
A native x86_64 macOS probe gives the same values. The patch only matters on older macOS.

Other checks on winecx-next and winecx-full-next: `cross cmd <bottle> /c ver` = Microsoft
Windows 10.0.19043; notepad opens ("Untitled - Notepad", 1360x1024, on screen);
`src/d3dtest/d3d11test.exe`: AMD Compatibility Mode, FL 11_0, 120 frames (57.5 fps on
winecx-next with the parallel build running, 118.5 fps on winecx-full-next);
`d3d12test.exe`: D3D12CreateDevice ok, FL 12_2, SM 6.6, 120 frames (68.1 / 119.3 fps).
winecx-full-next also initialises MoltenVK as before.

**Game Mode: not reachable this way.** `d3d11test.exe 720 fullscreen` (new option:
borderless screen-sized window + `SetFullscreenState(TRUE)`, both calls `S_OK`) puts a
3440x1440 window on screen (layer 3) at 60 fps. But LaunchServices registers every Wine
process, old and new runtime alike, as name `"wine"`, bundleID NULL (`lsappinfo info`), type
`BackgroundOnly` until winemac turns it into `Foreground`. If the embedded `__info_plist` were
read, the name would be its `CFBundleName` ("CrossOver-Hosted Application") and `LSUIElement`
would make it a UIElement. So macOS ignores the loader's embedded plist, the Game Mode keys
included. gamepolicyd logs `Ignoring <private>` for the process (`log stream --predicate
'process == "gamepolicyd"'`). The process could not be made frontmost from a script
(`NSRunningApplication.activate` returned true, `isActive` stayed false) and no screenshot of
the menu bar was taken, so this is evidence, not a check of the Game Mode indicator. Making
it work probably needs the loader inside a real `.app` bundle (`Contents/Info.plist` with
these keys + `Contents/MacOS/wine`); not tried. The patch is harmless and kept for that.

### Swap (for the main session; runtimes must be idle)
1. Stop everything that uses the runtimes: `pgrep -fl 'runtimes/winecx'` must be empty (quit
   Steam etc. in the bottles, `cross kill <bottle>`).
2. Carry over anything added to the live runtimes after the clone (21:10 on 2026-10-22;
   normally nothing): `rsync -a --ignore-existing runtimes/winecx/ runtimes/winecx-next/` and
   `rsync -a --ignore-existing runtimes/winecx-full/ runtimes/winecx-full-next/`.
3. `mv runtimes/winecx runtimes/winecx-prev && mv runtimes/winecx-next runtimes/winecx`, then
   `mv runtimes/winecx-full runtimes/winecx-full-prev && mv runtimes/winecx-full-next runtimes/winecx-full`.
4. Check: `cross cmd <a winecx bottle> /c ver`, `cross run <bottle> src/hagstest/hagstest.exe`
   (expect `HwSchEnabled=1`, exit 0), the same in a winecx-full bottle. Existing bottles need no
   `wineboot --update`: only unix-side files (`ntdll.so`, `win32u.so`) and `bin/wine` changed.
5. Rollback = the two `mv`s in reverse. After the user has run games on it: delete
   `runtimes/winecx-prev`, `runtimes/winecx-full-prev`, and `build/x86_64-next`,
   `build/x86_64-full-next` (3.1 GB each; their Makefiles point at the `-next` prefixes and this
   worktree's source path, so they are not reusable for incremental builds after the swap).

## Sizes
- `runtimes/winecx-full`: 1.5 GB (winecx: 1.4 GB). 114 dylibs in `lib/`, 31 unix `.so`
  (winecx: 30, the extra one is `winegstreamer.so`), 983 x86_64 + 1049 i386 PE files
  (+ `winegstreamer.dll`). MoltenVK 5.4 MB, SDL2 1.7 MB, gio 2.0 MB, glib 1.4 MB, plugins 5.8 MB
  (6.1 MB with gst-libav), FFmpeg libs 3.3 MB (2026-10-17).
- `build/x86_64-full`: 3.8 GB (wine 3.1 GB, MoltenVK tree 479 MB).

## Build times (M4 Max, `make -j16` / ninja)
Deps, per `times.log`: gmp 24 s, nettle 12 s, gnutls 89 s, freetype 6 s, libffi 8 s, pcre2 9 s,
glib 13 s (resumed run; the first, failed attempts add ~1 min), ogg/vorbis/theora 24 s,
gstreamer core 10 s, base 12 s, good 6 s, bad 11 s, ugly 4 s, SDL2 22 s, MoltenVK 83 s
(incl. cloning its deps) = **~5.5 min**. Wine: configure 19 s, **make 3 min 28 s**, install 1.5 min.

## Verification (bottle `bottles/full`, runtime winecx-full, D3DMetal 2.1 default)
- `bin/wine --version` = `wine-10.0`. All 31 unix `.so`, 37 plugins and every new dylib are
  `Mach-O 64-bit ... x86_64`.
- `scripts/bottle.sh create full winecx-full`: wineboot 22 s. MoltenVK already initialises
  during wineboot (`[mvk-info] MoltenVK version 1.4.2, supporting Vulkan version 1.4.357`).
- `cmd /c ver` = Microsoft Windows 10.0.19043, user `crossover`, AMD64.
- winecfg opens; Graphics tab and Audio tab render (Audio: `winecoreaudio.drv`, lists the
  Mac's CoreAudio devices). Tabs switched with PSM_SETCURSEL from a helper exe in the same
  bottle, captured with `screencapture -l` (`build/x86_64-full/winecfg-tab{2,5}.png`).
- notepad opens with a proper window (`build/x86_64-full/notepad.png`).
- **Steam** (cloned from `bottles/steam11` with `cp -Rc`, launched with `scripts/bottle.sh steam
  full`, i.e. the webhelper shim + `-noverifyfiles -no-cef-sandbox`): "Sign in to Steam"
  window after 15 s; `steam.exe -shutdown` exits cleanly in 6 s. (Another Steam was running on
  winecx in bottle `cx` at the same time; no interference.)
- **Vulkan** (`src/vktest/vktest.exe`, vulkan-1.dll -> winevulkan -> MoltenVK): instance
  1.4.0, 1 device "Apple M4 Max" (vendor 0x106b), vkCreateDevice OK.
- **Video / winegstreamer**:
  - `src/mftest/mftest.exe` (Media Foundation source reader, H.264 + AAC 640x360 5 s mp4,
    made with ffmpeg in `build/x86_64-full/media/`): **150/150 frames to NV12 and all 235
    audio buffers to PCM**. Elements created (from `GST_DEBUG=GST_ELEMENT_FACTORY:4`):
    decodebin, typefind, qtdemux, multiqueue, h264parse, **vtdec_hw**, videoconvert,
    deinterlace, videoflip, aacparse, **atdec**, audioconvert. (Asking for RGB32 directly gives
    MF_E_TOPO_CODEC_NOT_FOUND, as on Windows without video processing.)
  - `src/mftest/dshowtest.exe` (DirectShow / quartz: RenderFile, Run, WaitForCompletion):
    5 s clip EC_COMPLETE after 5.33 s, 15 s clip after 15.35 s (real-time playback); VMR7
    "ActiveMovie Window" created and shown by winemac.drv (trace), same GStreamer elements.
  - WMV (before 2026-10-17): asfdemux ran but there was no decoder ->
    `MFCreateSourceReaderFromURL` 0xC00D36BB. With FFmpeg + gst-libav (above), Worms W.M.D's
    `uidata/video/Team17Logo.wmv` (WMV3 1920x1080 25 fps + WMA Pro 44.1 kHz stereo):
    - native: `bin/gst-launch-1.0 filesrc ... ! decodebin ...` -> `asfdemux`, `avdec_wmv3`,
      `avdec_wmapro`, 89 I420 frames to EOS at 3.52 s;
    - `mftest.exe` (bottle steamtest): 89 video frames to NV12 (last 3.52 s), 77 audio samples
      to PCM;
    - `dshowtest.exe`: RenderFile OK, duration 4.02 s, EC_COMPLETE after 3.89 s wall (real time);
    - the game itself started from Steam: see docs/worms-opengl.md section 4.
  - Wine 10's `wmplayer.exe` is a 33-line stub and there is no mplay32, hence the test exes.
  - `WINEDEBUG=+winegstreamer` prints nothing useful in Wine 10 (the unix side logs to other
    channels); `GST_DEBUG=GST_ELEMENT_FACTORY:4` is the way to see the pipeline.
  - Native check without Wine: `bin/gst-launch-1.0 filesrc ... ! decodebin ! ...` decodes the
    same mp4.
- **SDL2**: `WINEDEBUG=+hid` shows `L"SDL" main loop started` / `sdl_bus_init` without errors
  (next to the IOHID bus). No controller was connected, so no device was enumerated.
- **D3D parity with winecx** (`src/d3dtest/d3d11test.exe`):
  - D3DMetal 2.1: "AMD Compatibility Mode", FL 11_0, 120 frames OK.
  - wined3d: now "Apple M4 Max", **FL 9_3** (winecx: "NVIDIA GeForce 8800 GTX", FL 10_1).
    Cause: CW HACK 18311 in `dlls/wined3d/directx.c`: on macOS wined3d prefers its **Vulkan
    renderer** whenever Vulkan works, and over MoltenVK it reaches only 9_3. With
    `HKCU\Software\Wine\Direct3D "renderer"="gl"` it is the old GL path again (8800 GTX,
    FL 10_1, 143 fps). This only matters for `WINECX_GRAPHICS=wined3d` bottles; worth setting
    `renderer=gl` there by default if DX10/11 games run worse.

## Test programs added
- `src/hagstest/` (`make -C src/hagstest`): HAGS / `D3DKMTQueryAdapterInfo` check (2026-10-22).
- `src/avxtest/` (`make -C src/avxtest`): cpuid AVX bits, `xgetbv`, one AVX op (2026-10-22).
- `src/d3dtest/d3d11test.exe <frames> fullscreen`: full-screen variant (2026-10-22).
- `src/mftest/` (`make -C src/mftest`): `mftest.exe <file>` (Media Foundation),
  `dshowtest.exe <file> [timeout_ms]` (DirectShow).
- `src/vktest/` (`make -C src/vktest`, uses the Vulkan headers MoltenVK's fetchDependencies
  cloned into `build/x86_64-full/moltenvk/External/Vulkan-Headers`).

## Open items
- `cli/` support for runtime `winecx-full` (see above).
- FFmpeg has only the Windows Media decoders enabled; add others to `WM_DECODERS` (LGPL ones
  only) when a game needs them.
- `runtimes/winecx` (non-full) has no GStreamer at all, so WMV only plays on winecx-full.
- CodeWeavers' MoltenVK (transform feedback etc.) needs their non-public SPIRV-Cross fork.
- DXVK / DXMT on top of MoltenVK: not tried yet.
