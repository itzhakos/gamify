# Licensing of Cross and everything it uses

Status 2026-10-16. Engineering notes, not legal advice; the points marked **unclear** need a
lawyer or a written answer from the rights holder before a paid release.

Apple's, CodeWeavers' and Valve's agreements are paraphrased here with section numbers
instead of being reproduced; the full texts are at the paths/URLs given and should be read
in the original before a release.

## Summary

| Component | License | Ship in a free build? | Ship in a paid build? | Plan |
|---|---|---|---|---|
| Wine (CrossOver 25.1.0 sources, our build `runtimes/winecx`) | LGPL-2.1-or-later | Yes, with source | Yes, with source | Publish our exact Wine source + build scripts + patches for every release |
| Libraries bundled inside the Wine tree (`libs/`: vkd3d, faudio, mpg123, fluidsynth, jpeg, png, zlib, lcms2, tiff, xml2, xslt, ldap, jxr, capstone, gsm, musl) | various permissive + LGPL | Yes | Yes | Covered by the Wine source release; list in notices |
| gmp 6.3.0 | LGPL-3.0+ or GPL-2.0+ (dual) | Yes, with source | Yes, with source | Ship as separate dylib, publish source |
| nettle 4.0 | LGPL-3.0+ or GPL-2.0+ (dual) | Yes, with source | Yes, with source | same |
| gnutls 3.8.13 (libgnutls, with included libtasn1 and libunistring) | LGPL-2.1+ (library) | Yes, with source | Yes, with source | same |
| FreeType 2.15.0 | FTL or GPL-2.0 (dual) | Yes | Yes | Use under FTL: credit line in docs/about box |
| GStreamer 1.24.2 (not built yet) | LGPL-2.1+ core; plugins vary | Yes, with source | Yes, with source | Ship only LGPL plugins; **unclear**: codec patents |
| SDL2 (not built yet) | zlib | Yes | Yes | Notice |
| MoltenVK (not built yet) | Apache-2.0 | Yes | Yes | LICENSE in notices |
| DXVK / vkd3d-proton / DXMT (if added) | zlib / LGPL-2.1 / MIT | Yes | Yes | Notices (+ source for LGPL) |
| Wine Mono 9.4.0 / Wine Gecko 2.47.4 | Mono: MIT + LGPL + MS-PL mix; Gecko: MPL-2.0 | Yes, or download on demand | Same | Let Wine download them from WineHQ, as upstream does |
| **Apple D3DMetal** (GPTK 3.0, `runtimes/d3dmetal`) | Apple GPTK license EA18380 | **Allowed, non-commercial only** | **No** | Free build may bundle (with notices); paid build: user installs GPTK, app extracts |
| **D3DMetal 2.1 from the CrossOver trial** (`runtimes/d3dmetal-2.1`) | CrossOver license (no redistribution) | **No** | **No** | **Local-only.** Never ship; obtain 2.1 from Apple if we need it |
| Steam client | Steam Subscriber Agreement | We never ship Steam | same | User installs Steam from Valve; shim risk below |
| Our code (cli/, scripts/, src/webhelper-shim, src/d3dtest, app) | proposed **MIT** | — | — | Wine patches stay LGPL-2.1+ |

## 1. Wine (CrossOver 25.1.0 sources)

- **Source used:** `upstream/crossover-sources-25.1.0/sources/wine`, from
  `https://media.codeweavers.com/pub/crossover/source/crossover-sources-25.1.0.tar.gz`
  (SHA-256 `85458dca285ff29eed9134c0d091a84648208ac2609eeb3baa9c71acd5af106b`).
  CodeWeavers' changes over Wine 10.0 are mapped in [codeweavers-patches.md](codeweavers-patches.md).
- **License:** LGPL 2.1 or later. Text: `sources/wine/LICENSE` (copyright notice + LGPL
  pointer) and `sources/wine/COPYING.LIB` (full LGPL 2.1). Contributors: `sources/wine/AUTHORS`.
  New CodeWeavers files carry LGPL 2.1+ headers too (e.g. `dlls/winemac.drv/d3dmetal.c`,
  copyright 2023 Brendan Shanks for CodeWeavers, LGPL 2.1+).
