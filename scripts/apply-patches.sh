#!/bin/bash
# Applies our own fixes on top of CodeWeavers' tree, src/patches/*.patch in name order, to the Wine
# source tree given as $1 (scripts/build-winecx.sh and scripts/build-winecx-full.sh call it before
# configure). The .diff there is only the CrossOver-vs-Wine-10.0 reference, never applied.
#
# Idempotent: the tree may already hold some of them (the shared tree is patched in place). A later
# patch may change lines an earlier one added (ntdll-gamemode-bundle.patch changes the first-process
# code of loader-rosetta-x87.patch), so the earlier one no longer reverses cleanly on its own.
# Which patches the tree holds is therefore decided on a scratch copy of the files they touch, by
# reversing them newest first; the others are applied in order, each only if it applies cleanly
# (never half: a patch that does not apply stops the build).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$1"
PATCHES=()
for p in "$ROOT"/src/patches/*.patch; do [ -e "$p" ] && PATCHES+=("$p"); done
[ ${#PATCHES[@]} -gt 0 ] || exit 0

SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH:?}"' EXIT
awk '/^\+\+\+ /{ f = $2; sub(/^b\//, "", f); print f }' "${PATCHES[@]}" | sort -u | while read -r f; do
  if [ -f "$SRC/$f" ]; then mkdir -p "$SCRATCH/$(dirname "$f")"; cp "$SRC/$f" "$SCRATCH/$f"; fi
done
APPLIED=" "
for ((i = ${#PATCHES[@]} - 1; i >= 0; i--)); do
  p="${PATCHES[$i]}"
  if patch -p1 -R --dry-run -s -f -d "$SCRATCH" < "$p" > /dev/null 2>&1; then
    patch -p1 -R -s -f -d "$SCRATCH" < "$p" > /dev/null
    APPLIED+="$(basename "$p") "
  fi
done

for p in "${PATCHES[@]}"; do
  [[ "$APPLIED" == *" $(basename "$p") "* ]] && continue
  if ! patch -p1 --dry-run -s -f -d "$SRC" < "$p" > /dev/null 2>&1; then
    echo "=== $(basename "$p") does not apply to $SRC (and is not in it)"; exit 1
  fi
  echo "=== applying $(basename "$p")"
  patch -p1 -s -f -d "$SRC" < "$p"
done
