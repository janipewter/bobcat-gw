#!/bin/bash
# bobcat-gw installer: turns a Bobcat 300 G285 running Armbian into a LoRaWAN
# gateway with a web UI. Supports LoRa Basics Station, the Semtech UDP packet forwarder and MQTT
# (ChirpStack MQTT Forwarder). Ethernet only: the onboard WiFi is disabled.
#
# Inspired by https://github.com/AdvdLaar/Bobcat300-TTN
#
# Usage: sudo ./install.sh [--password <password> | --default-password] [--rebuild] [--build-on-device] [--force] [--no-tailscale]
#    or: curl -fsSL https://raw.githubusercontent.com/janipewter/bobcat-gw/main/install.sh | sudo bash -s -- [options]
set -euo pipefail

VERSION="0.1.0"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP=/opt/bobcat-gw
CONF=/etc/bobcat-gw
STATE=/var/lib/bobcat-gw
BUILD=/var/cache/bobcat-gw/build

HAL_REPO=https://github.com/Lora-net/sx1302_hal.git
HAL_VERSION=V2.1.0
STATION_REPO=https://github.com/lorabasics/basicstation.git
STATION_VERSION=v2.0.6
MQF_VERSION=4.6.1
MQF_URL="https://artifacts.chirpstack.io/packages/4.x/deb/pool/main/c/chirpstack-mqtt-forwarder/chirpstack-mqtt-forwarder_${MQF_VERSION}_linux_arm64.deb"

SPI_DEV="${SPI_DEV:-/dev/spidev1.0}"
WEB_PASSWORD=""
DEFAULT_PW=0    # default password bobcat for the web UI and root, changed on first login
REBUILD=0
BUILD_ON_DEVICE=0
FORCE=0
TAILSCALE=1

ARGS=("$@")   # kept for re-running the installer: the loop below consumes "$@"
while [ $# -gt 0 ]; do
    case "$1" in
        --password) WEB_PASSWORD="$2"; shift 2 ;;
        --default-password) DEFAULT_PW=1; shift ;;
        --rebuild)  REBUILD=1; shift ;;
        --build-on-device) BUILD_ON_DEVICE=1; shift ;;
        --force)    FORCE=1; shift ;;
        --no-tailscale) TAILSCALE=0; shift ;;
        -h|--help)  sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

