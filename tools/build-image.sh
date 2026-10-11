#!/bin/bash
# Build a ready-to-flash bobcat-gw SD card image from the Bobcat-Armbian G285 image.
#
#   sudo tools/build-image.sh BobcatArmbian285.img.xz [output.img.xz]
#
# Needs Linux (or WSL2) with root, loop devices, xz and curl. The board itself isn't needed:
# everything that depends on the hardware (the gateway EUI, package holds, Tailscale) runs
# on the card's first boot through image/firstboot.sh, which calls the normal install.sh.
#
# Done here, so that the very first boot is already safe and quiet:
#   - bobcat-gw's source in /opt/bobcat-gw-src and the ChirpStack MQTT Forwarder binary
#   - the WiFi driver blocked (it can hang the board while it starts; see README)
#   - the journal in RAM and Armbian's ramlog on (SD card wear)
#   - Armbian's first-login wizard and console autologin removed, root's password locked
#     (the first boot sets the default password bobcat for the web UI and root; the web
#     UI makes you change it on first login, and SSH stays off until enabled there)
#   - the one-shot first-boot service enabled
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$REPO/install.sh")
MQF_URL=$(sed -n 's/^MQF_URL="\(.*\)"/\1/p' "$REPO/install.sh")
MQF_VERSION=$(sed -n 's/^MQF_VERSION=\(.*\)/\1/p' "$REPO/install.sh")
MQF_URL=${MQF_URL//\$\{MQF_VERSION\}/$MQF_VERSION}

IN=${1:?usage: sudo $0 <BobcatArmbian285.img[.xz]> [output.img.xz]}
OUT=${2:-$REPO/build/bobcat-gw-$VERSION-g285.img.xz}

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }
[ "$(id -u)" -eq 0 ] || die "run as root (loop devices and mounts)"
for t in losetup mount xz curl dpkg-deb blkid; do command -v "$t" >/dev/null || die "missing tool: $t"; done
[ -f "$IN" ] || die "no such file: $IN"

WORK=$(mktemp -d /var/tmp/bobcat-gw-image.XXXXXX)
LOOP=""
R="$WORK/root"
cleanup() {
    set +e
    mountpoint -q "$R/boot" && umount "$R/boot"
    mountpoint -q "$R" && umount "$R"
    [ -n "$LOOP" ] && losetup -d "$LOOP"
    rm -rf "$WORK"
}
trap cleanup EXIT

step "Unpacking $(basename "$IN")"
case "$IN" in
    *.xz) xz -dc -T0 "$IN" > "$WORK/image.img" ;;
    *)    cp --sparse=always "$IN" "$WORK/image.img" ;;
esac

step "Mounting the image"
LOOP=$(losetup -fP --show "$WORK/image.img")
command -v udevadm >/dev/null && udevadm settle || true
[ "$(blkid -o value -s TYPE "${LOOP}p3")" = ext4 ] || die "partition 3 is not ext4: is this the Bobcat-Armbian G285 image?"
[ "$(blkid -o value -s TYPE "${LOOP}p2")" = vfat ] || die "partition 2 is not FAT: is this the Bobcat-Armbian G285 image?"
mkdir -p "$R"
mount "${LOOP}p3" "$R"
mount "${LOOP}p2" "$R/boot"
grep -q '^BOARD=bobcat-285' "$R/etc/armbian-release" || die "not a Bobcat 300 G285 image (/etc/armbian-release)"

step "Adding bobcat-gw $VERSION"
rm -rf "$R/opt/bobcat-gw-src" && mkdir -p "$R/opt/bobcat-gw-src"
GIT=(git -c safe.directory="$REPO" -C "$REPO")   # the repo may belong to another user (WSL)
if "${GIT[@]}" rev-parse --git-dir >/dev/null 2>&1; then
    # The working tree as committed, plus uncommitted changes, with git's file modes
    # (a checkout on a Windows drive loses the executable bits).
    SNAP=$("${GIT[@]}" stash create 2>/dev/null || true)
    "${GIT[@]}" archive "${SNAP:-HEAD}" | tar -x -C "$R/opt/bobcat-gw-src"
    # stash create leaves out new, not yet added files: copy those too (but not ignored ones)
    "${GIT[@]}" ls-files -z --others --exclude-standard | (cd "$REPO" && tar --null -T - -c) | tar -x -C "$R/opt/bobcat-gw-src"
    find "$R/opt/bobcat-gw-src" -name '*.sh' -exec chmod 755 {} +
    echo "  source: $("${GIT[@]}" describe --always --dirty 2>/dev/null)"
