# Source code offer (LGPL)

Gamify ships a build of Wine and of libraries licensed under the GNU Lesser General Public
License (LGPL 2.1 or later, LGPL 3 for gmp and nettle). You are entitled to their complete
corresponding source code.

## What each release contains
Every release in this repository has a `Gamify-<version>-source.tar.gz` asset with:
- `src/patches/` — our changes to the Wine tree, as a diff over Wine 10.0 (LGPL 2.1 or later);
- `scripts/build-winecx-deps.sh`, `scripts/build-winecx.sh`, `scripts/build-winecx-full-deps.sh`,
  `scripts/build-winecx-full.sh`, `scripts/winecx-env.sh`, `scripts/package-app.sh` — the
  scripts that configure, build, install and package the Wine runtime and its libraries;
- `src/webhelper-shim/` — the Steam webhelper shim (our code);
- `src/steam-probe/` — the Steam licence check program behind Check Steam (our code);
- `docs/LICENSING.md` — the component list with versions and licenses.

## Upstream sources used
- Wine (CrossOver 25.1.0 source release, Wine 10.0 + CodeWeavers changes), plus GStreamer,
  MoltenVK and the libraries in its `sources/` tree:
  https://media.codeweavers.com/pub/crossover/source/crossover-sources-25.1.0.tar.gz
- gnutls 3.8.13: https://www.gnutls.org/download.html
- nettle 4.0: https://ftp.gnu.org/gnu/nettle/
- gmp 6.3.0: https://gmplib.org/download/gmp/
- FreeType, SDL2, libogg, libvorbis, libtheora, libffi, pcre2: the versions listed in
  docs/LICENSING.md, from their official release pages.

## Written offer
For at least three years after the last release that contains a given version, the
maintainer will provide the complete corresponding source of that release (the exact source
trees as built, with the build scripts), on request, at no charge beyond the cost of
transfer. Open an issue in this repository to ask for it.
