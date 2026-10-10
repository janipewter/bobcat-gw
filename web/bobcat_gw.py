#!/usr/bin/env python3
"""bobcat-gw manager.

Single process, standard library only. It
  * owns the gateway configuration (/etc/bobcat-gw/config.json),
  * renders the configuration of the active backend (Semtech UDP packet
    forwarder, LoRa Basics Station, or ChirpStack MQTT Forwarder),
  * starts/stops the backend systemd units,
  * follows the backend journals to collect gateway statistics,
  * reports the network interfaces (Ethernet only: the onboard BCM43430 WiFi is
    disabled because its driver can hang the board, see README),
  * serves the web UI and its JSON API.
"""
import base64
import collections
import hashlib
import hmac
import html
import http.server
import json
import os
import re
import secrets
import shutil
import signal
import socketserver
import subprocess
import threading
import time
import urllib.parse

VERSION = "0.1.0"

APP_DIR = os.environ.get("BOBCAT_GW_APP", "/opt/bobcat-gw")
CONF_DIR = os.environ.get("BOBCAT_GW_CONF", "/etc/bobcat-gw")
STATE_DIR = os.environ.get("BOBCAT_GW_STATE", "/var/lib/bobcat-gw")
CONFIG_PATH = os.path.join(CONF_DIR, "config.json")
HW_PATH = os.path.join(CONF_DIR, "hw.json")
WEB_PORT = int(os.environ.get("BOBCAT_GW_PORT", "80"))
SYSTEM_CA = "/etc/ssl/certs/ca-certificates.crt"

UNITS = {
    "pktfwd": "bobcat-gw-pktfwd.service",
    "mqtt": "bobcat-gw-mqtt.service",
    "station": "bobcat-gw-station.service",
}
BACKEND_UNITS = {
    "udp": ["pktfwd"],
    "mqtt": ["pktfwd", "mqtt"],
    "basicstation": ["station"],
    "monitor": ["pktfwd"],  # receive and display only; nothing is forwarded to an LNS
    "none": [],
}
UNIT_TO_KEY = {v: k for k, v in UNITS.items()}

SECRET_MASK = "\u2022\u2022\u2022\u2022\u2022\u2022"

DEFAULT_CONFIG = {
    "gateway_eui": "",
    "region": "EU868",
    "subband": 2,
    "backend": "none",
    "udp": {"server": "eu1.cloud.thethings.network", "port_up": 1700, "port_down": 1700},
    "basicstation": {
        "mode": "lns",  # lns | cups
        "uri": "wss://eu1.cloud.thethings.network:8887",
        "auth": "token",  # none | token | tls
        "token": "",
        "trust": "",  # PEM; empty = system CA bundle
        "cert": "",
        "key": "",
    },
    "mqtt": {
        "server": "tcp://127.0.0.1:1883",
        "username": "",
        "password": "",
        "topic_prefix": "eu868",
        "json": False,
        "ca_cert": "",
        "tls_cert": "",
        "tls_key": "",
    },
    "tailscale": {"hostname": "", "ssh": False},
    "web": {"password_hash": ""},
}

SECRET_FIELDS = [
    ("basicstation", "token"), ("basicstation", "key"),
    ("mqtt", "password"), ("mqtt", "tls_key"),
]

# --------------------------------------------------------------------------
# Helpers


def run(cmd, timeout=30, check=False):
    """Run a command, return (rc, stdout). Never raises on failure unless check."""
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout, text=True)
    except (OSError, subprocess.TimeoutExpired) as e:
        if check:
            raise
        return 1, str(e)
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)}: {p.stdout.strip()}")
    return p.returncode, p.stdout


def write_file(path, content, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(content)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def deep_merge(base, override):
    out = json.loads(json.dumps(base))
    for k, v in (override or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def get_path(d, path):
    for p in path:
        d = d.get(p, {}) if isinstance(d, dict) else {}
    return d


def set_path(d, path, value):
    for p in path[:-1]:
        d = d.setdefault(p, {})
    d[path[-1]] = value


def hash_password(password, salt=None, iterations=200000):
    salt = salt or secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), iterations).hex()
    return f"pbkdf2${iterations}${salt}${h}"


def check_password(password, stored):
    try:
        _, iterations, salt, h = stored.split("$")
    except ValueError:
        return False
    return hmac.compare_digest(hash_password(password, salt, int(iterations)), stored)


def load_hw():
    hw = {"spi_dev": "/dev/spidev1.0", "board": "", "mac_eui": "", "chip_eui": "",
          "held_packages": [], "versions": {}}
    try:
        hw.update(json.load(open(HW_PATH)))
    except (OSError, ValueError):
        pass
    return hw


# --------------------------------------------------------------------------
# Region channel plans (used by the packet forwarder; Basics Station gets its
# channel plan from the LNS).

RSSI_TCOMP = {"coeff_a": 0, "coeff_b": 0, "coeff_c": 20.41, "coeff_d": 2162.56, "coeff_e": 0}
# sx1302_hal V2.1.0 global_conf.json.sx1250.{EU868,US915}; identical for both.
TX_GAIN_LUT = [
    {"rf_power": p, "pa_gain": g, "pwr_idx": i} for p, g, i in [
        (12, 0, 15), (13, 0, 16), (14, 0, 17), (15, 0, 19), (16, 0, 20), (17, 0, 22),
        (18, 1, 1), (19, 1, 2), (20, 1, 3), (21, 1, 4), (22, 1, 5), (23, 1, 6),
        (24, 1, 7), (25, 1, 9), (26, 1, 11), (27, 1, 14)]
]
MAX_IF = 400000

REGIONS = {
    "EU868": "Europe 863-870 MHz",
    "US915": "United States 902-928 MHz",
    "AU915": "Australia 915-928 MHz",
    "AS923": "Asia 923 MHz (AS923-1)",
    "KR920": "South Korea 920-923 MHz",
}


def region_plan(region, subband=2):
    mhz = lambda f: int(round(f * 1e6))
    if region == "EU868":
        return {
            "radios": [mhz(867.5), mhz(868.5)],
            "multi": [mhz(f) for f in (868.1, 868.3, 868.5, 867.1, 867.3, 867.5, 867.7, 867.9)],
            "std": (mhz(868.3), 250000, 7),
            "fsk": (mhz(868.8), 125000, 50000),
            "tx": (863000000, 870000000),
        }
    if region in ("US915", "AU915"):
        sb = max(1, min(8, int(subband)))
        first = (902.3 if region == "US915" else 915.2) + (sb - 1) * 1.6
        wide = (903.0 if region == "US915" else 915.9) + (sb - 1) * 1.6
        return {
            "radios": [mhz(first + 0.4), mhz(first + 1.1)],
            "multi": [mhz(first + 0.2 * i) for i in range(8)],
            "std": (mhz(wide), 500000, 8),
            "fsk": None,
            "tx": (923000000, 928000000) if region == "US915" else (915000000, 928000000),
        }
    if region == "AS923":
        return {
            "radios": [mhz(922.0), mhz(923.0)],
            "multi": [mhz(f) for f in (923.2, 923.4, 922.2, 922.4, 922.6, 922.8, 923.0, 922.0)],
            "std": (mhz(922.1), 250000, 7),
            "fsk": (mhz(921.8), 125000, 50000),
            "tx": (915000000, 928000000),
        }
    if region == "KR920":
        return {
            "radios": [mhz(922.3), mhz(923.1)],
            "multi": [mhz(f) for f in (922.1, 922.3, 922.5, 922.7, 922.9, 923.1, 923.3, 921.9)],
            "std": None,
            "fsk": None,
            "tx": (920900000, 923300000),
        }
    raise ValueError(f"no packet forwarder channel plan for region {region}")


