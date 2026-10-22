#!/bin/bash
# Build the x86_64 (Rosetta) native dependencies of our CrossOver-lineage Wine
# from the sources CodeWeavers ships in crossover-sources-25.1.0, with the
# arm64 host clang generating x86_64 code (-arch x86_64). Homebrew no longer
# publishes x86_64 bottles for macOS 27 and /usr/local needs sudo, so an
# x86_64 Homebrew is not an option on this machine.
#
# Everything installs into runtimes/winecx (same prefix as Wine itself), so the
# dylib install names are absolute and Wine's dlopen() finds them without any
# DYLD variable; scripts/winecx-env.sh adds DYLD_FALLBACK_LIBRARY_PATH anyway.
#
# Order: gmp -> nettle -> gnutls (schannel/TLS for Steam) ; freetype (fonts).
# gstreamer / SDL2 / MoltenVK are NOT built yet (see NOTES.md).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/upstream/crossover-sources-25.1.0/sources"
# WINECX_PREFIX / WINECX_BUILD: same meaning as in scripts/build-winecx.sh (a second
# runtime next to the live one). Each dep is skipped when its dylib is already in the prefix,
# so on a `cp -Rc` clone of the live runtime this is a no-op.
PREFIX="${WINECX_PREFIX:-$ROOT/runtimes/winecx}"
BUILD="${WINECX_BUILD:-$ROOT/build/x86_64}"
SDK="$(xcrun --show-sdk-path)"
JOBS="$(sysctl -n hw.ncpu)"
mkdir -p "$PREFIX" "$BUILD"

export CC="/usr/bin/clang -arch x86_64"
export CXX="/usr/bin/clang++ -arch x86_64"
export CFLAGS="-O2"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"
export PKG_CONFIG="/opt/homebrew/bin/pkg-config"
# Only our own x86_64 libs and the SDK: never let arm64 Homebrew libs leak in.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$SDK/usr/lib/pkgconfig"
export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
HOST=x86_64-apple-darwin

step() { echo "=== $(date '+%H:%M:%S') $*"; }

# ---- gmp 6.x (bundled in sources/gnutls/gmp) ----
if [ ! -f "$PREFIX/lib/libgmp.10.dylib" ]; then
  step gmp
  mkdir -p "$BUILD/gmp" && cd "$BUILD/gmp"
  "$SRC/gnutls/gmp/configure" --host=$HOST --prefix="$PREFIX" \
      --disable-assembly --disable-static --enable-shared > configure.log 2>&1
  make -j"$JOBS" > make.log 2>&1 && make install > install.log 2>&1
fi

# ---- nettle ----
# CodeWeavers' sources/gnutls/nettle has no Makefile.in (stripped), so we use
# the release tarball fetched (sha256-checked) by `brew fetch -s nettle` and
# unpacked into upstream/nettle-src/.
NETTLE_SRC="$(ls -d "$ROOT"/upstream/nettle-src/nettle-*/ | head -1)"
if [ ! -f "$PREFIX/lib/libnettle.dylib" ]; then
  step nettle "($NETTLE_SRC)"
  mkdir -p "$BUILD/nettle" && cd "$BUILD/nettle"
  "$NETTLE_SRC/configure" --host=$HOST --prefix="$PREFIX" \
      --disable-assembler --disable-documentation --disable-openssl --disable-static \
      --enable-shared > configure.log 2>&1
  make -j"$JOBS" > make.log 2>&1 && make install > install.log 2>&1
fi

# ---- gnutls ----
# CodeWeavers' sources/gnutls/gnutls (3.8.3) is a git checkout whose Makefile
# runs `git submodule update` -> fails outside git. Release tarball instead
# (`brew fetch -s gnutls`, unpacked into upstream/gnutls-src/).
GNUTLS_SRC="$(ls -d "$ROOT"/upstream/gnutls-src/gnutls-*/ | head -1)"
if [ ! -f "$PREFIX/lib/libgnutls.30.dylib" ]; then
  step gnutls "($GNUTLS_SRC)"
  mkdir -p "$BUILD/gnutls" && cd "$BUILD/gnutls"
  "$GNUTLS_SRC/configure" --host=$HOST --prefix="$PREFIX" \
      --with-included-libtasn1 --with-included-unistring \
      --without-p11-kit --without-idn --without-tpm --without-tpm2 \
      --without-brotli --without-zstd --disable-libdane --disable-doc \
      --disable-tools --disable-tests --disable-cxx --disable-nls \
      --disable-hardware-acceleration --disable-static > configure.log 2>&1
  make -j"$JOBS" > make.log 2>&1 && make install > install.log 2>&1
fi

# ---- freetype ----
# Same story: sources/freetype (2.13.3) lacks the subprojects/dlg submodule.
# Release tarball from `brew fetch -s freetype` in upstream/freetype-src/.
FREETYPE_SRC="$(ls -d "$ROOT"/upstream/freetype-src/freetype-*/ | head -1)"
if [ ! -f "$PREFIX/lib/libfreetype.6.dylib" ]; then
  step freetype "($FREETYPE_SRC)"
  mkdir -p "$BUILD/freetype" && cd "$BUILD/freetype"
  "$FREETYPE_SRC/configure" --host=$HOST --prefix="$PREFIX" \
      --with-zlib=yes --without-png --without-harfbuzz --without-brotli --without-bzip2 \
      --disable-static > configure.log 2>&1
  make -j"$JOBS" > make.log 2>&1 && make install > install.log 2>&1
fi

step done
for f in libgmp.10.dylib libnettle.dylib libhogweed.dylib libgnutls.30.dylib libfreetype.6.dylib; do
  file "$PREFIX/lib/$f" | sed 's/.*: //' | sed "s|^|$f: |"
done
