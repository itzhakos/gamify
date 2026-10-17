#!/bin/bash
# Build the x86_64 (Rosetta) native dependencies of the *full* CrossOver-lineage
# Wine runtime (runtimes/winecx-full): everything scripts/build-winecx-deps.sh
# builds for runtimes/winecx (gmp, nettle, gnutls, freetype) PLUS
#   glib (+ gobject/gmodule/gio)  -> gstreamer core + base/good/bad/ugly plugins
#                                    (winegstreamer: video playback, mfplat, quartz)
#   SDL2                          -> winebus joystick backend
#   MoltenVK                      -> winevulkan (Vulkan for DXVK/DXMT later)
# with the arm64 host clang generating x86_64 code (-arch x86_64). Homebrew no
# longer publishes x86_64 bottles for macOS 27 and /usr/local needs sudo, so an
# x86_64 Homebrew is not an option on this machine. meson/ninja/cmake/python from
# arm64 Homebrew are host tools only; every library produced is x86_64.
#
# Everything installs into runtimes/winecx-full (same prefix as Wine itself), so
# the dylib install names are absolute; scripts/winecx-env.sh adds
# DYLD_FALLBACK_LIBRARY_PATH anyway (Wine dlopens gnutls/SDL2/MoltenVK by leaf name).
#
# Sources: crossover-sources-25.1.0 where it is complete (gmp, glib 2.78.0,
# gstreamer 1.24.2 monorepo), release tarballs from `brew fetch -s`
# (sha256-checked by Homebrew) for the rest, incl. MoltenVK 1.4.2 (section 5
# says why not CrossOver's 1.2.10), unpacked into upstream/<name>-src/. SDL2: Homebrew's `sdl2` is now sdl2-compat
# (needs SDL3), so the real SDL2 2.32.10 release is fetched from GitHub and
# checked against the sha256 Homebrew recorded for it.
#
# Logs and build trees: build/x86_64-full/<dep>/, step timings in times.log.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/upstream/crossover-sources-25.1.0/sources"
PREFIX="$ROOT/runtimes/winecx-full"
BUILD="$ROOT/build/x86_64-full"
SDK="$(xcrun --show-sdk-path)"
JOBS="$(sysctl -n hw.ncpu)"
mkdir -p "$PREFIX/lib/pkgconfig" "$BUILD"

export CC="/usr/bin/clang -arch x86_64"
export CXX="/usr/bin/clang++ -arch x86_64"
export CFLAGS="-O2"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"
export PKG_CONFIG="/opt/homebrew/bin/pkg-config"
# Only our own x86_64 libs and the SDK: never let arm64 Homebrew libs leak in.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$SDK/usr/lib/pkgconfig"
export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
HOST=x86_64-apple-darwin

step() { echo "=== $(date '+%H:%M:%S') $*"; STEP_NAME="$1"; STEP_START=$SECONDS; }
done_step() { echo "$STEP_NAME $((SECONDS-STEP_START)) s" >> "$BUILD/times.log"; }

# unpack <name> <tarball>: unpack once into upstream/<name>-src/, print the source dir
unpack() {
  local dir="$ROOT/upstream/$1-src"
  if ! ls -d "$dir"/*/ > /dev/null 2>&1; then mkdir -p "$dir"; tar -xf "$2" -C "$dir"; fi
  ls -d "$dir"/*/ | head -1 | sed 's|/$||'
}
# brew_src <formula>: release tarball of a formula, fetched + sha256-checked by Homebrew
brew_src() { brew fetch -s "$1" > /dev/null; brew --cache -s "$1"; }

# autotools <name> <srcdir> <configure args...>
autotools() {
  local name="$1" src="$2"; shift 2
  mkdir -p "$BUILD/$name" && cd "$BUILD/$name"
  "$src/configure" --host=$HOST --prefix="$PREFIX" --disable-static --enable-shared "$@" > configure.log 2>&1
  make -j"$JOBS" > make.log 2>&1 && make install > install.log 2>&1
}

# meson cross file: host = x86_64-darwin. Rosetta runs the x86_64 test binaries,
# so no exe wrapper is needed (same as cross_compiling=no for autoconf).
CROSS="$BUILD/x86_64-darwin.ini"
cat > "$CROSS" <<EOF
[binaries]
c = ['/usr/bin/clang', '-arch', 'x86_64']
cpp = ['/usr/bin/clang++', '-arch', 'x86_64']
objc = ['/usr/bin/clang', '-arch', 'x86_64']
objcpp = ['/usr/bin/clang++', '-arch', 'x86_64']
ar = '/usr/bin/ar'
strip = '/usr/bin/strip'
pkg-config = '/opt/homebrew/bin/pkg-config'

