<h1 align="center">📡 bobcat-gw</h1>

<p align="center"><b>Turn a retired Bobcat 300 G285 Helium miner into a general-purpose LoRaWAN gateway, with a web UI.</b></p>

<p align="center">
  <img alt="Hardware: Bobcat 300 G285" src="https://img.shields.io/badge/Hardware-Bobcat%20300%20G285-1f6feb?labelColor=555">
  <img alt="SoC: RK3566 and SX1302" src="https://img.shields.io/badge/SoC-RK3566%20%7C%20SX1302-1f6feb?labelColor=555">
  <img alt="OS: Armbian" src="https://img.shields.io/badge/OS-Armbian-f1592a?logo=linux&logoColor=white&labelColor=555">
  <img alt="Python: standard library only" src="https://img.shields.io/badge/Python-stdlib%20only-3776ab?logo=python&logoColor=white&labelColor=555">
  <br>
  <img alt="LoRaWAN: The Things Stack" src="https://img.shields.io/badge/LoRaWAN-The%20Things%20Stack-0d83d0?labelColor=555">
  <img alt="LoRaWAN: ChirpStack" src="https://img.shields.io/badge/LoRaWAN-ChirpStack-0d83d0?labelColor=555">
  <img alt="Backends: Basics Station, packet forwarder, MQTT" src="https://img.shields.io/badge/Backends-Basics%20Station%20%7C%20Packet%20Forwarder%20%7C%20MQTT-2ea44f?labelColor=555">
  <img alt="Remote access: Tailscale" src="https://img.shields.io/badge/Remote%20access-Tailscale-242424?logo=tailscale&logoColor=white&labelColor=555">
</p>

> [!WARNING]
> **This project is vibe coded.** The code, the installer and this README were written by an AI coding assistant, directed and tested by a human on a single Bobcat 300 G285. It has not been reviewed line by line, and it has not been tested on other boards or setups. It works on that one gateway; use it at your own risk, and read `install.sh` before running it as root.

