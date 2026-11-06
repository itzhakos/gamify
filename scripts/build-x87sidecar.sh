#!/bin/bash
# Build x87sidecar (github.com/athei/x87sidecar, MIT) and install it into runtimes/x87sidecar:
#
#   runtimes/x87sidecar/x87sidecar   native arm64, the flat build (no entitlements)
#   runtimes/x87sidecar/LICENSE      MIT
#   runtimes/x87sidecar/VERSION      the commit it was built from + `--probe` of this Mac
#
# x87sidecar replaces Rosetta 2's software emulation of x87 floating point with ARM64 code
# from an out-of-process translator (a hook in libRosettaRuntime's translate_insn). Our
# Wine starts every 32-bit (i386) process through `x87sidecar --cooperative` when
# ROSETTA_X87_PATH names this binary (src/patches/loader-rosetta-x87.patch); CrossCore sets
# it for bottles with `performance.x87 = sidecar` on a runtime that carries the patch.
# Cooperative mode needs no entitlement and no password: the process hands over its own task
# port. (The `x87sidecar_entitled` build, which attaches to any process, is not installed.)
#
#   scripts/build-x87sidecar.sh          clone (if needed), build, install, probe
#
# Sources: upstream/x87sidecar (git clone; X87SIDECAR_COMMIT pins the revision).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${X87SIDECAR_SRC:-$ROOT/upstream/x87sidecar}"
COMMIT="${X87SIDECAR_COMMIT:-03581e1}"   # "Build every target for macOS 14.0 and release on xcode-27 (#50)"
PREFIX="${X87SIDECAR_PREFIX:-$ROOT/runtimes/x87sidecar}"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if [ ! -d "$SRC/.git" ]; then
  git clone https://github.com/athei/x87sidecar.git "$SRC"
fi
git -C "$SRC" fetch --quiet origin || true
git -C "$SRC" checkout --quiet "$COMMIT"

# Only the sidecar target: the x86_64 tests and benchmarks are not needed. The build signs
# x87sidecar ad hoc without entitlements ("flat"); package-app.sh signs it again.
cmake -B "$SRC/build" -S "$SRC" -G Ninja -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build "$SRC/build" --target x87sidecar

mkdir -p "$PREFIX"
cp "$SRC/build/bin/x87sidecar" "$PREFIX/x87sidecar"
cp "$SRC/LICENSE" "$PREFIX/LICENSE"
{
  echo "x87sidecar $(git -C "$SRC" rev-parse HEAD) (https://github.com/athei/x87sidecar)"
  echo "built $(date '+%Y-%m-%d') on macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
} > "$PREFIX/VERSION"
echo "=== installed $PREFIX/x87sidecar"
# Does the Rosetta runtime on this Mac have everything the hook needs? The loader refuses a
# runtime it does not recognise; the game then runs without the hook (and says so on stderr).
"$PREFIX/x87sidecar" --probe