step() { echo; echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ------------------------------------------------------------------
# One-line install: `curl -fsSL <raw install.sh URL> | sudo bash`. Piped in like that, the
# script has none of the repository's files around it, so download the repository and run
# the real installer from there. Options are passed on (`| sudo bash -s -- --password x`).
GITHUB_REPO="${BOBCAT_GW_REPO:-janipewter/bobcat-gw}"
GITHUB_REF="${BOBCAT_GW_REF:-main}"
if [ ! -f "$SRC_DIR/web/bobcat_gw.py" ]; then
    [ "$(id -u)" -eq 0 ] || die "run as root: curl -fsSL <install.sh URL> | sudo bash"
    TARBALL="${BOBCAT_GW_TARBALL:-https://github.com/$GITHUB_REPO/archive/$GITHUB_REF.tar.gz}"
    DL=$(mktemp -d /tmp/bobcat-gw.XXXXXX)
    echo "Downloading bobcat-gw from $TARBALL"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$TARBALL" | tar -xz -C "$DL" --strip-components=1
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$TARBALL" | tar -xz -C "$DL" --strip-components=1
    else
        die "neither curl nor wget is installed"
    fi
    [ -f "$DL/install.sh" ] && [ -f "$DL/web/bobcat_gw.py" ] || die "the download does not look like bobcat-gw"
    # stdin is the pipe the script came from; give the real installer the terminal, if
    # there is one, so it can ask for the web UI password.
    if (: </dev/tty) 2>/dev/null; then
        exec bash "$DL/install.sh" "${ARGS[@]}" </dev/tty
    fi
    exec bash "$DL/install.sh" "${ARGS[@]}" </dev/null
fi

echo "=========================================="
echo " bobcat-gw ${VERSION} - Bobcat 300 LoRaWAN gateway"
echo "=========================================="

[ "$(id -u)" -eq 0 ] || die "run as root (sudo $0)"
[ "$(uname -m)" = "aarch64" ] || die "expected an arm64 (aarch64) system"
for f in web/bobcat_gw.py web/static/index.html files/reset_lgw.sh files/patch_hal_tempsensor.py; do
    [ -f "$SRC_DIR/$f" ] || die "missing $f; run install.sh from the bobcat-gw directory"
done

# ------------------------------------------------------------------
# Run detached, so a dropped SSH session cannot interrupt the install (the board is slow
# to respond while it builds). The password is asked for first, as that needs a terminal.
if [ -z "${BGW_DETACHED:-}" ]; then
    if [ "$DEFAULT_PW" -eq 0 ] && [ -z "$WEB_PASSWORD" ] && [ -t 0 ] && ! grep -q '"password_hash": "pbkdf2' "$CONF/config.json" 2>/dev/null; then
        while :; do
            read -r -s -p "Choose a web UI password (8+ characters): " WEB_PASSWORD; echo
            [ "${#WEB_PASSWORD}" -ge 8 ] && break
            echo "Too short."
        done
    fi
    LOGFILE=/var/log/bobcat-gw-install.log
    BGW_DETACHED=1 BGW_PW="$WEB_PASSWORD" setsid nohup "$0" "${ARGS[@]}" </dev/null >"$LOGFILE" 2>&1 &
    CHILD=$!
    echo "Installing in the background; it is safe if this connection drops."
    echo "Log file: $LOGFILE   (re-attach with: tail -f $LOGFILE)"
    sleep 1
    tail -n +1 -f "$LOGFILE" --pid="$CHILD" || true
    grep -q "bobcat-gw installed" "$LOGFILE" && exit 0
    exit 1
fi
[ -z "${BGW_PW:-}" ] || WEB_PASSWORD="$BGW_PW"
unset BGW_PW

# ------------------------------------------------------------------
step "Checking hardware"
BOARD=""
[ -f /etc/armbian-release ] && BOARD=$(. /etc/armbian-release; echo "${BOARD:-}")
[ -n "$BOARD" ] || BOARD=$(hostname)
echo "Board: $BOARD"
case "$BOARD" in
    bobcat-285) ;;
    *)
        [ "$FORCE" -eq 1 ] || die "this installer is made for the Bobcat 300 G285 (board '$BOARD'). Use --force (and SPI_DEV=...) at your own risk."
        echo "WARNING: untested board, continuing because of --force" ;;
esac
[ -e "$SPI_DEV" ] || die "SPI device $SPI_DEV not found. Is the Bobcat device tree installed?"
[ -d /sys/class/gpio ] || die "sysfs GPIO (/sys/class/gpio) is not available"
echo "SPI device: $SPI_DEV"

# ------------------------------------------------------------------
step "Holding the kernel, device tree and bootloader packages"
# The Bobcat 300 is not mainlined in Armbian: an upgraded kernel, DTB or
# U-Boot package can leave the gateway unable to boot. Hold them, and pin them
# so even 'apt full-upgrade' leaves them alone.
mapfile -t HOLD_PKGS < <(dpkg-query -W -f='${Package} ${db:Status-Status}\n' \
    'linux-image-*' 'linux-dtb-*' 'linux-u-boot-*' 'armbian-bsp-cli-*' 2>/dev/null \
    | awk '$2 == "installed" { print $1 }')
if [ "${#HOLD_PKGS[@]}" -eq 0 ]; then
    echo "WARNING: no Armbian kernel/DTB/U-Boot packages found to hold"
else
    apt-mark hold "${HOLD_PKGS[@]}"
    {
        echo "# Written by bobcat-gw: the Bobcat 300 boots only with the installed"
        echo "# kernel, device tree and U-Boot. Remove this file (and apt-mark unhold)"
        echo "# only if you know the replacement packages support the board."
        for p in "${HOLD_PKGS[@]}"; do
            printf 'Package: %s\nPin: release *\nPin-Priority: -1\n\n' "$p"
        done
    } > /etc/apt/preferences.d/bobcat-gw-boot-hold
