# Changelog

All notable changes to SIP Anywhere. Stable releases are on branch `main`
(tags `v1.x`); new features are developed on `develop` and released here once
they are confirmed on a real provider.

## 1.0.1 — 2026-10-27

- **Fixed:** after a call in which keys were pressed (with keypad tones on), the
  microphone stayed open until the app quit: the macOS microphone indicator
  stayed on and the app kept using about 10% CPU. The tone generator is now
  connected to the speaker only while tones play, so the audio closes as usual
  a second after hanging up.

## 1.0 — 2026-10-16

First public release.

- **Calls:** audio calls in and out, up to four at once (hold, switch, call
  waiting), three-way conference, mute, keypad tones (RFC 2833), blind and
  attended transfer, volume of each call separate from the Mac's.
- **Codecs:** G.711, G.722 and G.729 (bcg729), G.711 preferred.
- **Accounts:** UDP, TCP or TLS; optional SRTP; several outbound proxies with
  automatic failover. Registration follows RFC 5626 (device identity, keep-alive)
  and refreshes early, as some IMS providers need. When a registration gets no
  response at all, the next attempt uses a new local port.
- **Built-in VPN (OpenVPN 3):** used only by the app, for calling through the home
  or office connection from anywhere. Calls survive network changes (Wi-Fi ↔ cable,
  hotspot); the VPN reconnects only when its own route changes.
- **Menu bar:** the app lives in the menu bar and can open at login without a
  window. A call panel under the icon answers or declines a call without taking
  the keyboard, and then becomes a mini control: duration, volume, mute, keypad
  (digits can be typed), recording at one click, VPN status, audio devices, hold.
- **Answering machine** while Do Not Disturb is on: a spoken or recorded greeting,
  messages in Music › SIP Anywhere › Voicemail and in the Messages tab.
- **Recents and Contacts:** names from the Mac's Contacts, missed call
  notifications and count, call back from Recents, delete with confirmation. The
  keypad recalls the last number called.
- **Recording** of calls to Music › SIP Anywhere › Recordings.
- **Audio:** macOS voice processing (echo cancellation) with the system devices,
  or chosen devices; the choice follows devices being plugged and unplugged.
- **Log:** full SIP log (Off / Standard / Detailed), VPN diagnostics, and the
  audio devices each call uses.
- **Performance:** about 14% CPU during a call (most of it macOS voice
  processing) and 0.2% when idle. Developers can measure the app with the test
  bench in `scripts/bench`, which needs no provider.
