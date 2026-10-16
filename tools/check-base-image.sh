#!/bin/bash
# Check whether sicXnull/Bobcat-Armbian has a newer G285 image than the one in image/BASE_IMAGE.
#
#   tools/check-base-image.sh
#
# Exit 0: up to date. Exit 10: upstream has a different image (details printed).
# Exit 1: the check itself failed. Needs curl and python3.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
get() { sed -n "s/^$1=//p" "$REPO/image/BASE_IMAGE"; }
URL=$(get URL); SHA=$(get SHA256)
NAME=${URL##*/}
TAG=$(basename "$(dirname "$URL")")
API="https://api.github.com/repos/sicXnull/Bobcat-Armbian/releases/tags/$TAG"

json=$(curl -fsSL -H "Accept: application/vnd.github+json" "$API") || { echo "ERROR: could not reach $API" >&2; exit 1; }
PY=$(command -v python3 || command -v python) || { echo "ERROR: needs python3" >&2; exit 1; }
read -r UP_SHA UP_DATE < <(printf '%s' "$json" | "$PY" -c '
import json, sys
a = [a for a in json.load(sys.stdin)["assets"] if a["name"] == sys.argv[1]]
print((a[0].get("digest") or "-").removeprefix("sha256:"), a[0]["updated_at"]) if a else print("missing -")
' "$NAME")
[ "$UP_SHA" != missing ] || { echo "ERROR: $NAME is no longer in upstream release $TAG" >&2; exit 1; }
[ "$UP_SHA" != - ] || { echo "ERROR: upstream gives no checksum for $NAME" >&2; exit 1; }

if [ "$UP_SHA" = "$SHA" ]; then
    echo "Up to date: $NAME from $(get UPDATED) (Armbian $(get ARMBIAN))"
    exit 0
fi
echo "Upstream has a new $NAME, updated $UP_DATE"
echo "  ours:     $SHA ($(get UPDATED))"
echo "  upstream: $UP_SHA"
echo "Download it, test it on a G285, then update image/BASE_IMAGE (SHA256, UPDATED, and ARMBIAN"
echo "from /etc/armbian-release in the image) before building the next release."
exit 10
