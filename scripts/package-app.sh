#!/bin/bash
# Packages Gamify as a self-contained, installable app:
#   dist/stage/Gamify.app   the bundle (app + one runtime + D3DMetal + webhelper shim)
#   dist/Gamify.dmg         drag-to-Applications disk image
#
#   scripts/package-app.sh                 # bundles runtimes/winecx-full
#   CROSS_RUNTIME=winecx scripts/package-app.sh
#
# Layout inside the bundle (CrossCore's Project.locate finds it from the executable):
#   Gamify.app/Contents/SharedSupport/root/runtimes/<runtime>   our Wine build, relocated
#   Gamify.app/Contents/SharedSupport/root/runtimes/d3dmetal    Apple D3DMetal 3.0 + its notices
#   Gamify.app/Contents/SharedSupport/root/src/webhelper-shim/steamwebhelper.exe
#   Gamify.app/Contents/SharedSupport/root/THIRD_PARTY_NOTICES.md
# Bottles and downloads of a bundled app live in ~/Library/Application Support/Gamify.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="${CROSS_RUNTIME:-winecx-full}"
DIST="$ROOT/dist"
STAGE="$DIST/stage"
APP="$STAGE/Gamify.app"
R="$APP/Contents/SharedSupport/root"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/app/Info.plist")"

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }

[ -d "$ROOT/runtimes/$RUNTIME/lib/wine" ] || { echo "runtime $RUNTIME not built (runtimes/$RUNTIME)"; exit 1; }
[ -d "$ROOT/runtimes/d3dmetal/x86_64-unix" ] || { echo "runtimes/d3dmetal missing"; exit 1; }

log "webhelper shim"
[ -f "$ROOT/src/webhelper-shim/steamwebhelper.exe" ] || make -C "$ROOT/src/webhelper-shim"

log "building the app"
"$ROOT/app/build.sh"

log "staging"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$ROOT/app/build/Gamify.app" "$APP"      # first, so the root dirs below land inside it
mkdir -p "$R/runtimes" "$R/src/webhelper-shim" "$R/scripts"
# -R keeps symlinks (the D3DMetal .so files and wineloader must stay symlinks)
cp -R "$ROOT/runtimes/$RUNTIME" "$R/runtimes/$RUNTIME"
cp -R "$ROOT/runtimes/d3dmetal" "$R/runtimes/d3dmetal"
cp "$ROOT/src/webhelper-shim/steamwebhelper.exe" "$R/src/webhelper-shim/"
cp "$ROOT/scripts/winecx-env.sh" "$R/scripts/"        # Project.looksLikeRoot wants runtimes/ + scripts/
cp "$ROOT/docs/LICENSING.md" "$R/THIRD_PARTY_NOTICES.md"
# nothing from the build trees, headers or static libs is needed at runtime
rm -rf "$R/runtimes/$RUNTIME/include" "$R/runtimes/$RUNTIME/lib/pkgconfig" "$R/runtimes/$RUNTIME/share/man" \
       "$R/runtimes/$RUNTIME/lib/gstreamer-1.0/include"
find "$R/runtimes/$RUNTIME/lib" -name '*.a' -delete -o -name '*.la' -delete

log "relocating install names (absolute checkout paths -> @loader_path)"
# The x86_64 dylibs were built with absolute install names into the checkout. Rewrite
# every reference to <checkout>/runtimes/<runtime>/lib/... as a path relative to the
# referencing file, so the bundle works wherever it is copied. No new load commands are
# added (no headerpad needed): -change and -id only.
python3 -I - "$ROOT/runtimes/$RUNTIME" "$R/runtimes/$RUNTIME" <<'PY'
import os, subprocess, sys
src_root, dst_root = sys.argv[1], sys.argv[2]
src_lib = os.path.join(src_root, "lib")
def machos():
    for base in ("bin", "lib", "libexec"):
        for dp, dn, fn in os.walk(os.path.join(dst_root, base)):
            for f in fn:
                p = os.path.join(dp, f)
                if os.path.islink(p): continue
                with open(p, "rb") as fh: magic = fh.read(4)
                if magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf"):
                    yield p
changed = 0
for p in machos():
    out = subprocess.run(["otool", "-L", p], capture_output=True, text=True).stdout.splitlines()[1:]
    deps = [l.split()[0] for l in out if l.strip()]
    args = []
    for d in deps:
        if d.startswith(src_lib + "/"):
            target = os.path.join(dst_root, "lib", d[len(src_lib) + 1:])
            rel = os.path.relpath(target, os.path.dirname(p))
            args += ["-change", d, "@loader_path/" + rel]
    ident = subprocess.run(["otool", "-D", p], capture_output=True, text=True).stdout.splitlines()
    if len(ident) > 1 and ident[1].startswith(src_lib + "/"):
        args += ["-id", "@rpath/" + ident[1][len(src_lib) + 1:]]
    if args:
        subprocess.run(["install_name_tool"] + args + [p], check=True, capture_output=True)
        changed += 1
print(f"relocated {changed} Mach-O files")
# verify: nothing may still point into the checkout
left = []
for p in machos():
    for l in subprocess.run(["otool", "-L", p], capture_output=True, text=True).stdout.splitlines()[1:]:
        if src_root in l: left.append((p, l.strip()))
if left:
    for p, l in left[:10]: print("STILL ABSOLUTE:", p, l)
    sys.exit(1)
PY
grep -rl "$ROOT" "$R/runtimes/$RUNTIME/lib/gstreamer-1.0" 2>/dev/null | head -3 || true

log "signing (ad-hoc; set CROSS_SIGN_IDENTITY for a Developer ID)"
IDENTITY="${CROSS_SIGN_IDENTITY:--}"
# install_name_tool invalidated the signatures of the relocated files: sign every Mach-O
# inside the root first, then the app itself (same designated requirement as app/build.sh,
# so the TCC grant survives rebuilds).
find "$R" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0 | while IFS= read -r -d '' f; do
  if head -c 4 "$f" | grep -q $'\xcf\xfa\xed\xfe'; then codesign --force --sign "$IDENTITY" "$f" 2>/dev/null || true; fi
done
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - -r='designated => identifier "local.gamify.app"' "$APP"
else
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
fi

log "disk image"
ln -sfn /Applications "$STAGE/Applications"
rm -f "$DIST/Gamify-$VERSION.dmg"
hdiutil create -quiet -volname "Gamify $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/Gamify-$VERSION.dmg"
rm -f "$STAGE/Applications"
du -sh "$APP" "$DIST/Gamify-$VERSION.dmg"
echo "done: $APP and $DIST/Gamify-$VERSION.dmg"
