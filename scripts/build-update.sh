#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/build/ELTransfer.app"
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
UPDATES="$ROOT/website/updates"
mkdir -p "$UPDATES"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/eltransfer-update.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT INT TERM
ARCHIVE="$STAGING/ELTransfer-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$TOOLS/generate_appcast" --ed-key-file - \
    --download-url-prefix https://duuberian.com/eltransfer/updates/ \
    --link https://duuberian.com/eltransfer/ --maximum-deltas 0 \
    -o "$STAGING/appcast.xml" "$STAGING"
else
  "$TOOLS/generate_appcast" --account com.duuberian.ELTransfer \
    --download-url-prefix https://duuberian.com/eltransfer/updates/ \
    --link https://duuberian.com/eltransfer/ --maximum-deltas 0 \
    -o "$STAGING/appcast.xml" "$STAGING"
fi
cp "$ARCHIVE" "$UPDATES/"
cp "$STAGING/appcast.xml" "$ROOT/website/appcast.xml"
printf 'Signed update %s\n' "$ARCHIVE"
