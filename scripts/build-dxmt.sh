#!/bin/bash
# Build DXMT (D3D10/11 -> Metal, github.com/3Shain/dxmt) at tag v0.80, the last
# MIT-licensed release, for our winecx-full runtime, and install it into runtimes/dxmt:
#
#   runtimes/dxmt/x86_64-windows/{d3d10core,d3d11,dxgi,winemetal,nvapi64,nvngx}.dll
#   runtimes/dxmt/i386-windows/{d3d10core,d3d11,dxgi,winemetal}.dll
#   runtimes/dxmt/x86_64-unix/winemetal.so
#   runtimes/dxmt/LICENSE (MIT), LICENSE.LLVM.txt, LICENSE.nvapi.txt, VERSION, dxmt.conf
#
# The PE DLLs are Wine builtins (DXMT's default `wine_builtin_dll=true`), so the
# backend is selected by putting runtimes/dxmt first in WINEDLLPATH (docs/dxmt-dxvk.md).
#
#   scripts/build-dxmt.sh            all steps
#   scripts/build-dxmt.sh llvm       only step 1 (LLVM 15 static libs, ~10 min, once)
#   scripts/build-dxmt.sh dxmt       only steps 2-4 (needs step 1)
#
# Steps:
#   1. LLVM 15.0.7 static libraries for x86_64-apple-darwin (no targets, no tools),
#      exactly as DXMT's docs/DEVELOPMENT.md and CI, built with Apple clang -arch x86_64
#      (no x86_64 Homebrew needed; tablegen runs under Rosetta). DXMT's shader
#      converter (airconv) links them into winemetal.so.
#   2. 64-bit: PE DLLs (mingw-w64 gcc) + the x86_64 unix lib winemetal.so (Apple clang).
#   3. 32-bit (WoW64): PE DLLs only; they thunk into the same 64-bit winemetal.so.
#   4. Install into runtimes/dxmt.
#
# Sources: upstream/dxmt (git clone + `git checkout v0.80` + submodules) and
# upstream/llvm-project-15.0.7 (git clone --depth 1 --branch llvmorg-15.0.7).
# Wine headers/import libs: runtimes/winecx-full (`wine_install_path`): include/wine and
# lib/wine/*-windows/lib*.a, i.e. our own CrossOver 25.1 Wine 10.0, not 3Shain's Wine 8.16.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${DXMT_SRC:-$ROOT/upstream/dxmt}"
TAG="${DXMT_TAG:-v0.80}"
LLVM_SRC="${LLVM_SRC:-$ROOT/upstream/llvm-project-15.0.7}"
BUILD="${DXMT_BUILD:-$ROOT/build/dxmt}"
LLVM_PREFIX="$BUILD/llvm-15-x86_64"
WINE="${WINECX_HOME:-$ROOT/runtimes/winecx-full}"
PREFIX="${DXMT_PREFIX:-$ROOT/runtimes/dxmt}"
JOBS="$(sysctl -n hw.ncpu)"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
STEP="${1:-all}"
mkdir -p "$BUILD"

step_llvm() {
  [ -f "$LLVM_PREFIX/lib/libLLVMCore.a" ] && { echo "build-dxmt: LLVM already in $LLVM_PREFIX"; return; }
  # CMAKE_POLICY_VERSION_MINIMUM: CMake 4 refuses LLVM 15's old policy settings otherwise.
  cmake -B "$BUILD/llvm-build" -S "$LLVM_SRC/llvm" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="$LLVM_PREFIX" \
    -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DLLVM_HOST_TRIPLE=x86_64-apple-darwin \
    -DLLVM_ENABLE_ASSERTIONS=On \
    -DLLVM_ENABLE_ZSTD=Off -DLLVM_ENABLE_ZLIB=Off -DLLVM_ENABLE_LIBXML2=Off \
    -DLLVM_ENABLE_TERMINFO=Off \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_TARGETS_TO_BUILD="" \
    -DLLVM_BUILD_TOOLS=Off -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_BENCHMARKS=Off \
    -DLLVM_INCLUDE_EXAMPLES=Off \
    -DBUG_REPORT_URL="https://github.com/3Shain/dxmt" \
    -DPACKAGE_VENDOR="DXMT" \
    -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off
  cmake --build "$BUILD/llvm-build" -j "$JOBS"
  cmake --install "$BUILD/llvm-build"
}

