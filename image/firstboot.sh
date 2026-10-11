#!/bin/bash
# bobcat-gw first boot (ready-made image only): run the normal installer once, unattended.
#
# Started by bobcat-gw-firstboot.service on the image's first boot, after Armbian has
# resized the root filesystem and made new SSH host keys. The web UI and root get the
# default password bobcat, and the web UI makes you change it on first login (root's
# password follows). SSH stays off until you enable it in the web UI, unless you put
# keys on the boot partition. Works offline too: only avahi (bobcat-xxx.local names) and
# Tailscale need the internet, and the installer carries on without them.

LOG=/var/log/bobcat-gw-install.log
DONE=/var/lib/bobcat-gw/firstboot.done
exec >>"$LOG" 2>&1
echo "=== bobcat-gw first boot, $(date -Is)"

# Optional: SSH keys put on the card's boot partition (FAT) as bobcat-gw/authorized_keys.
KEYS=0
if [ -s /boot/bobcat-gw/authorized_keys ]; then
    KEYS=1
    install -d -m 700 /root/.ssh
    tr -d '\r' < /boot/bobcat-gw/authorized_keys >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    echo "Added SSH keys from /boot/bobcat-gw/authorized_keys"
fi

# Give the network up to 2 minutes; the installer works without it, just with less.
for _ in $(seq 1 60); do
    getent hosts deb.debian.org >/dev/null 2>&1 && break
    sleep 2
done

for attempt in 1 2 3; do
    if BGW_DETACHED=1 bash /opt/bobcat-gw-src/install.sh --default-password; then
        # root's password is the well-known default until it is changed in the web UI, so
        # keep SSH off (enable it in the web UI) unless keys were supplied above.
        if [ "$KEYS" -eq 0 ]; then
            systemctl disable --now ssh
            echo "SSH is off: enable it on the web UI's System tab"
        else
            # SSH stays on for the keys, but not with the default password: lock root's
            # password until it is changed in the web UI (which sets and unlocks it).
            passwd -l root >/dev/null
            echo "SSH is on for the keys from the boot partition (root's password locked until changed)"
        fi
        mkdir -p "$(dirname "$DONE")"
        touch "$DONE"
        systemctl disable bobcat-gw-firstboot.service
        sync
        echo "=== bobcat-gw first boot finished"
        exit 0
    fi
    echo "=== install failed (attempt $attempt of 3), trying again in 60 s"
    sleep 60
done
exit 1
