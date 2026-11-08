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

# A newer image could also come as a new release under another tag: list every release
# with a G285 image ("285" in the file name) other than ours.
ALL="https://api.github.com/repos/sicXnull/Bobcat-Armbian/releases?per_page=100"
all=$(curl -fsSL -H "Accept: application/vnd.github+json" "$ALL") || { echo "ERROR: could not reach $ALL" >&2; exit 1; }
OTHERS=$(printf '%s' "$all" | "$PY" -c '
import json, sys
for r in json.load(sys.stdin):
    if r["tag_name"] == sys.argv[1] or r.get("draft"):
        continue
    for a in r["assets"]:
        if "285" in a["name"]:
            pre = " (pre-release)" if r.get("prerelease") else ""
            print("  release " + r["tag_name"] + pre + ", " + r["published_at"] + ": " + a["name"])
' "$TAG")

if [ "$UP_SHA" = "$SHA" ] && [ -z "$OTHERS" ]; then
    echo "Up to date: $NAME from $(get UPDATED) (Armbian $(get ARMBIAN))"
    exit 0
fi
if [ -n "$OTHERS" ]; then
    echo "Upstream has G285 images in other releases than $TAG (ours: $NAME in $TAG):"
    echo "$OTHERS"
    echo "Check which is newest. Download it, test it on a G285, then update image/BASE_IMAGE (URL,"
    echo "SHA256, UPDATED, and ARMBIAN from /etc/armbian-release in the image) before the next release."
    exit 10
fi
echo "Upstream has a new $NAME, updated $UP_DATE"
echo "  ours:     $SHA ($(get UPDATED))"
echo "  upstream: $UP_SHA"
echo "Download it, test it on a G285, then update image/BASE_IMAGE (SHA256, UPDATED, and ARMBIAN"
echo "from /etc/armbian-release in the image) before building the next release."
exit 10
