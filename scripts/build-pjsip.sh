#!/bin/bash
# Builds a trimmed PJSIP containing only what SIP Anywhere uses, as universal
# (Apple Silicon + Intel) static libraries in vendor/pjsip. TLS uses Apple's own
# implementation (Network framework), so OpenSSL is not needed.
#
# Left out: video, and the codecs the app never offers (G.722.1, iLBC, GSM,
# Speex, L16, Opus, SILK, AMR). Kept: G.711 (PCMA/PCMU), G.722, G.729 (through
# bcg729), SRTP, WebRTC echo cancellation and resampling.
#
# Patched (scripts/patches): macOS voice processing ducks other audio as little as
# possible.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=2.17
SHA256=065fe06c06788d97c35f563796d59f00ce52fe9558a52d7b490a042a966facce
MIN_MACOS=14.0
ROOT="$PWD/vendor"
OUT="$ROOT/pjsip"
TARBALL="$ROOT/pjproject-$VERSION.tar.gz"
# G.729 codec (GPLv3), built as a static library and linked into PJSIP.
BCG729_VERSION=1.1.1
BCG729_SHA256=68599a850535d1b182932b3f86558ac8a76d4b899a548183b062956c5fdc916d
BCG729_TARBALL="$ROOT/bcg729-$BCG729_VERSION.tar.gz"

mkdir -p "$ROOT"
if [ ! -f "$TARBALL" ]; then
    curl -fL -o "$TARBALL" "https://github.com/pjsip/pjproject/archive/refs/tags/$VERSION.tar.gz"
fi
echo "$SHA256  $TARBALL" | shasum -a 256 -c -
if [ ! -f "$BCG729_TARBALL" ]; then
    curl -fL -o "$BCG729_TARBALL" "https://github.com/BelledonneCommunications/bcg729/archive/refs/tags/$BCG729_VERSION.tar.gz"
fi
echo "$BCG729_SHA256  $BCG729_TARBALL" | shasum -a 256 -c -

OPTIONS=(
    --disable-video --disable-libyuv --disable-openh264 --disable-ffmpeg
    --disable-sdl --disable-v4l2 --disable-upnp
    --disable-g7221-codec --disable-ilbc-codec --disable-gsm-codec
    --disable-speex-codec --disable-l16-codec --disable-opencore-amr
    --disable-silk --disable-opus
    --disable-speex-aec
    # No OpenSSL/GnuTLS detection: Apple's TLS is selected in config_site.h.
    --disable-ssl --disable-darwin-ssl
)

# PJSIP build-time configuration: TLS through Apple's Network framework, and
# digest credentials reused on later requests (see below).
CONFIG_SITE='/* SIP Anywhere: TLS through Apple'"'"'s Network framework (no OpenSSL). */
#define PJ_HAS_SSL_SOCK     1
#define PJ_SSL_SOCK_IMP     PJ_SSL_SOCK_IMP_APPLE
/* Send the cached digest credentials with later requests (nonce reused, nc
 * incremented, RFC 7616), so registration refreshes are authenticated at once
 * instead of going out unauthenticated and waiting for a new challenge. */
#define PJSIP_AUTH_AUTO_SEND_NEXT   1
/* Answer offers with our own codec order (PCMA first), not the offerer'"'"'s (RFC 3264
 * allows either): an offer listing G.729 first would otherwise get it. G.729 is
 * still chosen when it is the only common codec, or when preferred. */
#define PJMEDIA_SDP_NEG_PREFER_REMOTE_CODEC_ORDER   0'

for arch in arm64 x86_64; do
    # bcg729 first, installed where PJSIP's configure will look for it.
    bsrc="$ROOT/bcg729-src-$arch"
    bprefix="$ROOT/bcg729-$arch"
    rm -rf "$bsrc" "$bprefix"
    mkdir -p "$bsrc"
    tar xzf "$BCG729_TARBALL" -C "$bsrc" --strip-components 1
    cmake -S "$bsrc" -B "$bsrc/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DENABLE_SHARED=NO -DENABLE_STATIC=YES \
        -DENABLE_STRICT=NO -DENABLE_TESTS=NO -DCMAKE_INSTALL_PREFIX="$bprefix"
    cmake --build "$bsrc/build"
    cmake --install "$bsrc/build"

    src="$ROOT/build-$arch"
    prefix="$ROOT/install-$arch"
    rm -rf "$src" "$prefix"
    mkdir -p "$src"
    tar xzf "$TARBALL" -C "$src" --strip-components 1
    printf '%s\n' "$CONFIG_SITE" > "$src/pjlib/include/pj/config_site.h"
    # Our changes to PJSIP's sources (each patch explains itself).
    for p in scripts/patches/pjsip-*.patch; do
        patch -p1 --forward --silent -d "$src" < "$p"
    done
    # Each architecture is configured and built natively (Intel through Rosetta):
    # PJSIP's configure turns TLS off when it thinks it is cross-compiling.
    arch -"$arch" /bin/bash -euo pipefail -c '
        cd "$1"
        export CFLAGS="-arch $2 -mmacosx-version-min=$3 -O2"
        export LDFLAGS="-arch $2 -mmacosx-version-min=$3 -framework Network -framework Security -framework Foundation"
        ./aconfigure --prefix="$4" "${@:5}"
        make dep
        make -j"$(sysctl -n hw.ncpu)"
        make install
    ' _ "$src" "$arch" "$MIN_MACOS" "$prefix" "${OPTIONS[@]}" --with-bcg729="$bprefix"
done

# Merge both architectures into universal libraries with plain names (libpj.a, ...).
rm -rf "$OUT"
mkdir -p "$OUT/lib"
cp -R "$ROOT/install-arm64/include" "$OUT/include"
for lib in "$ROOT"/install-arm64/lib/*.a; do
    name=$(basename "$lib" | sed -E 's/-(aarch64|arm64)-apple-darwin.*\.a$/.a/')
    intel=$(ls "$ROOT"/install-x86_64/lib/"${name%.a}"-x86_64-apple-darwin*.a)
    lipo -create "$lib" "$intel" -output "$OUT/lib/$name"
done
lipo -create "$ROOT/bcg729-arm64/lib/libbcg729.a" "$ROOT/bcg729-x86_64/lib/libbcg729.a" \
     -output "$OUT/lib/libbcg729.a"
# The only per-architecture headers just name the architecture; pick the right one.
for h in m_auto.h os_auto.h; do
    dir="$OUT/include/pj/compat"
    cp "$ROOT/install-arm64/include/pj/compat/$h" "$dir/${h%.h}_arm64.h"
    cp "$ROOT/install-x86_64/include/pj/compat/$h" "$dir/${h%.h}_x86_64.h"
    printf '#if defined(__arm64__)\n#include "%s"\n#else\n#include "%s"\n#endif\n' \
        "${h%.h}_arm64.h" "${h%.h}_x86_64.h" > "$dir/$h"
done
echo "PJSIP $VERSION built in $OUT:"
ls "$OUT/lib"