def assign_radio(radios, freq):
    best = min(range(len(radios)), key=lambda r: abs(freq - radios[r]))
    if_freq = freq - radios[best]
    if abs(if_freq) > MAX_IF:
        raise ValueError(f"channel {freq} Hz is out of range of both radios")
    return best, if_freq


def build_global_conf(cfg, hw, server, port_up, port_down):
    p = region_plan(cfg["region"], cfg.get("subband", 2))
    radio = lambda i: {"enable": True, "type": "SX1250", "freq": p["radios"][i],
                       "rssi_offset": -215.4, "rssi_tcomp": RSSI_TCOMP}
    r0 = radio(0)
    r0.update({"tx_enable": True, "tx_freq_min": p["tx"][0], "tx_freq_max": p["tx"][1],
               "tx_gain_lut": TX_GAIN_LUT})
    r1 = radio(1)
    r1["tx_enable"] = False
    sx = {
        "com_type": "SPI",
        "com_path": hw["spi_dev"],
        "lorawan_public": True,
        "clksrc": 0,
        "antenna_gain": 0,
        "full_duplex": False,
        "fine_timestamp": {"enable": False, "mode": "all_sf"},
        "radio_0": r0,
        "radio_1": r1,
        "chan_multiSF_All": {"spreading_factor_enable": [5, 6, 7, 8, 9, 10, 11, 12]},
    }
    for i, f in enumerate(p["multi"]):
        r, if_freq = assign_radio(p["radios"], f)
        sx[f"chan_multiSF_{i}"] = {"enable": True, "radio": r, "if": if_freq}
    if p["std"]:
        f, bw, sf = p["std"]
        r, if_freq = assign_radio(p["radios"], f)
        sx["chan_Lora_std"] = {"enable": True, "radio": r, "if": if_freq, "bandwidth": bw,
                               "spread_factor": sf, "implicit_hdr": False,
                               "implicit_payload_length": 17, "implicit_crc_en": False,
                               "implicit_coderate": 1}
    else:
        sx["chan_Lora_std"] = {"enable": False}
    if p["fsk"]:
        f, bw, dr = p["fsk"]
        r, if_freq = assign_radio(p["radios"], f)
        sx["chan_FSK"] = {"enable": True, "radio": r, "if": if_freq, "bandwidth": bw, "datarate": dr}
    else:
        sx["chan_FSK"] = {"enable": False}
    gw = {
        "gateway_ID": cfg["gateway_eui"].upper(),
        "server_address": server,
        "serv_port_up": int(port_up),
        "serv_port_down": int(port_down),
        "keepalive_interval": 10,
        "stat_interval": 30,
        "push_timeout_ms": 100,
        "forward_crc_valid": True,
        "forward_crc_error": False,
        "forward_crc_disabled": False,
        "ref_latitude": 0.0,
        "ref_longitude": 0.0,
        "ref_altitude": 0,
        "beacon_period": 0,
    }
    return {"SX130x_conf": sx, "gateway_conf": gw}


# --------------------------------------------------------------------------
# Backend configuration rendering


def render_pktfwd(cfg, hw):
    d = os.path.join(STATE_DIR, "pktfwd")
    if cfg["backend"] in ("mqtt", "monitor"):
        # mqtt: the local MQTT forwarder listens here. monitor: nothing does, so nothing leaves the gateway.
        conf = build_global_conf(cfg, hw, "127.0.0.1", 1700, 1700)
    else:
        u = cfg["udp"]
        conf = build_global_conf(cfg, hw, u["server"], u["port_up"], u["port_down"])
    write_file(os.path.join(d, "global_conf.json"), json.dumps(conf, indent=2))
    link = os.path.join(d, "reset_lgw.sh")
    if not os.path.lexists(link):
        os.symlink(os.path.join(APP_DIR, "bin", "reset_lgw.sh"), link)


def station_conf(cfg, hw):
    radio = {"type": "SX1250", "rssi_offset": -215.4, "rssi_tcomp": RSSI_TCOMP}
    r0 = dict(radio, tx_enable=True, antenna_gain=0, tx_gain_lut=TX_GAIN_LUT)
    r1 = dict(radio, tx_enable=False)
    return {
        "SX1302_conf": {
            "device": hw["spi_dev"],
            "lorawan_public": True,
            "clksrc": 0,
            "full_duplex": False,
            "radio_0": r0,
            "radio_1": r1,
        },
        "station_conf": {
            "routerid": cfg["gateway_eui"].upper(),
            "radio_init": os.path.join(APP_DIR, "bin", "rinit.sh"),
            "RADIO_INIT_WAIT": "5s",
            "RX_POLL_INTV": "10ms",
            "TC_TIMEOUT": "360s",
            "log_file": "stderr",
            "log_level": "VERBOSE",
            "log_size": 10000000,
            "log_rotate": 3,
        },
    }


def auth_header(token):
    token = token.strip()
    if token.lower().startswith("authorization:"):
        return token + "\r\n"
    return f"Authorization: Bearer {token}\r\n"


def render_station(cfg, hw):
    d = os.path.join(STATE_DIR, "station")
    # Start from a clean directory: station keeps CUPS/TC state files here.
    if os.path.isdir(d):
        shutil.rmtree(d)
    os.makedirs(d, mode=0o700)
    b = cfg["basicstation"]
    write_file(os.path.join(d, "station.conf"), json.dumps(station_conf(cfg, hw), indent=2))
    prefix = "cups" if b["mode"] == "cups" else "tc"
    uri = b["uri"].strip()
    write_file(os.path.join(d, prefix + ".uri"), uri + "\n")
    if uri.startswith(("wss://", "https://")):
        trust = b.get("trust", "").strip()
        if not trust:
            trust = open(SYSTEM_CA).read()
        write_file(os.path.join(d, prefix + ".trust"), trust.strip() + "\n")
    if b["auth"] == "token" and b.get("token"):
        write_file(os.path.join(d, prefix + ".key"), auth_header(b["token"]), 0o600)
    elif b["auth"] == "tls":
        write_file(os.path.join(d, prefix + ".crt"), b.get("cert", "").strip() + "\n")
        write_file(os.path.join(d, prefix + ".key"), b.get("key", "").strip() + "\n", 0o600)


def toml_str(s):
    return json.dumps(str(s))


def render_mqtt(cfg, hw):
    d = os.path.join(STATE_DIR, "mqtt")
    os.makedirs(d, mode=0o700, exist_ok=True)
    m = cfg["mqtt"]
    paths = {}
    for field in ("ca_cert", "tls_cert", "tls_key"):
        path = os.path.join(d, field.replace("_", ".") + ".pem")
        if m.get(field, "").strip():
            write_file(path, m[field].strip() + "\n", 0o600)
            paths[field] = path
        else:
            paths[field] = ""
            if os.path.exists(path):
                os.remove(path)
    toml = f"""# Generated by bobcat-gw - changes are overwritten.
[logging]
  level="info"
  log_to_syslog=false

[mqtt]
  topic_prefix={toml_str(m['topic_prefix'])}
  json={'true' if m.get('json') else 'false'}
  server={toml_str(m['server'])}
  username={toml_str(m.get('username', ''))}
  password={toml_str(m.get('password', ''))}
  qos=0
  clean_session=false
  client_id=""
  keep_alive_interval="30s"
  ca_cert={toml_str(paths['ca_cert'])}
  tls_cert={toml_str(paths['tls_cert'])}
  tls_key={toml_str(paths['tls_key'])}

[backend]
  enabled="semtech_udp"

  [backend.filters]
    forward_crc_ok=true
    forward_crc_invalid=false
    forward_crc_missing=false

  [backend.semtech_udp]
    bind="127.0.0.1:1700"
    time_fallback_enabled=true
"""
    write_file(os.path.join(d, "chirpstack-mqtt-forwarder.toml"), toml, 0o600)


