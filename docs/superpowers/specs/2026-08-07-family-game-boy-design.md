# The family Game Boy — design

*2026-08-07 — approved: Bonjour discovery, Developer ID + notarization.
The engine is untouched: `--listen`/`--link` have worked since the cable
was built; this arc gives them a face and gives the app legs.*

## 1. The link, in the app

The cable is plugged at boot on real hardware and in this engine alike, so
linking is a **relaunch** of the current ROM with the link flags — the
battery is safe in the library, flushed on stop and loaded on boot.

* **Game → Link Cable… (⌘L)** opens the Link sheet.
* **Host**: relaunch with `--listen 7373` and publish a Bonjour service
  (`_atomboy._tcp`, named "«Mac name» — «game»"). The sheet shows "the
  cable is out — waiting for the other Game Boy" with Stop Hosting.
* **Join**: the sheet lists discovered hosts; one click resolves the
  service and relaunches with `--link host:port`.
* **Unplug**: relaunch plain.

`Link.listen` times out after 120 s and the engine exits — and the shell's
termination handler currently quits the app. It learns one nuance: an exit
during a link attempt relaunches the ROM without the cable instead of
terminating. NetService/NetServiceBrowser carry the Bonjour work
(deprecated but complete, and the build already silences warnings);
`Info.plist` gains `NSLocalNetworkUsageDescription` and
`NSBonjourServices` for the macOS local-network prompt.

Port 7373 is written in two places — `Atomboy.Link` and the shell — the
same knowingly-coupled way `atomboy-moteur` is.

## 2. The legs: bin/build --release

A new flag (implies `--app`):

1. Sign `atomboy-moteur` and the bundle with **Developer ID Application**
   (auto-detected via `security find-identity`, `ATOMBOY_SIGN_ID`
   overrides), hardened runtime, and an entitlements file granting the
   BEAM its JIT (`allow-jit`, `allow-unsigned-executable-memory`).
2. `ditto` the app into a zip, submit with
   `xcrun notarytool submit --wait` under keychain profile
   `ATOMBOY_NOTARY_PROFILE` (default `atomboy`), then `stapler staple`
   and re-zip.
3. The result — `burrito_out/Atomboy.zip` — AirDrops to any Mac and
   double-clicks clean.

One-time setup, printed by the script when the profile is missing:
`xcrun notarytool store-credentials atomboy --apple-id … --team-id …`
with an app-specific password.

## Testing

Bonjour and the two-Mac session by hand (it takes two Macs). The release
path runs end to end on the first real invocation — the script fails loud
and early on a missing identity or profile. Elixir suite untouched.

## Out of scope

Mid-game plugging (the engine's cable is a boot-time affair); linking over
the internet; Sparkle-style updates; Mac App Store.
