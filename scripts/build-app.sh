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
# Versions come from history: each commit after the baseline adds 0.0.1 to its version,
# and Sparkle offers an update only when the build number rises.
BASE_COMMIT=9a58a319d0e6032c5d436eee83d278fc2c911a1d
BASE_VERSION=$(git -C "$ROOT" show "$BASE_COMMIT:Resources/Info.plist" | plutil -extract CFBundleShortVersionString raw -)
COMMITS=$(git -C "$ROOT" rev-list --count "$BASE_COMMIT..HEAD")
VERSION=$(printf '%s' "$BASE_VERSION" | awk -F. -v n="$COMMITS" '{ print $1 "." $2 "." $3 + n }')
BUILD=$(git -C "$ROOT" rev-list --count HEAD)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
printf 'Version %s (build %s)\n' "$VERSION" "$BUILD"
chmod +x "$APP/Contents/MacOS/ELTransfer"
mkdir -p "$APP/Contents/Frameworks"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
# ditto preserves the versioned framework's symlinks and embedded helpers.
ditto "$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$FRAMEWORK"

# Sign nested code inside-out with the same identity as the host.
for COMPONENT in \
  "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
  "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
  "$FRAMEWORK/Versions/B/Autoupdate" \
  "$FRAMEWORK/Versions/B/Updater.app" \
  "$FRAMEWORK" "$APP"
do
  if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - "$COMPONENT"
  else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$COMPONENT"
  fi
done
if [ "$SIGN_IDENTITY" = "-" ]; then
  printf '%s\n' 'Ad-hoc build: macOS may ask for permissions again. Use a persistent CODESIGN_IDENTITY for releases.' >&2
fi
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