- **CodeWeavers' own permission:** CrossOver's `license.txt` §2
  (`downloads/crossover/CrossOver.app/Contents/SharedSupport/CrossOver/license.txt`) states
  that its FOSS components keep their own licenses, that their sources are at
  `https://www.codeweavers.com/crossover/source`, and that the CrossOver grant does not
  supersede those licenses. So the Wine sources in the tarball are usable under LGPL alone.
- **What LGPL 2.1 obliges us to do when we distribute our Wine binaries (free or paid; price
  does not matter):**
  1. Give recipients the complete corresponding source of the Wine we ship (§6). The easiest
     compliant form is §6(d): offer the source tarball for download from the same place as the
     app, for every release we publish, for as long as we distribute that binary. Alternative
     §6(c): a written offer valid three years. "Complete source" = the exact tree we built
     (CrossOver tarball + our changes) **and the scripts used to build it**
     (`scripts/build-winecx-deps.sh`, `scripts/build-winecx.sh`, the generated
     `programs/winedbg/distversion.h`); LGPL 2.1 §0 defines a library's complete source as
     including the scripts used to control its compilation and installation.
  2. Keep all copyright notices and give every recipient a copy of the LGPL (§1).
  3. Mark modified files with a notice and date of change (§2(b)) — easiest via a
     `PATCHES.md` / per-patch headers in `src/patches/`.
  4. Our own app/CLI only executes Wine as a separate program; it does not link against Wine.
     That is "mere aggregation", so the app's own license is free to choose. Anything that
     *does* modify Wine (patches, new DLLs built inside the Wine tree) is LGPL.
- **Branding:** our current build embeds CodeWeavers' identifiers
  (`loader/wine_info.plist.in`, CW Hack 10913: `com.codeweavers.CrossOver.wineloader`,
  "CrossOver-Hosted Application"; `strings runtimes/winecx/bin/wine` shows them), the Windows
  user name `crossover` (CW Hack 12735) and `$CX_ROOT/bin/cxntlm_auth` (13228). The LGPL
  allows shipping them, but "CrossOver" and "CodeWeavers" are their trademarks; a distributed
  Cross build should use its own bundle id and name. **Unclear** whether the user name
  `crossover` is a trademark problem; changing it is one line in `dlls/advapi32/advapi.c`.

### Libraries compiled into Wine (`sources/wine/libs/`)

