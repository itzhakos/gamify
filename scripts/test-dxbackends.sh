#!/bin/bash
# Run the D3D smoke tests in a bottle on each graphics backend, selecting the backend
# by environment only (the recipe CrossCore's Runtime.environment needs, docs/dxmt-dxvk.md):
#
#   CROSS_BOTTLES=<dir> scripts/test-dxbackends.sh <bottle> [backend...]
#       backends: d3dmetal wined3d dxvk dxmt (default: all four)
#   scripts/test-dxbackends.sh --env <bottle> <backend>    print the exports only
#   scripts/test-dxbackends.sh --run <bottle> <backend> <exe> [args...]   run one exe
#
# WINECX_HOME=<runtime> overrides the bottle's runtime (e.g. a clone with the proposed
# lib/wined3d layout, see "Runtime layout" in docs/dxmt-dxvk.md). The test exes are built
# with `make -C src/d3dtest d3d11test.exe`, `make -C src/d3dtest32`, `make -C src/d3d9test`
# and copied to C:\dxtest. Each result line is the test's own last line.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CROSS="${CROSS:-$ROOT/cli/.build/release/cross}"
DXVK_HOME="${DXVK_HOME:-$ROOT/runtimes/dxvk}"
DXMT_HOME="${DXMT_HOME:-$ROOT/runtimes/dxmt}"
ORIG_DLLOVERRIDES="${WINEDLLOVERRIDES:-}"

# backend_env <bottle> <backend>: the bottle's normal environment from `cross env`, with
# the graphics part replaced. This is the whole recipe:
#   WINEDLLPATH = <backend dir>:<runtime>/lib/wined3d:<runtime>/lib/wine
#     (wined3d alone: <runtime>/lib/wined3d:<runtime>/lib/wine). lib/wined3d is the
#     fallback for whatever the backend does not provide (D3DMetal: all i386 DLLs and
#     d3d9; DXVK: d3d10/d3d10_1/d3d12; DXMT: d3d9/d3d10/d3d10_1/d3d12).
#   DXVK: DXVK_CONFIG_FILE=<dxvk>/dxvk.conf; DXMT: nothing (winemetal.so is found next to
#     the PE DLLs, <dxmt>/x86_64-unix, by ntdll itself).
#   DXVK also: WINEDLLOVERRIDES += vulkan-1=b (see below).
#   CX_APPLEGPTK_LIBD3DSHARED_PATH only for d3dmetal.
backend_env() {
  local bottle="$1" backend="$2" home dll
  eval "$(env -u WINECX_GRAPHICS "$CROSS" env "$bottle" --export | grep -E "^export (WINE|CX_|D3DMETAL|DYLD|GST|DOTNET|MTL|PATH)")"
  home="${WINECX_HOME_OVERRIDE:-$WINECX_HOME}"
  export WINECX_HOME="$home" WINELOADER="$home/bin/wineloader" WINESERVER="$home/bin/wineserver"
  export PATH="$home/bin:$PATH"
  export DYLD_FALLBACK_LIBRARY_PATH="$home/lib:$D3DMETAL_HOME/x86_64-unix:$home/lib/wine/x86_64-unix:/usr/local/lib:/usr/lib"
  unset DXVK_CONFIG_FILE; WINEDLLOVERRIDES="$ORIG_DLLOVERRIDES"
  case "$backend" in
    d3dmetal) dll="$D3DMETAL_HOME:" ;;
    wined3d)  dll=""; unset CX_APPLEGPTK_LIBD3DSHARED_PATH ;;
    dxvk)     dll="$DXVK_HOME:"; unset CX_APPLEGPTK_LIBD3DSHARED_PATH
              export DXVK_CONFIG_FILE="$DXVK_HOME/dxvk.conf" DXVK_LOG_PATH="${DXVK_LOG_PATH:-none}"
              # Apps that ship the Khronos loader (Battle.net/CEF: vulkan-1.dll next to the
              # exe) would hand DXVK a loader that enumerates adapters through dxgi =
              # DXVK again: endless recursion, stack overflow. Always use Wine's builtin.
              export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:+$WINEDLLOVERRIDES;}vulkan-1=b" ;;
    dxmt)     dll="$DXMT_HOME:"; unset CX_APPLEGPTK_LIBD3DSHARED_PATH ;;
    *) echo "unknown backend $backend" >&2; exit 1 ;;
  esac
  export WINEDLLPATH="$dll$home/lib/wined3d:$home/lib/wine"
  export WINECX_GRAPHICS="$backend"
}

