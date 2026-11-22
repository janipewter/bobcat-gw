#!/bin/bash
# Test bobcat-gw against every Bobcat-Armbian base image it has shipped on.
#
#   sudo tools/test-base-images.sh                  # every base in image/SHIPPED_BASES
#   sudo tools/test-base-images.sh some.img.xz ...  # just these images
#
# Installed gateways keep the base system they were flashed with forever: updates from the
# web UI only rerun install.sh on it. So every release must still work on every base image
# that any release has shipped. Run this before every release; every image must pass.
#
# Each image is mounted read-only (with a throwaway overlay) and its own aarch64 programs run
# under qemu-user, so the checks use the old base's Python, bash and NetworkManager:
#   1. the unit tests (tests/) with the base's python3
#   2. every command the installer and the web UI need exists there (or is installed by
#      install.sh), and the packages install.sh needs are already there (no apt run)
#   3. install.sh and the other scripts parse with the base's bash
#   4. if this version ships a device tree fix (files/install-dtb.sh): on a copy of the
#      image's boot partition it either installs the fix or leaves the device tree untouched,
#      and a second run changes nothing
#   5. if this version writes WiFi profiles: the base's NetworkManager accepts each kind of
#      profile and understands every setting in it
#
# Needs Linux or WSL2 with root, loop devices, overlayfs, xz, curl and qemu-user-static
# (apt install qemu-user-static). Images are found by checksum in $BOBCAT_GW_IMAGES (default:
# ../bobcat-armbian next to the repository) or downloaded into $BOBCAT_GW_IMAGE_CACHE.
set -uo pipefail

# BOBCAT_GW_REPO: the repository to test, when this script runs from a copy (e.g. one with LF
# line endings, made from a Windows checkout)
REPO=${BOBCAT_GW_REPO:-"$(cd "$(dirname "$0")/.." && pwd)"}
IMAGES_DIR=${BOBCAT_GW_IMAGES:-$REPO/../bobcat-armbian}
CACHE=${BOBCAT_GW_IMAGE_CACHE:-/var/cache/bobcat-gw-test-images}
QEMU=/usr/bin/qemu-aarch64-static

