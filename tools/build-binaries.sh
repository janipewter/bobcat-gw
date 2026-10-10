#!/bin/bash
# Cross-compile the gateway binaries for the Bobcat (Debian 12 "bookworm", arm64) on an
# x86-64 Debian/Ubuntu machine, so nothing has to be compiled on the gateway itself (its
# SD card and 2 GB of RAM make that slow and, in practice, unreliable).
#
# Produces prebuilt/aarch64/{lora_pkt_fwd,chip_id,station,BUILDINFO}.
#
# The binaries are linked against Debian 12's own libc (downloaded into a sysroot), so
# they run on the gateway even if this machine has a newer libc (e.g. Ubuntu 24.04).
#
# Usage: sudo tools/build-binaries.sh        (run as root; uses apt to install the toolchain)
set -euo pipefail

HAL_REPO=https://github.com/Lora-net/sx1302_hal.git
HAL_VERSION=V2.1.0
STATION_REPO=https://github.com/lorabasics/basicstation.git
STATION_VERSION=v2.0.6
DEBIAN_MIRROR=http://deb.debian.org/debian
DEBIAN_SUITE=bookworm
TRIPLE=aarch64-linux-gnu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
WORK="${WORK:-/root/bgw-build}"
OUT="$ROOT/prebuilt/aarch64"
SYSROOT="$WORK/sysroot"
TCBIN="$WORK/tc/bin"

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
mkdir -p "$WORK" "$OUT" "$TCBIN"

echo "==> Installing the cross toolchain"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq gcc gcc-$TRIPLE binutils-$TRIPLE make git curl python3 xz-utils qemu-user >/dev/null

echo "==> Building the Debian $DEBIAN_SUITE arm64 sysroot"
if [ ! -f "$SYSROOT/usr/include/stdio.h" ]; then
    rm -rf "$SYSROOT" "$WORK/debs"; mkdir -p "$SYSROOT" "$WORK/debs"
    curl -fsSL "$DEBIAN_MIRROR/dists/$DEBIAN_SUITE/main/binary-arm64/Packages.xz" | xz -dc > "$WORK/Packages"
    for pkg in libc6 libc6-dev linux-libc-dev libcrypt1 libcrypt-dev libgcc-s1; do
        file=$(awk -v p="$pkg" 'BEGIN{RS="";FS="\n"} $1=="Package: "p {for(i=1;i<=NF;i++) if($i ~ /^Filename:/) print substr($i,11)}' "$WORK/Packages")
        [ -n "$file" ] || { echo "package $pkg not found in the Debian index"; exit 1; }
        curl -fsSL "$DEBIAN_MIRROR/$file" -o "$WORK/debs/$pkg.deb"
        dpkg-deb -x "$WORK/debs/$pkg.deb" "$SYSROOT"
    done
    # Debian is "merged /usr"; make the multiarch library directory complete under /usr/lib.
    mkdir -p "$SYSROOT/usr/lib/$TRIPLE"
    [ -d "$SYSROOT/lib/$TRIPLE" ] && cp -a "$SYSROOT/lib/$TRIPLE/." "$SYSROOT/usr/lib/$TRIPLE/"
fi
LIBC_VER=$(dpkg-deb -f "$WORK/debs/libc6.deb" Version 2>/dev/null || true)
echo "sysroot libc: ${LIBC_VER:-unknown}"

echo "==> Toolchain wrappers (compile and link against the sysroot)"
# The distro's cross compiler searches its own (newer) glibc headers before the sysroot's,
# which makes the binaries need symbols this libc lacks. -nostdinc plus explicit paths avoids that:
# the compiler's own headers first, then only Debian 12's.
CC_INC=$("$TRIPLE-gcc" -print-file-name=include)
CC_INC_FIXED=$("$TRIPLE-gcc" -print-file-name=include-fixed)
INC_ARGS="-nostdinc"
[ -d "$CC_INC_FIXED" ] && INC_ARGS="$INC_ARGS -isystem $CC_INC_FIXED"
INC_ARGS="$INC_ARGS -isystem $CC_INC -isystem $SYSROOT/usr/include/$TRIPLE -isystem $SYSROOT/usr/include"
printf '#!/bin/sh\nexec /usr/bin/%s-gcc --sysroot=%s %s "$@"\n' "$TRIPLE" "$SYSROOT" "$INC_ARGS" > "$TCBIN/$TRIPLE-gcc"
for t in ar ld objdump objcopy strip ranlib; do
    ln -sf "/usr/bin/$TRIPLE-$t" "$TCBIN/$TRIPLE-$t"
