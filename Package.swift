// swift-tools-version:5.9
import Foundation
import PackageDescription

// PJSIP is linked statically from vendor/pjsip, a trimmed universal build made by
// scripts/build-pjsip.sh (TLS through Apple's Network framework, no OpenSSL).
let pj = Context.packageDirectory + "/vendor/pjsip"

let pjLibs = [
    "pjsua", "pjsip-ua", "pjsip-simple", "pjsip", "pjmedia-codec", "pjmedia-audiodev",
    "pjmedia-videodev", "pjmedia", "pjnath", "pjlib-util", "pj", "srtp", "resample", "webrtc",
    "bcg729",   // G.729 codec (GPLv3), linked into PJSIP by build-pjsip.sh
].map { "\(pj)/lib/lib\($0).a" }

// OpenVPN 3 client core and its dependencies, built by scripts/build-openvpn3.sh.
let ovpn = Context.packageDirectory + "/vendor/openvpn3"
let ovpnLibs = ["mbedtls", "mbedx509", "mbedcrypto", "lz4"].map { "\(ovpn)/lib/lib\($0).a" }

// Source paths compiled into the app (assertion and log messages) are made relative to
// the package, so the app does not carry the folder names of the Mac it was built on.
let noPaths = "-fmacro-prefix-map=\(Context.packageDirectory)/="

let package = Package(
    name: "SIPAnywhere",
    platforms: [.macOS("14.0")],
    targets: [
        .target(
            name: "CSIPCore",
            cSettings: [
                .unsafeFlags([
                    "-I\(pj)/include", noPaths,
                    "-DPJ_AUTOCONF=1", "-DPJ_IS_BIG_ENDIAN=0", "-DPJ_IS_LITTLE_ENDIAN=1",
                ]),
            ]
        ),
        .target(
            name: "COpenVPN",
            cxxSettings: [
                .unsafeFlags([
                    "-I\(ovpn)/openvpn3", "-I\(ovpn)/include", noPaths,
                    "-DASIO_STANDALONE", "-DUSE_ASIO", "-DHAVE_LZ4", "-DUSE_MBEDTLS", "-DUSE_TUN_BUILDER",
                    "-Wno-deprecated-declarations", "-Wno-macro-redefined",
                ]),
            ]
        ),
        .executableTarget(
            name: "SIPAnywhere",
            dependencies: ["CSIPCore", "COpenVPN"],
            linkerSettings: [
                .unsafeFlags(pjLibs + ovpnLibs),
                .linkedLibrary("c++"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreServices"),
                .linkedFramework("AudioUnit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("Network"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
