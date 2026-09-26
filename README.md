# ELTransfer prototype

A pointer-overlay prototype for two Macs on the same local network. It never moves or controls the receiving Mac’s real cursor and cannot click, type, drag, or scroll.

## What this build does
- Sender Mac: hold `⌘ Command` while moving the cursor to any screen edge.
- Receiver Mac: also hold `⌘ Command` to consent to receiving the overlay pointer.
- The receiver shows an animated blue overlay at the corresponding location.
- The sender’s normalized cursor position is transmitted over UDP. Because positions are normalized to screen dimensions, cursor movement/sensitivity is preserved proportionally between different screen sizes.
- Release `⌘` on either Mac to end the session.

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
4. Ensure the sender can resolve `ELTransfer.local` on your network. Right now the sender targets `ELTransfer.local`; later this should become automatic Bonjour discovery.
5. Hold `⌘` on both Macs, then move the sender cursor to a screen edge.

The app prints diagnostic state to Console.app / stderr.
