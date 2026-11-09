#!/bin/bash
# Before every release: check that the image is built from the newest upstream versions of
#   - the Bobcat-Armbian G285 base image (tools/check-base-image.sh)
#   - Semtech sx1302_hal and LoRa Basics Station (built into prebuilt/aarch64/)
#   - the ChirpStack MQTT Forwarder (MQF_VERSION in install.sh)
#   - Tailscale (not pinned: the first boot installs the newest stable from pkgs.tailscale.com,
#     so it is only reported)
#
#   tools/check-upstream.sh
#
# Exit 0: all up to date. Exit 10: something has a newer version (details printed).
# Exit 1: a check itself failed. Needs curl and python3.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PY=$(command -v python3 || command -v python) || { echo "ERROR: needs python3" >&2; exit 1; }
RC=0
newer() { RC=$((RC == 1 ? 1 : 10)); }
fail()  { echo "ERROR: $*" >&2; RC=1; }
pin()   { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$2"; }

# Newest full release of a GitHub repo (pre-releases and test tags don't count).
latest() {
    curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$1/releases/latest" |
        "$PY" -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])'
}

echo "== Base image"
"$REPO/tools/check-base-image.sh"
case $? in 0) ;; 10) newer ;; *) fail "base image check failed" ;; esac

# sx1302_hal and Basics Station are pinned twice: build-binaries.sh builds prebuilt/aarch64/,
# install.sh rebuilds on the gateway with --build-on-device. Both must agree.
check_built() {  # label repo VAR
    local a b up
    a=$(pin "$3" "$REPO/tools/build-binaries.sh"); b=$(pin "$3" "$REPO/install.sh")
    echo "== $1"
    [ "$a" = "$b" ] || { fail "$3 differs: build-binaries.sh $a, install.sh $b"; return; }
    up=$(latest "$2") || { fail "could not get the latest $2 release"; return; }
    if [ "$up" = "$a" ]; then
        echo "Up to date: $a"
    else
        echo "Newer release: $up (ours: $a, https://github.com/$2/releases/tag/$up)"
        echo "Set $3 in tools/build-binaries.sh and install.sh, check the no-temperature-sensor"
        echo "patches still apply, rebuild prebuilt/aarch64/ and test it on a G285."
        newer
    fi
}
check_built "Semtech sx1302_hal" Lora-net/sx1302_hal HAL_VERSION
check_built "LoRa Basics Station" lorabasics/basicstation STATION_VERSION

echo "== ChirpStack MQTT Forwarder"
MQF=$(pin MQF_VERSION "$REPO/install.sh")
if up=$(latest chirpstack/chirpstack-mqtt-forwarder); then
    up=${up#v}
    if [ "$up" = "$MQF" ]; then
        echo "Up to date: $MQF"
    else
        echo "Newer release: $up (ours: $MQF)"
        url=$(pin MQF_URL "$REPO/install.sh"); url=${url//\$\{MQF_VERSION\}/$up}
        if curl -fsSIL -o /dev/null "$url"; then
            echo "Set MQF_VERSION=$up in install.sh and test it on a G285."
        else
            echo "Its arm64 .deb isn't published yet ($url): wait for it before bumping."
        fi
        newer
    fi
else
    fail "could not get the latest chirpstack-mqtt-forwarder release"
fi

echo "== Tailscale"
if ts=$(curl -fsSL "https://pkgs.tailscale.com/stable/?mode=json" |
        "$PY" -c 'import json, sys; print(json.load(sys.stdin)["Version"])'); then
    echo "Latest stable: $ts (installed on first boot from the stable apt repo, nothing to bump)"
else
    fail "could not get the latest Tailscale version"
fi

echo
case $RC in
    0)  echo "All up to date." ;;
    10) echo "Newer upstream versions above: integrate them before the release." ;;
esac
exit $RC