fi

# ------------------------------------------------------------------
step "Stopping software that uses the concentrator"
systemctl stop bobcat-gw-station bobcat-gw-pktfwd bobcat-gw-mqtt 2>/dev/null || true
if command -v docker >/dev/null 2>&1; then
    # Bobcat300-TTN / Helium packet forwarder containers would fight over the SPI bus.
    for c in $(docker ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null \
               | awk 'tolower($0) ~ /pktfwd|sx1302|helium|miner|packet.forwarder/ { print $1 }'); do
        echo "Stopping container $c and disabling its restart policy"
        docker update --restart=no "$c" >/dev/null 2>&1 || true
        docker stop "$c" >/dev/null 2>&1 || true
    done
fi

# ------------------------------------------------------------------
step "Checking packages"
export DEBIAN_FRONTEND=noninteractive
# Skip apt's huge "Contents" indexes and pdiffs: on this board 'apt-get update' with them
# can take tens of minutes and over 1 GB of RAM.
# Run apt in a memory-capped group, so that if it ever misbehaves the kernel kills only apt
# instead of taking the whole (2 GB, no real swap) gateway down.
memcap() {
    if command -v systemd-run >/dev/null 2>&1; then
        systemd-run --scope --quiet --collect -p MemoryHigh=500M -p MemoryMax=700M -p MemorySwapMax=0 "$@"
    else
        "$@"
    fi
}
APT_OPTS=(-o DPkg::Lock::Timeout=900 -y -q
          -o Acquire::IndexTargets::deb::Contents-deb::DefaultEnabled=false
          -o Acquire::PDiffs=false)
NEED=(curl ca-certificates python3 network-manager coreutils chrony)
[ "$BUILD_ON_DEVICE" -eq 1 ] && NEED+=(build-essential git)
MISSING=()
for p in "${NEED[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p"); done
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "Installing: ${MISSING[*]}"
    memcap apt-get "${APT_OPTS[@]}" update
    memcap nice -n 10 apt-get "${APT_OPTS[@]}" install --no-install-recommends "${MISSING[@]}"
else
    echo "All required packages are already installed"
fi

mkdir -p "$APP/bin" "$APP/web/static" "$CONF" "$STATE" "$BUILD"
chmod 700 "$CONF"
install -m 755 "$SRC_DIR/files/reset_lgw.sh" "$APP/bin/reset_lgw.sh"
install -m 755 "$SRC_DIR/files/rinit.sh" "$APP/bin/rinit.sh"
sed -i 's/\r$//' "$APP/bin/reset_lgw.sh" "$APP/bin/rinit.sh"

# ------------------------------------------------------------------
if [ "$BUILD_ON_DEVICE" -eq 0 ]; then
    step "Installing the prebuilt packet forwarder and Basics Station"
    PREBUILT="$SRC_DIR/prebuilt/aarch64"
    for b in lora_pkt_fwd chip_id station; do
        [ -f "$PREBUILT/$b" ] || die "missing prebuilt/aarch64/$b. Build the binaries on a PC with tools/build-binaries.sh (compiling on the gateway is slow and can overload it; --build-on-device forces that)."
        install -m 755 "$PREBUILT/$b" "$APP/bin/$b"
        if MISSING_LIBS=$(ldd "$APP/bin/$b" 2>&1 | grep -E "not found|version"); then
            die "$b cannot run on this system: $MISSING_LIBS"
        fi
    done
    [ -f "$PREBUILT/BUILDINFO" ] && sed 's/^/  /' "$PREBUILT/BUILDINFO" | head -4