[built-in options]
c_args = ['-I$PREFIX/include']
objc_args = ['-I$PREFIX/include']
c_link_args = ['-L$PREFIX/lib']
objc_link_args = ['-L$PREFIX/lib']
cpp_link_args = ['-L$PREFIX/lib']

[properties]
needs_exe_wrapper = false
pkg_config_libdir = ['$PREFIX/lib/pkgconfig']

[host_machine]
system = 'darwin'
subsystem = 'macos'
kernel = 'xnu'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

# mesonbuild <name> <srcdir> <meson options...>
mesonbuild() {
  local name="$1" src="$2"; shift 2
  local b="$BUILD/$name"
  if [ ! -f "$b/build.ninja" ]; then
    meson setup "$b" "$src" --cross-file "$CROSS" --prefix="$PREFIX" --libdir=lib \
        --buildtype=release --default-library=shared "$@" > "$BUILD/$name.configure.log" 2>&1 \
      || { tail -30 "$BUILD/$name.configure.log"; exit 1; }
  fi
  ninja -C "$b" -j"$JOBS" > "$BUILD/$name.make.log" 2>&1 || { tail -40 "$BUILD/$name.make.log"; exit 1; }
  ninja -C "$b" install > "$BUILD/$name.install.log" 2>&1
}

# ======================================================================
# 1. Same four as runtimes/winecx (identical flags, see build-winecx-deps.sh)
# ======================================================================

# ---- gmp 6.x (bundled in sources/gnutls/gmp) ----
if [ ! -f "$PREFIX/lib/libgmp.10.dylib" ]; then
  step gmp
  autotools gmp "$SRC/gnutls/gmp" --disable-assembly
  done_step
fi

# ---- nettle (release tarball, CodeWeavers' copy has no Makefile.in) ----
NETTLE_SRC="$(ls -d "$ROOT"/upstream/nettle-src/nettle-*/ | head -1)"
if [ ! -f "$PREFIX/lib/libnettle.dylib" ]; then
  step nettle "($NETTLE_SRC)"
  autotools nettle "$NETTLE_SRC" --disable-assembler --disable-documentation --disable-openssl
  done_step
fi

# ---- gnutls (release tarball, CodeWeavers' copy is a git checkout) ----
GNUTLS_SRC="$(ls -d "$ROOT"/upstream/gnutls-src/gnutls-*/ | head -1)"
if [ ! -f "$PREFIX/lib/libgnutls.30.dylib" ]; then
  step gnutls "($GNUTLS_SRC)"
  autotools gnutls "$GNUTLS_SRC" \
      --with-included-libtasn1 --with-included-unistring \
      --without-p11-kit --without-idn --without-tpm --without-tpm2 \
      --without-brotli --without-zstd --disable-libdane --disable-doc \
      --disable-tools --disable-tests --disable-cxx --disable-nls \
      --disable-hardware-acceleration
  done_step
fi

# ---- freetype (release tarball, CodeWeavers' copy lacks the dlg submodule) ----
FREETYPE_SRC="$(ls -d "$ROOT"/upstream/freetype-src/freetype-*/ | head -1)"
if [ ! -f "$PREFIX/lib/libfreetype.6.dylib" ]; then
  step freetype "($FREETYPE_SRC)"
  autotools freetype "$FREETYPE_SRC" \
      --with-zlib=yes --without-png --without-harfbuzz --without-brotli --without-bzip2
  done_step
fi

# ======================================================================
# 2. glib 2.78.0 (CrossOver tarball) and its deps
# ======================================================================

# ---- libffi (gobject closures). The SDK has headers + libffi.tbd but no .pc;
# CrossOver ships its own libffi.8.dylib too. ----
if [ ! -f "$PREFIX/lib/libffi.8.dylib" ]; then
  LIBFFI_SRC="$(unpack libffi "$(brew_src libffi)")"
  step libffi "($LIBFFI_SRC)"
  autotools libffi "$LIBFFI_SRC" --disable-docs
  done_step
fi

# ---- pcre2 (GRegex), 8-bit only like CrossOver's libpcre2-8 ----
if [ ! -f "$PREFIX/lib/libpcre2-8.0.dylib" ]; then
  PCRE2_SRC="$(unpack pcre2 "$(brew_src pcre2)")"
  step pcre2 "($PCRE2_SRC)"
  autotools pcre2 "$PCRE2_SRC" --enable-pcre2-8 --disable-pcre2-16 --disable-pcre2-32
  done_step
fi