These are built into PE DLLs and come with the Wine source release. Notices to copy into
THIRD_PARTY_NOTICES: `libs/vkd3d/COPYING` (LGPL 2.1), `libs/faudio/LICENSE` (zlib),
`libs/mpg123/LICENSE` (LGPL 2.1), `libs/fluidsynth/COPYING.md` (LGPL 2.1),
`libs/jpeg/LICENSE` (IJG: requires the "based in part on the work of the Independent JPEG
Group" credit), `libs/png/LICENSE`, `libs/zlib/LICENSE`, `libs/lcms2/COPYING` (MIT),
`libs/tiff/COPYRIGHT`, `libs/xml2/COPYING`, `libs/xslt/COPYING` (MIT),
`libs/ldap/LICENSE` (OpenLDAP Public License 2.8), `libs/jxr/LICENSE` (Microsoft BSD-style),
`libs/capstone/LICENSE.TXT` + `LICENSE_LLVM.TXT`, `libs/gsm/COPYRIGHT`, `libs/musl/COPYRIGHT`.
The PE side is built with Homebrew mingw-w64 16.2; any libgcc code linked in falls under the
GCC Runtime Library Exception (not checked which objects end up linked).

## 2. gmp, nettle, gnutls, FreeType (built into `runtimes/winecx/lib`)

| Library | Version / source used | License (and where the text is) | Obligations |
|---|---|---|---|
| gmp | 6.3.0, `upstream/crossover-sources-25.1.0/sources/gnutls/gmp` | Dual LGPLv3+ / GPLv2+: `gmp/README` lines 8-18, `COPYING.LESSERv3`, `COPYINGv2`, `COPYINGv3` | We choose LGPLv3: ship as a separate replaceable dylib (we do: `libgmp.10.dylib`), include LGPLv3 + GPLv3 texts, offer source. LGPLv3's "Installation Information" clause only applies to hardware ("User Products"), not to us. |
| nettle (+ hogweed) | 4.0, `upstream/nettle-src/nettle-4.0` (Homebrew release tarball) | Dual LGPLv3+ / GPLv2+: `README` lines 27-29, `COPYING.LESSERv3`, `COPYINGv2` | Same as gmp. |
| gnutls | 3.8.13, `upstream/gnutls-src/gnutls-3.8.13` | libgnutls LGPLv2.1+ (`README.md` "Licensing", `COPYING.LESSERv2`); tools GPLv3+ (we do not ship `src/` tools); README notes the gmp/nettle dual license | Ship dylib, LGPL text, source. Built with `--with-included-libtasn1` (LGPLv2.1+) and `--with-included-unistring` (LGPLv3+ or GPLv2+): both inside libgnutls, covered by the gnutls source release. |
| FreeType | 2.15.0, `upstream/freetype-src/freetype-2.15.0` | Dual FTL / GPLv2: `LICENSE.TXT`, `docs/FTL.TXT`, `docs/GPLv2.TXT` | Use under FTL (compatible with a closed app): FTL requires a credit in the documentation, e.g. "Portions of this software are copyright © <year> The FreeType Project (https://freetype.org). All rights reserved." CrossOver's license.txt Appendix A does the same. |

Code signing: if Cross.app ever enables library validation for the Wine processes, users can
no longer swap these dylibs. LGPL 2.1 §6(b) / LGPLv3 §4(d)(1) are satisfied by shipping
shared libraries the user can replace, so keep them replaceable (no library validation on
the Wine executables, or document how to re-sign).

## 3. GStreamer, SDL2, MoltenVK (not built yet; CrossOver ships them in `lib64/`)

- **GStreamer** 1.24.2 (`upstream/crossover-sources-25.1.0/sources/gstreamer`, `LICENSE` =
  LGPL 2.1; `meson.build` version 1.24.2). Core and -base/-good are LGPL; -ugly contains GPL
  elements; -bad is mixed; FFmpeg/libav wrappers are LGPL if FFmpeg is built without GPL
  parts. Plan: ship only LGPL plugins, list each in notices, publish source like Wine.
  **Unclear:** patent licensing for H.264/AAC decoders; Wine itself only needs them for
  mfplat/winegstreamer video playback. Decide when we build it.
- **SDL2**: zlib license (CrossOver's license.txt Appendix A lists SDL under zlib). There is no
  SDL source in the CrossOver tarball; we would fetch it from libsdl.org. zlib requires no
  notice in binaries, add one anyway.
- **MoltenVK**: Apache-2.0 (`sources/moltenvk/LICENSE`; no NOTICE file in that tree). Include
  the license text; state modifications if we patch it.
- Same for **DXVK** (`sources/dxvk/LICENSE`, zlib), **vkd3d** (`sources/vkd3d/COPYING`, LGPL
  2.1), **DXMT** (MIT, per CrossOver Appendix A) if we add them.

## 4. Wine Mono and Wine Gecko

- Our Wine expects Wine Mono **9.4.0** and Wine Gecko **2.47.4**
  (`dlls/appwiz.cpl/addons.c:47,59`). Bottle `cx` has Mono 9.4.0 installed
  (`bottles/cx/drive_c/windows/mono/`, `system.reg`) and Gecko (`system32/gecko`); they came
  with the prefix, not from anything we ship.
- **Wine Mono**: mixed licensing per `https://github.com/madewokherd/wine-mono/blob/master/COPYING`:
  Mono parts LGPL or MIT X11 (SharpZipLib GPL with exception), FNA MS-PL/MIT, SDL/FAudio zlib,
  winforms/wpf MIT, everything else MIT.
- **Wine Gecko**: a Gecko (Firefox engine) build, MPL-2.0 like upstream Mozilla code
  (source at `https://dl.winehq.org/wine/wine-gecko/`). **Not verified** against the LICENSE
  file inside the 2.47.4 tarball; check before bundling.
- **Plan:** do not bundle. Let Wine's `appwiz.cpl` download them from WineHQ on first prefix
  creation, as upstream Wine does. If we bundle later for offline installs, add their
  notices and a source pointer (MPL/LGPL require the source to be available).

## 5. Apple D3DMetal (Game Porting Toolkit)

### Where the license text is

- **On this Mac:** `/Applications/Game Porting Toolkit.app` is **Gcenx's Homebrew cask**
  (`brew install --cask gcenx/wine/game-porting-toolkit`, Info.plist `CFBundleIdentifier =
  org.winehq.wine-devel.wine`, version `3.0-3`), not Apple's DMG. It contains **no Apple
  license PDF**; the only license file is
  `Contents/Resources/wine/lib/external/D3DMetal.framework/Versions/A/Resources/LICENSE`, which
  is the xxHash BSD-2 notice (a third-party component of D3DMetal), not Apple's terms.
- **Apple's license, as shipped by Sikarugir** (read for this document):
  - `runtimes/sikarugir-template/Template-1.0.23.app/Contents/SharedSupport/renderer/d3dmetal/License.rtf`
    (D3DMetal 4.0b3; converted with `textutil`), with `Acknowledgements.rtf` next to it.
  - `https://github.com/Sikarugir-App/Sikarugir/tree/main/D3DMetal/{1.1,2.0,2.1,3.0,4.0}/License.pdf`
    (extracted with `pdftotext`). **All five PDFs have identical text**, titled "Apple Inc.
    Software License Agreement for Game Porting Toolkit", footer **EA18380, 8/17/2023**. The
    RTF in the Sikarugir template matches as well.
  - Apple's own copy is in the GPTK DMG ("Evaluation environment for Windows games 3.0") from
    `https://developer.apple.com/games/game-porting-toolkit/` (Apple Account sign-in). **Not
    checked here** (no DMG on this machine); the Sikarugir copies are assumed to be faithful.

### What the agreement says (paraphrased; EA18380)

- **§1 Definitions:** "Apple Software" is the whole toolkit; the **Framework** is
  `D3DMetal.framework`; the **Redistributables** are the components in the toolkit's `/redist`
  directory (that is `libd3dshared.dylib` and the `wine/x86_64-{unix,windows}` d3d DLLs/.so).
- **§2A License:** a limited, personal, non-transferable license to (i) install, use and test
  the software *only to develop, test or evaluate video games for Apple products*; (ii) let
  service providers do that for you; (iii) distribute it, in Apple's words,
  "solely for non-commercial purposes", in line with §2C. Every copy must keep Apple's
  copyright and proprietary notices.
- **§2C Other restrictions:** no use on non-Apple hardware; no renting, leasing, lending,
  hosting, **selling** or sublicensing; components may not be separated from the bundle for
  distribution, **except** that the Framework as a whole or any individual Redistributable may
  be distributed separately; all such distribution is still bound by the non-commercial rule
  of §2A(iii).
- **§2D:** no decompiling, reverse engineering, disassembling, modifying or creating
  derivative works of the Apple Software.
- **§5:** the license ends automatically on breach; then all copies must be destroyed.
- **§13:** open-source components are listed in the Acknowledgements file.

GPTK 3.0's Read Me (`https://github.com/Sikarugir-App/Sikarugir/blob/main/D3DMetal/3.0/Read%20Me.pdf`)
lists both free and commercial products that bundle the evaluation layers: Gcenx's Homebrew
casks and CodeWeavers' CrossOver. CrossOver is commercial, so CodeWeavers
presumably has a separate agreement with Apple. **Unclear**; nothing public says so, and the
EA18380 text gives no commercial right.

### Conclusion for Cross

- **Free, non-commercial Cross build:** may bundle D3DMetal (the whole `D3DMetal.framework`
  plus the Redistributables), as Gcenx, Sikarugir and Whisky do, provided we keep Apple's
  notices (ship `License.pdf` + `Acknowledgements.pdf` and the framework's own `LICENSE`),
  do not modify the binaries, and do not charge. **Unclear:** "non-commercial" is not defined;
  donations, sponsorships, ads or a paid "pro" tier next to a free build could each be read as
  commercial. Also **unclear:** §2A(i) only licenses *use* for developing/testing/evaluating
  games; end users simply playing games sit outside the literal grant, for every project that
  ships D3DMetal (Apple's Read Me points end users at those projects anyway).
- **Paid Cross build (or any doubt):** must **not** contain D3DMetal. The user downloads GPTK
  from Apple themselves (accepting Apple's license), and Cross copies the files out of it on
  the user's machine. That is the safe pattern; copying from the user's own licensed install
  into the user's own Application Support is not distribution by us.
- **What other projects did (checked in their sources):**
  - Whisky (`https://github.com/Whisky-App/Whisky`, GPL-3.0, archived): the final version
    downloads a prebuilt `https://data.getwhisky.app/Wine/Libraries.tar.gz`
    (`Whisky/Views/Setup/WhiskyWineDownloadView.swift:68`) and the README credits "D3DMetal by
    Apple", i.e. Whisky (free) redistributed D3DMetal itself. Earlier Whisky versions that
    reportedly had users install GPTK themselves were not checked. The tarball was not
    downloaded to confirm its contents.
  - Sikarugir/Kegworks: ships D3DMetal 4.0b3 in its Template with License/Acknowledgements
    RTFs; its README warns that D3DMetal's license rules out commercial ports and links the
    License.pdf.
  - Gcenx's `game-porting-toolkit` cask: redistributes Apple's redist inside a Wine build.
- **Our runtimes:** `runtimes/d3dmetal` (3.0) came from Gcenx's cask, i.e. from a
  non-commercial redistribution under EA18380; we hold it under the same terms. Caution under
  §2D: inspecting it with `strings`/`nm` is borderline; never patch or disassemble it.

### Extraction plan (paid build, or "bring your own GPTK" in any build)

Sources Cross can import from, in order of preference:

1. **Apple's DMG** (what the user downloads from developer.apple.com). Per Apple's GPTK 3.0
   Read Me, the volume is `/Volumes/Evaluation environment for Windows games 3.0/` and the
   files are under `redist/lib/`, with subdirectories `external/` and `wine/` (the Read Me tells
   CrossOver users to `ditto ".../redist/lib/" .` into
   `CrossOver.app/Contents/SharedSupport/CrossOver/lib64/apple_gptk`). Not verified on a real
   DMG here.
2. **Gcenx's cask** at `/Applications/Game Porting Toolkit.app/Contents/Resources/wine/lib/`
   (present on this Mac, D3DMetal 3.0, `version.plist` CFBundleShortVersionString 3.0):
   - `external/D3DMetal.framework` (whole framework, including
     `Versions/A/Resources/{default.metallib,libdxcompiler.dylib,libdxilconv.dylib,libdxccontainer.dylib,libmetalirconverter.dylib,LICENSE}`)
   - `external/libd3dshared.dylib`
   - `wine/x86_64-unix/{d3d10,d3d11,d3d12,dxgi,atidxx64,nvapi64,nvngx,nvngx-on-metalfx}.so`,
     all symlinks to `../../external/libd3dshared.dylib`
   - `wine/x86_64-windows/{d3d10,d3d10_1,d3d10core,d3d11,d3d12,dxgi,atidxx64,nvapi64,nvngx-on-metalfx}.dll`
     (the same directory also holds the cask's own Wine DLLs, so copy only these names).
3. **CrossOver** at `/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64/apple_gptk/{external,wine}` —
   only as a technical fallback for the user's own machine; see §6 below.

The importer copies into `~/Library/Application Support/Cross/d3dmetal/<version>/` with the
layout winecx expects (`x86_64-unix/`, `x86_64-windows/`, framework next to libd3dshared),
recreates the symlinks instead of duplicating 96 KB files, records the version from
`D3DMetal.framework/Versions/A/Resources/version.plist`, and leaves Apple's `LICENSE`/PDFs in
place. Note: our Wine currently works only with D3DMetal **2.1**
(see codeweavers-patches.md, `d3dmetal.c`); with only GPTK 3.0 importable, a release needs the
newer `winemac.drv` hook table first.

## 6. D3DMetal 2.1 copied from the CrossOver trial (`runtimes/d3dmetal-2.1`)

- Source: `downloads/crossover/CrossOver.app/Contents/SharedSupport/CrossOver/lib64/apple_gptk/`
  of the CrossOver 25.1.0 **trial**.
- That copy reached us under CrossOver's license (`license.txt`): §1 grants use by one person,
  §3(b) forbids renting, lending, **distributing** or creating derivative works of the
  Software except as the FOSS licenses of §2 allow, and §3(a) forbids reverse engineering.
  D3DMetal is Apple's, not FOSS, and is not mentioned in CrossOver's Appendix A. So we have no
  right to redistribute this copy, free or paid, and the trial period limits even local use.
- **Decision: `runtimes/d3dmetal-2.1` is local-only.** It must never be committed, packaged,
  uploaded or offered for download (`runtimes/` is git-ignored already). Same for anything else
  taken from `downloads/crossover/` (cxcompatdb.so, CrossOver's binaries).
- If a release needs D3DMetal 2.1, get it from Apple's GPTK 2.1 DMG (if Apple still offers it)
  under EA18380 and compare hashes with our copy. **Unverified** whether Apple's 2.1 redist
  is byte-identical to CrossOver's.

## 7. Steam / Valve

- We do not ship any Valve code. The user downloads `SteamSetup.exe` from Valve and installs
  Steam inside a bottle; `downloads/steam/SteamSetup.exe` stays local.
- `src/webhelper-shim/steamwebhelper-shim.c` (81 lines) is **our own code**: it contains no
  Valve code and only re-launches Valve's renamed binary with extra Chromium flags. The idea
  follows `github.com/notpop/steam-on-m1-wine` (MIT); no code was copied from it (if any is,
  keep its MIT notice).
- The Steam Subscriber Agreement (`https://store.steampowered.com/subscriber_agreement/`,
  revision of September 10, 2026, fetched today) is relevant in two places:
  - **§2.G** (restrictions): without Valve's written consent you may not copy, reverse
    engineer, **modify** or create derivative works of the Content and Services or any
    software accessed via Steam.
  - **§4.B** (cheating): you agree not to tamper with the execution of Steam unless Valve
    authorizes it, and not to use unauthorized third-party software to modify how you interact
    with or control Steam's processes or user interface, except as expressly permitted.
  Renaming `steamwebhelper.exe`, putting our shim in its place and starting Steam with
  `-noverifyfiles` so Steam does not restore it is, read literally, a modification of
  Steam's installation and its execution. The agreement binds the **user**, not Cross; the
  realistic risk is to the user's account, not a copyright claim against us (no Valve code is
  copied or distributed). **Unclear:** whether Valve would ever object; it does not act against
  Wine/Proton/CrossOver users, but those do not replace Steam binaries.
- **Plan:** (1) keep the shim optional and off by default in a release, with a clear note that
  it modifies the user's Steam install; (2) prefer a fix that needs no Steam modification: the
  CrossOver trial renders Valve's unmodified webhelper on this Mac (NOTES.md), so the black
  window is a Wine-side bug we can fix in winecx; (3) never touch Steam's anti-cheat or DRM.

## 8. Our own code

- Today there is **no license file** in the project (no `LICENSE` at the root, in `cli/` or in
  `src/`).
- **Proposal: MIT** for everything we write that is not part of Wine: `cli/`, `scripts/`,
  `src/webhelper-shim/`, `src/d3dtest/`, and the future SwiftUI app. Reasons: it keeps a paid
  app possible (MIT code can be relicensed into a closed product by its owner), it is
  compatible with distributing alongside LGPL/GPL/Apache components, the shim's model project
  (notpop) is MIT, and it costs contributors nothing. The trade-off is that anyone may fork
  Cross commercially; if that matters more than adoption, GPL-3.0 (Whisky's choice) or keeping
  the app closed are the alternatives, and that is the owner's decision.
- **Exception:** changes to Wine itself (anything in `src/patches/` that is applied to the
  Wine tree, files added to the Wine build) are **LGPL-2.1-or-later**, because they are
  modifications of Wine. Label them as such.
- Copyright line: the project owner's name, since the owner holds the copyright in this code.

## 9. What every release must contain

1. `LICENSE` (MIT, our code) at the top of the app bundle and the source repository.
2. `THIRD_PARTY_NOTICES` (text or HTML, inside the app and on the download page), with, for
   each shipped component: name, version, upstream URL, license name and the full license text:
   Wine (LGPL 2.1 + AUTHORS pointer), every `libs/` library listed in §1, gmp, nettle, gnutls
   (+ libtasn1, libunistring), FreeType (FTL credit), and later GStreamer, SDL2, MoltenVK,
   DXVK/vkd3d/DXMT. Plus the "CrossOver" lineage statement: "Wine sources from CodeWeavers'
   CrossOver 25.1.0 source release, LGPL 2.1".
3. **Source offer / source archive** for every LGPL/GPL component, for that exact release:
   a tarball (or tagged git repo) with the Wine tree as built, our patches, the dependency
   sources (gmp, nettle, gnutls, freetype, ...), and our build scripts, offered from the same
   download page (LGPL 2.1 §6(d)); state in the app's About box where it is.
4. A list of our modifications to Wine (`src/patches/` + a short PATCHES.md), satisfying LGPL
   §2(b).
5. Rebranded loader Info.plist (no `com.codeweavers.*`, no "CrossOver-Hosted Application").
6. **Free build only:** D3DMetal with Apple's `License.pdf`, `Acknowledgements.pdf`, the
   framework's `LICENSE`, and a sentence that D3DMetal is Apple's, licensed for non-commercial
   use only. **Paid build:** no Apple files at all; a GPTK import step instead (§5).
7. Never: `runtimes/d3dmetal-2.1`, anything from `downloads/crossover/`, Steam files, Wine
   Mono/Gecko unless their notices and sources are added.

## Sources consulted

- `upstream/crossover-sources-25.1.0/sources/wine/{LICENSE,COPYING.LIB,AUTHORS}`, `libs/*/`
  license files, `dlls/appwiz.cpl/addons.c`
- `upstream/crossover-sources-25.1.0/sources/{gnutls/gmp/README,gstreamer/LICENSE,moltenvk/LICENSE,dxvk/LICENSE,vkd3d/COPYING}`
- `upstream/gnutls-src/gnutls-3.8.13/README.md`, `upstream/nettle-src/nettle-4.0/README`,
  `upstream/freetype-src/freetype-2.15.0/{LICENSE.TXT,docs/FTL.TXT}`
- `downloads/crossover/CrossOver.app/Contents/SharedSupport/CrossOver/license.txt`,
  `downloads/crossover/CrossOver.app/Contents/Resources/ThirdPartyLicenses.txt` (does not
  mention D3DMetal or Apple)
- `/Applications/Game Porting Toolkit.app` (Gcenx cask 3.0-3)
- `runtimes/sikarugir-template/.../renderer/d3dmetal/{License.rtf,Acknowledgements.rtf}`
- `https://github.com/Sikarugir-App/Sikarugir/tree/main/D3DMetal` (License.pdf 1.1-4.0,
  Read Me.pdf 3.0), Sikarugir README
- `https://github.com/Whisky-App/Whisky` (cloned, final source)
- `https://github.com/madewokherd/wine-mono/blob/master/COPYING`
- `https://store.steampowered.com/subscriber_agreement/` (revision 2026-09-10)
