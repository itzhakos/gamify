# Gamify releases

Downloads for **Gamify**, a macOS app (Apple Silicon) for running Windows games, built on a
CrossOver-lineage Wine 10.0 and Apple's D3DMetal. This repository holds only the release files;
the source code lives in a separate repository.

## Install

1. Download `Gamify-<version>.dmg` from the [latest release](https://github.com/itzhakos/gamify-releases/releases/latest).
2. Open it and drag **Gamify** to **Applications**.
3. The app is not notarized, so macOS blocks the first launch. Either run
   `xattr -dr com.apple.quarantine /Applications/Gamify.app` in Terminal, or open it once,
   then click **Open Anyway** in System Settings > Privacy & Security.

Requirements: Apple Silicon, macOS 14 or later, Rosetta 2 (the app's first-run tutorial installs it).

## Updates

The app checks this repository on launch and updates itself (Settings > General can turn that
off). It fetches `releases/latest/download/latest.json` and, when you click Install, one of the
release assets. Nothing else is sent: no analytics, no identifiers.

| Asset | What |
|---|---|
| `Gamify-<version>.dmg` | the full app |
| `Gamify-app-<version>.zip` | the app without its Wine runtime (used by the updater when the runtime did not change) |
| `Gamify-<version>-source.tar.gz` | our Wine patches and build scripts (see [SOURCE_OFFER.md](SOURCE_OFFER.md)) |
| `latest.json` | the update manifest: version, required runtime, asset sizes and SHA-256 |

## Terms

Free, for non-commercial use only: the app contains Apple's D3DMetal, which Apple licenses for
non-commercial redistribution. Do not sell it or bundle it with paid products.
Third-party components and their licenses: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
(also inside the app, Contents/SharedSupport/root/THIRD_PARTY_NOTICES.md).