else
    cp -a "$REPO/." "$R/opt/bobcat-gw-src/"
fi
rm -rf "$R/opt/bobcat-gw-src/build"

step "Adding ChirpStack MQTT Forwarder $MQF_VERSION"
curl -fsSL "$MQF_URL" -o "$WORK/mqf.deb"
dpkg-deb -x "$WORK/mqf.deb" "$WORK/mqf"
install -D -m 755 "$WORK/mqf/usr/bin/chirpstack-mqtt-forwarder" "$R/opt/bobcat-gw/bin/chirpstack-mqtt-forwarder"

step "Making the first boot safe and SD-card friendly"
# Keep these in step with install.sh, which applies the same settings on normal installs.
cat > "$R/etc/modprobe.d/bobcat-gw-no-wifi.conf" <<'EOF'
# bobcat-gw: the onboard BCM43430 WiFi can hang the Bobcat when its driver starts.
# The gateway is Ethernet-only. Remove this file at your own risk.
blacklist brcmfmac
blacklist brcmfmac_wcc
install brcmfmac /bin/false
EOF
mkdir -p "$R/etc/systemd/journald.conf.d"
cat > "$R/etc/systemd/journald.conf.d/bobcat-gw.conf" <<'EOF'
# bobcat-gw: keep the journal in RAM to spare the SD card. Logs don't survive a reboot.
[Journal]
Storage=volatile
RuntimeMaxUse=30M
EOF
rm -rf "$R/var/log/journal"
[ -f "$R/etc/default/armbian-ramlog" ] && sed -i 's/^ENABLED=.*/ENABLED=true/' "$R/etc/default/armbian-ramlog"

step "Logins: web UI first, no default passwords"
rm -f "$R/root/.not_logged_in_yet"   # Armbian's interactive first-login wizard
rm -f "$R/etc/systemd/system/getty@.service.d/override.conf" \
      "$R/etc/systemd/system/serial-getty@.service.d/override.conf"   # root console autologin
sed -i 's/^root:\([^!*:]\)/root:!\1/' "$R/etc/shadow"   # lock root's password (keys still work)
grep -q '^root:[!*]' "$R/etc/shadow" || die "could not lock root's password"
mkdir -p "$R/boot/bobcat-gw"
cat > "$R/boot/bobcat-gw/README.txt" <<'EOF'
bobcat-gw ready-made image
==========================

On first boot the gateway sets itself up (a few minutes; it needs Ethernet, and the
internet for the optional parts). Then open http://bobcat-285.local/ or http://<its IP>/
and sign in with the default password bobcat. You'll be asked to change it; the new
password is also root's password.

SSH is off until you enable it on the web UI's System tab. To have it on from the first
boot instead, put your public key(s) in a file called authorized_keys in this folder
before the first boot (password login for root then stays off until you change it).
EOF

step "Enabling the first-boot service"
install -m 644 "$REPO/image/bobcat-gw-firstboot.service" "$R/etc/systemd/system/bobcat-gw-firstboot.service"
mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
ln -sf ../bobcat-gw-firstboot.service "$R/etc/systemd/system/multi-user.target.wants/bobcat-gw-firstboot.service"
df -h "$R" | tail -1 | awk '{print "  root filesystem: " $3 " used, " $4 " free (grows to fill the card on first boot)"}'

step "Writing $(basename "$OUT")"
sync
umount "$R/boot"; umount "$R"
losetup -d "$LOOP"; LOOP=""
mkdir -p "$(dirname "$OUT")"
xz -T0 -6 -c "$WORK/image.img" > "$OUT.part"
mv "$OUT.part" "$OUT"
(cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
ls -la "$OUT"
echo "Done. Flash it with Balena Etcher or dd, boot with Ethernet, open http://bobcat-285.local/"
