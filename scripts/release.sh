#!/bin/bash
# Builds and publishes a Gamify release to the public feed (docs/updates.md).
#
#   scripts/release.sh 0.2               bump, package, commit + tag + push, publish
#   scripts/release.sh 0.2 --draft       same, but the GitHub release stays a draft
#   scripts/release.sh 0.2 --local       build the release files only (dist/release-0.2):
#                                        no git, no upload, app/Info.plist restored afterwards
#
# Environment:
#   RELEASE_NOTES="..."        release notes (default: a short install note)
#   RELEASE_URL_BASE=<url>     asset URL prefix written into latest.json (default: the
#                              GitHub release download URL; for local tests e.g.
#                              http://127.0.0.1:8765/0.2)
#   RELEASE_ALLOW_DIRTY=1      allow uncommitted changes under app/ cli/ scripts/ src/
#   CROSS_RUNTIME=winecx       passed through to package-app.sh
#
# Output in dist/release-<ver>/: Gamify-<ver>.dmg, Gamify-app-<ver>.zip,
# Gamify-<ver>-source.tar.gz, latest.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO=itzhakos/gamify-releases
FEED="https://github.com/$REPO/releases/latest/download/latest.json"
PLIST="$ROOT/app/Info.plist"

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 1 ] || usage
VERSION="$1"; shift
MODE=publish; DRAFT=""
for arg in "$@"; do
  case "$arg" in
    --draft) DRAFT=--draft ;;
    --local) MODE=local ;;
    *) usage ;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "version must look like 0.2 or 1.0.3"; exit 2; }
TAG="v$VERSION"
OUT="$ROOT/dist/release-$VERSION"
URL_BASE="${RELEASE_URL_BASE:-https://github.com/$REPO/releases/download/$TAG}"

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
newer() {  # newer A B: A > B, numerically per dotted part
  python3 -I -c 'import sys
p=lambda v:[int(x) for x in v.lstrip("v").split(".")]
a,b=p(sys.argv[1]),p(sys.argv[2]); n=max(len(a),len(b)); a+=[0]*(n-len(a)); b+=[0]*(n-len(b))
sys.exit(0 if a>b else 1)' "$1" "$2"
}
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }

log "checks"
cd "$ROOT"
if [ "$MODE" = publish ]; then
  gh auth status >/dev/null 2>&1 || { echo "gh is not logged in"; exit 1; }
  gh repo view "$REPO" >/dev/null 2>&1 || { echo "$REPO does not exist (gh repo create $REPO --public)"; exit 1; }
  if [ -z "${RELEASE_ALLOW_DIRTY:-}" ] && [ -n "$(git status --porcelain -- app cli scripts src)" ]; then
    git status --short -- app cli scripts src
    echo "uncommitted changes under app/ cli/ scripts/ src/ would be built but not tagged (RELEASE_ALLOW_DIRTY=1 overrides)"
    exit 1
  fi
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "tag $TAG exists already"; exit 1; }
  PUBLISHED="$(curl -fsSL "$FEED" 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null || true)"
  if [ -n "$PUBLISHED" ] && ! newer "$VERSION" "$PUBLISHED"; then
    echo "$VERSION is not newer than the published $PUBLISHED"; exit 1
  fi
  echo "published now: ${PUBLISHED:-nothing}"
fi

log "app/Info.plist -> $VERSION"
mkdir -p "$ROOT/dist"
cp "$PLIST" "$ROOT/dist/.Info.plist.before-release"
COMMITTED=0
# --local, or a failure before the release commit: put app/Info.plist back
restore_plist() {
  if [ "$MODE" = local ] || [ "$COMMITTED" = 0 ]; then cp "$ROOT/dist/.Info.plist.before-release" "$PLIST"; fi
  rm -f "$ROOT/dist/.Info.plist.before-release"
}
trap restore_plist EXIT
BUILD=$(( $(pb 'Print :CFBundleVersion') + 1 ))
pb "Set :CFBundleShortVersionString $VERSION"
pb "Set :CFBundleVersion $BUILD"

log "package (scripts/package-app.sh)"
"$ROOT/scripts/package-app.sh"
# copy out right away: other sessions may run package-app.sh again
rm -rf "$OUT"; mkdir -p "$OUT"
STAGED="$OUT/Gamify.app"
ditto "$ROOT/dist/stage/Gamify.app" "$STAGED"
mv "$ROOT/dist/Gamify-$VERSION.dmg" "$OUT/Gamify-$VERSION.dmg"
GOT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGED/Contents/Info.plist")"
[ "$GOT" = "$VERSION" ] || { echo "the staged app says $GOT, expected $VERSION (did another package-app.sh run interfere?)"; exit 1; }
RUNTIME_VERSION="$(cat "$STAGED/Contents/SharedSupport/root/runtime-version")"

