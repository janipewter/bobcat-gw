# bobcat-gw

Turn a **Bobcat 300 G285** Helium hotspot running Armbian into a general-purpose
LoRaWAN gateway with a web UI.

Inspired by [AdvdLaar/Bobcat300-TTN](https://github.com/AdvdLaar/Bobcat300-TTN), which
does the same for TTN over the Semtech UDP packet forwarder. bobcat-gw adds:

- **Three ways to connect to the LNS:** Semtech UDP packet forwarder, LoRa Basics
  Station (LNS or CUPS, with token or TLS client certificate auth), and MQTT through
  the ChirpStack MQTT Forwarder.
- **Monitor only mode:** receive and display packets (device address, frame counter, RSSI,
  SNR) without forwarding anything, to test the antenna and coverage before you register
  the gateway with a network server.
- **Any network server:** The Things Network or The Things Stack, ChirpStack, or anything
  else that speaks one of the protocols above.
- **Web UI:** configuration plus live statistics: LNS connection state, uplinks and
  downlinks, CRC errors, recent packets with RSSI/SNR, an hourly chart, and logs.
- **Boot protection:** the kernel, device tree and U-Boot packages are held, so
  `apt upgrade` cannot replace them with versions that don't boot on the Bobcat.

Like Bobcat300-TTN, everything runs from the microSD card. The internal eMMC and its
Helium firmware are not touched.

## Requirements

- Bobcat 300 **G285** with Armbian booting from microSD. Follow the
  [Bobcat-Armbian](https://github.com/sicXnull/Bobcat-Armbian) guide: "G285 – SD Card
  Boot" and "First Boot".
- An **Ethernet** connection. bobcat-gw is Ethernet-only: the installer switches the
  built-in WiFi off (see [Ethernet only](#ethernet-only)).

## Install

```bash
git clone https://github.com/<you>/bobcat-gw.git   # or copy this directory to the gateway
cd bobcat-gw
sudo ./install.sh
```

The installer:

1. checks that this is a G285 and that the SX1302 is reachable on `/dev/spidev1.0`,
2. **holds and pins** the `linux-image-*`, `linux-dtb-*`, `linux-u-boot-*` and
   `armbian-bsp-cli-*` packages (see [Boot protection](#boot-protection)),
3. stops any old packet forwarder or Helium Docker containers that would compete for
   the concentrator,
4. installs the prebuilt Semtech packet forwarder and LoRa Basics Station from
   `prebuilt/aarch64/` (no compiling on the gateway, which is slow and can overload it) and
   downloads the ChirpStack MQTT Forwarder, and Tailscale from its official repository,
5. switches the built-in WiFi off for good (see [Ethernet only](#ethernet-only)),
6. installs the web UI, asks for a web UI password, and prints the gateway EUI.

The install takes a few minutes. If you are installing over an existing Bobcat300-TTN setup,
its server and region are imported. Its gateway EUI is not: see [Gateway EUI](#gateway-eui),
so re-register the gateway with the new EUI.

The installer runs itself in the background, so a dropped SSH session cannot interrupt it; the
log is `/var/log/bobcat-gw-install.log`. It is safe to run again if it is ever interrupted.

Options: `--password <pw>` (non-interactive), `--no-tailscale`, `--build-on-device` (compile on the gateway instead of using the prebuilt binaries; very slow),
`--force` (other boards; also set `SPI_DEV=`).

## Use

Open `http://<gateway-ip>/` and sign in.

- **LNS:** pick the connection method (or *Monitor only*) and a preset (TTN eu1/nam1/au1, ChirpStack,
  Custom), the region, and for US915/AU915 the sub-band. Save. The backend restarts
  with the new settings.
- **Dashboard:** connection state, packet counters, a 24-hour chart, and the last
  packets with device address, frame counter, RSSI and SNR.
- **Network:** the Ethernet interface, and Tailscale for remote access.
- **System:** health, boot protection status, service logs, restarting the gateway services, and
  password.

### Registering on The Things Network

| Method | TTN console settings | bobcat-gw |
|---|---|---|
| Semtech UDP | Gateway EUI only. | Server `eu1.cloud.thethings.network`, ports 1700. |
| Basics Station (LNS) | Create an API key with *Link as Gateway to a Gateway Server*. | URI `wss://eu1.cloud.thethings.network:8887`, auth *API key*. |
| Basics Station (CUPS) | Create an API key that can also *view and edit gateway information*. | URI `https://eu1.cloud.thethings.network:443`, auth *API key*. |

Use the same gateway EUI as shown in the web UI. TTN does not accept gateways over
MQTT; use MQTT with ChirpStack.

### ChirpStack over MQTT

Point the broker at your ChirpStack MQTT broker and set the topic prefix to the
ChirpStack region ID (`eu868`, `us915_1`, …). The gateway publishes to
`<prefix>/gateway/<eui>/event/up` like any ChirpStack gateway.

## Gateway EUI

The gateway EUI is the SX1302 concentrator chip's own EUI-64 (for example
`0016C001F1501019`). Semtech assigns it, so it is globally unique, and it is fixed to
the hardware: it cannot be changed in the web UI or the API, so a typo or a copied EUI
can never clash with another gateway. The Ethernet MAC on the Bobcat is a locally
administered address, so an EUI derived from it is not guaranteed to be unique. It is
used only as a fallback if the installer could not read the concentrator.

## Ethernet only

The Bobcat's built-in WiFi (a BCM43430 on SDIO, driver `brcmfmac`) is switched off, and
bobcat-gw has no WiFi or WiFi hotspot features.

When the driver starts the chip, it downloads the chip's firmware over the SDIO bus. If the
microSD card is being read at the same time, the SDIO bus jams: one CPU core gets stuck in
the SDIO interrupt handler, NetworkManager and everything else that touches the network
blocks, and the gateway drops off the network with no way back except a power cycle. At boot
the SD card is always busy, so this happened on most warm reboots and on some cold starts,
which is what looked like "the Bobcat hangs on reboot". With the driver disabled, reboots
are reliable (10 of 10 warm reboots in testing).

The installer adds `/etc/modprobe.d/bobcat-gw-no-wifi.conf`, which stops the driver from
loading. Starting it later, waiting for the SD card to be quiet, or reading its files into
memory first only made the problem less frequent. A fix probably needs a device tree change
for the WiFi chip (no in-band SDIO interrupt, or an out-of-band one), which bobcat-gw does
not make.

## Rebuilding the binaries

`prebuilt/aarch64/` holds the packet forwarder (`lora_pkt_fwd`, `chip_id`) and Basics Station,
cross-compiled on a PC and patched to work without the temperature sensor the Bobcat lacks.
To rebuild them (Debian/Ubuntu x86-64, as root):

```bash
sudo tools/build-binaries.sh
```

The script links against Debian 12's own libc, so the result runs on the gateway even when
the build machine's libc is newer, and refuses to finish if a binary needs a newer glibc than
Debian 12 has. `prebuilt/aarch64/BUILDINFO` records versions and checksums.

## Boot protection

The Bobcat 300 is not supported by mainline Armbian. An upgraded kernel, device tree
or U-Boot package can leave it unable to boot. The installer runs `apt-mark hold` on
these packages and adds `/etc/apt/preferences.d/bobcat-gw-boot-hold`, which pins them
so `apt full-upgrade` leaves them alone too. Everything else can be upgraded normally.
The System tab warns if a hold is removed.

## How it works

| Mode | Processes |
|---|---|
| Semtech UDP | `lora_pkt_fwd` → LNS:1700 |
| MQTT | `lora_pkt_fwd` → 127.0.0.1:1700 → `chirpstack-mqtt-forwarder` → MQTT broker |
| Basics Station | `station` → LNS (WebSocket) |

- Everything runs natively under systemd: `bobcat-gw-pktfwd`, `bobcat-gw-station`,
  `bobcat-gw-mqtt` and `bobcat-gw-web`. There is no Docker.
- The SX1302 is powered and reset by `/opt/bobcat-gw/bin/reset_lgw.sh` (GPIO 125 and
  122 power, GPIO 149 reset), the same sequence as Bobcat300-TTN.
- The Bobcat has no STTS751 temperature sensor, which makes the stock Semtech HAL
  refuse to start. `files/patch_hal_tempsensor.py` patches both HAL copies to use a
  fixed 25 °C instead.
- The web UI (`/opt/bobcat-gw/web/bobcat_gw.py`) is a single Python program that uses
  only the standard library. It writes the backend configuration, starts and stops
  the units, and reads statistics from their journal.

Files:

| Path | Contents |
|---|---|
| `/etc/bobcat-gw/config.json` | Configuration (mode 600, contains keys) |
| `/etc/bobcat-gw/hw.json` | Hardware facts found by the installer |
| `/var/lib/bobcat-gw/{pktfwd,station,mqtt}` | Generated backend configs |
| `/opt/bobcat-gw` | Binaries and web UI |

Command line: `journalctl -u bobcat-gw-pktfwd -f` (or `-station`, `-mqtt`, `-web`).

## Limitations

- Tested on the G285 only. The G280 (SX1301) is not supported. The G29x uses a
  different SPI device and is untested.
- The packet forwarder channel plans cover EU868, US915, AU915, AS923-1 and KR920.
  With Basics Station the LNS sends the channel plan, so the region is whatever the
  LNS is configured for.
- Ethernet only; the built-in WiFi is disabled (see [Ethernet only](#ethernet-only)).
- If the gateway ever stops responding, unplug the power for at least 60 seconds before
  plugging it back in.
- No GPS on the Bobcat, so no Class B beacons and no fine timestamps.
- The web UI is plain HTTP on the local network. Don't expose port 80 to the
  internet.

## Credits

- [AdvdLaar/Bobcat300-TTN](https://github.com/AdvdLaar/Bobcat300-TTN): the
  original TTN conversion and the G285 reset sequence.
- [sicXnull/Bobcat-Armbian](https://github.com/sicXnull/Bobcat-Armbian): Armbian for
  the Bobcat 300.
- [metrafonic/Bobcat300-DebianMinimalDocker](https://github.com/metrafonic/Bobcat300-DebianMinimalDocker)
  and r00t1ng: the LDO reset script.
- Semtech [sx1302_hal](https://github.com/Lora-net/sx1302_hal) and
  [Basics Station](https://github.com/lorabasics/basicstation), and the
  [ChirpStack MQTT Forwarder](https://github.com/chirpstack/chirpstack-mqtt-forwarder).
