# ELTransfer prototype

A pointer-overlay prototype for two Macs on the same local network. It never moves or controls the receiving Mac’s real cursor and cannot click, type, drag, or scroll.

## What this build does
- Sender Mac: hold `⌘ Command` while moving the cursor to any screen edge to start sharing; keep holding it and your own cursor stays put while the mouse steers the shared pointer anywhere on the screen. Clicks go to the shared pointer, which plays a click animation on the receiver, instead of the app under your cursor.
- While sharing, press `⌘ Return` to latch the session and type on the other Mac: you no longer need to hold `⌘`, your keys stop reaching your own apps, and shortcuts show as keycaps along the bottom of the receiver's screen until released. Typed text appears there too; after a short pause it fades and lands on the receiver's clipboard, ready for `⌘V`. `⌘ Esc` ends the session.
- Both Macs show a banner: "Sharing your pointer" on the sender, "Receiving …’s pointer" on the receiver.
- Receiver Mac: choose in Settings how a shared pointer gets in — **Always** (default; it appears straight away and both hands stay free), **Tap ⌘** (tap `⌘` to let it in, tap again to stop), or **Hold ⌘** (the old behaviour). `⌘ Esc` turns a session away in any mode.
- The receiver shows an animated blue overlay at the corresponding location.
- The sender’s normalized cursor position is transmitted over UDP, with Bluetooth/AWDL via MultipeerConnectivity as a fallback. Because positions are normalized to screen dimensions, cursor movement/sensitivity is preserved proportionally between different screen sizes.
- Release `⌘` (or press `⌘ Esc` once typing) on the sender to end the session.

## Build
```sh
./scripts/build-app.sh
```

## DMG and website

`./scripts/build-dmg.sh` builds `website/downloads/ELTransfer.dmg` with a Finder layout. Every push to `main` runs `.github/workflows/publish.yml` on a macOS runner, which builds the app and DMG, stamps the version, size and SHA-256 into the page, and pushes `website/` into the `eltransfer/` folder of the `duuberian/duuberian` homepage repository, which serves https://duuberian.com/eltransfer/. The workflow needs the `DUUBERIAN_SITE_DEPLOY_KEY` secret, a deploy key with write access to that repository.

## Run on both Macs
1. Copy/build this folder on both Macs.
2. Run `build/ELTransfer.app` on both.
3. Allow Accessibility/Input Monitoring permissions when macOS asks at launch.
4. Allow Local Network access when macOS asks; the Macs find each other over Bonjour (`_eltransfer._udp`) and fall back to Apple peer-to-peer transport when Wi-Fi blocks direct traffic. Allow Bluetooth access if macOS asks.
5. Move the sender cursor to a screen edge while holding `⌘`. The receiver shows the pointer right away (or, in the Tap/Hold ⌘ modes, a banner asking to tap or hold `⌘`).

The app prints diagnostic state to Console.app / stderr.