log "app layer zip"
# Contents/MacOS, Resources, Info.plist, PkgInfo + the loose text files of the root
# (everything the runtime-version digest does not cover).
LAYER="$OUT/layer/Contents"
mkdir -p "$LAYER/SharedSupport/root/scripts"
ditto "$STAGED/Contents/MacOS" "$LAYER/MacOS"
ditto "$STAGED/Contents/Resources" "$LAYER/Resources"
cp "$STAGED/Contents/Info.plist" "$STAGED/Contents/PkgInfo" "$LAYER/"
cp "$STAGED/Contents/SharedSupport/root/THIRD_PARTY_NOTICES.md" "$LAYER/SharedSupport/root/"
cp "$STAGED/Contents/SharedSupport/root/scripts/winecx-env.sh" "$LAYER/SharedSupport/root/scripts/"
ditto -c -k --norsrc --noextattr --keepParent "$LAYER" "$OUT/Gamify-app-$VERSION.zip"
rm -rf "$OUT/layer"

if [ "$MODE" = publish ]; then
  log "commit + tag $TAG"
  git commit -q -m "Release $VERSION" -- app/Info.plist
  git tag -a "$TAG" -m "Gamify $VERSION"
  COMMITTED=1
fi

log "source archive"
# LGPL source offer (SOURCE_OFFER.md): our Wine patches, build scripts, shim source.
SRC_REF=HEAD; [ "$MODE" = publish ] && SRC_REF="$TAG"
git archive --format=tar.gz --prefix="gamify-$VERSION-source/" -o "$OUT/Gamify-$VERSION-source.tar.gz" "$SRC_REF" \
  src/patches src/webhelper-shim/Makefile src/webhelper-shim/steamwebhelper-shim.c \
  scripts/build-winecx-deps.sh scripts/build-winecx.sh scripts/build-winecx-full-deps.sh \
  scripts/build-winecx-full.sh scripts/winecx-env.sh scripts/package-app.sh docs/LICENSING.md

log "latest.json"
python3 -I - "$OUT" "$VERSION" "$BUILD" "$RUNTIME_VERSION" "$URL_BASE" "https://github.com/$REPO/releases/tag/$TAG" \
  "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$STAGED/Contents/Info.plist")" <<'PY'
import datetime, hashlib, json, os, sys
out, version, build, runtime, base, notes, minos = sys.argv[1:8]
def asset(name):
    p = os.path.join(out, name)
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 22), b""): h.update(chunk)
    return {"url": f"{base}/{name}", "size": os.path.getsize(p), "sha256": h.hexdigest()}
manifest = {
    "schema": 1,
    "version": version,
    "build": build,
    "published": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "minimumSystemVersion": minos,
    "runtimeVersion": runtime,
    "notesURL": notes,
    "app": asset(f"Gamify-app-{version}.zip"),
    "full": asset(f"Gamify-{version}.dmg"),
}
with open(os.path.join(out, "latest.json"), "w") as f:
    json.dump(manifest, f, indent=2); f.write("\n")
print(json.dumps(manifest, indent=2))
PY
rm -rf "$STAGED"

if [ "$MODE" = local ]; then
  ls -la "$OUT"
  echo "local build done (app/Info.plist restored): $OUT"
  exit 0
fi

log "push to origin (private)"
git push -q origin HEAD:main
git push -q origin "$TAG"

log "sync $REPO files"
PUB="$ROOT/dist/gamify-releases"
if [ -d "$PUB/.git" ]; then git -C "$PUB" pull -q --ff-only; else git clone -q "https://github.com/$REPO.git" "$PUB"; fi
cp "$ROOT/scripts/releases-repo/README.md" "$ROOT/scripts/releases-repo/SOURCE_OFFER.md" "$PUB/"
cp "$ROOT/docs/LICENSING.md" "$PUB/THIRD_PARTY_NOTICES.md"
if [ -n "$(git -C "$PUB" status --porcelain)" ]; then
  git -C "$PUB" add -A
  git -C "$PUB" commit -q -m "Files for Gamify $VERSION"
  git -C "$PUB" push -q origin HEAD
fi

log "GitHub release $TAG on $REPO"
NOTES="${RELEASE_NOTES:-Gamify $VERSION.

Install: download Gamify-$VERSION.dmg, drag Gamify to Applications, then run \`xattr -dr com.apple.quarantine /Applications/Gamify.app\` once (the app is not notarized). Installed copies update themselves.}"
gh release create "$TAG" --repo "$REPO" --title "Gamify $VERSION" --notes "$NOTES" $DRAFT \
  "$OUT/Gamify-$VERSION.dmg" "$OUT/Gamify-app-$VERSION.zip" "$OUT/Gamify-$VERSION-source.tar.gz" "$OUT/latest.json"
echo "published: https://github.com/$REPO/releases/tag/$TAG"