# prefix_setup <prefix>: DXMT's winemetal.dll is a new builtin; Wine only loads builtins
# that have a file in system32/syswow64 (ntdll loader.c find_builtin_without_file works
# during prefix bootstrap only), so put the PE files there once. Harmless for the other
# backends (nothing imports winemetal.dll).
prefix_setup() {
  local p="$1"
  cp -f "$DXMT_HOME/x86_64-windows/winemetal.dll" "$p/drive_c/windows/system32/winemetal.dll"
  [ -d "$p/drive_c/windows/syswow64" ] && cp -f "$DXMT_HOME/i386-windows/winemetal.dll" "$p/drive_c/windows/syswow64/winemetal.dll"
}

run_exe() {  # run_exe <exe path> [args...]: cwd = the exe's directory, like `cross run`
  local dir exe; dir="$(dirname "$1")"; exe="$(basename "$1")"; shift
  (cd "$dir" && "$WINELOADER" "$exe" "$@")
}

case "${1:-}" in
  --env)
    WINECX_HOME_OVERRIDE="${WINECX_HOME:-}"; backend_env "$2" "$3"
    # export -p, not env(1): SIP strips DYLD_* from the environment of /usr/bin/env.
    export -p | grep -E "^(declare -x|export) (WINE|DXVK|DYLD|CX_|PATH=)"; exit 0 ;;
  --run)
    WINECX_HOME_OVERRIDE="${WINECX_HOME:-}"; b="$2"; g="$3"; shift 3
    backend_env "$b" "$g"; prefix_setup "$WINEPREFIX"; run_exe "$@"; exit $? ;;
esac

BOTTLE="${1:?usage: $0 <bottle> [backend...]}"; shift
if [ $# -gt 0 ]; then BACKENDS=("$@"); else BACKENDS=(d3dmetal wined3d dxvk dxmt); fi
WINECX_HOME_OVERRIDE="${WINECX_HOME:-}"
backend_env "$BOTTLE" wined3d
T="$WINEPREFIX/drive_c/dxtest"; mkdir -p "$T"
for f in src/d3dtest/d3d11test.exe src/d3dtest32/d3d11test32.exe src/d3d9test/d3d9test.exe src/d3d9test/d3d9test64.exe; do
  [ -f "$ROOT/$f" ] && cp -f "$ROOT/$f" "$T/"
done
prefix_setup "$WINEPREFIX"
if [ -f "$WINECX_HOME/lib/wine/i386-windows/d3d11.dll" ]; then
  echo "note: $WINECX_HOME still has Wine's i386 d3d*/dxgi in lib/wine, so 32-bit tests get wined3d on every backend" >&2
fi

TESTS=(
  "d3d11test.exe 120 1" "d3d11test.exe 1000 0"
  "d3d11test32.exe 120 1" "d3d11test32.exe 1000 0"
  "d3d9test.exe 120 1" "d3d9test.exe 1000 0"
  "d3d9test64.exe 120 1" "d3d9test64.exe 1000 0"
)
for g in "${BACKENDS[@]}"; do
  backend_env "$BOTTLE" "$g"
  for t in "${TESTS[@]}"; do
    set -- $t
    [ -f "$T/$1" ] || continue
    out="$(run_exe "$T/$@" 2>&1 | tr -d '\r' || true)"
    adapter="$(echo "$out" | grep -m1 -E "^adapter( 0)?:" | sed 's/^adapter[^:]*: //' || true)"
    fl="$(echo "$out" | grep -m1 -oE "feature level 0x[0-9a-f]+" || true)"
    last="$(echo "$out" | grep -E "^(presented|Present failed|D3D11CreateDeviceAndSwapChain: 0x8|CreateDevice: 0x8|CreateDXGIFactory1: 0x8)" | tail -1 || true)"
    printf "%-8s | %-24s | %-48s | %-24s | %s\n" "$g" "$t" "${adapter:-?}" "${fl:-}" "${last:-no result (exit/crash)}"
  done
done
