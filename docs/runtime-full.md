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

Host tools from arm64 Homebrew: meson 1.12.1, ninja, cmake (installed for this), python 3.14,
pkg-config, bison; meson uses a cross file (`build/x86_64-full/x86_64-darwin.ini`, host
x86_64-darwin, `needs_exe_wrapper = false` because Rosetta runs the test binaries).
All dylibs get absolute install names in `runtimes/winecx-full/lib` (MoltenVK via
`install_name_tool -id` + ad-hoc re-sign).

GStreamer plugin set (37 plugins in `lib/gstreamer-1.0`, 5.8 MB) = everything CrossOver 25.1
ships in `lib64/gstreamer-1.0` (applemedia, asf, audioconvert, audioparsers, audioresample,
avi, coreelements, deinterlace, id3demux, isomp4, opengl, playback, typefindfunctions,
videoconvertscale, videofilter, videoparsersbad, wavparse) plus app, apetag, audiorate,
audiotestsrc, autodetect, coretracers, flv, gio, matroska, mpegtsdemux, ogg, osxaudio, pbtypes,
rawparse, subparse, theora, videorate, videotestsrc, volume, vorbis. `applemedia` gives
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

## Wine configure (from scripts/build-winecx-full.sh)
Identical to `scripts/build-winecx.sh` except prefix/build dir and
`--with-gstreamer --with-sdl --with-vulkan` instead of the three `--without-*` (the script
aborts if configure prints "GStreamer/SDL2/Vulkan won't be supported"). Result in config.h:
`SONAME_LIBVULKAN "libMoltenVK.dylib"`, `SONAME_LIBSDL2 "libSDL2-2.0.0.dylib"`,
`HAVE_SDL_H`; `GSTREAMER_LIBS` links gstvideo/audio/tag/base/gstreamer/gobject/glib/intl.
Same post-install steps (`bin/wineloader -> wine`, d3d10*/d3d11/d3d12/dxgi moved to
`lib/wined3d/x86_64-windows`, generated `distversion.h`).

## Sizes
- `runtimes/winecx-full`: 1.5 GB (winecx: 1.4 GB). 114 dylibs in `lib/`, 31 unix `.so`
  (winecx: 30, the extra one is `winegstreamer.so`), 983 x86_64 + 1049 i386 PE files
  (+ `winegstreamer.dll`). MoltenVK 5.4 MB, SDL2 1.7 MB, gio 2.0 MB, glib 1.4 MB, plugins 5.8 MB.
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
  - WMV (wmv2 + wmav2): asfdemux runs but there is no decoder ->
    `MFCreateSourceReaderFromURL` 0xC00D36BB. Expected: no gst-libav/FFmpeg, and CrossOver's
    plugin set has none either (WMV/WMA needs `gst-libav`, which means building FFmpeg x86_64).
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
- `src/mftest/` (`make -C src/mftest`): `mftest.exe <file>` (Media Foundation),
  `dshowtest.exe <file> [timeout_ms]` (DirectShow).
- `src/vktest/` (`make -C src/vktest`, uses the Vulkan headers MoltenVK's fetchDependencies
  cloned into `build/x86_64-full/moltenvk/External/Vulkan-Headers`).

## Open items
- `cli/` support for runtime `winecx-full` (see above).
- WMV/WMA and other codecs need gst-libav + FFmpeg (x86_64); CrossOver doesn't ship it either.
- CodeWeavers' MoltenVK (transform feedback etc.) needs their non-public SPIRV-Cross fork.
- DXVK / DXMT on top of MoltenVK: not tried yet.
