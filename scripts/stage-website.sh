#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST=${1:?Pass the website staging directory}
test -f "$ROOT/website/downloads/ELTransfer.dmg"
mkdir -p "$DEST/eltransfer"
rsync -a --delete --exclude '*.md' --exclude '.DS_Store' "$ROOT/website/" "$DEST/eltransfer/"
python3 "$ROOT/scripts/stamp-site-version.py" "$DEST/eltransfer/"*.html
# This staging helper owns only /eltransfer/ in the homepage repository.
