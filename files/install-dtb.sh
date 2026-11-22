#!/bin/bash
# Make sure the G285 boots a device tree with working WiFi (see files/dtb/rk3566-bobcat.dts).
#
#   install-dtb.sh BOOT_DIR NEW_DTB
#
# BOOT_DIR is the boot partition (/boot on the board, the mounted image's boot partition in
# tools/build-image.sh). Exit 0 if the device tree the bootloader loads has the WiFi fix,
# after installing NEW_DTB if needed; exit 1 if it doesn't (the caller then keeps the WiFi
# driver blocked, because on the old device tree it can hang the board).
set -euo pipefail
BOOT=${1:?usage: $0 BOOT_DIR NEW_DTB}
NEW=${2:?usage: $0 BOOT_DIR NEW_DTB}
no() { echo "WiFi device tree: $*"; exit 1; }

# Bobcat-Armbian's boot script names the DTB itself and ignores fdtfile in armbianEnv.txt;
# fall back to fdtfile in case a later image goes back to Armbian's usual boot script.
DTB=""
[ -f "$BOOT/boot.cmd" ] && DTB=$(grep -o 'dtb/[A-Za-z0-9_./-]*\.dtb' "$BOOT/boot.cmd" | head -n1 || true)
if [ -z "$DTB" ] && [ -f "$BOOT/armbianEnv.txt" ]; then
    f=$(sed -n 's/^fdtfile=//p' "$BOOT/armbianEnv.txt" | tr -d '\r' | head -n1)
    [ -n "$f" ] && DTB="dtb/$f"
fi
[ -n "$DTB" ] || no "can't tell which DTB the bootloader loads"
CUR="$BOOT/$DTB"
[ -f "$CUR" ] || no "$DTB not found"

# Already fixed (this file, or a newer Bobcat-Armbian image that has the fix itself): a
# mainline brcmfmac node. The old G285 device tree has only Rockchip's vendor node.
if grep -q -a 'bcm4329-fmac' "$CUR"; then
    cmp -s "$CUR" "$NEW" && echo "WiFi device tree: installed" || echo "WiFi device tree: $DTB already has the fix"
    exit 0
fi
# Only replace the exact device tree the fix was made from and tested against. A different
# one (another board's, or a newer Bobcat-Armbian image's without the fix) may need things this
# older copy lacks, and swapping it could stop the board booting: leave it, WiFi stays off.
# sha256 of dtb/rockchip/rk3566-bobcat.dtb in Bobcat-Armbian G285 2026-01-19 (image/BASE_IMAGE).
KNOWN_ORIG="591156896a1668ce366a404a46b6ba63e5d3a6e0a695911cff42f33111b5df55"
[ "$(basename "$DTB")" = "$(basename "$NEW")" ] || no "$DTB is not the G285 device tree this fix is for"
case " $KNOWN_ORIG " in
    *" $(sha256sum "$CUR" | cut -d' ' -f1) "*) ;;
    *) no "$DTB is not the Bobcat-Armbian device tree this fix was tested with; leaving it alone" ;;
esac

mkdir -p "$BOOT/bobcat-gw"
[ -f "$BOOT/bobcat-gw/$(basename "$DTB").orig" ] || cp "$CUR" "$BOOT/bobcat-gw/$(basename "$DTB").orig"
cp "$NEW" "$CUR.new"
sync
mv "$CUR.new" "$CUR"
sync
if ! cmp -s "$CUR" "$NEW"; then
    cp "$BOOT/bobcat-gw/$(basename "$DTB").orig" "$CUR" && sync
    no "writing $DTB failed; put the original back"
fi
echo "WiFi device tree: installed $DTB (original kept in $BOOT/bobcat-gw/); WiFi works after a reboot"
