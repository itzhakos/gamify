# Gamify

Run Windows games on an Apple Silicon Mac. Gamify (project folder: Cross) wraps our own build of CrossOver-lineage
Wine 10.0 with Apple's D3DMetal (DirectX 11/12 to Metal) in a small macOS app: create a
bottle, install Steam with one click, launch games.

- Users: open `Gamify-<version>.dmg`, drag Gamify to Applications, right-click > Open the first time
  (the build is not notarized yet), follow the tutorial. Rosetta 2 is required; the tutorial
  installs it.
- Developers: `NOTES.md` (current state + the whole log), `docs/app.md` (GUI),
  `docs/packaging.md` (installer), `docs/runtime-full.md` (building the runtime),
  `docs/LICENSING.md` (what may be shipped). Build the CLI with `cd cli && swift build -c
  release`, the app with `app/build.sh`, the installer with `scripts/package-app.sh`.

Free and non-commercial while it bundles Apple's D3DMetal (see docs/LICENSING.md).

## License

Our own code (`app/`, `cli/`, `scripts/`, `src/` except `src/patches/`) is MIT, see `LICENSE`.
The patches in `src/patches/` modify Wine and are LGPL-2.1-or-later, like Wine itself.
Wine, its libraries and Apple's D3DMetal keep their own licenses (docs/LICENSING.md); none of
them are in this repository.
