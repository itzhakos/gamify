#!/bin/bash
# Environment for our own CrossOver-lineage Wine (runtimes/winecx) paired with
# Apple D3DMetal 3.0 (runtimes/d3dmetal). Reproduces what CrossOver's Perl
# bin/wine sets up, minus the bottle bookkeeping.
#
#   source scripts/winecx-env.sh            # exports the variables below
#   scripts/winecx-env.sh wine notepad      # or run a command with them
#
# WINEPREFIX is left alone: set it before sourcing (the `cross` CLI does all of this itself).
# Works when sourced from bash or zsh, or when executed directly.
if [ -n "${BASH_SOURCE:-}" ]; then _src="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then eval '_src="${(%):-%x}"'
else _src="$0"; fi
_root="${WINECX_ROOT:-$(cd "$(dirname "$_src")/.." && pwd)}"
# Which Wine build: runtimes/winecx (default) or runtimes/winecx-full (same Wine
# plus gstreamer, SDL2 and MoltenVK; scripts/build-winecx-full*.sh, docs/runtime-full.md).
export WINECX_HOME="${WINECX_HOME:-$_root/runtimes/winecx}"
# D3DMetal 3.0 (GPTK 3.0). Its x86_64-unix/*.so must be symlinks to libd3dshared.dylib,
# not copies: dyld then loads one image whose globals dxgi.so and d3d11.so share
# (docs/d3dmetal3.md). runtimes/d3dmetal-2.1 (CrossOver 25.1 trial) still works too.
export D3DMETAL_HOME="${D3DMETAL_HOME:-$_root/runtimes/d3dmetal}"

# Graphics backend for 64-bit DirectX 10/11/12: d3dmetal (default) or wined3d.
# ntdll searches its own lib/wine first, before any WINEDLLPATH entry, so the
# build moves Wine's d3d10*/d3d11/d3d12/dxgi to lib/wined3d and we put exactly
# one of the two dirs in WINEDLLPATH. Entries must be the PARENT of the
# x86_64-windows/x86_64-unix dirs: ntdll appends "/x86_64-windows/<name>.dll" and
# looks for the matching unix lib at "<entry>/x86_64-unix/<name>.so". Pointing at
# the x86_64-windows dir itself finds the DLL but then looks for the .so next to
# it ("d3d11.dll failed to initialize, c0000142" with D3DMetal).
export WINECX_GRAPHICS="${WINECX_GRAPHICS:-d3dmetal}"
case "$WINECX_GRAPHICS" in
  d3dmetal) _d3d="$D3DMETAL_HOME" ;;
  wined3d)  _d3d="$WINECX_HOME/lib/wined3d" ;;
  *) echo "winecx-env: unknown WINECX_GRAPHICS='$WINECX_GRAPHICS' (d3dmetal|wined3d)" >&2; _d3d="$D3DMETAL_HOME" ;;
esac
export WINEDLLPATH="$_d3d:$WINECX_HOME/lib/wine"
unset _d3d

# CW HACK 22434: ntdll dlopens this at startup and registers D3DMetal's JIT
# code regions with Rosetta (needed for the Metal shader translation).
export CX_APPLEGPTK_LIBD3DSHARED_PATH="$D3DMETAL_HOME/x86_64-unix/libd3dshared.dylib"

# Our gnutls/freetype dylibs carry absolute install names, and the D3DMetal
# .so files reference @rpath/libd3dshared.dylib + D3DMetal.framework; the
# fallback paths cover both if the tree is ever moved.
export DYLD_FALLBACK_LIBRARY_PATH="$WINECX_HOME/lib:$D3DMETAL_HOME/x86_64-unix:$WINECX_HOME/lib/wine/x86_64-unix:${DYLD_FALLBACK_LIBRARY_PATH:-/usr/local/lib:/usr/lib}"
export DYLD_FALLBACK_FRAMEWORK_PATH="$D3DMETAL_HOME/x86_64-unix:${DYLD_FALLBACK_FRAMEWORK_PATH:-/Library/Frameworks:/System/Library/Frameworks}"

export WINELOADER="$WINECX_HOME/bin/wineloader"   # ntdll hardcodes this name (CrossOver hack)
export WINESERVER="$WINECX_HOME/bin/wineserver"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEESYNC="${WINEESYNC:-1}"
export DOTNET_EnableWriteXorExecute=0      # CrossOver sets this for .NET under Rosetta
export MTL_HUD_ENABLED="${MTL_HUD_ENABLED:-0}"
export PATH="$WINECX_HOME/bin:$PATH"
# winecx-full only: GStreamer's plugin dir and scanner are compiled in as absolute
# paths; set them explicitly so the runtime keeps working if the tree is moved.
if [ -d "$WINECX_HOME/lib/gstreamer-1.0" ]; then
  export GST_PLUGIN_SYSTEM_PATH_1_0="$WINECX_HOME/lib/gstreamer-1.0"
  export GST_PLUGIN_SCANNER_1_0="$WINECX_HOME/libexec/gstreamer-1.0/gst-plugin-scanner"
fi
unset _root _src

if [ -n "${BASH_SOURCE:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ] && [ $# -gt 0 ]; then exec "$@"; fi
