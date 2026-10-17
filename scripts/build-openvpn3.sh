#!/bin/bash
# Fetches and builds what the in-app VPN needs, as universal (Apple Silicon + Intel)
# static libraries and headers in vendor/openvpn3:
#   - OpenVPN 3 client core (used under the MPL-2.0 option of its AGPL-3.0/MPL-2.0 licence)
#   - asio (with OpenVPN's patches), mbed TLS, lz4, xxHash
# Every download is checked against a pinned SHA-256.
set -euo pipefail
cd "$(dirname "$0")/.."

MIN_MACOS=14.0
ROOT="$PWD/vendor/openvpn3"
SRC="$ROOT/src"
mkdir -p "$SRC"

fetch() {   # url file sha256
    [ -f "$SRC/$2" ] || curl -fL -o "$SRC/$2" "$1"
    echo "$3  $SRC/$2" | shasum -a 256 -c -
}
fetch https://github.com/OpenVPN/openvpn3/archive/refs/tags/release/3.11.7.tar.gz \
      openvpn3-3.11.7.tar.gz 6ec04d7e7824f043ee2ec6c2d98ce2655350e5cdcc969ab60a5f68cecb232289
fetch https://github.com/chriskohlhoff/asio/archive/asio-1-24-0.tar.gz \
      asio-1-24-0.tar.gz cbcaaba0f66722787b1a7c33afe1befb3a012b5af3ad7da7ff0f6b8c9b7a8a5b
fetch https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.7/mbedtls-3.6.7.tar.bz2 \
      mbedtls-3.6.7.tar.bz2 a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6
fetch https://github.com/lz4/lz4/archive/refs/tags/v1.10.0.tar.gz \
      lz4-1.10.0.tar.gz 537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b
fetch https://github.com/Cyan4973/xxHash/archive/refs/tags/v0.8.3.tar.gz \
      xxHash-0.8.3.tar.gz aae608dfe8213dfd05d909a57718ef82f30722c392344583d3f39050c7f29a80

BUILD="$ROOT/build"
# Source paths compiled into the libraries (assertion messages) are made relative, so
# the app does not carry the folder names of the Mac it was built on.
NOPATHS="-fmacro-prefix-map=$BUILD/="
rm -rf "$BUILD" "$ROOT/include" "$ROOT/lib" "$ROOT/openvpn3"
mkdir -p "$BUILD" "$ROOT/include" "$ROOT/lib"
ARCHS="-arch arm64 -arch x86_64 -mmacosx-version-min=$MIN_MACOS"

# OpenVPN 3: header-only core plus client/ovpncli.cpp, compiled by the app's COpenVPN target.
mkdir -p "$ROOT/openvpn3"
tar xzf "$SRC/openvpn3-3.11.7.tar.gz" -C "$ROOT/openvpn3" --strip-components 1

# asio 1.24.0 with the patches OpenVPN 3 relies on.
tar xzf "$SRC/asio-1-24-0.tar.gz" -C "$BUILD"
(cd "$BUILD/asio-asio-1-24-0" && for p in "$ROOT"/openvpn3/deps/asio/patches/*.patch; do patch -s -p1 < "$p"; done)
cp -R "$BUILD/asio-asio-1-24-0/asio/include/asio" "$BUILD/asio-asio-1-24-0/asio/include/asio.hpp" "$ROOT/include/"

# mbed TLS (TLS for the OpenVPN control channel, ciphers for the data channel).
tar xjf "$SRC/mbedtls-3.6.7.tar.bz2" -C "$BUILD"
# OpenVPN authenticates the server with its own CA and "remote-cert-tls server", not by
# host name; mbed TLS >= 3.6.3 refuses certificate checks without a host name unless told.
printf '\n#define MBEDTLS_SSL_CLI_ALLOW_WEAK_CERTIFICATE_VERIFICATION_WITHOUT_HOSTNAME\n' \
    >> "$BUILD/mbedtls-3.6.7/include/mbedtls/mbedtls_config.h"
cmake -S "$BUILD/mbedtls-3.6.7" -B "$BUILD/mbedtls-build" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_MACOS -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
      -DCMAKE_C_FLAGS="$NOPATHS" \
      -DCMAKE_INSTALL_PREFIX="$BUILD/mbedtls-install" >/dev/null
cmake --build "$BUILD/mbedtls-build" >/dev/null
cmake --install "$BUILD/mbedtls-build" >/dev/null
cp -R "$BUILD/mbedtls-install/include/"* "$ROOT/include/"
cp "$BUILD/mbedtls-install/lib/"libmbed*.a "$ROOT/lib/"

# lz4 (compression used by some OpenVPN servers).
tar xzf "$SRC/lz4-1.10.0.tar.gz" -C "$BUILD"
clang $ARCHS -O2 $NOPATHS -c "$BUILD/lz4-1.10.0/lib/lz4.c" -o "$BUILD/lz4.o"
libtool -static -o "$ROOT/lib/liblz4.a" "$BUILD/lz4.o" 2>/dev/null
cp "$BUILD/lz4-1.10.0/lib/lz4.h" "$ROOT/include/"

# xxHash (header-only).
tar xzf "$SRC/xxHash-0.8.3.tar.gz" -C "$BUILD"
cp "$BUILD/xxHash-0.8.3/xxhash.h" "$ROOT/include/"

echo "OpenVPN 3 and dependencies ready in $ROOT:"
for f in "$ROOT"/lib/*.a; do echo "  $(basename "$f"): $(lipo -archs "$f")"; done
