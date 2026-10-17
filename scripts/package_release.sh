#!/bin/bash
# Prepares the files to attach to a GitHub Release, in build/release/:
#
#   SIP-Anywhere-<version>.dmg                       the app, to drag to Applications (build it first
#                                                    with ./build_app.sh)
#   SIP-Anywhere-<version>.zip                       the same app as a zip
#   SIP-Anywhere-<version>-third-party-sources.zip   the original source archives of the libraries
#                                                    linked into the app, with the patches, build
#                                                    scripts and license texts: the corresponding
#                                                    source the licenses ask for with the app
#
# GitHub adds the project's own source to every release. Run on main (stable build):
#   ./build_app.sh && ./scripts/package_release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/^VERSION=//p' build_app.sh)
APP_NAME=$(sed -n 's/^APP_NAME="\(.*\)"$/\1/p' build_app.sh)
case "$VERSION" in
    *-dev) echo "Development build ($VERSION): package releases from main." >&2; exit 1 ;;
esac
APP="build/$APP_NAME.app"
[ -d "$APP" ] || { echo "Build the app first: ./build_app.sh" >&2; exit 1; }

OUT=build/release
BASE="SIP-Anywhere-$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"

# Zips without macOS resource forks and extended attributes (no "._" files for others).
zipup() { ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$1" "$2"; }

# The app (its signature lives inside the bundle): a disk image with a link to Applications,
# and a zip.
DMG="$OUT/dmg"
mkdir -p "$DMG"
ditto --norsrc --noextattr --noqtn --noacl "$APP" "$DMG/$APP_NAME.app"
ln -s /Applications "$DMG/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG" -fs HFS+ -format UDZO -ov "$OUT/$BASE.dmg" >/dev/null
rm -rf "$DMG"
zipup "$APP" "$OUT/$BASE.zip"

# The library sources, checked against the checksums pinned in the build scripts.
SRC="$OUT/$BASE-third-party-sources"
mkdir -p "$SRC/archives" "$SRC/build-scripts"
add() {     # archive sha256
    [ -f "$1" ] || { echo "Missing $1: run the build scripts in scripts/ first." >&2; exit 1; }
    echo "$2  $1" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch: $1" >&2; exit 1; }
    cp "$1" "$SRC/archives/"
}
pj_version=$(sed -n 's/^VERSION=//p' scripts/build-pjsip.sh)
add "vendor/pjproject-$pj_version.tar.gz" "$(sed -n 's/^SHA256=//p' scripts/build-pjsip.sh)"
bcg_version=$(sed -n 's/^BCG729_VERSION=//p' scripts/build-pjsip.sh)
add "vendor/bcg729-$bcg_version.tar.gz" "$(sed -n 's/^BCG729_SHA256=//p' scripts/build-pjsip.sh)"
# build-openvpn3.sh lists each download as: fetch <url> \ <file> <sha256>
awk '/^fetch /{getline; print $1, $2}' scripts/build-openvpn3.sh | while read -r file sha; do
    add "vendor/openvpn3/src/$file" "$sha"
done

cp scripts/build-pjsip.sh scripts/build-openvpn3.sh build_app.sh "$SRC/build-scripts/"
cp -R scripts/patches "$SRC/build-scripts/patches"
cp -R LICENSES THIRD_PARTY_NOTICES.md "$SRC/"
(cd "$SRC/archives" && shasum -a 256 *) > "$SRC/SHA256SUMS.txt"
cat > "$SRC/README.txt" <<EOF
Source code of the third-party software in SIP Anywhere $VERSION

archives/       the original, unmodified source archives of the libraries linked into the
                app, exactly as downloaded by the build scripts (checksums in SHA256SUMS.txt)
build-scripts/  how they are configured and built (build-pjsip.sh, build-openvpn3.sh,
                build_app.sh) and the patches applied (patches/)
LICENSES/       the license texts; THIRD_PARTY_NOTICES.md lists each component, its version
                and its license

The source code of SIP Anywhere itself is attached to the same release by GitHub.
EOF
(cd "$OUT" && zipup "$BASE-third-party-sources" "$BASE-third-party-sources.zip")
rm -rf "$SRC"

ls -lh "$OUT"