# --------------------------------------------------------------------------
# Config store


class ConfigStore:
    def __init__(self):
        self.lock = threading.RLock()
        self.cfg = self._load()

    def _load(self):
        try:
            data = json.load(open(CONFIG_PATH))
        except (OSError, ValueError):
            data = {}
        cfg = deep_merge(DEFAULT_CONFIG, data)
        # Older versions kept WiFi and setup hotspot settings (with passwords) here. The
        # gateway is Ethernet-only now, so drop them, also from the file on disk.
        if data.pop("network", None) is not None:
            cfg.pop("network", None)
            write_file(CONFIG_PATH, json.dumps(cfg, indent=2), 0o600)
        return cfg

    def get(self):
        with self.lock:
            return json.loads(json.dumps(self.cfg))

    def save(self, cfg):
        with self.lock:
            write_file(CONFIG_PATH, json.dumps(cfg, indent=2), 0o600)
            self.cfg = cfg

    def public(self):
        """Config for the UI with secrets masked."""
        cfg = self.get()
        cfg.pop("web", None)
        for path in SECRET_FIELDS:
            if get_path(cfg, path):
                set_path(cfg, path, SECRET_MASK)
        return cfg


EUI_RE = re.compile(r"^[0-9A-Fa-f]{16}$")
HOST_RE = re.compile(r"^[A-Za-z0-9.\-:\[\]]+$")


def validate(cfg):
    errors = []
    if not EUI_RE.match(cfg.get("gateway_eui", "")):
        errors.append("Gateway EUI must be 16 hexadecimal characters.")
    if cfg["backend"] not in BACKEND_UNITS:
        errors.append("Unknown backend.")
    if cfg["backend"] in ("udp", "mqtt", "monitor"):
        try:
            region_plan(cfg["region"], cfg.get("subband", 2))
        except ValueError as e:
            errors.append(str(e))
    if cfg["backend"] == "udp":
        u = cfg["udp"]
        if not u.get("server") or not HOST_RE.match(u["server"]):
            errors.append("UDP server address is invalid.")
        for k in ("port_up", "port_down"):
            try:
                if not 0 < int(u[k]) < 65536:
                    raise ValueError
            except (ValueError, TypeError):
                errors.append(f"UDP {k.replace('_', ' ')} must be 1-65535.")
    if cfg["backend"] == "basicstation":
        b = cfg["basicstation"]
        schemes = ("ws://", "wss://") if b["mode"] == "lns" else ("http://", "https://")
        if not b.get("uri", "").startswith(schemes):
            errors.append(f"{b['mode'].upper()} URI must start with {' or '.join(schemes)}")
        if b["auth"] == "token" and not b.get("token"):
            errors.append("An API key / token is required for token authentication.")
        if b["auth"] == "tls" and not (b.get("cert") and b.get("key")):
            errors.append("Client certificate and key are required for TLS authentication.")
    if cfg["backend"] == "mqtt":
        m = cfg["mqtt"]
        if not m.get("server", "").startswith(("tcp://", "ssl://", "ws://", "wss://")):
            errors.append("MQTT server must start with tcp://, ssl://, ws:// or wss://")
        if not m.get("topic_prefix"):
            errors.append("MQTT topic prefix is required.")
    return errors


def hardware_eui(hw):
    """The gateway EUI is the SX1302 concentrator's own EUI-64, assigned by Semtech and
    globally unique. It is deliberately not configurable: a mistyped or copied EUI could
    clash with another gateway. The EUI derived from the Ethernet MAC (a locally
    administered address, so not guaranteed unique) is only a fallback for when the
    installer could not read the chip. Returns (eui, source)."""
    chip = (hw.get("chip_eui") or "").upper()
    if EUI_RE.match(chip):
        return chip, "chip"
    mac = (hw.get("mac_eui") or "").upper()
    if EUI_RE.match(mac):
        return mac, "mac"
    return "", "none"


# --------------------------------------------------------------------------
# Statistics


def decode_phy(data_b64):
    """Pull the identifying fields out of a LoRaWAN PHYPayload."""
    try:
        b = base64.b64decode(data_b64)
    except (ValueError, TypeError):
        return {}
    if not b:
        return {}
    mtype = b[0] >> 5
    names = {0: "JoinRequest", 1: "JoinAccept", 2: "UnconfirmedUp", 3: "UnconfirmedDown",
             4: "ConfirmedUp", 5: "ConfirmedDown", 6: "RejoinRequest", 7: "Proprietary"}
    out = {"mtype": names.get(mtype, "?")}
    if mtype == 0 and len(b) >= 23:
        out["join_eui"] = b[1:9][::-1].hex().upper()
        out["dev_eui"] = b[9:17][::-1].hex().upper()
    elif mtype in (2, 3, 4, 5) and len(b) >= 8:
        out["dev_addr"] = b[1:5][::-1].hex().upper()
        out["fcnt"] = b[6] | (b[7] << 8)
    return out


class Source:
    """Connection state reported by one backend unit."""

    def __init__(self):
        self.state = "stopped"  # stopped | starting | connecting | connected | disconnected | error
        self.detail = ""
        self.last_ok = None
        self.rtt_ms = None
        self.since = None

    def set(self, state, detail, ts):
        if state != self.state:
            self.since = ts
        self.state = state
        if detail is not None:
            self.detail = detail


def _read_boot_id():
    try:
        return open("/proc/sys/kernel/random/boot_id").read().strip().replace("-", "")
    except OSError:
        return None


BOOT_ID = _read_boot_id()


def entry_time(entry):
    """Wall-clock time of a journal entry.

    The Bobcat has no RTC, so services log for a while after power-on with a stale clock
    until NTP syncs. For entries from this boot, use the monotonic timestamp (time since
    boot) against the current clock instead, so they land at the right time once the clock
    is corrected. Entries from earlier boots keep their recorded wall-clock time.
    """
    mono = entry.get("__MONOTONIC_TIMESTAMP")
    if BOOT_ID and mono and entry.get("_BOOT_ID") == BOOT_ID:
        return time.time() - time.monotonic() + int(mono) / 1e6
    return int(entry.get("__REALTIME_TIMESTAMP", time.time() * 1e6)) / 1e6


TOTALS_FILE = os.path.join(STATE_DIR, "totals.json")


class Totals:
    """Uplink and downlink counts for this boot and for all time, kept in TOTALS_FILE.

    The journal is replayed at every start, so each boot has a mark: the monotonic time of
    the last entry counted from it. Only entries past their boot's mark are counted. If
    the file loses its last few minutes (power cut), nothing is lost either: those
    entries are past the saved mark and get counted again from the journal.
    """
    SAVE_EVERY = 300  # seconds; limits SD card writes
    MAX_MARKS = 20

    def __init__(self, path):
        self.path = path
        try:
            with open(path) as f:
                d = json.load(f)
        except (OSError, ValueError):
            d = {}
        self.total = d.get("total") or {"up": 0, "down": 0}
        self.since = d.get("since")
        self.marks = d.get("marks") or {}
        b = d.get("boot") or {}
        self.boot = b if b.get("id") == BOOT_ID else {"id": BOOT_ID, "up": 0, "down": 0}
        self.dirty = False
        self.saved = time.monotonic()

    def count(self, key, ts, boot, mono):
        if boot and mono:
            if mono <= self.marks.get(boot, 0):
                return  # counted before this restart
            self.marks.pop(boot, None)
            self.marks[boot] = mono  # most recent boot last
            while len(self.marks) > self.MAX_MARKS:
                del self.marks[next(iter(self.marks))]
        self.total[key] += 1
        if boot == BOOT_ID:
            self.boot[key] += 1
        if self.since is None:
            self.since = ts
        self.dirty = True
        if time.monotonic() - self.saved >= self.SAVE_EVERY:
            self.save()

    def save(self):
        if not self.dirty:
            return
        data = {"total": self.total, "since": self.since, "boot": self.boot, "marks": self.marks}
        tmp = self.path + ".tmp"
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            with open(tmp, "w") as f:
                json.dump(data, f)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, self.path)
            dfd = os.open(os.path.dirname(self.path), os.O_RDONLY)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)
        except OSError:
            return
        self.dirty = False
        self.saved = time.monotonic()