# ---- glib: CodeWeavers' copy has an EMPTY subprojects/gvdb (a git submodule
# in upstream glib), so meson refuses it. We build from an APFS clone of the
# tree (build/x86_64-full/glib-src, upstream/ stays pristine) with the empty dir
# removed; meson then fetches the two wraps it needs into the clone:
# gvdb (gitlab.gnome.org, pinned commit 0854af0f) and proxy-libintl (tag 0.4,
# linked statically; nls is off, so translations are never looked up anyway). ----
if [ ! -f "$PREFIX/lib/libglib-2.0.0.dylib" ]; then
  step glib "($SRC/glib)"
  GLIB_SRC="$BUILD/glib-src"
  if [ ! -d "$GLIB_SRC" ]; then
    cp -Rc "$SRC/glib" "$GLIB_SRC"
    rmdir "$GLIB_SRC/subprojects/gvdb"
    # gdbus-codegen 2.78.0 imports distutils (removed in Python 3.12, Homebrew has
    # 3.14). Same fix as later glib: compare 'since' versions as integer tuples.
    python3 - "$GLIB_SRC/gio/gdbus-2.0/codegen/utils.py" <<'EOPY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("import distutils.version\n", "")
s = s.replace("return (distutils.version.LooseVersion(v), key[1])",
              "return (tuple(int(x) if x.isdigit() else 0 for x in v.split('.')), key[1])")
open(p, "w").write(s)
EOPY
  fi
  mesonbuild glib "$GLIB_SRC" --wrap-mode=default \
      -Dtests=false -Dinstalled_tests=false -Dnls=disabled -Dman=false -Dgtk_doc=false \
      -Dselinux=disabled -Dlibmount=disabled -Dxattr=false -Ddtrace=false \
      -Dsysprof=disabled -Dlibelf=disabled -Dbsymbolic_functions=false
  done_step
fi

# ======================================================================
# 3. GStreamer 1.24.2 (CrossOver's monorepo, each subproject built on its own)
# Plugin set = what CrossOver 25.1 ships in lib64/gstreamer-1.0 (applemedia for
# VideoToolbox H.264/HEVC + AudioToolbox AAC, isomp4, asf, avi, audioparsers,
# id3demux, wavparse, deinterlace, videofilter, videoparsersbad, opengl,
# playback, typefind, audioconvert/resample, videoconvertscale, coreelements)
# + app, ogg/vorbis/theora, matroska, mpegtsdemux and the test sources.
# ======================================================================
GST="$SRC/gstreamer/subprojects"
# --wrap-mode=nodownload: every dependency must come from our prefix (pkg-config),
# never from a subproject fallback.
GST_COMMON=(--wrap-mode=nodownload -Dauto_features=disabled -Dnls=disabled -Ddoc=disabled -Dtests=disabled
            -Dgobject-cast-checks=disabled -Dglib-asserts=disabled -Dglib-checks=disabled
            -Dpackage-origin="Cross winecx-full")

# ---- ogg / vorbis / theora (release tarballs) ----
if [ ! -f "$PREFIX/lib/libogg.0.dylib" ]; then
  OGG_SRC="$(unpack libogg "$(brew_src libogg)")"
  step libogg "($OGG_SRC)"
  autotools libogg "$OGG_SRC"
  done_step
fi
if [ ! -f "$PREFIX/lib/libvorbis.0.dylib" ]; then
  VORBIS_SRC="$(unpack libvorbis "$(brew_src libvorbis)")"
  step libvorbis "($VORBIS_SRC)"
  # same fix as Homebrew: modern ld rejects -force_cpusubtype_ALL
  sed -i '' 's/ -force_cpusubtype_ALL//' "$VORBIS_SRC/configure"
  autotools libvorbis "$VORBIS_SRC"
  done_step
fi
if [ ! -f "$PREFIX/lib/libtheora.0.dylib" ] && [ ! -f "$PREFIX/lib/libtheora.1.dylib" ]; then
  THEORA_SRC="$(unpack theora "$(brew_src theora)")"
  step libtheora "($THEORA_SRC)"
  autotools libtheora "$THEORA_SRC" --disable-oggtest --disable-vorbistest --disable-examples
  done_step
fi

if [ ! -f "$PREFIX/lib/libgstreamer-1.0.0.dylib" ]; then
  step gstreamer
  mesonbuild gstreamer "$GST/gstreamer" "${GST_COMMON[@]}" \
      -Dtools=enabled -Dexamples=disabled -Dbenchmarks=disabled -Dintrospection=disabled \
      -Dcheck=disabled -Dptp-helper=disabled -Dlibunwind=disabled -Dlibdw=disabled \
      -Dbash-completion=disabled -Dcoretracers=enabled
  done_step
