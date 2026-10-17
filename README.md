# SIP Anywhere

<img src="Resources/AppIcon.png" alt="SIP Anywhere icon" width="128" align="right">

**A simple SIP softphone for Mac, with a built-in VPN.** A small, native app built with SwiftUI and
[PJSIP](https://www.pjsip.org) that works with any standard SIP provider, including IMS-based fixed lines.
It calls from any network your provider accepts, and through your own OpenVPN server when the line only
accepts calls from its own network, at home or at the office.

- Audio calls in and out, up to four at once (hold, switch, call waiting), three-way conference
- Mute, hold/resume, keypad tones (RFC 2833, with optional local feedback), blind and attended transfer
- Volume of each call, separate from the Mac's volume
- Several outbound proxies with automatic failover
- Choice of microphone and speaker, remembered per device
- UDP, TCP or TLS; optional SRTP media encryption
- Built-in VPN (OpenVPN) for calling from anywhere through your home or office connection, used only by the app
- Lives in the menu bar: close the window and the app keeps waiting for calls; can open at login
- Call panel under the menu bar icon: answer, decline and control a call without the window
- Recents (double-click to call back), missed call notifications and count, names from the Mac's Contacts
- Do Not Disturb: silences this Mac while the line's other phones keep ringing
- Answering machine: while Do Not Disturb is on, it answers after a set time with a spoken or recorded
  greeting and saves the message (Messages tab)
- Call recording to a file on the Mac
- G.711, G.722 and G.729 codecs
- Full SIP log for troubleshooting

> **Emergency calls:** do not rely on this app for emergency calls (112, 911…). VoIP calls may not
> reach emergency services, and your location may not be transmitted. Keep another way to call for help.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon or Intel
- A SIP account: username, password, SIP domain and the provider's outbound proxy (IP address or host name)

## Install

Download `SIP-Anywhere-<version>.dmg` from the [Releases](https://github.com/Andrea79/sip-anywhere/releases)
page, open it, drag **SIP Anywhere** onto the **Applications** folder and open it from there (a `.zip` of
the app is also available). The app is not signed with an
Apple Developer ID, so the first time macOS refuses to open it:

- **macOS 15 and later:** after the warning, open **System Settings › Privacy & Security**, scroll down to
  the message about SIP Anywhere, click **Open Anyway** and confirm.
- **macOS 14:** right-click (or Control-click) the app, choose **Open**, then confirm.

Allow microphone access when asked (and Contacts and notifications, if you use those features).

## Build from source

You need the Xcode Command Line Tools (`xcode-select --install`).

```bash
./scripts/build-pjsip.sh    # once: downloads PJSIP 2.17 and builds a trimmed universal copy in vendor/
./scripts/build-openvpn3.sh # once: downloads OpenVPN 3, Mbed TLS, asio, LZ4, xxHash into vendor/openvpn3
./build_app.sh              # builds "build/SIP Anywhere.app" (Apple Silicon + Intel)
open "build/SIP Anywhere.app"
```

`build-pjsip.sh` verifies the PJSIP and bcg729 downloads against their SHA-256 checksums and builds
only what the app uses: no video and no codecs other than G.711, G.722 and G.729 (bcg729). TLS comes from Apple's Network framework, so
OpenSSL is not needed. `build-openvpn3.sh` does the same for the VPN (every download pinned by SHA-256;
needs CMake and Ninja, e.g. `brew install cmake ninja`). Everything is linked statically; the app has no
runtime dependencies.

**Test bench.** `scripts/bench/run.sh [calls]` measures the app without the provider: a copy of the build
with its own settings registers with a stand-in registrar on the Mac, PJSIP's test phone calls it and
plays recorded speech, and the copy answers and plays a scripted call (panel, keypad, recording,
window). The report in `.build/bench/report.txt` gives CPU per thread for each phase, memory after each
call and leaks. Calls are silent; the first run asks for microphone access.

**Release files.** `scripts/package_release.sh` (run on `main` after `./build_app.sh`) puts in
`build/release/` the app as a disk image (`.dmg`) and as a zip, and an archive with the original source code of every bundled library,
checked against the pinned checksums, with the patches and build scripts.

The icon is drawn by `scripts/make_icon.swift` (`swift scripts/make_icon.swift Resources/AppIcon.png`).

## Account configuration

On first launch (or with **⌘,** / the gear icon) the configuration asks for:

| Section | Field | Example |
|---|---|---|
| Identity | Username | `+15551234567`, usually your number in international format |
| | SIP domain | `sip.example.com` |
| | Display name (optional) | `Home` |
| Login | Auth username (optional) | only if your provider's login name differs from the username |
| | Password | your SIP password |
| Server | Outbound SIP proxies | one or more, e.g. `192.0.2.10`, `192.0.2.11` (IP or host name, optionally `:port`) |
| | Transport | UDP, TCP or TLS |

The proxy URIs are built automatically (e.g. `192.0.2.10` + TLS → `sip:192.0.2.10;transport=tls`).
All SIP traffic is sent to the outbound proxy and no DNS lookup is done, which helps if you don't use your
provider's DNS. Default ports: 5060 for UDP/TCP, 5061 for TLS.

**Several proxies (failover).** List them in order of preference. If registration through one fails or gets
no answer within 10 seconds, the next one is tried. After a failed round the app waits (30 s, doubling up to
15 min) so the provider is not flooded. The proxy in use is shown in the status bar, where you can also switch.

**Menu bar.** The phone icon in the menu bar shows the state (registered, offline, in a call, Do Not
Disturb). Its menu has the status and VPN state, Open (or Close Window), the call in progress, missed calls
and new messages, Do Not Disturb, Go Offline (or Register), Settings…, About and Quit. Closing the window
keeps the app running there (no Dock icon). An incoming call opens the call panel under the icon (see
below) or, if the panel is off, the window, which closes again when the call is over. The number next to
the icon counts missed calls and new messages. Settings › Startup can also open the app at login, start it
in the menu bar only, or hide the icon.

**Calls** (Settings › Calls): names from the Mac's Contacts, notifications for missed calls, and the G.729
codec (only if needed by default; "Preferred" saves bandwidth on a weak connection). **Do Not Disturb**
(menu bar, ⇧⌘D) stops this Mac from ringing; other phones on the line ring as usual and the calls are
noted in Recents. **Record** (⌥⌘R) saves both sides of a call to a WAV file in Music › SIP Anywhere,
on this Mac only: you may record a conversation you take part in, but ask before sharing it.
**Answering machine** (Settings › Answering machine): while Do Not Disturb is on, the Mac does not ring and,
if nobody answers on the line's other phones within the set time, the app answers, plays the greeting
(spoken by macOS from your text, or your own recording) and a beep, and records the message to
Music › SIP Anywhere › Voicemail. Messages are listed in the Messages tab.
With two calls, **Merge** joins them into a conference and **Split** separates them. This needs a line that
allows two calls at a time; some fixed lines allow only one (a second call is then refused).

**Startup.** "Register at startup" is off by default: the app opens offline. Register from the status bar
(**Register**, ⌘R) and go offline with the power button (⇧⌘R).

**Advanced:** SRTP (Off / Optional / Required), local SIP port (0 = automatic), registration expiry,
and TLS certificate verification.

### Example: a provider-issued fixed line

| Field | Value |
|---|---|
| Username | your number in international format, e.g. `+15551234567` |
| SIP domain | the provider's SIP domain, e.g. `sip.example.com` |
| Auth username | leave empty if the provider uses the number |
| Password | the SIP password from the provider |
| Outbound SIP proxies | the IP addresses of the provider's SIP server |
| Transport | UDP |

Some providers accept registrations only from their own access line. Calls ring on every registered device
(the provider's router, other SIP clients), so incoming calls may be answered elsewhere.

## Using the app

- **Dialling:** type with the keyboard or the numeric keypad (no need to click first); ⌫ deletes, Esc or
  Clear erases, Return calls, ⌘V pastes.
- **Audio devices:** in the **Audio** menu, in the settings or during a call under More (⋮).
  "System default" uses macOS voice processing (built-in echo cancellation); other audio on the Mac is
  lowered as little as possible, and only while someone speaks. Choosing specific devices avoids it entirely.

| During a call | |
|---|---|
| Mute (⇧⌘M) | disconnects the microphone from the call |
| Keypad, or typing digits | sends tones (RFC 2833) for voice menus; you hear the standard tones (Settings › Audio › Keypad tones) |
| Volume (call header) | lowers only this call, e.g. hold music; speaker icon: full / 15%; arrow keys: ±5% |
| Hold / Resume (⇧⌘H) | a held call never hears your other calls |
| Transfer | blind transfer to a number, or connect two of your calls |
| Add call / Calls | dial a second call; switch between calls (up to 4) |
| End (⇧⌘E) | hangs up |

The call header shows the duration, whether the audio is encrypted, and quality bars computed from
packet loss, jitter and round-trip time (click them for details).

**Call panel.** With the menu bar icon and the window closed, a call opens a small panel under the icon
instead (Settings › Startup › Incoming calls). It never takes the keyboard from the app in use: Answer
and Decline act on the first click. During the call it shows the duration and the call's volume, with
Mute, Keypad (digits can also be typed once the keypad is open) and End; the icons above record the call
and show the VPN; ⋯ holds the audio devices, Hold and Show Recordings; ⊕ opens the window and ⊖ puts the
panel away (the menu bar's Show Call Panel brings it back).

## Calling through a VPN

Some providers accept calls only from your own line. With the built-in VPN the app can call from anywhere
as if it were on your line's own network, at home or at the office: in **Settings › VPN** import the
OpenVPN profile (`.ovpn`) of your VPN server, enter the VPN username and password if the profile asks for
them, and turn on **Call through the VPN**. When you register, the app connects the VPN first and then
registers through it; the **VPN** badge in the status bar shows its state.

- **Only the app uses the VPN.** No network interface is created and no system setting changes: the app
  carries its own SIP and audio packets inside the tunnel. Browser, mail and everything else on the Mac
  keep using the normal connection, and no administrator password is needed.
- **Any OpenVPN server works** (OpenVPN 2.4 or later, or any server speaking the OpenVPN protocol): for
  example OpenVPN Access Server, pfSense/OPNsense, NAS VPN apps, many routers. The server must let VPN
  clients reach the Internet (often an option such as "use as the default gateway for remote devices").
  Username/password and certificate profiles are supported, as are `tls-auth`/`tls-crypt` and
  compressed links (`comp-lzo`). The profile must contain its certificates inline.
- Through the VPN, SIP uses **UDP** (choose UDP as transport).
- If the Mac changes network during a call (Wi-Fi to cable or to a phone's hotspot), the VPN reconnects
  at once and the call continues after a few seconds of silence. After sleep or a longer outage the VPN
  reconnects by itself and the app registers again.
- Each network change leaves the old VPN session on the server for about a minute, so let the server
  accept a few more clients than you have devices (some servers default to a maximum of 5).
  If the VPN server refuses the login the app stops and says so, rather than retrying with a wrong password.

## Troubleshooting

**One registration per line.** Only one copy of the app (stable, development or older builds) can be
registered with an account at a time; another copy asks you to quit the first one. If another SIP
softphone is open, the app warns before registering. Two clients registered with the same line from the
same network can make the provider stop answering both.

The **Log** tab shows the full SIP exchange; it is also saved to
`~/Library/Logs/SIP Anywhere/sip.log` (Log › Show log file).

**How the app works behind NAT** (e.g. a home or office router):

- The private address stays in the Via header and in the audio description (SDP); only the Contact
  carries the public address. The provider's border controller detects the NAT from this and keeps the
  signalling and audio paths open.
- Keep-alives (double CRLF, RFC 5626) are sent every 30 s.
- Reliable provisional responses (100rel) and session timers are not advertised; the provider refreshes
  calls itself.
- Only audio is offered.
- In-call OPTIONS and UPDATE requests from the provider are answered automatically.

## Privacy

The SIP and VPN passwords, and the VPN profile, are stored in your macOS Keychain. Settings and the call history stay on your Mac, and so does
the log, which contains phone numbers and SIP messages (not the password). The app talks only to the SIP
servers and the VPN server you configure; there is no analytics or other network traffic.

How much is logged is up to you (Settings › Advanced › Log detail): **Off** writes nothing to disk and
does not log SIP messages; **Standard** (the default) logs SIP messages in full and a VPN traffic summary
once a minute during calls; **Detailed** every 5 s, for troubleshooting. **Delete log files…**
removes the logs already saved.

## How it was made

SIP Anywhere was made by Andrea79 with [Claude Code](https://claude.com/claude-code),
Anthropic's AI coding assistant. All of the code, including the build scripts and the test
bench in `scripts/`, was written by Claude under Andrea79's direction. Andrea79 came up with
the idea, made the design decisions, and tested and debugged the app. Commits written with
Claude carry a `Co-Authored-By: Claude` line.

## License

Copyright © 2026 Andrea79.

SIP Anywhere is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, either version 3 of the License,
or (at your option) any later version. It is distributed in the hope that it will be useful, but
**without any warranty**; see [LICENSE](LICENSE).

It includes third-party software (PJSIP, bcg729, OpenVPN 3 and the libraries they use) under their own
licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the [LICENSES](LICENSES) folder. The
original source code of these libraries, as used for each release, is attached to the release as
`SIP-Anywhere-<version>-third-party-sources.zip`.