class Stats:
    HOURS = 48

    def __init__(self):
        self.lock = threading.Lock()
        self.started_mono = time.monotonic()  # not wall time: the clock may still be wrong
        self.counters = collections.Counter()
        self.packets = collections.deque(maxlen=100)
        self.events = collections.deque(maxlen=50)
        self.hourly = {}  # hour epoch -> [up, down]
        self.sources = {k: Source() for k in UNITS}
        self.concentrator = {"state": "unknown", "detail": "", "since": None}
        self.lns_region = ""
        self.push_ack_pct = None
        self.pull_ack_pct = None
        self._block_rx = 0
        # Counters are rebuilt from the journal (last 24 h) at startup, so they
        # survive restarts of this service without a separate history file.
        self.counting_since = None
        self.totals = Totals(TOTALS_FILE)
        self._entry = (None, None)  # (boot ID, monotonic µs) of the journal entry being parsed

    def _bucket(self, ts, idx):
        hour = int(ts // 3600 * 3600)
        b = self.hourly.setdefault(hour, [0, 0])
        b[idx] += 1
        cutoff = hour - self.HOURS * 3600
        for k in [k for k in self.hourly if k < cutoff]:
            del self.hourly[k]

    def event(self, ts, unit, level, msg):
        self.events.appendleft({"ts": ts, "unit": unit, "level": level, "msg": msg[:300]})

    def uplink(self, ts, unit, **pkt):
        pkt.update({"ts": ts, "dir": "up", "unit": unit})
        self.packets.appendleft(pkt)
        self.counters["uplinks"] += 1
        self.counters["last_uplink"] = ts
        self.totals.count("up", ts, *self._entry)
        self._bucket(ts, 0)

    def downlink(self, ts, unit, **pkt):
        pkt.update({"ts": ts, "dir": "down", "unit": unit})
        self.packets.appendleft(pkt)
        self.counters["downlinks"] += 1
        self.counters["last_downlink"] = ts
        self.totals.count("down", ts, *self._entry)
        self._bucket(ts, 1)

    # ---- journal parsing

    def feed(self, entry):
        msg = entry.get("MESSAGE")
        if isinstance(msg, list):  # journald encodes non-UTF8 messages as byte arrays
            msg = bytes(msg).decode("utf-8", "replace")
        if not isinstance(msg, str):
            return
        ts = entry_time(entry)
        mono = entry.get("__MONOTONIC_TIMESTAMP")
        unit = entry.get("_SYSTEMD_UNIT", "")
        with self.lock:
            if self.counting_since is None:
                self.counting_since = ts
            self._entry = (entry.get("_BOOT_ID"), int(mono) if mono else None)
            if unit not in UNIT_TO_KEY:
                # systemd's own messages about our units
                target = entry.get("UNIT") or entry.get("USER_UNIT")
                if target in UNIT_TO_KEY:
                    self._systemd_msg(UNIT_TO_KEY[target], msg, ts)
                return
            key = UNIT_TO_KEY[unit]
            for line in msg.splitlines():
                line = line.strip()
                if not line:
                    continue
                if key == "pktfwd":
                    self._pktfwd(line, ts)
                elif key == "station":
                    self._station(line, ts)
                elif key == "mqtt":
                    self._mqtt(line, ts)

    def _systemd_msg(self, key, msg, ts):
        src = self.sources[key]
        if msg.startswith("Started"):
            src.set("starting", "", ts)
            if key in ("pktfwd", "station"):
                self.concentrator.update(state="starting", detail="", since=ts)
        elif msg.startswith(("Stopped", "Deactivated")) or "Failed with result" in msg \
                or "Main process exited" in msg:
            if src.state != "stopped":
                src.set("stopped", msg if "Failed" in msg or "exited" in msg else "", ts)
            if key in ("pktfwd", "station"):
                self.concentrator.update(state="stopped", detail="", since=ts)

    PF_ACK = re.compile(r"\[(up|down)\] (PUSH|PULL)_ACK received in (\d+) ms")

    def _pktfwd(self, line, ts):
        src = self.sources["pktfwd"]
        if line.startswith("JSON up:"):
            try:
                data = json.loads(line[8:])
            except ValueError:
                return
            for p in data.get("rxpk", []):
                info = decode_phy(p.get("data", ""))
                self.uplink(ts, "pktfwd", freq=p.get("freq"), datr=p.get("datr"),
                            rssi=p.get("rssi"), snr=p.get("lsnr"), size=p.get("size"),
                            crc=p.get("stat"), **info)
            return
        if line.startswith("JSON down:"):
            try:
                t = json.loads(line[10:]).get("txpk", {})
            except ValueError:
                return
            self.downlink(ts, "pktfwd", freq=t.get("freq"), datr=t.get("datr"),
                          power=t.get("powe"), size=t.get("size"),
                          **decode_phy(t.get("data", "")))
            return
        m = self.PF_ACK.search(line)
        if m:
            src.last_ok = ts
            src.rtt_ms = int(m.group(3))
            src.set("connected", "", ts)
            return
        if line.startswith("# "):
            self._pktfwd_stat(line[2:])
            return
        if "concentrator started" in line:
            self.concentrator.update(state="running", detail="", since=ts)
            if src.state in ("stopped", "starting"):
                src.set("connecting", "", ts)
        elif "failed to start the concentrator" in line:
            self.concentrator.update(state="error", detail=line, since=ts)
            self.event(ts, "pktfwd", "error", line)
        elif line.startswith("ERROR"):
            self.event(ts, "pktfwd", "error", line)
            if "getaddrinfo" in line or "socket" in line.lower():
                src.set("error", line, ts)
        elif line.startswith("WARNING") and "temperature" not in line:
            self.event(ts, "pktfwd", "warning", line)

    PF_NUM = re.compile(r"-?\d+(?:\.\d+)?")

    def _pktfwd_stat(self, s):
        nums = [float(x) for x in self.PF_NUM.findall(s)]
        if not nums:
            return
        c = self.counters
        if s.startswith("RF packets received by concentrator"):
            self._block_rx = int(nums[0])
            c["rx_total"] += self._block_rx
        elif s.startswith("CRC_OK") and len(nums) >= 3:
            c["rx_ok"] += round(self._block_rx * nums[0] / 100)
            c["rx_bad"] += round(self._block_rx * nums[1] / 100)
            c["rx_nocrc"] += round(self._block_rx * nums[2] / 100)
        elif s.startswith("RF packets forwarded"):
            c["rx_forwarded"] += int(nums[0])
        elif s.startswith("PUSH_DATA acknowledged"):
            self.push_ack_pct = nums[0]
        elif s.startswith("PULL_DATA sent") and len(nums) >= 2:
            self.pull_ack_pct = nums[1]
        elif s.startswith("PULL_RESP"):
            c["dl_received"] += int(nums[0])
        elif s.startswith("RF packets sent to concentrator"):
            c["tx_requested"] += int(nums[0])
        elif s.startswith("TX errors"):
            c["tx_errors"] += int(nums[0])

    ST_LINE = re.compile(r"\[(\w{3}):(\w{4})\] (.*)$")
    ST_RX = re.compile(r"^RX ([\d.]+)MHz DR(\d+) (\S+) snr=(-?[\d.]+) rssi=(-?\d+) \S+ - (\w+)(.*)$")
    ST_TX = re.compile(r"^TX .* - (\w+): ([\d.]+)MHz ([\d.]+)dBm \S+ DR(\d+) (\S+) frame=\S+ \((\d+) bytes\)")

    def _station(self, line, ts):
        m = self.ST_LINE.search(line)
        if not m:
            return
        mod, level, text = m.groups()
        src = self.sources["station"]
        rx = self.ST_RX.match(text)
        if rx:
            freq, dr, rps, snr, rssi, mtype, rest = rx.groups()
            info = {}
            for k, pat in (("dev_addr", r"DevAddr=([0-9A-Fa-f]+)"), ("fcnt", r"FCnt=(\d+)"),
                           ("dev_eui", r"DevEui=([0-9A-Fa-f:\-]+)"),
                           ("join_eui", r"JoinEui=([0-9A-Fa-f:\-]+)"), ("size", r"\((\d+) bytes\)")):
                mm = re.search(pat, rest, re.I)
                if mm:
                    v = mm.group(1)
                    info[k] = int(v) if k in ("fcnt", "size") else v.replace(":", "").replace("-", "").upper()
            mt = {"updf": "Uplink", "jreq": "JoinRequest", "propdf": "Proprietary"}.get(mtype, mtype)
            self.uplink(ts, "station", freq=float(freq), datr=f"DR{dr} {rps}", rssi=int(rssi),
                        snr=float(snr), mtype=mt, **info)
            self.counters["rx_forwarded"] += 1
            return
        tx = self.ST_TX.match(text)
        if tx:
            kind, freq, power, dr, rps, size = tx.groups()
            self.downlink(ts, "station", freq=float(freq), datr=f"DR{dr} {rps}",
                          power=float(power), size=int(size), mtype=kind)
            self.counters["tx_requested"] += 1
            return
        if "Connected to MUXS" in text:
            src.last_ok = ts
            src.set("connected", "", ts)
        elif "Connecting to MUXS" in text or "Connecting to INFOS" in text:
            src.set("connecting", text, ts)
        elif text.startswith("Configuring for region"):
            # "EU868 -- 863.0MHz..870.0MHz" -> "EU868"
            self.lns_region = (text.split(":", 1)[1].split() or [""])[0]
        elif (mod == "RAL" and "Concentrator started" in text) or text.startswith("Station device"):
            self.concentrator.update(state="running", detail="", since=ts)
        elif mod == "RAL" and level in ("ERRO", "CRIT"):
            self.concentrator.update(state="error", detail=text, since=ts)
            self.event(ts, "station", "error", text)
        elif level in ("ERRO", "CRIT"):
            self.event(ts, "station", "error", f"[{mod}] {text}")
            if mod in ("TCE", "AIO", "CUP", "WSC", "TLS"):
                src.set("disconnected", text, ts)
        elif level == "WARN":
            self.event(ts, "station", "warning", f"[{mod}] {text}")
        if mod == "S2E" and "Concentrator" in text and level == "INFO":
            self.concentrator.update(state="running", detail="", since=ts)
        if mod == "SYN" and src.state == "connected":
            src.last_ok = ts

    def _mqtt(self, line, ts):
        src = self.sources["mqtt"]
        if "Subscribing to command topic" in line or "Sending conn state" in line:
            src.last_ok = ts
            src.set("connected", "", ts)
        elif "Connection error" in line or "MQTT error" in line:
            detail = line.split("]", 1)[-1].strip()
            src.set("disconnected", detail, ts)
            self.event(ts, "mqtt", "error", detail)
        elif "Sending uplink event" in line or "Message published" in line:
            src.last_ok = ts
        elif " ERROR " in line or " WARN " in line:
            self.event(ts, "mqtt", "error" if " ERROR " in line else "warning",
                       line.split("]", 1)[-1].strip())

    # ---- views

    def lns_status(self, backend, unit_states):
        now = time.time()
        if backend == "none":
            return {"state": "disabled", "detail": "No LNS backend configured."}
        if backend == "monitor":
            if unit_states.get("pktfwd") != "active":
                return {"state": "stopped", "detail": "Service is %s." % unit_states.get("pktfwd", "inactive")}
            return {"state": "monitor", "detail": "Monitor only: packets are received and shown here, but nothing is forwarded to any LNS."}
        key = {"udp": "pktfwd", "mqtt": "mqtt", "basicstation": "station"}[backend]
        src = self.sources[key]
        active = unit_states.get(key) == "active"
        if not active:
            st = unit_states.get(key, "inactive")
            return {"state": "stopped", "detail": f"Service is {st}.", "since": src.since}
        state, detail = src.state, src.detail
        if state in ("starting", "stopped"):
            state = "connecting"
        if backend == "udp":
            if src.last_ok and now - src.last_ok < 35:
                state, detail = "connected", ""
            elif src.last_ok:
                state = "disconnected"
                detail = "No acknowledgement from the LNS for %d s." % (now - src.last_ok)
            elif state not in ("error",):
                state = "connecting"
                detail = "Waiting for the LNS to acknowledge. Check the server address and that the gateway is registered."
        out = {"state": state, "detail": detail, "since": src.since, "last_ok": src.last_ok,
               "rtt_ms": src.rtt_ms if backend == "udp" else None}
        if backend == "udp":
            out["push_ack_pct"] = self.push_ack_pct
            out["pull_ack_pct"] = self.pull_ack_pct
        if backend == "basicstation" and self.lns_region:
            out["region"] = self.lns_region
        return out

    def snapshot(self, hours=24):
        with self.lock:
            now_hour = int(time.time() // 3600 * 3600)
            series = []
            for h in range(now_hour - (hours - 1) * 3600, now_hour + 1, 3600):
                up, down = self.hourly.get(h, [0, 0])
                series.append({"t": h, "up": up, "down": down})
            return {
                "counters": dict(self.counters),
                "packets": list(self.packets)[:50],
                "events": list(self.events)[:20],
                "hourly": series,
                "concentrator": dict(self.concentrator),
                "counting_since": self.counting_since or time.time() - (time.monotonic() - self.started_mono),
                "totals": {"boot_up": self.totals.boot["up"], "boot_down": self.totals.boot["down"],
                           "total_up": self.totals.total["up"], "total_down": self.totals.total["down"],
                           "total_since": self.totals.since, "boot_time": time.time() - time.monotonic()},
            }


class JournalFollower(threading.Thread):
    """Replays the last 24 h of backend logs, then follows them."""

    def __init__(self, stats):
        super().__init__(daemon=True)
        self.stats = stats

    def _stream(self, args, follow, skip_this_boot=False):
        cmd = ["journalctl", "-o", "json", "--no-pager"] + (["-f"] if follow else []) + args
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    text=True, bufsize=1)
            for raw in proc.stdout:
                try:
                    entry = json.loads(raw)
                except ValueError:
                    continue
                if skip_this_boot and entry.get("_BOOT_ID") == BOOT_ID:
                    continue
                self.stats.feed(entry)
            proc.wait()
        except OSError:
            pass

    def run(self):
        units = []
        for u in UNITS.values():
            units += ["-u", u]
        # Lines logged before NTP synced carry a stale wall-clock time, so "--since -24h"
        # would drop them. If this boot is less than a day old, replay earlier boots by
        # time and this whole boot by boot ID instead.
        if BOOT_ID and time.monotonic() < 86400:
            self._stream(["--since", "-24h"] + units, follow=False, skip_this_boot=True)
            args = ["-b"]
        else:
            args = ["--since", "-24h"]
        while True:
            self._stream(args + units, follow=True)
            args = ["--since", "-10s"]
            time.sleep(5)


# --------------------------------------------------------------------------
# Services


def unit_states():
    rc, out = run(["systemctl", "show", "-p", "Id,ActiveState,NRestarts"] + list(UNITS.values()))
    states, restarts = {}, {}
    for block in out.strip().split("\n\n"):
        props = dict(l.split("=", 1) for l in block.splitlines() if "=" in l)
        key = UNIT_TO_KEY.get(props.get("Id"))
        if key:
            states[key] = props.get("ActiveState", "unknown")
            restarts[key] = int(props.get("NRestarts", "0") or 0)
    return states, restarts


def apply_backend(cfg, hw):
    backend = cfg["backend"]
    wanted = BACKEND_UNITS[backend]
    if "pktfwd" in wanted:
        render_pktfwd(cfg, hw)
    if "mqtt" in wanted:
        render_mqtt(cfg, hw)
    if "station" in wanted:
        render_station(cfg, hw)
    stop = [UNITS[k] for k in UNITS if k not in wanted]
    if stop:
        run(["systemctl", "disable", "--now"] + stop, timeout=60)
    if wanted:
        units = [UNITS[k] for k in wanted]
        run(["systemctl", "enable"] + units, timeout=60)
        run(["systemctl", "restart"] + units, timeout=90)


# --------------------------------------------------------------------------
# Network (NetworkManager)


def nm_split(line):
    """Split nmcli terse output, honouring backslash escapes."""
    out, cur, esc = [], "", False
    for ch in line:
        if esc:
            cur += ch
            esc = False
        elif ch == "\\":
            esc = True
        elif ch == ":":
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return out


class Network:
    """Read-only view of the wired network. The gateway is Ethernet-only: the onboard
    BCM43430 WiFi is disabled (its driver can jam the SDIO bus and hang the board)."""

    def devices(self):
        rc, out = run(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device"])
        devs = []
        for line in out.splitlines():
            f = nm_split(line)
            if len(f) >= 4 and f[1] == "ethernet":
                devs.append({"device": f[0], "type": f[1], "state": f[2], "connection": f[3]})
        rc, out = run(["ip", "-j", "addr"])
        try:
            addrs = {i["ifname"]: [a["local"] for a in i.get("addr_info", []) if a.get("family") == "inet"]
                     for i in json.loads(out)}
        except ValueError:
            addrs = {}
        for d in devs:
            d["ipv4"] = addrs.get(d["device"], [])
            try:
                d["mac"] = open(f"/sys/class/net/{d['device']}/address").read().strip()
            except OSError:
                d["mac"] = ""
        return devs

    def status(self):
        devs = self.devices()
        return {"devices": devs,
                "online": any(d["state"] == "connected" and d["ipv4"] for d in devs)}


# --------------------------------------------------------------------------
# Tailscale (optional remote access). Credentials live in tailscaled's own state
# directory, never in config.json; an auth key is used once and not stored.

TS_HOST_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
TS_KEY_RE = re.compile(r"^tskey-[A-Za-z0-9_-]{8,200}$")
TS_STATES = {
    "Running": "connected", "Starting": "connecting", "NeedsLogin": "needs-login",
    "NeedsMachineAuth": "needs-approval", "Stopped": "stopped", "NoState": "starting",
}


class Tailscale:
    def __init__(self, store):
        self.store = store
        self.lock = threading.Lock()
        self.login_proc = None  # a `tailscale up` that is waiting for a browser login
        self.message = ""
        self.serve_checked = 0

    @staticmethod
    def installed():
        return shutil.which("tailscale") is not None

    @staticmethod
    def kernel_tun():
        return os.path.exists("/dev/net/tun")

    def ensure_serve(self):
        """Forward tailnet port 80 to this web UI in userspace-networking mode (no
        /dev/net/tun), where that is the only way to reach it over Tailscale. With a TUN
        device the UI is already reachable on the tailnet address, and a serve rule makes
        tailscaled bind <tailnet ip>:80 itself: if it does that before this program starts,
        our bind to 0.0.0.0:80 fails. So remove the rule there. Idempotent; re-checked at
        most every 30 s."""
        if time.time() - self.serve_checked < 30:
            return
        self.serve_checked = time.time()
        rc, out = run(["tailscale", "serve", "status", "--json"], timeout=10)
        try:
            ok = "80" in (json.loads(out).get("TCP") or {})
        except ValueError:
            ok = False
        if self.kernel_tun():
            if ok:
                run(["tailscale", "serve", "--tcp=80", "off"], timeout=20)
            return
        if not ok:
            rc, out = run(["tailscale", "serve", "--bg", "--tcp=80", "tcp://127.0.0.1:%d" % WEB_PORT], timeout=20)
            if rc != 0:
                self.message = "Could not publish the web UI on the tailnet: " + out.strip()[:160]

    def status(self):
        cfg = self.store.get()["tailscale"]
        out = {"installed": self.installed(), "state": "not-installed", "message": self.message,
               "hostname": cfg.get("hostname", ""), "ssh": bool(cfg.get("ssh")),
               "default_hostname": os.uname().nodename}
        if not out["installed"]:
            return out
        rc, txt = run(["tailscale", "status", "--json"], timeout=10)
        try:
            d = json.loads(txt)
        except ValueError:
            out.update(state="daemon-down", detail=txt.strip()[:200])
            return out
        out["state"] = TS_STATES.get(d.get("BackendState", ""), "unknown")
        out["backend_state"] = d.get("BackendState", "")
        out["auth_url"] = d.get("AuthURL", "")
        me = d.get("Self") or {}
        out["ips"] = d.get("TailscaleIPs") or me.get("TailscaleIPs") or []
        out["dns_name"] = (me.get("DNSName") or "").rstrip(".")
        out["tailnet"] = (d.get("CurrentTailnet") or {}).get("Name", "")
        out["peers"] = len(d.get("Peer") or {})
        out["health"] = d.get("Health") or []
        out["login_pending"] = bool(self.login_proc and self.login_proc.poll() is None)
        out["mode"] = "kernel" if self.kernel_tun() else "userspace"
        if out["state"] == "connected":
            self.ensure_serve()
            out["web_urls"] = (["http://%s/" % out["dns_name"]] if out["dns_name"] else []) +                               ["http://%s/" % ip for ip in out["ips"] if ":" not in ip]
        return out

    def _stop_login(self):
        if self.login_proc and self.login_proc.poll() is None:
            self.login_proc.terminate()
        self.login_proc = None

    def up(self, hostname, ssh, authkey):
        """Connect. With an auth key this completes (or fails) here; without one it starts
        an interactive login and the status then carries the URL to open."""
        if not self.installed():
            raise RuntimeError("Tailscale is not installed. Re-run install.sh without --no-tailscale.")
        hostname = (hostname or "").strip()
        if hostname and not TS_HOST_RE.match(hostname):
            raise ValueError("Tailscale hostname may only contain letters, digits and hyphens.")
        authkey = (authkey or "").strip()
        if authkey and not TS_KEY_RE.match(authkey):
            raise ValueError("That does not look like a Tailscale auth key (tskey-...).")
        with self.lock:
            cfg = self.store.get()
            cfg["tailscale"] = {"hostname": hostname, "ssh": bool(ssh)}
            self.store.save(cfg)
            run(["systemctl", "enable", "--now", "tailscaled"], timeout=60)
            self._stop_login()
            cmd = ["tailscale", "up", "--reset", "--accept-dns=false",
                   "--ssh=" + ("true" if ssh else "false")]
            if hostname:
                cmd.append("--hostname=" + hostname)
            keyfile = None
            if authkey:
                keyfile = os.path.join(STATE_DIR, "ts-authkey")
                write_file(keyfile, authkey + "\n", 0o600)
                cmd.append("--auth-key=file:" + keyfile)
            try:
                if authkey:
                    rc, out = run(cmd + ["--timeout=60s"], timeout=90)
                    self.message = "Connected to Tailscale." if rc == 0 else                         "Tailscale: " + (out.strip().splitlines() or ["failed"])[-1]
                else:
                    self.login_proc = subprocess.Popen(cmd + ["--timeout=600s"], stdout=subprocess.DEVNULL,
                                                       stderr=subprocess.DEVNULL)
                    self.message = "Open the login link to finish connecting."
            finally:
                if keyfile and os.path.exists(keyfile):
                    os.remove(keyfile)

    def down(self):
        with self.lock:
            self._stop_login()
            rc, out = run(["tailscale", "down"], timeout=30)
            self.message = "Tailscale is disconnected." if rc == 0 else out.strip()[:200]

    def logout(self):
        with self.lock:
            self._stop_login()
            rc, out = run(["tailscale", "logout"], timeout=30)
            self.message = "Logged out of Tailscale." if rc == 0 else out.strip()[:200]


# --------------------------------------------------------------------------
# System information


ZONEINFO = "/usr/share/zoneinfo/"


def current_timezone():
    """The system time zone, from the /etc/localtime symlink (cheap enough for every status)."""
    path = os.path.realpath("/etc/localtime")
    return path[len(ZONEINFO):] if path.startswith(ZONEINFO) else "UTC"


def list_timezones():
    rc, out = run(["timedatectl", "list-timezones", "--no-pager"])
    return [z for z in out.split() if z] if rc == 0 else []


def set_timezone(tz):
    if tz not in list_timezones():
        raise ValueError(f"Unknown time zone: {tz}")
    rc, out = run(["timedatectl", "set-timezone", tz])
    if rc != 0:
        raise RuntimeError(out.strip() or "timedatectl set-timezone failed")
    os.sync()  # the board has hung without warning before; get /etc/localtime onto the card


def system_info(hw):
    info = {"hostname": os.uname().nodename, "version": VERSION, "versions": hw.get("versions", {})}
    try:
        info["uptime"] = float(open("/proc/uptime").read().split()[0])
        info["load"] = open("/proc/loadavg").read().split()[:3]
        mem = dict(l.split(":", 1) for l in open("/proc/meminfo"))
        total = int(mem["MemTotal"].split()[0])
        avail = int(mem["MemAvailable"].split()[0])
        info["mem"] = {"total_mb": total // 1024, "used_mb": (total - avail) // 1024}
        st = os.statvfs("/")
        info["disk"] = {"total_gb": round(st.f_blocks * st.f_frsize / 1e9, 1),
                        "used_gb": round((st.f_blocks - st.f_bfree) * st.f_frsize / 1e9, 1)}
        info["cpu_temp"] = round(int(open("/sys/class/thermal/thermal_zone0/temp").read()) / 1000, 1)
    except (OSError, ValueError, KeyError):
        pass
    rc, out = run(["apt-mark", "showhold"])
    held = set(out.split())
    expected = hw.get("held_packages", [])
    info["holds"] = {"expected": expected, "held": sorted(held),
                     "missing": [p for p in expected if p not in held]}
    rc, out = run(["timedatectl", "show", "-p", "NTPSynchronized", "--value"])
    info["time_synced"] = out.strip() == "yes"
    info["timezone"] = current_timezone()
    return info


# --------------------------------------------------------------------------
# HTTP


class App:
    def __init__(self):
        self.store = ConfigStore()
        self.hw = load_hw()
        eui, self.eui_source = hardware_eui(self.hw)
        cfg = self.store.get()
        if eui and cfg["gateway_eui"] != eui:
            cfg["gateway_eui"] = eui
            self.store.save(cfg)
            if cfg["backend"] != "none":
                apply_backend(cfg, self.hw)  # re-render the backend config with the new EUI
        self.stats = Stats()
        self.net = Network()
        self.ts = Tailscale(self.store)
        self.sessions = {}
        self.login_failures = collections.deque(maxlen=20)
        self._units = ({}, {})
        self._units_time = 0

    def units(self):
        if time.time() - self._units_time > 3:
            self._units = unit_states()
            self._units_time = time.time()
        return self._units

    def status(self):
        cfg = self.store.get()
        states, restarts = self.units()
        snap = self.stats.snapshot()
        return {
            "gateway_eui": cfg["gateway_eui"],
            "backend": cfg["backend"],
            "region": cfg["region"],
            "subband": cfg.get("subband"),
            "lns": self.stats.lns_status(cfg["backend"], states),
            "lns_target": lns_target(cfg),
            "timezone": current_timezone(),
            "services": {k: {"state": states.get(k, "unknown"), "restarts": restarts.get(k, 0)}
                         for k in UNITS},
            "now": time.time(),
            **snap,
        }


def lns_target(cfg):
    b = cfg["backend"]
    if b == "udp":
        return f"{cfg['udp']['server']}:{cfg['udp']['port_up']}"
    if b == "basicstation":
        return cfg["basicstation"]["uri"]
    if b == "mqtt":
        return cfg["mqtt"]["server"]
    return ""


APP = None
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
SESSION_TTL = 7 * 24 * 3600


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "bobcat-gw/" + VERSION
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    # Security headers on every response: no framing (clickjacking), no MIME sniffing, no
    # referrer leaks, and only this origin's own page code may run.
    SECURITY_HEADERS = {
        "X-Content-Type-Options": "nosniff",
        "X-Frame-Options": "DENY",
        "Referrer-Policy": "no-referrer",
        "Content-Security-Policy": "default-src 'self'; script-src 'self' 'unsafe-inline'; "
                                   "style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
                                   "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
    }

    def end_headers(self):
        for k, v in self.SECURITY_HEADERS.items():
            self.send_header(k, v)
        super().end_headers()

    # ---- response helpers

    def send_json(self, obj, code=200, headers=None):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def send_text(self, text, ctype="text/plain; charset=utf-8", code=200):
        body = text.encode() if isinstance(text, str) else text
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    # ---- auth

    def session(self):
        cookie = self.headers.get("Cookie", "")
        m = re.search(r"(?:^|;\s*)bgw_session=([A-Za-z0-9_\-]+)", cookie)
        if not m:
            return None
        exp = APP.sessions.get(m.group(1))
        if exp and exp > time.time():
            return m.group(1)
        APP.sessions.pop(m.group(1), None)
        return None

    def authed(self):
        if not APP.store.get()["web"].get("password_hash"):
            return True
        return self.session() is not None

    def read_json(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        if n > 1_000_000:
            raise ValueError("request too large")
        data = self.rfile.read(n) if n else b"{}"
        return json.loads(data or b"{}")

    # ---- routing

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        path = url.path
        if path in ("/", "/index.html"):
            # The hostname is written in here so the first paint already shows it
            # (it is also on the sign-in screen, so this reveals nothing new).
            page = open(os.path.join(STATIC_DIR, "index.html"), encoding="utf-8").read()
            return self.send_text(page.replace("__HOSTNAME__", html.escape(os.uname().nodename)),
                                  "text/html; charset=utf-8")
        if not path.startswith("/api/"):
            return self.redirect("/")
        if path == "/api/session":
            return self.send_json({"authenticated": self.authed(), "hostname": os.uname().nodename})
        if not self.authed():
            return self.send_json({"error": "unauthorized"}, 401)
        q = urllib.parse.parse_qs(url.query)
        if path == "/api/status":
            return self.send_json(APP.status())
        if path == "/api/config":
            return self.send_json({"config": APP.store.public(), "regions": REGIONS,
                                   "eui_source": APP.eui_source,
                                   "hw": {k: APP.hw.get(k) for k in ("board", "mac_eui", "chip_eui", "spi_dev")}})
        if path == "/api/network":
            return self.send_json(APP.net.status())
        if path == "/api/tailscale":
            return self.send_json(APP.ts.status())
        if path == "/api/system":
            return self.send_json(system_info(APP.hw))
        if path == "/api/timezones":
            return self.send_json({"timezones": list_timezones(), "timezone": current_timezone()})
        if path == "/api/logs":
            key = q.get("unit", ["pktfwd"])[0]
            unit = UNITS.get(key, "bobcat-gw-web.service" if key == "web" else None)
            if not unit:
                return self.send_json({"error": "unknown unit"}, 400)
            n = max(10, min(2000, int(q.get("n", ["300"])[0])))
            rc, out = run(["journalctl", "-u", unit, "-n", str(n), "--no-pager", "-o", "short-iso"])
            return self.send_json({"unit": unit, "log": out})
        self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        # Custom header blocks cross-site form posts (CSRF); SameSite cookies do the rest.
        if self.headers.get("X-Requested-With") != "bobcat-gw":
            return self.send_json({"error": "missing X-Requested-With header"}, 403)
        try:
            body = self.read_json()
        except ValueError as e:
            return self.send_json({"error": str(e)}, 400)
        if path == "/api/login":
            return self.login(body)
        if path == "/api/logout":
            tok = self.session()
            APP.sessions.pop(tok, None)
            return self.send_json({"ok": True}, headers={"Set-Cookie": "bgw_session=; Max-Age=0; Path=/"})
        if not self.authed():
            return self.send_json({"error": "unauthorized"}, 401)
        try:
            if path == "/api/config":
                return self.save_config(body)
            if path == "/api/password":
                return self.change_password(body)
            if path == "/api/timezone":
                try:
                    set_timezone(str(body.get("timezone", "")))
                except ValueError as e:
                    return self.send_json({"error": str(e)}, 400)
                return self.send_json({"ok": True, "timezone": current_timezone()})
            if path == "/api/action":
                return self.action(body)
        except Exception as e:
            return self.send_json({"error": f"{type(e).__name__}: {e}"}, 500)
        self.send_json({"error": "not found"}, 404)

    # ---- API actions

    def login(self, body):
        now = time.time()
        recent = [t for t in APP.login_failures if now - t < 60]
        if len(recent) >= 5:
            return self.send_json({"error": "Too many attempts, wait a minute."}, 429)
        stored = APP.store.get()["web"].get("password_hash", "")
        if stored and not check_password(str(body.get("password", "")), stored):
            APP.login_failures.append(now)
            time.sleep(1)
            return self.send_json({"error": "Wrong password."}, 403)
        tok = secrets.token_urlsafe(24)
        APP.sessions[tok] = now + SESSION_TTL
        cookie = f"bgw_session={tok}; Max-Age={SESSION_TTL}; Path=/; HttpOnly; SameSite=Strict"
        self.send_json({"ok": True}, headers={"Set-Cookie": cookie})

    def merge_secrets(self, new, old):
        for path in SECRET_FIELDS:
            if get_path(new, path) == SECRET_MASK:
                set_path(new, path, get_path(old, path))

    def save_config(self, body):
        old = APP.store.get()
        # gateway_eui is not accepted: it is fixed to the concentrator's EUI (see hardware_eui)
        new = deep_merge(old, {k: body[k] for k in ("region", "subband", "backend",
                                                     "udp", "basicstation", "mqtt") if k in body})
        self.merge_secrets(new, old)
        try:
            new["subband"] = int(new.get("subband", 2))
        except (TypeError, ValueError):
            new["subband"] = 2
        errors = validate(new)
        if errors:
            return self.send_json({"error": " ".join(errors), "errors": errors}, 400)
        APP.store.save(new)
        apply_backend(new, APP.hw)
        APP._units_time = 0
        self.send_json({"ok": True})

    def change_password(self, body):
        stored = APP.store.get()["web"].get("password_hash", "")
        if stored and not check_password(str(body.get("current", "")), stored):
            return self.send_json({"error": "Current password is wrong."}, 403)
        pw = str(body.get("new", ""))
        if len(pw) < 8:
            return self.send_json({"error": "Use at least 8 characters."}, 400)
        cfg = APP.store.get()
        cfg["web"]["password_hash"] = hash_password(pw)
        APP.store.save(cfg)
        APP.sessions = {self.session(): time.time() + SESSION_TTL} if self.session() else {}
        self.send_json({"ok": True})

    def action(self, body):
        a = body.get("action")
        cfg = APP.store.get()
        if a == "restart":
            units = [UNITS[k] for k in BACKEND_UNITS[cfg["backend"]]]
            if units:
                run(["systemctl", "restart"] + units, timeout=90)
            APP._units_time = 0
            return self.send_json({"ok": True})
        if a in ("ts_up", "ts_down", "ts_logout"):
            try:
                if a == "ts_up":
                    APP.ts.up(body.get("hostname", ""), body.get("ssh", False), body.get("authkey", ""))
                elif a == "ts_down":
                    APP.ts.down()
                else:
                    APP.ts.logout()
            except (ValueError, RuntimeError) as e:
                return self.send_json({"error": str(e)}, 400)
            return self.send_json({"ok": True, "message": APP.ts.message})
        self.send_json({"error": "unknown action"}, 400)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


LEGACY_TTN_CONF = "/opt/bobcat-ttn/packet_forwarder/packet_forwarder/configs/global_conf.json"
LEGACY_TTN_COMPOSE = "/opt/bobcat-ttn/packet_forwarder/docker-compose-G285.yml"


def init_config():
    """Installer hook: create/complete the config and apply the backend.

    Reads the web password from $BOBCAT_GW_PASSWORD (only set when given).
    """
    store = ConfigStore()
    hw = load_hw()
    cfg = store.get()
    fresh = not os.path.exists(CONFIG_PATH)
    if fresh and os.path.exists(LEGACY_TTN_CONF):
        # Carry over an AdvdLaar/Bobcat300-TTN installation's server and region. Its EUI is
        # not carried over: the gateway now uses the concentrator's EUI.
        try:
            gw = json.load(open(LEGACY_TTN_CONF))["gateway_conf"]
            old_eui = gw.get("gateway_ID", "").upper()
            cfg["udp"]["server"] = gw["server_address"]
            cfg["udp"]["port_up"] = gw.get("serv_port_up", 1700)
            cfg["udp"]["port_down"] = gw.get("serv_port_down", 1700)
            cfg["backend"] = "udp"
            m = re.search(r"REGION:\s*(\w+)", open(LEGACY_TTN_COMPOSE).read())
            if m and m.group(1) in REGIONS:
                cfg["region"] = m.group(1)
            print(f"Imported Bobcat300-TTN settings: {cfg['udp']['server']}, {cfg['region']}. "
                  f"Note: the gateway EUI changes from {old_eui} to the concentrator's EUI; "
                  f"re-register the gateway on your network server.")
        except (OSError, ValueError, KeyError) as e:
            print(f"Could not import Bobcat300-TTN settings: {e}")
    cfg["gateway_eui"] = hardware_eui(hw)[0]
    pw = os.environ.get("BOBCAT_GW_PASSWORD")
    if pw:
        cfg["web"]["password_hash"] = hash_password(pw)
    errors = validate(cfg)
    if errors:
        print("Configuration problems (fix them in the web UI): " + " ".join(errors))
        cfg["backend"] = "none"
    store.save(cfg)
    apply_backend(cfg, hw)
    print(json.dumps({"gateway_eui": cfg["gateway_eui"], "backend": cfg["backend"],
                      "region": cfg["region"], "has_password": bool(cfg["web"]["password_hash"])}))


def main():
    global APP
    import sys
    if "--init" in sys.argv:
        return init_config()
    APP = App()
    JournalFollower(APP.stats).start()

    def stop(signum, frame):
        with APP.stats.lock:
            APP.stats.totals.save()
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)

    srv = Server(("0.0.0.0", WEB_PORT), Handler)
    print(f"bobcat-gw {VERSION} listening on port {WEB_PORT}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