else
    fetch_tag() {  # repo tag dir
        [ -d "$3/.git" ] || git clone -q --depth 1 -b "$2" "$1" "$3"
    }
    step "Building Semtech sx1302_hal $HAL_VERSION on the gateway (slow)"
    rm -rf "$BUILD/sx1302_hal"
    fetch_tag "$HAL_REPO" "$HAL_VERSION" "$BUILD/sx1302_hal"
    python3 "$SRC_DIR/files/patch_hal_tempsensor.py" "$BUILD/sx1302_hal/libloragw/src/loragw_hal.c"
    nice -n 19 make -C "$BUILD/sx1302_hal" -j1 >"$BUILD/sx1302_hal.log" 2>&1 \
        || { tail -30 "$BUILD/sx1302_hal.log"; die "sx1302_hal build failed (log: $BUILD/sx1302_hal.log)"; }
    install -m 755 "$BUILD/sx1302_hal/packet_forwarder/lora_pkt_fwd" "$APP/bin/lora_pkt_fwd"
    install -m 755 "$BUILD/sx1302_hal/util_chip_id/chip_id" "$APP/bin/chip_id"

    step "Building LoRa Basics Station $STATION_VERSION on the gateway (very slow)"
    rm -rf "$BUILD/basicstation"
    fetch_tag "$STATION_REPO" "$STATION_VERSION" "$BUILD/basicstation"
    # Fetch the bundled HAL first so it can be patched before it is compiled.
    (cd "$BUILD/basicstation/deps/lgw1302" && platform=corecell variant=std ./prep.sh) >"$BUILD/station.log" 2>&1 \
        || { tail -30 "$BUILD/station.log"; die "Basics Station HAL preparation failed"; }
    python3 "$SRC_DIR/files/patch_hal_tempsensor.py" \
        "$BUILD/basicstation/deps/lgw1302/platform-corecell/libloragw/src/loragw_hal.c"
    # The corecell platform defaults to a 32-bit ARM cross toolchain; build natively instead.
    nice -n 19 make -C "$BUILD/basicstation" -j1 platform=corecell variant=std ARCH="$(gcc -dumpmachine)" >>"$BUILD/station.log" 2>&1 \
        || { tail -30 "$BUILD/station.log"; die "Basics Station build failed (log: $BUILD/station.log)"; }
    install -m 755 "$BUILD/basicstation/build-corecell-std/bin/station" "$APP/bin/station"
fi

if [ "$REBUILD" -eq 1 ] || [ ! -x "$APP/bin/chirpstack-mqtt-forwarder" ]; then
    step "Installing ChirpStack MQTT Forwarder $MQF_VERSION"
    rm -rf "$BUILD/mqf" && mkdir -p "$BUILD/mqf"
    curl -fsSL "$MQF_URL" -o "$BUILD/mqf/mqf.deb" || die "download failed: $MQF_URL"
    # Only the binary is used; the package's own service is not installed.
    dpkg-deb -x "$BUILD/mqf/mqf.deb" "$BUILD/mqf/root"
    install -m 755 "$BUILD/mqf/root/usr/bin/chirpstack-mqtt-forwarder" "$APP/bin/chirpstack-mqtt-forwarder"
else
    echo "MQTT forwarder already installed"
fi

# ------------------------------------------------------------------
if [ "$TAILSCALE" -eq 1 ]; then
    step "Installing Tailscale (optional remote access; log in from the web UI)"
    if ! command -v tailscale >/dev/null 2>&1; then
        CODENAME=$(. /etc/os-release; echo "${VERSION_CODENAME:-bookworm}")
        {
            curl -fsSL "https://pkgs.tailscale.com/stable/debian/${CODENAME}.noarmor.gpg"                 -o /usr/share/keyrings/tailscale-archive-keyring.gpg &&
            curl -fsSL "https://pkgs.tailscale.com/stable/debian/${CODENAME}.tailscale-keyring.list"                 -o /etc/apt/sources.list.d/tailscale.list &&
            memcap apt-get "${APT_OPTS[@]}" -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/tailscale.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 update &&
            memcap apt-get "${APT_OPTS[@]}" install --no-install-recommends tailscale
        } || echo "WARNING: Tailscale could not be installed (continuing without it; re-run to retry)"
    else
        echo "Tailscale already installed"
    fi
    if command -v tailscale >/dev/null 2>&1; then
        systemctl enable --now tailscaled >/dev/null 2>&1 || true
        [ -e /dev/net/tun ] || modprobe tun 2>/dev/null || true
        if [ -e /dev/net/tun ]; then
            echo "Tailscale: kernel TUN device available"
        else
            # No TUN in this kernel: run tailscaled in userspace mode. The web UI is still
            # reachable over the tailnet because the manager publishes it with 'tailscale serve'.
            echo "Tailscale: no /dev/net/tun, using userspace networking mode"
            if grep -q '^FLAGS=' /etc/default/tailscaled 2>/dev/null; then
                sed -i 's|^FLAGS=.*|FLAGS="--tun=userspace-networking"|' /etc/default/tailscaled
            else
                echo 'FLAGS="--tun=userspace-networking"' >> /etc/default/tailscaled
            fi
            systemctl restart tailscaled >/dev/null 2>&1 || true
        fi
    fi
