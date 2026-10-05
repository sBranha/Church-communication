#!/bin/bash
set -euo pipefail

# The current Mac app baseline is 3.0.1. This wrapper builds the next Mac app
# version, 3.0.2, while preserving the current website-compatible six-digit
# pairing and huge full-screen-priority alert changes from the underlying build.
TMP_SCRIPT="$(mktemp /tmp/cc-techbooth-3.0.2.XXXXXX.sh)"
trap 'rm -f "$TMP_SCRIPT"' EXIT
cp scripts/build-tech-booth-3.0.0.sh "$TMP_SCRIPT"

python3 - "$TMP_SCRIPT" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
s = s.replace("VER='2.5.22'", "VER='3.0.2'")
s = s.replace('Set :CFBundleVersion 20522', 'Set :CFBundleVersion 302')
s = s.replace('2.5.22', '3.0.2')
p.write_text(s)
PY

chmod +x "$TMP_SCRIPT"
bash "$TMP_SCRIPT"

test -s releases/Church-Communications-Tech-Booth-3.0.2.dmg
test -s releases/Church-Communications-Tech-Booth-3.0.2.dmg.sha256.txt
