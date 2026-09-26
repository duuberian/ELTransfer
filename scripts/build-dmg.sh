#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/build/ELTransfer.app"
OUTPUT_DIR=${DMG_OUTPUT_DIR:-"$ROOT/website/downloads"}
OUTPUT="$OUTPUT_DIR/ELTransfer.dmg"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/eltransfer-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT INT TERM

if [ ! -d "$APP" ]; then
  "$ROOT/scripts/build-app.sh"
fi

# Finder metadata is written directly by dmgbuild, so this works on headless CI.
TOOLS="$ROOT/build/dmg-tools"
if [ ! -x "$TOOLS/bin/python" ]; then python3 -m venv "$TOOLS"; fi
if ! "$TOOLS/bin/python" -c 'import importlib.metadata as m; assert m.version("dmgbuild") == "1.6.7" and m.version("ds_store") == "1.3.3" and m.version("mac_alias") == "2.2.3"' 2>/dev/null; then
  "$TOOLS/bin/python" -m pip install --disable-pip-version-check dmgbuild==1.6.7 ds_store==1.3.3 mac_alias==2.2.3
fi
mkdir -p "$OUTPUT_DIR"
swift "$ROOT/scripts/dmg-background.swift" "$STAGING/installer.tiff"
"$TOOLS/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" -D "root=$ROOT" -D "background=$STAGING/installer.tiff" ELTransfer "$STAGING/ELTransfer.dmg"
"$TOOLS/bin/python" "$ROOT/scripts/verify-dmg.py" "$STAGING/ELTransfer.dmg"
mv "$STAGING/ELTransfer.dmg" "$OUTPUT"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256"
)
printf 'Created %s\n' "$OUTPUT"
