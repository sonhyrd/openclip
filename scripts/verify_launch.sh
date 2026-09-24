#!/bin/bash
# verify_launch.sh
#
# Fails if a packaged OpenClip.app cannot actually start.
#
# verify_signing.sh reads the signature; this runs the binary. dyld loads Core.framework and
# Sparkle.framework before main(), so `OpenClip --version` exits 0 only if library validation
# accepted every linked framework. An ad-hoc build signed with the hardened runtime fails exactly
# here ("Library not loaded … different Team IDs"), and shipped through Sparkle it would brick
# every installed build on auto-update.
#
# Usage:
#   ./scripts/verify_launch.sh <path-to-OpenClip.app>

set -euo pipefail

APP="${1:-}"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "usage: $0 <path-to-OpenClip.app>" >&2
    exit 2
fi
BIN="${APP%/}/Contents/MacOS/OpenClip"

echo "==> Launching $(basename "${APP%/}") headless (--version)"
# perl's alarm is the portable timeout; macOS ships no `timeout`.
STATUS=0
OUTPUT="$(perl -e 'alarm 30; exec @ARGV' "$BIN" --version 2>&1)" || STATUS=$?
echo "$OUTPUT" | sed 's/^/    /'

if [ "$STATUS" -ne 0 ] || ! grep -q "^OpenClip " <<<"$OUTPUT"; then
    echo "error: OpenClip failed to launch (exit $STATUS)." >&2
    if grep -qE "Library not loaded|different Team IDs" <<<"$OUTPUT"; then
        echo "       dyld rejected a bundled framework — an ad-hoc build must not carry the hardened runtime." >&2
    fi
    exit 1
fi
echo "==> Launch OK"
