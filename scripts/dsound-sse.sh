#!/bin/bash
# SSE build of the 32-bit (i386) dsound.dll, installed into a bottle as a native DLL.
# Why: our runtimes build the i386 PE side with mingw gcc's default -g -O2 = x87 floating
# point, which Rosetta emulates slowly. Wine's DirectSound resampler (any game buffer whose
# rate differs from the Mac device, e.g. 44.1 kHz on a 48 kHz device) then eats a whole core
# and audio ticks. See docs/portal2-audio.md. Stopgap until the runtimes are rebuilt with
# i386_CFLAGS="-g -O2 -msse2 -mfpmath=sse" (then this script is not needed).
#
#   scripts/dsound-sse.sh build            configure a minimal Wine tree + make dsound (~30 s)
#   scripts/dsound-sse.sh install <bottle> copy into bottles/<bottle>/drive_c/windows/syswow64
#                                          and set HKCU\Software\Wine\DllOverrides dsound=native,builtin
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/upstream/crossover-sources-25.1.0/sources/wine"
BUILD="$ROOT/build/dsound-sse"
OUT="$BUILD/dsound-sse-native.dll"

build() {
  mkdir -p "$BUILD"; cd "$BUILD"
  export CC="/usr/bin/clang -arch x86_64"
  export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export BISON=/opt/homebrew/opt/bison/bin/bison FLEX=/usr/bin/flex
  # Only the PE side matters here, so no unix-side dependencies.
  [ -f Makefile ] || "$SRC/configure" --host=x86_64-apple-darwin --enable-win64 \
    --enable-archs=i386,x86_64 --disable-tests --without-x --without-freetype --without-gnutls \
    --without-gstreamer --without-sdl --without-vulkan \
    i386_CC=/opt/homebrew/bin/i686-w64-mingw32-gcc x86_64_CC=/opt/homebrew/bin/x86_64-w64-mingw32-gcc \
    i386_CFLAGS="-g -O2 -msse2 -mfpmath=sse" > configure.out 2>&1
  make -j16 dlls/dsound/i386-windows/dsound.dll > make.log 2>&1 || { tail -20 make.log; exit 1; }
  # Wine refuses a builtin-marked file as "native": blank the "Wine builtin DLL" marker
  # (DOS stub, offset 0x40). This also keeps wineboot --update from overwriting it.
  python3 -I - dlls/dsound/i386-windows/dsound.dll "$OUT" <<'EOF'
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
i = d.find(b'Wine builtin DLL')
assert 0 < i < 0x100, i
d[i:i+16] = b'\0' * 16
open(sys.argv[2], 'wb').write(d)
EOF
  echo "built $OUT (x87 ops: $(i686-w64-mingw32-objdump -d "$OUT" | grep -cE '\sf(ld|mul|add|stp|ild)[a-z]*\s'))"
}

install() {
  local bottle="$1" dst="$ROOT/bottles/$1/drive_c/windows/syswow64/dsound.dll"
  [ -f "$OUT" ] || build
  [ -f "$dst.wine-x87.bak" ] || cp -p "$dst" "$dst.wine-x87.bak"
  cp "$OUT" "$dst"
  "$ROOT/cli/.build/release/cross" cmd "$bottle" /c reg add 'HKCU\Software\Wine\DllOverrides' \
    /v dsound /d native,builtin /f
  echo "installed in $bottle (AppDefaults\\<game>.exe\\DllOverrides dsound=builtin would undo it)"
}

case "${1:-}" in
  build) build ;;
  install) install "${2:?bottle}" ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
