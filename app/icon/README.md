# App icon

Put the icon here as `app/icon/AppIcon.png`: square, 1024x1024 pixels, PNG (transparency is fine;
macOS expects the rounded-rectangle shape to be part of the image, like other Mac icons).
`app/build.sh` turns it into `AppIcon.icns` (all sizes via sips + iconutil) and puts it in the
bundle; `scripts/package-app.sh` then ships it in the DMG. Without the PNG the app gets the
generic macOS icon.