check_src() {
  git -C "$SRC" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "build-dxmt: no tag $TAG in $SRC" >&2; exit 1; }
  local head tagc
  head="$(git -C "$SRC" rev-parse HEAD)"; tagc="$(git -C "$SRC" rev-parse "$TAG^{commit}")"
  [ "$head" = "$tagc" ] || { echo "build-dxmt: $SRC is at $head, not $TAG ($tagc); git checkout $TAG" >&2; exit 1; }
  grep -q "^MIT License" "$SRC/LICENSE" || { echo "build-dxmt: $SRC/LICENSE is not MIT, refusing" >&2; exit 1; }
  [ -f "$SRC/include/native/directx/d3d11.h" ] || git -C "$SRC" submodule update --init --recursive
}

# Build from an APFS clone of the checkout (with .git, so DXMT's `git describe` version
# stamp still says v0.80) with scripts/dxmt-patches/*.patch applied: Xcode 27 metal and
# GCC 16 fixes, equivalent to upstream commits made after v0.80.
prepare_src() {
  local patches=("$ROOT"/scripts/dxmt-patches/*.patch) stamp
  stamp="$(git -C "$SRC" rev-parse HEAD)-$(cat "${patches[@]}" | shasum | cut -c1-12)"
  WSRC="$BUILD/src"
  if [ "$(cat "$BUILD/src.stamp" 2>/dev/null)" != "$stamp" ]; then
    rm -rf "$WSRC" "$BUILD"/build.* "$BUILD/install"
    cp -Rc "$SRC" "$WSRC"
    for p in "${patches[@]}"; do patch -d "$WSRC" -p1 --no-backup-if-mismatch < "$p"; done
    echo "$stamp" > "$BUILD/src.stamp"
  fi
}

step_dxmt() {
  check_src
  [ -f "$LLVM_PREFIX/lib/libLLVMCore.a" ] || { echo "build-dxmt: run '$0 llvm' first" >&2; exit 1; }
  prepare_src
  local common=(--buildtype release --strip -Dwine_install_path="$WINE")
  if [ ! -f "$BUILD/build.64/build.ninja" ]; then
    meson setup --cross-file "$WSRC/build-win64.txt" "${common[@]}" \
      -Dnative_llvm_path="$LLVM_PREFIX" -Denable_nvapi=true -Denable_nvngx=true \
      --prefix "$BUILD/install" "$BUILD/build.64" "$WSRC"
  fi
  meson compile -C "$BUILD/build.64"
  meson install -C "$BUILD/build.64"
  if [ ! -f "$BUILD/build.32/build.ninja" ]; then
    meson setup --cross-file "$WSRC/build-win32.txt" "${common[@]}" \
      --prefix "$BUILD/install" "$BUILD/build.32" "$WSRC"
  fi
  meson compile -C "$BUILD/build.32"
  meson install -C "$BUILD/build.32"

  rm -rf "$PREFIX"; mkdir -p "$PREFIX"
  for d in x86_64-windows i386-windows x86_64-unix; do
    [ -d "$BUILD/install/$d" ] && cp -R "$BUILD/install/$d" "$PREFIX/$d"
  done
  find "$PREFIX" -name '*.a' -delete
  install -m 644 "$SRC/LICENSE" "$PREFIX/LICENSE"
  # Notices for what is linked in: LLVM (winemetal.so), NVIDIA nvapi (nvapi64.dll).
  install -m 644 "$LLVM_SRC/llvm/LICENSE.TXT" "$PREFIX/LICENSE.LLVM.txt"
  install -m 644 "$SRC/external/nvapi/License.txt" "$PREFIX/LICENSE.nvapi.txt"
  install -m 644 "$SRC/dxmt.conf" "$PREFIX/dxmt.conf"
  {
    echo "DXMT $TAG ($(git -C "$SRC" rev-parse HEAD), MIT; source: github.com/3Shain/dxmt; patched: $(cd "$ROOT/scripts/dxmt-patches" && echo *.patch))"
    echo "LLVM 15.0.7 (x86_64-apple-darwin static libs from ${LLVM_SRC#$ROOT/}, linked into winemetal.so)"
    echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ) with $(x86_64-w64-mingw32-gcc --version | head -1) and $(/usr/bin/clang --version | head -1)"
    echo "Wine headers: ${WINE#$ROOT/}"
  } > "$PREFIX/VERSION"
  echo "build-dxmt: installed into $PREFIX"
  find "$PREFIX" -type f | sort
}

case "$STEP" in
  llvm) step_llvm ;;
  dxmt) step_dxmt ;;
  all)  step_llvm; step_dxmt ;;
  *) echo "usage: $0 [all|llvm|dxmt]" >&2; exit 1 ;;
esac