fi

if [ ! -f "$PREFIX/lib/gstreamer-1.0/libgstplayback.dylib" ]; then
  step gst-plugins-base
  mesonbuild gst-plugins-base "$GST/gst-plugins-base" "${GST_COMMON[@]}" \
      -Dtools=enabled -Dexamples=disabled -Dintrospection=disabled -Dorc=disabled \
      -Dapp=enabled -Daudioconvert=enabled -Daudioresample=enabled -Daudiorate=enabled \
      -Daudiotestsrc=enabled -Dplayback=enabled -Dtypefind=enabled -Dvideoconvertscale=enabled \
      -Dvideorate=enabled -Dvideotestsrc=enabled -Dvolume=enabled -Dpbtypes=enabled \
      -Drawparse=enabled -Dsubparse=enabled -Dgio=enabled -Dgio-typefinder=enabled \
      -Dogg=enabled -Dvorbis=enabled -Dtheora=enabled \
      -Dgl=enabled -Dgl_api=opengl -Dgl_platform=cgl -Dgl_winsys=cocoa
  done_step
fi

if [ ! -f "$PREFIX/lib/gstreamer-1.0/libgstisomp4.dylib" ]; then
  step gst-plugins-good
  mesonbuild gst-plugins-good "$GST/gst-plugins-good" "${GST_COMMON[@]}" \
      -Dexamples=disabled -Dorc=disabled -Dasm=disabled \
      -Disomp4=enabled -Davi=enabled -Daudioparsers=enabled -Did3demux=enabled \
      -Dapetag=enabled -Dwavparse=enabled -Ddeinterlace=enabled -Dvideofilter=enabled \
      -Dmatroska=enabled -Dflv=enabled -Dautodetect=enabled -Dosxaudio=enabled
  done_step
fi

if [ ! -f "$PREFIX/lib/gstreamer-1.0/libgstapplemedia.dylib" ]; then
  step gst-plugins-bad
  mesonbuild gst-plugins-bad "$GST/gst-plugins-bad" "${GST_COMMON[@]}" \
      -Dexamples=disabled -Dtools=disabled -Dintrospection=disabled -Dorc=disabled -Dgpl=disabled \
      -Dgl=enabled -Dapplemedia=enabled -Dvideoparsers=enabled -Dmpegtsdemux=enabled
  done_step
fi

if [ ! -f "$PREFIX/lib/gstreamer-1.0/libgstasf.dylib" ]; then
  step gst-plugins-ugly
  mesonbuild gst-plugins-ugly "$GST/gst-plugins-ugly" "${GST_COMMON[@]}" \
      -Dorc=disabled -Dgpl=disabled -Dasfdemux=enabled
  done_step
fi

# ======================================================================
# 4. SDL2 2.32.10 (winebus joysticks). CMake does not take "clang -arch x86_64"
# as CC, so the arch goes through CMAKE_OSX_ARCHITECTURES instead.
# ======================================================================
if [ ! -f "$PREFIX/lib/libSDL2-2.0.0.dylib" ]; then
  SDL2_VER=2.32.10
  SDL2_SHA=5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165
  SDL2_TGZ="$ROOT/upstream/SDL2-$SDL2_VER.tar.gz"
  if [ ! -f "$SDL2_TGZ" ]; then
    curl -fsSL -o "$SDL2_TGZ.part" \
      "https://github.com/libsdl-org/SDL/releases/download/release-$SDL2_VER/SDL2-$SDL2_VER.tar.gz"
    echo "$SDL2_SHA  $SDL2_TGZ.part" | shasum -a 256 -c - && mv "$SDL2_TGZ.part" "$SDL2_TGZ"
  fi
  SDL2_SRC="$(unpack sdl2 "$SDL2_TGZ")"
  step sdl2 "($SDL2_SRC)"
  env -u CC -u CXX -u CFLAGS -u CPPFLAGS -u LDFLAGS \
    cmake -S "$SDL2_SRC" -B "$BUILD/sdl2" -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_OSX_ARCHITECTURES=x86_64 \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_NAME_DIR="$PREFIX/lib" \
      -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew \
      -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF -DSDL_X11=OFF > "$BUILD/sdl2.configure.log" 2>&1
  ninja -C "$BUILD/sdl2" -j"$JOBS" > "$BUILD/sdl2.make.log" 2>&1 || { tail -30 "$BUILD/sdl2.make.log"; exit 1; }
  ninja -C "$BUILD/sdl2" install > "$BUILD/sdl2.install.log" 2>&1
  done_step
fi