fi

# ------------------------------------------------------------------
step "Installing the web UI and services"
install -m 755 "$SRC_DIR/web/bobcat_gw.py" "$APP/web/bobcat_gw.py"
install -m 644 "$SRC_DIR/web/static/index.html" "$APP/web/static/index.html"
cat > /usr/local/sbin/bobcat-gw-update <<'EOF'
#!/bin/sh
# Update bobcat-gw to the newest release on GitHub (as the web UI's System tab does).
#   bobcat-gw-update [--check]
exec /usr/bin/python3 /opt/bobcat-gw/web/bobcat_gw.py --update-cli "$@"
EOF
chmod 755 /usr/local/sbin/bobcat-gw-update
for u in "$SRC_DIR"/files/systemd/*.service; do
    install -m 644 "$u" /etc/systemd/system/
done
mkdir -p "$STATE/station" "$STATE/pktfwd" "$STATE/mqtt"
ln -sf "$APP/bin/reset_lgw.sh" "$STATE/pktfwd/reset_lgw.sh"
systemctl daemon-reload

# ------------------------------------------------------------------
step "Disabling the onboard WiFi"
# The BCM43430 WiFi (brcmfmac, SDIO) jams its SDIO bus if the SD card is busy while the
# driver starts the chip, which is nearly always the case at boot. The board then looks
# dead (no network, no SSH) and only a power cycle recovers it; this is also what made
# warm reboots "hang". So the gateway is Ethernet-only and the driver is never loaded.
cat > /etc/modprobe.d/bobcat-gw-no-wifi.conf <<'EOF'
# bobcat-gw: the onboard BCM43430 WiFi can hang the Bobcat when its driver starts.
# The gateway is Ethernet-only. Remove this file at your own risk.
blacklist brcmfmac
blacklist brcmfmac_wcc
install brcmfmac /bin/false
EOF
if command -v lsinitramfs >/dev/null 2>&1 && lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null | grep -q brcmfmac; then
    update-initramfs -u >/dev/null 2>&1 || echo "Warning: could not update the initramfs; WiFi may still load at boot"
fi
if lsmod | grep -q '^brcmfmac'; then
    echo "The WiFi driver is loaded now; it stays off from the next boot."
fi
# Clean up after older bobcat-gw versions: WiFi/hotspot profiles, captive portal, and the
# cold-reboot hook (warm reboots are fine without WiFi).
for c in bobcat-wifi bobcat-hotspot; do nmcli connection delete "$c" >/dev/null 2>&1 || true; done
rm -f /etc/NetworkManager/dnsmasq-shared.d/bobcat-gw.conf /etc/bobcat-gw/wifi-ca.pem \
      /usr/lib/systemd/system-shutdown/bobcat-gw-cold-reboot

# ------------------------------------------------------------------
step "Reducing SD card writes"
# Logging was the gateway's biggest SD card writer (about 2 GB a day of small writes,
# mostly the systemd journal). Keep the journal in RAM, and let Armbian's ramlog hold
# /var/log in RAM and copy it to the card only now and then. Logs don't survive a reboot.
rm -f /etc/systemd/journald.conf.d/bobcat-gw-debug.conf   # left over from debugging
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/bobcat-gw.conf <<'EOF'
# bobcat-gw: keep the journal in RAM to spare the SD card. Logs don't survive a reboot.
[Journal]
Storage=volatile
RuntimeMaxUse=30M
EOF
systemctl restart systemd-journald
rm -rf /var/log/journal
if [ -f /etc/default/armbian-ramlog ]; then
    sed -i 's/^ENABLED=.*/ENABLED=true/' /etc/default/armbian-ramlog
    systemctl enable armbian-ramlog >/dev/null 2>&1 || true
    # ramlog copies /var/log into a small RAM disk at boot: drop old rotated logs first
    find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' \) -delete
    echo "Logs are kept in RAM from the next boot (armbian-ramlog)."