> [!NOTE]
> bobcat-gw is inspired by **[AdvdLaar/Bobcat300-TTN](https://github.com/AdvdLaar/Bobcat300-TTN)**, which first turned the Bobcat 300 into a The Things Network gateway with the Semtech UDP packet forwarder. bobcat-gw uses its G285 concentrator reset sequence, can import its settings, and builds on its approach of running everything from the microSD card.

## Features

- **Three ways to reach your network server**
  - LoRa Basics Station (recommended): LNS or CUPS over TLS, with API key/token or client certificate authentication
  - Semtech UDP packet forwarder: unencrypted and unauthenticated, but supported almost everywhere
  - MQTT, through the ChirpStack MQTT Forwarder
- **Works with any network server** that speaks one of those: The Things Network / The Things Stack, ChirpStack, and others. The web UI has presets for TTN (eu1, nam1, au1) and ChirpStack.
- **Monitor only mode**: receive and show packets (device address, frame counter, RSSI, SNR) without forwarding anything, to check the antenna and coverage before registering the gateway.
- **Web UI** with live statistics:
  - LNS connection state and region
  - uplink and downlink counts since boot and in total
  - a 24-hour packets-per-hour chart
  - recent packets with full ISO timestamps, RSSI and SNR
  - service logs, system health, and the gateway's time zone
- **Remote access** through Tailscale, set up from the web UI.
- **Boot protection**: the kernel, device tree and U-Boot packages are held, so `apt upgrade` can't replace them with versions that don't boot on the Bobcat.
- **Nothing on the eMMC is touched.** Everything runs from the microSD card; remove the card and the Bobcat boots its original Helium firmware.

## Requirements

- A **Bobcat 300 G285** running Armbian from microSD. Flash the G285 image from [sicXnull/Bobcat-Armbian](https://github.com/sicXnull/Bobcat-Armbian) and follow its "G285 – SD Card Boot" and "First Boot" steps.
- **Ethernet.** bobcat-gw is Ethernet-only; the installer switches the built-in WiFi off. See [Why Ethernet only?](#why-ethernet-only)

## Ready-made image

The quickest way: flash a ready-made SD card image and boot straight into the gateway.

1. Download `bobcat-gw-<version>-g285.img.xz` from the releases page and flash it to a microSD card (8 GB or more) with [Balena Etcher](https://etcher.balena.io/) or `dd`.
2. Put the card in the Bobcat, connect Ethernet, and power it on.
3. Wait a few minutes while it sets itself up on first boot, then open **http://bobcat-285.local/** (or the IP address your router gave it) and sign in with the default password **bobcat**. You'll be asked to choose a new one straight away.

The image is the [Bobcat-Armbian](https://github.com/sicXnull/Bobcat-Armbian) G285 image with bobcat-gw added. The web UI password is also root's password: changing one changes both. SSH is off until you turn it on with **Enable SSH** on the System tab (after the default password has been changed). To have SSH from the first boot, put your public key in `bobcat-gw/authorized_keys` on the card's boot partition before the first boot. The first boot works without internet; only the `.local` name and Tailscale need it.

To build the image yourself (Linux or WSL2, as root):

```bash
sudo tools/build-image.sh BobcatArmbian285.img.xz
```

This writes `build/bobcat-gw-<version>-g285.img.xz`. The build only changes files in the image; everything that needs the hardware runs on the gateway's first boot.

## Installation

To install on a Bobcat that already runs Bobcat-Armbian: on the gateway, as root (or with `sudo`):

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/bobcat-gw/main/install.sh | sudo bash
```

`wget -qO- <same URL> | sudo bash` works too. The script downloads the rest of the repository into `/tmp` and runs the installer from there. To pass options, add `-s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/bobcat-gw/main/install.sh | sudo bash -s -- --no-tailscale
```

Or clone the repository and run the installer from it:

```bash
git clone https://github.com/OWNER/bobcat-gw.git
cd bobcat-gw
sudo ./install.sh
```

The installer:

1. checks that the board is a G285 and that the SX1302 concentrator answers on `/dev/spidev1.0`;
2. holds and pins the `linux-image-*`, `linux-dtb-*`, `linux-u-boot-*` and `armbian-bsp-cli-*` packages (see [Boot protection](#boot-protection));
3. stops any old packet forwarder or Helium Docker containers that would compete for the concentrator;
4. installs the prebuilt Basics Station and packet forwarder from `prebuilt/aarch64/`, downloads the ChirpStack MQTT Forwarder, and installs Tailscale from its official repository;
5. switches the built-in WiFi off;
6. keeps logs in RAM to spare the SD card (see [SD card wear](#sd-card-wear));
7. sets up chrony to keep the clock tightly synced (see [Time sync](#time-sync));
8. installs the web UI, asks for a web UI password, and prints the gateway EUI.

It takes a few minutes. The installer re-runs itself in the background, so a dropped SSH session can't interrupt it; the log is in `/var/log/bobcat-gw-install.log`. It is safe to run again.

Options:

| Option | Effect |
|---|---|
| `--password <pw>` | Set the password without prompting (for the web UI and root, which share it) |
| `--default-password` | Use the default password `bobcat` (web UI and root); the web UI asks for a new one on first login |
| `--no-tailscale` | Don't install Tailscale |
| `--build-on-device` | Compile the packet forwarder and Basics Station on the gateway instead of using the prebuilt binaries (very slow) |
| `--force` | Install on a board that isn't a G285 (also set `SPI_DEV=`) |

The one-line install downloads `OWNER/bobcat-gw` at `main`; set `BOBCAT_GW_REPO=you/your-fork` or `BOBCAT_GW_REF=<branch or tag>` (for example `curl ... | sudo BOBCAT_GW_REF=v0.1.0 bash`) to install something else.

**Coming from Bobcat300-TTN?** Its server address and region are imported. Its gateway EUI is not (see [Gateway EUI](#gateway-eui)), so register the gateway again with the new EUI.

## Using the web UI

Open `http://<gateway-ip>/` and sign in.

| Tab | What it's for |
|---|---|
| **Dashboard** | Connection state, packet counters, the 24-hour chart, and recent packets |
| **LNS** | Connection method (or monitor only), preset, region, and for US915/AU915 the sub-band. Saving restarts the backend with the new settings. |
| **Network** | The Ethernet interface, and Tailscale |
| **System** | Health, boot protection status, time sync and time zone, service logs, restarting the services, rebooting, SSH on/off, and the password (for the web UI and root) |

### The Things Network

| Method | In the TTN console | In bobcat-gw |
|---|---|---|
| Basics Station (LNS), recommended | Create an API key with *Link as Gateway to a Gateway Server for traffic exchange*. | URI `wss://eu1.cloud.thethings.network:8887`, auth *API key* |
| Basics Station (CUPS) | Create a CUPS API key with *View gateway information*, *Edit basic gateway settings* and *Retrieve secrets associated with a gateway*. Save the LNS API key in the gateway's settings too: TTN hands it to the gateway over CUPS. | URI `https://eu1.cloud.thethings.network:443`, auth *API key* |
| Semtech UDP | Register the gateway EUI. | Server `eu1.cloud.thethings.network`, ports 1700 |

Use the gateway EUI shown in the web UI, and the cluster (`eu1`, `nam1`, `au1`) you registered on. TTN doesn't accept gateways over MQTT; use MQTT with ChirpStack.

### ChirpStack over MQTT

Point the forwarder at your ChirpStack MQTT broker and set the topic prefix to the ChirpStack region ID (`eu868`, `us915_1`, ...). The gateway publishes to `<prefix>/gateway/<eui>/event/up` like any other ChirpStack gateway.

## Gateway EUI

The gateway EUI is the SX1302 chip's own EUI-64, for example `0016C001F1501019`. Semtech assigns it, so it is globally unique, and it is fixed to the hardware: it can't be changed in the web UI or the API, so a typo or a copied EUI can never clash with another gateway.

The Bobcat's Ethernet MAC is a locally administered address, so an EUI derived from it isn't guaranteed to be unique. bobcat-gw only falls back to it if the installer couldn't read the concentrator.

## Why Ethernet only?

The Bobcat's built-in WiFi (a BCM43430 on SDIO, driver `brcmfmac`) is switched off, and bobcat-gw has no WiFi features.

When the driver starts the chip, it downloads the chip's firmware over the SDIO bus. If the microSD card is being read at the same moment, the SDIO bus jams: one CPU core gets stuck in the SDIO interrupt handler, NetworkManager and everything else that touches the network blocks, and the gateway drops off the network until it is power-cycled. At boot the SD card is always busy, so this happened on most warm reboots and on some cold starts. It looked like "the Bobcat hangs on reboot". With the driver disabled, warm reboots were reliable (10 of 10 in testing).

The installer adds `/etc/modprobe.d/bobcat-gw-no-wifi.conf`, which stops the driver from loading. Starting it later, waiting for the SD card to go quiet, or reading its files into memory first only made the problem less frequent. A proper fix most likely needs a device tree change in the Armbian image: the shipped device tree only describes the WiFi chip with Rockchip's vendor binding, so mainline Linux uses in-band SDIO interrupts instead of the chip's out-of-band host-wake line (GPIO2_B2).

## SD card wear

Logging used to be the gateway's biggest SD card writer: about 2 GB a day of small writes, mostly the systemd journal. The installer keeps the journal in RAM (`/etc/systemd/journald.conf.d/bobcat-gw.conf`, at most 30 MB) and turns on Armbian's ramlog, which holds `/var/log` in RAM and copies it to the card only now and then. The trade-off: logs don't survive a reboot or power cut. The packet totals are kept in their own small file, written every 5 minutes.

## Time sync

The Bobcat has no battery-backed clock, so after a power cut it starts in 2017. LoRa packet timestamps and the TLS connection to the network server both need the right time, so the installer configures chrony (replacing `systemd-timesyncd` if the image uses that) to sync only with `time.cloudflare.com` and `time.google.com`, polling every 64 seconds at first and backing off to about hourly once the clock is stable, and to step the clock straight away whenever it is more than 100 ms off. The System tab shows the sync status, the server in use, and the offset.

Google smears leap seconds over a day while Cloudflare doesn't, and mixing the two is not ideal during a leap second. None is scheduled, and they are due to be abolished by 2035.

## Boot protection

The Bobcat 300 isn't supported by mainline Armbian, and an upgraded kernel, device tree or U-Boot package can leave it unable to boot. The installer runs `apt-mark hold` on those packages and adds `/etc/apt/preferences.d/bobcat-gw-boot-hold`, which pins them so `apt full-upgrade` leaves them alone too. Everything else can be upgraded normally, and the System tab warns if a hold is removed.

## How it works

| Mode | Data path |
|---|---|
| Basics Station | `station` → network server, WebSocket |
| Semtech UDP | `lora_pkt_fwd` → network server, UDP 1700 |
| MQTT | `lora_pkt_fwd` → 127.0.0.1:1700 → `chirpstack-mqtt-forwarder` → MQTT broker |

- Everything runs natively under systemd as `bobcat-gw-station`, `bobcat-gw-pktfwd`, `bobcat-gw-mqtt` and `bobcat-gw-web`. There is no Docker.
- The SX1302 is powered and reset by `/opt/bobcat-gw/bin/reset_lgw.sh` (GPIOs 125 and 122 for power, 149 for reset), the same sequence as Bobcat300-TTN.
- The Bobcat has no STTS751 temperature sensor, which makes the stock Semtech HAL refuse to start. `files/patch_hal_tempsensor.py` patches the HAL to use a fixed 25 °C instead.
- The web UI, `/opt/bobcat-gw/web/bobcat_gw.py`, is a single Python program using only the standard library. It writes the backend configuration, starts and stops the services, and reads statistics from their journal.

| Path | Contents |
|---|---|
| `/etc/bobcat-gw/config.json` | Configuration (mode 600, contains keys) |
| `/etc/bobcat-gw/hw.json` | Hardware details found by the installer |
| `/var/lib/bobcat-gw/` | Generated backend configs, and the packet totals |
| `/opt/bobcat-gw/` | Binaries and the web UI |

Logs: `journalctl -u bobcat-gw-station -f` (or `-pktfwd`, `-mqtt`, `-web`).

### Rebuilding the binaries

`prebuilt/aarch64/` holds Basics Station (`station`) and the packet forwarder (`lora_pkt_fwd`, `chip_id`), cross-compiled on a PC and patched for the missing temperature sensor. To rebuild them on Debian or Ubuntu x86-64:

```bash
sudo tools/build-binaries.sh
```

The script links against Debian 12's libc, so the binaries run on the gateway even if the build machine's libc is newer, and it refuses to finish if a binary needs a newer glibc than Debian 12 has. `prebuilt/aarch64/BUILDINFO` records the versions and checksums.

## Limitations

- Tested on one G285 only. The G280 (SX1301) isn't supported; the G29x uses a different SPI device and is untested.
- The packet forwarder channel plans cover EU868, US915, AU915, AS923-1 and KR920. With Basics Station the network server sends the channel plan.
- Ethernet only (see [Why Ethernet only?](#why-ethernet-only)).
- No GPS, so no Class B beacons and no fine timestamps.
- The web UI is plain HTTP for the local network. Don't expose port 80 to the internet; use Tailscale for remote access.
- If the gateway ever stops responding, unplug the power for at least 60 seconds before plugging it back in.

## Credits

- **[AdvdLaar/Bobcat300-TTN](https://github.com/AdvdLaar/Bobcat300-TTN)**: the inspiration for this project, the original Bobcat 300 TTN conversion, and the G285 reset sequence.
- [sicXnull/Bobcat-Armbian](https://github.com/sicXnull/Bobcat-Armbian): Armbian for the Bobcat 300.
- [metrafonic/Bobcat300-DebianMinimalDocker](https://github.com/metrafonic/Bobcat300-DebianMinimalDocker) and r00t1ng: the LDO reset script.
- [Basics Station](https://github.com/lorabasics/basicstation), Semtech [sx1302_hal](https://github.com/Lora-net/sx1302_hal), and the [ChirpStack MQTT Forwarder](https://github.com/chirpstack/chirpstack-mqtt-forwarder).
