#!/bin/bash
# Builds the app in ./build for the architectures in ARCHS (a universal app when both).
# Requires the trimmed PJSIP and OpenVPN 3 builds: run ./scripts/build-pjsip.sh and
# ./scripts/build-openvpn3.sh once first.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=1.0.1
# Stable build. (On develop: "SIP Anywhere Dev" and a .dev identifier, so the two never share settings.)
APP_NAME="SIP Anywhere"
BUNDLE_ID=io.github.andrea79.SIPAnywhere
MIN_MACOS=14.0
# The project's page (e.g. on GitHub), linked in the About window; empty: no link.
PROJECT_URL="https://github.com/Andrea79/sip-anywhere"
# Stable builds are universal (Apple Silicon + Intel); develop defaults to arm64 only.
ARCHS=${ARCHS:-arm64 x86_64}

if [ ! -f vendor/pjsip/lib/libpjsua.a ]; then
    echo "PJSIP is missing: run ./scripts/build-pjsip.sh first." >&2
    exit 1
fi
if [ ! -f vendor/openvpn3/lib/libmbedtls.a ]; then
    echo "OpenVPN 3 is missing: run ./scripts/build-openvpn3.sh first." >&2
    exit 1
fi

# One build per architecture, then merged into one executable.
for arch in $ARCHS; do
    swift build -c release --triple "$arch-apple-macosx$MIN_MACOS" --scratch-path ".build/$arch"
done
APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BINARIES=()
for arch in $ARCHS; do BINARIES+=(".build/$arch/release/SIPAnywhere"); done
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/SIPAnywhere"

# App icon: all macOS sizes generated from the 1024 px artwork (scripts/make_icon.swift).
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for px in 16 32 128 256 512; do
    sips -z $px $px Resources/AppIcon.png --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Credits for the About window, and the licenses travelling with the app.
cp Resources/Credits.rtf "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Licenses"
cp LICENSE THIRD_PARTY_NOTICES.md LICENSES/* "$APP/Contents/Resources/Licenses/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>SIPAnywhere</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Andrea79. Free software under the GNU GPL v3.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>SSPProjectURL</key><string>$PROJECT_URL</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSContactsUsageDescription</key><string>SIP Anywhere shows the names of your contacts for the numbers you call and that call you. Contacts stay on this Mac.</string>
    <key>NSMicrophoneUsageDescription</key><string>SIP Anywhere needs the microphone to carry your voice during calls.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/SIPAnywhere"))"