die() { echo "ERROR: $*" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || die "run as root (loop devices, mounts, chroot)"
for t in losetup mount xz curl sha256sum chroot git; do command -v "$t" >/dev/null || die "missing tool: $t"; done
[ -x "$QEMU" ] || die "missing $QEMU (apt install qemu-user-static)"

# aarch64 programs run through qemu. "F" makes the kernel keep the interpreter open, so it
# also works inside the chroot. (WSL has no systemd-binfmt, so register it by hand.)
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    [ -e /proc/sys/fs/binfmt_misc/register ] || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
    printf '%s' ':qemu-aarch64:M::\x7f\x45\x4c\x46\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:'"$QEMU"':F' \
        > /proc/sys/fs/binfmt_misc/register || die "could not register qemu-aarch64 with binfmt_misc"
fi

# ---- which images
declare -a LIST=()   # entries: "<file>|<label>"
find_local() {   # a local file with this sha256, or nothing
    local want=$1 f
    for f in "$IMAGES_DIR"/*.img.xz "$IMAGES_DIR"/*/*.img.xz "$CACHE"/*.img.xz; do
        [ -f "$f" ] || continue
        [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$want" ] && { echo "$f"; return; }
    done
}
if [ $# -gt 0 ]; then
    for f in "$@"; do [ -f "$f" ] || die "no such file: $f"; LIST+=("$f|$(basename "$f")"); done
else
    while read -r base armbian date first fixture_url fixture_sha; do
        case "$base" in ''|\#*) continue ;; esac
        label="base ${base:0:12} (Armbian $armbian, $date, shipped since $first)"
        f=$(find_local "$base")
        [ -n "$f" ] || f=$(find_local "$fixture_sha")
        if [ -z "$f" ]; then
            # Upstream replaces its images in place, so the copy kept for an old base is the
            # bobcat-gw release image built on it.
            mkdir -p "$CACHE"
            f="$CACHE/$(basename "$fixture_url")"
            echo "Downloading $fixture_url"
            curl -fL --retry 3 -o "$f.part" "$fixture_url" || die "download failed: $fixture_url"
            [ "$(sha256sum "$f.part" | cut -d' ' -f1)" = "$fixture_sha" ] || die "checksum mismatch: $fixture_url"
            mv "$f.part" "$f"
        fi
        LIST+=("$f|$label")
    done < "$REPO/image/SHIPPED_BASES"
fi
[ ${#LIST[@]} -gt 0 ] || die "no images to test"

# ---- the code under test: the working tree as committed plus uncommitted changes, with LF
# line endings and git's file modes (as tools/build-image.sh does)
SRC=$(mktemp -d /var/tmp/bobcat-gw-src.XXXXXX)
GIT=(git -c safe.directory="$REPO" -C "$REPO")
SNAP=$("${GIT[@]}" stash create 2>/dev/null || true)
"${GIT[@]}" archive "${SNAP:-HEAD}" | tar -x -C "$SRC"
"${GIT[@]}" ls-files -z --others --exclude-standard | (cd "$REPO" && tar --null -T - -c) | tar -x -C "$SRC"
echo "Testing $("${GIT[@]}" describe --tags --always --dirty 2>/dev/null) on ${#LIST[@]} base image(s)"

# Commands that must exist on the base, or be installed by install.sh (its NEED packages).
# Keep in step with the scripts and with the run([...]) calls in web/bobcat_gw.py (those are
# also collected automatically below).
NEED_CMDS="bash sh python3 nmcli ip journalctl systemctl systemd-run hostnamectl timedatectl
  apt-mark apt-get dpkg dpkg-query chpasswd passwd curl tar setsid nohup sed grep awk install
  sha256sum cmp sync timeout mktemp find cut tr head tail id uname hostname ln chmod mkdir rm
  cp mv cat date sleep basename dirname getent gpg lsmod modprobe chronyc"
# Installed by install.sh itself or optional (the scripts check for them)
OPTIONAL_CMDS="tailscale wget lsinitramfs update-initramfs avahi-daemon chirpstack-mqtt-forwarder"
NEED_PKGS=$(sed -n 's/^NEED=(\(.*\))$/\1/p' "$SRC/install.sh")
AUTO_CMDS=$(grep -o -E 'run\(\[ *"[A-Za-z0-9_.-]+"|subprocess\.(call|run|Popen)\(\[ *"[A-Za-z0-9_./-]+"' "$SRC/web/bobcat_gw.py" \
            | sed -E 's/.*"([^"]+)"/\1/' | sort -u | tr '\n' ' ')

W=""; LOOP=""
cleanup() {
    set +e
    if [ -n "$W" ]; then
        for m in "$W/root/tmp/bgw" "$W/root/dev/pts" "$W/root/dev" "$W/root/sys" "$W/root/proc" "$W/root" "$W/boot" "$W/lower" "$W/ovl"; do
            mountpoint -q "$m" && umount -l "$m"
        done
    fi
    [ -n "$LOOP" ] && losetup -d "$LOOP"
    [ -n "$W" ] && rm -rf "$W"
    W=""; LOOP=""
}
trap 'cleanup; rm -rf "$SRC"' EXIT

RESULTS=()
for entry in "${LIST[@]}"; do
    file=${entry%%|*}; label=${entry#*|}
    echo; echo "=================================================================="
    echo " $label"
    echo " $file"
    echo "=================================================================="
    FAIL=0
    pass() { echo "  PASS  $*"; }
    fail() { echo "  FAIL  $*"; FAIL=1; }
    note() { echo "  note  $*"; }

    W=$(mktemp -d /var/tmp/bobcat-gw-base.XXXXXX)
    case "$file" in
        *.xz) xz -dc -T0 "$file" > "$W/image.img" || { fail "could not unpack"; RESULTS+=("FAIL  $label"); cleanup; continue; } ;;
        *)    cp --sparse=always "$file" "$W/image.img" ;;
    esac
    LOOP=$(losetup -fP -r --show "$W/image.img")
    command -v udevadm >/dev/null && udevadm settle 2>/dev/null
    mkdir -p "$W/lower" "$W/ovl" "$W/root" "$W/boot"
    mount -o ro "${LOOP}p3" "$W/lower" && mount -o ro "${LOOP}p2" "$W/boot" || { fail "could not mount (not a Bobcat-Armbian G285 image?)"; RESULTS+=("FAIL  $label"); cleanup; continue; }
    mount -t tmpfs tmpfs "$W/ovl" && mkdir -p "$W/ovl/up" "$W/ovl/work"
    mount -t overlay overlay -o "lowerdir=$W/lower,upperdir=$W/ovl/up,workdir=$W/ovl/work" "$W/root"
    mount --bind /proc "$W/root/proc"; mount --bind /sys "$W/root/sys"; mount --bind /dev "$W/root/dev"
    mount --bind /dev/pts "$W/root/dev/pts" 2>/dev/null
    mkdir -p "$W/root/tmp/bgw"; mount --bind "$SRC" "$W/root/tmp/bgw"
    in_image() { chroot "$W/root" /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 "$@"; }

    grep -h -E '^(BOARD|VERSION)=' "$W/lower/etc/armbian-release" 2>/dev/null | tr '\n' ' ' | sed 's/^/  base: /'; echo
    echo "  python $(in_image python3 -c 'import platform; print(platform.python_version())' 2>&1), $(in_image nmcli --version 2>&1), bash $(in_image bash -c 'echo $BASH_VERSION')"

    # 1. unit tests with the base's Python
    out=$(in_image /bin/sh -c 'cd /tmp/bgw && python3 -m unittest discover -s tests 2>&1')
    if printf '%s\n' "$out" | tail -n 3 | grep -q '^OK'; then
        pass "unit tests: $(printf '%s\n' "$out" | grep -E '^Ran ' | head -n1)"
    else
        fail "unit tests with the base's python3:"; printf '%s\n' "$out" | tail -n 30 | sed 's/^/        /'
    fi

    # 2. commands and packages
    nopkg=""; for p in $NEED_PKGS; do in_image dpkg -s "$p" >/dev/null 2>&1 || nopkg="$nopkg $p"; done
    if [ -z "$nopkg" ]; then pass "install.sh's packages already installed (no apt run: $NEED_PKGS)"
    else note "install.sh will apt-get install:$nopkg (works, but slow and memory-hungry on the G285)"; fi
    missing=""; for c in $(printf '%s\n' $NEED_CMDS $AUTO_CMDS | sort -u); do
        case " $OPTIONAL_CMDS " in *" $c "*) continue ;; esac
        in_image /bin/sh -c "command -v '$c'" >/dev/null 2>&1 || missing="$missing $c"
    done
    if [ -z "$missing" ]; then pass "all required commands present"
    elif [ -n "$nopkg" ]; then note "commands not on this base yet:$missing (check that install.sh's packages$nopkg provide them)"
    else fail "commands missing on this base:$missing"; fi

    # 3. the scripts parse with the base's bash
    bad=""; for s in install.sh files/*.sh image/firstboot.sh; do
        [ -f "$SRC/$s" ] || continue
        in_image bash -n "/tmp/bgw/$s" 2>/dev/null || bad="$bad $s"
    done
    [ -z "$bad" ] && pass "scripts parse with the base's bash" || fail "bash syntax errors in:$bad"

    # 4. device tree fix: install it or leave the device tree untouched, never anything else
    if [ -f "$SRC/files/install-dtb.sh" ]; then
        mkdir -p "$W/root/tmp/bootcopy" && cp -a "$W/boot/." "$W/root/tmp/bootcopy/"
        dtb=$(grep -o 'dtb/[A-Za-z0-9_./-]*\.dtb' "$W/boot/boot.cmd" 2>/dev/null | head -n1)
        before=$( [ -n "$dtb" ] && sha256sum "$W/root/tmp/bootcopy/$dtb" | cut -d' ' -f1 )
        out=$(in_image bash /tmp/bgw/files/install-dtb.sh /tmp/bootcopy /tmp/bgw/files/dtb/rk3566-bobcat.dtb 2>&1); rc=$?
        after=$( [ -n "$dtb" ] && sha256sum "$W/root/tmp/bootcopy/$dtb" | cut -d' ' -f1 )
        ours=$(sha256sum "$SRC/files/dtb/rk3566-bobcat.dtb" | cut -d' ' -f1)
        if [ $rc -eq 0 ] && [ "$after" = "$ours" ]; then
            if [ "$before" = "$ours" ] || cmp -s "$W/root/tmp/bootcopy/bobcat-gw/$(basename "$dtb").orig" "$W/boot/$dtb"; then
                out2=$(in_image bash /tmp/bgw/files/install-dtb.sh /tmp/bootcopy /tmp/bgw/files/dtb/rk3566-bobcat.dtb 2>&1); rc2=$?
                [ $rc2 -eq 0 ] && [ "$(sha256sum "$W/root/tmp/bootcopy/$dtb" | cut -d' ' -f1)" = "$ours" ] \
                    && pass "device tree: fix installed, original kept, second run changes nothing" \
                    || fail "device tree: second run changed something ($out2)"
            else
                fail "device tree: installed, but the original was not kept"
            fi
        elif [ $rc -eq 0 ] && [ "$after" = "$before" ]; then
            pass "device tree: already has the fix, left as it is ($out)"
        elif [ $rc -ne 0 ] && [ "$after" = "$before" ]; then
            pass "device tree: left untouched, WiFi stays off on this base ($out)"
        else
            fail "device tree: changed to something unexpected (rc=$rc: $out)"
        fi
    fi

    # 5. WiFi profiles: the base's NetworkManager must accept them and understand every setting
    if grep -q '^def wifi_keyfile' "$SRC/web/bobcat_gw.py"; then
        out=$(in_image /bin/bash -c 'cd /tmp/bgw/web && python3 - <<"EOF"
import bobcat_gw as bg, os, re, subprocess
PEM = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
cases = {
    "personal": {"ssid": "Home", "password": "secret123"},
    "personal-hidden-odd-ssid": {"ssid": " Badger;Net\\\\ IoT ", "hidden": True, "password": " pa;ss\\\\w= "},
    "wpa3-only": {"ssid": "W3", "security": "sae", "password": "secret123"},
    "open": {"ssid": "Cafe", "security": "open"},
    "peap-mschapv2-custom-ca": {"ssid": "Corp", "security": "enterprise", "eap": "peap", "phase2": "mschapv2",
        "identity": "u@x.org", "password": "p", "anonymous_identity": "anon@x.org", "ca": "custom", "ca_cert": PEM},
    "ttls-pap-system-ca-domain": {"ssid": "Corp", "security": "enterprise", "eap": "ttls", "phase2": "pap",
        "identity": "u", "password": "p", "ca": "system", "domain": "radius.x.org"},
    "ttls-mschap-no-check": {"ssid": "Corp", "security": "enterprise", "eap": "ttls", "phase2": "mschap",
        "identity": "u", "password": "p", "ca": "none"},
}
bad = 0
for name, s in cases.items():
    text = bg.wifi_keyfile(bg.clean_wifi(s), "11111111-2222-3333-4444-555555555555")
    p = subprocess.run(["nmcli", "--offline", "connection", "modify", "connection.id", bg.WIFI_CON],
                       input=text, capture_output=True, text=True)
    if p.returncode:
        print(f"REJECTED {name}: {p.stderr.strip()}"); bad = 1; continue
    def keys(t):
        sec, out = None, set()
        for line in t.splitlines():
            m = re.match(r"^\[(.+)\]$", line)
            if m: sec = m.group(1)
            elif "=" in line and sec: out.add(sec + "." + line.split("=", 1)[0])
        return out
    lost = keys(text) - keys(p.stdout)
    if lost:
        print(f"NOT UNDERSTOOD {name}: {sorted(lost)}"); bad = 1
    else:
        print(f"ok {name}")
raise SystemExit(bad)
EOF' 2>&1); rc=$?
        if [ $rc -eq 0 ]; then pass "NetworkManager accepts every kind of WiFi profile ($(printf '%s\n' "$out" | grep -c '^ok ') kinds)"
        else fail "NetworkManager on this base and our WiFi profiles:"; printf '%s\n' "$out" | grep -v '^ok ' | sed 's/^/        /'; fi
    fi

    cleanup
    if [ $FAIL -eq 0 ]; then RESULTS+=("PASS  $label"); else RESULTS+=("FAIL  $label"); fi
done

echo; echo "==== Summary"
printf '  %s\n' "${RESULTS[@]}"
printf '%s\n' "${RESULTS[@]}" | grep -q '^FAIL' && { echo "Not compatible with every shipped base image: fix before releasing."; exit 1; }
echo "Compatible with every tested base image."