fi

# ------------------------------------------------------------------
step "Setting up time sync (chrony)"
# The board has no battery-backed clock: after a power cut it starts in 2017. Sync fast
# and keep tracking closely: LoRa packet timestamps and TLS to the network server depend
# on it. chrony replaces systemd-timesyncd (the package conflicts with it).
cat > /etc/chrony/sources.d/bobcat-gw.sources <<'EOF'
# bobcat-gw: quick first sync (iburst), then back off from 64 s to about hourly (2^12 s).
server time.cloudflare.com iburst minpoll 6 maxpoll 12
server time.google.com iburst minpoll 6 maxpoll 12
EOF
cat > /etc/chrony/conf.d/bobcat-gw.conf <<'EOF'
# bobcat-gw: step the clock whenever it is more than 100 ms off, not only at start-up.
makestep 0.1 -1
EOF
# Make sure chrony reads the two files above (Debian's chrony.conf does, older ones may not).
grep -q '^sourcedir /etc/chrony/sources.d' /etc/chrony/chrony.conf || echo 'sourcedir /etc/chrony/sources.d' >> /etc/chrony/chrony.conf
grep -q '^confdir /etc/chrony/conf.d' /etc/chrony/chrony.conf || echo 'confdir /etc/chrony/conf.d' >> /etc/chrony/chrony.conf
# Use only the servers above: comment out the distribution's pool and its makestep.
sed -i -e 's/^\(pool .*\)/# bobcat-gw: \1/' -e 's/^\(makestep .*\)/# bobcat-gw: \1/' /etc/chrony/chrony.conf
systemctl enable chrony >/dev/null 2>&1 || true
systemctl restart chrony
sleep 5
chronyc -n sources 2>/dev/null | tail -n +3 || true

# ------------------------------------------------------------------
step "Enabling <hostname>.local (avahi mDNS)"
# Optional: lets you open http://<hostname>.local/ without looking up the IP address.
# Needs the internet to install; the gateway works without it.
if ! dpkg -s avahi-daemon >/dev/null 2>&1; then
    { memcap apt-get "${APT_OPTS[@]}" update &&
      memcap nice -n 10 apt-get "${APT_OPTS[@]}" install --no-install-recommends avahi-daemon; }         || echo "WARNING: avahi could not be installed (no internet?). Use the IP address instead."
fi
systemctl enable --now avahi-daemon >/dev/null 2>&1 || true

# ------------------------------------------------------------------
step "Identifying the gateway"
IFACE=""
for i in end0 eth0; do [ -e "/sys/class/net/$i/address" ] && { IFACE=$i; break; }; done
MAC_EUI=""
if [ -n "$IFACE" ]; then
    MAC=$(tr -d ':' < "/sys/class/net/$IFACE/address" | tr '[:lower:]' '[:upper:]')
    MAC_EUI="${MAC:0:6}FFFE${MAC:6:6}"
    echo "MAC-derived EUI ($IFACE): $MAC_EUI"
fi
CHIP_EUI=""
TMP=$(mktemp -d)
ln -s "$APP/bin/reset_lgw.sh" "$TMP/reset_lgw.sh"
if OUT=$(cd "$TMP" && timeout 60 "$APP/bin/chip_id" -d "$SPI_DEV" 2>&1); then
    CHIP_EUI=$(echo "$OUT" | sed -n 's/.*concentrator EUI: 0x\([0-9a-fA-F]\{16\}\).*/\1/p' | tr '[:lower:]' '[:upper:]')
