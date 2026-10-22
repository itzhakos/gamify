#!/bin/bash
# Build DXVK 1.10.3 (D3D9/10/11 -> Vulkan, CrossOver's fork from
# crossover-sources-25.1.0) for both PE architectures with Homebrew mingw-w64,
# and install it as a Wine *builtin* DLL dir into runtimes/dxvk:
#
#   runtimes/dxvk/x86_64-windows/{d3d9,d3d10core,d3d11,dxgi}.dll
#   runtimes/dxvk/i386-windows/{d3d9,d3d10core,d3d11,dxgi}.dll
#   runtimes/dxvk/dxvk.conf, LICENSE, VERSION
#
# Vulkan itself comes from runtimes/winecx-full (vulkan-1.dll -> winevulkan -> MoltenVK).
# The DLLs are marked with `winebuild --builtin` so ntdll accepts them from WINEDLLPATH
# ("found in WINEDLLPATH but not a builtin, ignoring" otherwise, ntdll/unix/virtual.c),
# which makes the backend selectable by environment alone (docs/dxmt-dxvk.md).
#
#   scripts/build-dxvk.sh            configure (if needed) + build + install
#   DXVK_SRC=<tree> scripts/build-dxvk.sh   build another DXVK 1.10.x tree
#
# Patches: scripts/dxvk-patches/*.patch, applied to a copy in build/dxvk/src: two
# mingw-w64 14 header clashes, and geometry shaders / cull distance / tessellation made
# optional, because CrossOver's tree expects CodeWeavers' MoltenVK fork, which has them,
# while ours is upstream MoltenVK 1.4.2 (docs/dxmt-dxvk.md).
# Host tools (arm64 Homebrew): mingw-w64, meson, ninja, glslang (glslangValidator).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${DXVK_SRC:-$ROOT/upstream/crossover-sources-25.1.0/sources/dxvk}"
BUILD="${DXVK_BUILD:-$ROOT/build/dxvk}"
PREFIX="${DXVK_PREFIX:-$ROOT/runtimes/dxvk}"
# winebuild only rewrites the DOS stub, any of our Wine builds will do (x86_64, Rosetta).
WINEBUILD="${WINEBUILD:-$ROOT/runtimes/winecx-full/bin/winebuild}"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# DXVK stamps its version with `git describe`; the copy in build/ has no .git, so stop git
# from climbing into our own repository (it reported "v0.6-..." = a Gamify tag).
export GIT_CEILING_DIRECTORIES="$BUILD"

for t in meson ninja glslangValidator i686-w64-mingw32-g++ x86_64-w64-mingw32-g++; do
  command -v "$t" >/dev/null || { echo "build-dxvk: missing $t (brew install mingw-w64 meson ninja glslang)" >&2; exit 1; }
done
[ -x "$WINEBUILD" ] || { echo "build-dxvk: no winebuild at $WINEBUILD" >&2; exit 1; }

# Build from a copy of the tree with scripts/dxvk-patches/*.patch applied; the copy is
# redone whenever the patch set changes.
PATCHES=("$ROOT"/scripts/dxvk-patches/*.patch)
STAMP="$(cat "${PATCHES[@]}" | shasum | cut -c1-12)"
WSRC="$BUILD/src"
if [ "$(cat "$BUILD/src.stamp" 2>/dev/null)" != "$STAMP" ]; then
  rm -rf "$WSRC" "$BUILD"/build.* "$BUILD"/install.*
  mkdir -p "$BUILD"
  cp -R "$SRC" "$WSRC"
  for p in "${PATCHES[@]}"; do patch -d "$WSRC" -p1 --no-backup-if-mismatch < "$p"; done
  echo "$STAMP" > "$BUILD/src.stamp"
fi

DLLS=(d3d9 d3d10core d3d11 dxgi)
# DXVK 1.10.3 predates GCC 13's leaner libstdc++ headers and uses uint32_t etc. without
# <cstdint> (fixed upstream in 2.x); force-include it instead of patching the tree.
CPP_ARGS="['-include','cstdint']"
mkdir -p "$PREFIX"

build_arch() {  # $1 = 32|64, $2 = Wine PE dir name
  local bits="$1" pedir="$2" bdir="$BUILD/build.$1"
  if [ ! -f "$bdir/build.ninja" ]; then
    # Same options as DXVK's package-release.sh (release, stripped, no tests); the
    # cross files are CrossOver's own build-win32.txt / build-win64.txt.
    meson setup --cross-file "$WSRC/build-win$bits.txt" \
      --buildtype release --strip \
      --prefix "$BUILD/install.$bits" --bindir bin --libdir lib \
      -Denable_tests=false -Dbuild_id=false \
      -Dcpp_args="$CPP_ARGS" \
      "$bdir" "$WSRC"
  fi
  ninja -C "$bdir" install
  mkdir -p "$PREFIX/$pedir"
  for d in "${DLLS[@]}"; do
    install -m 644 "$BUILD/install.$bits/bin/$d.dll" "$PREFIX/$pedir/$d.dll"
  done
  for d in "${DLLS[@]}"; do "$WINEBUILD" --builtin "$PREFIX/$pedir/$d.dll"; done
}

build_arch 64 x86_64-windows
build_arch 32 i386-windows

# dxvk.conf: our defaults (this tree has no async shader compilation), read via
# DXVK_CONFIG_FILE, which the environment points here (docs/dxmt-dxvk.md).
install -m 644 "$ROOT/scripts/dxvk.conf" "$PREFIX/dxvk.conf"
install -m 644 "$SRC/LICENSE" "$PREFIX/LICENSE"
{
  echo "DXVK $(cat "$SRC/RELEASE") (source: ${SRC#$ROOT/}, patched: $(cd "$ROOT/scripts/dxvk-patches" && echo *.patch))"
  echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ) with $(x86_64-w64-mingw32-gcc --version | head -1)"
} > "$PREFIX/VERSION"
echo "build-dxvk: installed into $PREFIX"
ls -l "$PREFIX"/*-windows