done
chmod +x "$TCBIN"/*

echo "==> sx1302_hal $HAL_VERSION (packet forwarder, chip_id)"
rm -rf "$WORK/sx1302_hal"
git clone -q --depth 1 -b "$HAL_VERSION" "$HAL_REPO" "$WORK/sx1302_hal"
python3 "$ROOT/files/patch_hal_tempsensor.py" "$WORK/sx1302_hal/libloragw/src/loragw_hal.c"
make -C "$WORK/sx1302_hal" -j"$(nproc)" CROSS_COMPILE="$TCBIN/$TRIPLE-" >"$WORK/hal.log" 2>&1 \
    || { tail -30 "$WORK/hal.log"; exit 1; }
install -m 755 "$WORK/sx1302_hal/packet_forwarder/lora_pkt_fwd" "$OUT/lora_pkt_fwd"
install -m 755 "$WORK/sx1302_hal/util_chip_id/chip_id" "$OUT/chip_id"

echo "==> LoRa Basics Station $STATION_VERSION"
rm -rf "$WORK/basicstation" "$WORK/home"
mkdir -p "$WORK/home"
git clone -q --depth 1 -b "$STATION_VERSION" "$STATION_REPO" "$WORK/basicstation"
# Station looks for its cross toolchain in $HOME/toolchain-<platform>/bin/<ARCH>-gcc
ln -s "$WORK/tc" "$WORK/home/toolchain-corecell"
(cd "$WORK/basicstation/deps/lgw1302" && platform=corecell variant=std ./prep.sh) >"$WORK/station.log" 2>&1 \
    || { tail -30 "$WORK/station.log"; exit 1; }
python3 "$ROOT/files/patch_hal_tempsensor.py" \
    "$WORK/basicstation/deps/lgw1302/platform-corecell/libloragw/src/loragw_hal.c"
# -j1: the bundled makefiles build the radio library twice concurrently and corrupt its generated config.h
HOME="$WORK/home" make -C "$WORK/basicstation" -j1 platform=corecell variant=std ARCH=$TRIPLE \
    >>"$WORK/station.log" 2>&1 || { tail -40 "$WORK/station.log"; exit 1; }
install -m 755 "$WORK/basicstation/build-corecell-std/bin/station" "$OUT/station"

echo "==> Checking the binaries"
for b in lora_pkt_fwd chip_id station; do
    readelf -h "$OUT/$b" | grep -q "AArch64" || { echo "$b is not an aarch64 binary"; exit 1; }
    maxv=$($TRIPLE-objdump -T "$OUT/$b" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)
    echo "  $b: needs up to ${maxv:-no versioned glibc symbols}"
    # the gateway runs glibc 2.36 (Debian 12)
    case "${maxv#GLIBC_}" in
        2.3[7-9]*|2.[4-9]*) echo "  ERROR: $b needs a newer glibc than Debian 12 provides"; exit 1 ;;
    esac
done
echo "  smoke test under qemu:"
qemu-aarch64 -L "$SYSROOT" "$OUT/station" --version 2>&1 | head -3 | sed 's/^/    /'

{
    echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(. /etc/os-release; echo "$PRETTY_NAME")"
    echo "sx1302_hal: $HAL_VERSION (patched for no temperature sensor)"
    echo "basicstation: $STATION_VERSION (patched for no temperature sensor)"
    echo "sysroot libc: ${LIBC_VER:-unknown} (Debian $DEBIAN_SUITE)"
    (cd "$OUT" && sha256sum lora_pkt_fwd chip_id station)
} > "$OUT/BUILDINFO"
echo; cat "$OUT/BUILDINFO"