# ======================================================================
# 5. MoltenVK. CrossOver's tarball has MoltenVK 1.2.10 with CodeWeavers changes,
# but its MoltenVKShaderConverter needs CodeWeavers' SPIRV-Cross fork (commit
# d52dc12d: needs_xfb_buffer, needs_texture_offset_buffer, can_compile_with_
# fast_math), which is neither in the tarball (its External/SPIRV-Cross is plain
# Khronos and fails to compile against it) nor public (not in KhronosGroup or
# cdavis5e/SPIRV-Cross). So: upstream MoltenVK release tarball from
# `brew fetch -s molten-vk` (1.4.2, sha256-checked by Homebrew). Its own
# fetchDependencies clones cereal, Vulkan-Headers, SPIRV-Cross, glslang +
# SPIRV-Tools/Headers, Vulkan-Tools and Volk at the commits pinned in
# ExternalRevisions/. Xcode builds it universal; we keep the x86_64 slice.
# xcodebuild treats environment variables as build settings, hence the env -u.
# ======================================================================
if [ ! -f "$PREFIX/lib/libMoltenVK.dylib" ]; then
  MVK_SRC="$(unpack moltenvk "$(brew_src molten-vk)")"
  step moltenvk "($MVK_SRC)"
  MVK="$BUILD/moltenvk"
  [ -d "$MVK" ] || cp -R "$MVK_SRC" "$MVK"    # fetchDependencies writes into External/
  # Xcode 27 only accepts macOS deployment targets >= 12.0 (1.4.2 already says
  # 12.0; older MoltenVK said 10.15). Project settings beat environment variables.
  { grep -rl "MACOSX_DEPLOYMENT_TARGET = 10.15" --include=project.pbxproj "$MVK" || true; } \
    | while read -r f; do sed -i '' 's/MACOSX_DEPLOYMENT_TARGET = 10.15;/MACOSX_DEPLOYMENT_TARGET = 12.0;/' "$f"; done
  cd "$MVK"
  env -u CC -u CXX -u CFLAGS -u CPPFLAGS -u LDFLAGS -u PKG_CONFIG_LIBDIR \
    ./fetchDependencies --macos > "$BUILD/moltenvk.fetch.log" 2>&1 \
    || { tail -30 "$BUILD/moltenvk.fetch.log"; exit 1; }
  env -u CC -u CXX -u CFLAGS -u CPPFLAGS -u LDFLAGS -u PKG_CONFIG_LIBDIR \
    make macos > "$BUILD/moltenvk.make.log" 2>&1 || { tail -40 "$BUILD/moltenvk.make.log"; exit 1; }
  MVK_DYLIB="$(find "$MVK/Package/Release/MoltenVK" -name libMoltenVK.dylib -path '*macOS*' | head -1)"
  lipo -thin x86_64 "$MVK_DYLIB" -output "$PREFIX/lib/libMoltenVK.dylib" 2>/dev/null \
    || cp "$MVK_DYLIB" "$PREFIX/lib/libMoltenVK.dylib"
  install_name_tool -id "$PREFIX/lib/libMoltenVK.dylib" "$PREFIX/lib/libMoltenVK.dylib"
  codesign -f -s - "$PREFIX/lib/libMoltenVK.dylib"
  mkdir -p "$PREFIX/include" "$PREFIX/etc/vulkan/icd.d"
  rm -rf "$PREFIX/include/MoltenVK" && cp -R "$MVK/MoltenVK/MoltenVK/API" "$PREFIX/include/MoltenVK"
  sed 's|"./libMoltenVK.dylib"|"../../../lib/libMoltenVK.dylib"|' "$MVK/MoltenVK/icd/MoltenVK_icd.json" \
    > "$PREFIX/etc/vulkan/icd.d/MoltenVK_icd.json"
  done_step
fi

step done
cd "$PREFIX/lib"
for f in libgmp.10.dylib libnettle.dylib libhogweed.dylib libgnutls.30.dylib libfreetype.6.dylib \
         libffi.8.dylib libpcre2-8.0.dylib libglib-2.0.0.dylib libgobject-2.0.0.dylib \
         libgmodule-2.0.0.dylib libgio-2.0.0.dylib libgstreamer-1.0.0.dylib libgstvideo-1.0.0.dylib \
         libgstgl-1.0.0.dylib libSDL2-2.0.0.dylib libMoltenVK.dylib; do
  echo "$f: $(file -b "$f")"
done
echo "gstreamer plugins: $(ls gstreamer-1.0/*.dylib | wc -l | tr -d ' ') ($(file -b gstreamer-1.0/*.dylib | sort -u | tr '\n' ' '))"