fi
rm -rf "$TMP"
if [ -n "$CHIP_EUI" ]; then
    echo "SX1302 concentrator found, chip EUI: $CHIP_EUI"
else
    echo "WARNING: could not read the SX1302 concentrator. Output:"
    echo "$OUT" | tail -5
fi

STATION_VER=$("$APP/bin/station" --version 2>&1 | head -1 | sed -n 's/^Station: \([^ (]*\).*/\1/p' || true)
python3 - "$CONF/hw.json" <<EOF
import json, sys
json.dump({
    "board": "$BOARD",
    "spi_dev": "$SPI_DEV",
    "mac_eui": "$MAC_EUI",
    "chip_eui": "$CHIP_EUI",
    "held_packages": "${HOLD_PKGS[*]:-}".split(),
    "versions": {
        "sx1302_hal": "$HAL_VERSION",
        "Basics Station": """$STATION_VER""".strip() or "$STATION_VERSION",
        "MQTT forwarder": "$MQF_VERSION",
        "Tailscale": """$(tailscale version 2>/dev/null | head -1)""".strip() or "not installed",
    },
}, open(sys.argv[1], "w"), indent=2)
EOF

# ------------------------------------------------------------------
step "Configuring"
if [ "$DEFAULT_PW" -eq 0 ] && [ -z "$WEB_PASSWORD" ] && ! grep -q '"password_hash": "pbkdf2' "$CONF/config.json" 2>/dev/null; then
    if [ -t 0 ]; then
        while :; do
            read -r -s -p "Choose a web UI password (8+ characters): " WEB_PASSWORD; echo
            [ "${#WEB_PASSWORD}" -ge 8 ] && break
            echo "Too short."
        done
    else
        WEB_PASSWORD=$(tr -dc 'a-km-np-z2-9' < /dev/urandom | head -c 12)
        GENERATED_PW=1
    fi
fi
# The web UI password is root's password too (bobcat_gw.py --init sets both).
SET_DEFAULT=""
[ "$DEFAULT_PW" -eq 1 ] && [ -z "$WEB_PASSWORD" ] && ! grep -q '"password_hash": "pbkdf2' "$CONF/config.json" 2>/dev/null && SET_DEFAULT=1
RESULT=$(BOBCAT_GW_PASSWORD="$WEB_PASSWORD" BOBCAT_GW_DEFAULT_PASSWORD="$SET_DEFAULT" python3 "$APP/web/bobcat_gw.py" --init | tail -1)
systemctl enable bobcat-gw-web.service >/dev/null 2>&1
systemctl restart bobcat-gw-web.service

get() { python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('$1',''))" "$RESULT"; }
IPS=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -3 | tr '\n' ' ')

echo
echo "=========================================="
echo " bobcat-gw installed"
echo "=========================================="
echo
echo "Web UI       : $(for ip in $IPS; do printf 'http://%s/  ' "$ip"; done)"
systemctl is-active --quiet avahi-daemon 2>/dev/null && echo "               http://$(hostname).local/"
[ "${GENERATED_PW:-0}" = 1 ] && echo "Web password : $WEB_PASSWORD   (generated - change it in System)"
[ -n "$SET_DEFAULT" ] && echo "Password     : bobcat (default, for the web UI and root). The web UI asks you to change it on first login."
[ -n "$WEB_PASSWORD" ] && [ "${GENERATED_PW:-0}" != 1 ] && echo "Password     : as given; root's password is now the same as the web UI password"
echo "Gateway EUI  : $(get gateway_eui)"
echo "Backend      : $(get backend)   region $(get region)"
echo
echo "Network      : Ethernet only (the onboard WiFi is disabled)"
echo
echo "Next: open the web UI, choose the LNS connection on the LNS tab, and"
echo "register the gateway EUI on your network server."
