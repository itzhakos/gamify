#!/bin/sh
# Builds the Gamify GUI into app/build/Gamify.app (no Xcode project needed).
#   app/build.sh            release build
#   app/build.sh debug      debug build
# The app finds the Cross checkout by walking up from its own location, so keep the
# bundle inside this repo (or set the root in Settings > Paths).
set -eu
cd "$(dirname "$0")"
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product CrossApp
BIN="$(swift build -c "$CONFIG" --show-bin-path)/CrossApp"
APP=build/Gamify.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CrossApp"
cp Info.plist "$APP/Contents/Info.plist"
# App icon: icon/AppIcon.png (1024x1024) -> Contents/Resources/AppIcon.icns (see icon/README.md)
if [ -f icon/AppIcon.png ]; then
  ./make-icon.sh icon/AppIcon.png build/AppIcon.icns
  cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "note: no app/icon/AppIcon.png, the app keeps the generic icon"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Ad-hoc signature, but with a designated requirement that does not pin the cdhash:
# TCC (the "access files in your Desktop folder" prompt, since the checkout lives on
# ~/Desktop) keys its grant on this requirement, so a rebuild keeps the permission.
# CROSS_SIGN_IDENTITY=<codesigning identity> signs with a real certificate instead.
if [ -n "${CROSS_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$CROSS_SIGN_IDENTITY" "$APP" >/dev/null
else
  codesign --force --sign - -r='designated => identifier "local.gamify.app"' "$APP" >/dev/null
fi
echo "built $(pwd)/$APP"
