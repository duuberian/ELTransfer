#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift build --package-path "$ROOT" -c release
BIN_DIR=$(swift build --package-path "$ROOT" -c release --show-bin-path)
APP="$ROOT/build/ELTransfer.app"
SIGN_IDENTITY=${CODESIGN_IDENTITY:--}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ELTransfer" "$APP/Contents/MacOS/ELTransfer"
cp "$ROOT/Resources/ELTransfer.icns" "$APP/Contents/Resources/ELTransfer.icns"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/ELTransfer"

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
  printf '%s\n' 'Ad-hoc build: macOS may ask for permissions again. Use a persistent CODESIGN_IDENTITY for releases.' >&2
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
