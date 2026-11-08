"""Tests for web/bobcat_gw.py that run on any Linux machine (no Bobcat, no root).

    python3 -m unittest discover -s tests -v

The module reads its directories from the environment when it is imported, so they are
pointed at a temporary directory first.
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = tempfile.mkdtemp(prefix="bobcat-gw-test.")
ENV = {
    "BOBCAT_GW_APP": os.path.join(TMP, "app"),
    "BOBCAT_GW_CONF": os.path.join(TMP, "conf"),
    "BOBCAT_GW_STATE": os.path.join(TMP, "state"),
}
os.environ.update(ENV)
sys.path.insert(0, os.path.join(ROOT, "web"))
import bobcat_gw as bg  # noqa: E402

HW = {"board": "bobcat-285", "spi_dev": "/dev/spidev1.0", "mac_eui": "0016C0FFFE001019",
      "chip_eui": "0016C001F1501019"}

# Real Basics Station lines from a G285 (journal MESSAGE field).
ST_UPLINK = ("2026-11-08 14:19:11.681 [S2E:VERB] RX 867.1MHz DR5 SF7/BW125 snr=13.5 rssi=-48 "
             "xtime=0x35000DA6C179AD - updf mhdr=40 DevAddr=260B6C76 FCtrl=80 FCnt=1711 FOpts=[] "
             "088DBED3..89A9 mic=643235132 (25 bytes)")
ST_JOIN = ("2026-11-08 14:31:41.682 [S2E:VERB] RX 868.3MHz DR2 SF10/BW125 snr=-11.8 rssi=-120 "
           "xtime=0x35000DD3756784 - jreq MHdr=00 JoinEui=24e1:24c0:2a:1 DevEui=24e1:2477:3f02:7916 "
           "DevNonce=54804 MIC=-1370893182")
ST_NOISE = [
    "2026-11-08 14:17:30.592 [SYN:VERB] Time sync rejected: quality=470 threshold=468",
    "2026-11-08 14:17:26.390 [SYN:INFO] Time sync qualities: min=196 q90=468 max=541 (previous q90=473)",
    "2026-11-08 14:16:39.128 [SYN:INFO] Mean MCU drift vs SX130X#0: -1.4ppm",
    "2026-11-08 14:48:10.738 [SYN:WARN] Repeated excessive clock drifts between MCU/SX130X#0 "
    "(3 retries): -15.0ppm (threshold 12.9ppm)",
]


def default_cfg():
    return bg.ConfigStore().get()


def station_entry(message, ts=1762611551.0):
    return {"MESSAGE": message, "_SYSTEMD_UNIT": bg.UNITS["station"],
            "__REALTIME_TIMESTAMP": str(int(ts * 1e6))}


class Versions(unittest.TestCase):
    def test_parse_version(self):
        self.assertEqual(bg.parse_version("v0.1.5"), (0, 1, 5))
        self.assertEqual(bg.parse_version("0.10.0"), (0, 10, 0))
        self.assertGreater(bg.parse_version("v0.10.0"), bg.parse_version("v0.9.9"))
        for bad in ("", "v1.2", "latest", "v1.2.3-rc1", None):
            self.assertIsNone(bg.parse_version(bad), bad)

    def test_versions_match(self):
        """install.sh and bobcat_gw.py must carry the same version (see Making a release)."""
        with open(os.path.join(ROOT, "install.sh")) as f:
            sh = f.read()
        self.assertIn(f'VERSION="{bg.VERSION}"', sh)


class Configs(unittest.TestCase):
    def test_station_conf(self):
        cfg = default_cfg()
        cfg["gateway_eui"] = "0016c001f1501019"
        conf = bg.station_conf(cfg, HW)
        json.dumps(conf)
        st = conf["station_conf"]
        self.assertEqual(st["routerid"], "0016C001F1501019")
        self.assertEqual(conf["SX1302_conf"]["device"], HW["spi_dev"])
        # The dashboard reads the RX/TX lines, which Basics Station logs at VERBOSE.
        self.assertEqual(st["log_level"].split(",")[0], "VERBOSE")
        for part in st["log_level"].split(",")[1:]:
            mod, level = part.split(":")
            self.assertEqual(len(mod), 3, part)
            self.assertIn(level[:4], ("XDEB", "DEBU", "VERB", "INFO", "NOTI", "WARN", "ERRO", "CRIT"), part)

    def test_global_conf_every_region(self):
        cfg = default_cfg()
        cfg["gateway_eui"] = "0016C001F1501019"
        for region in bg.REGIONS:
            with self.subTest(region=region):
                cfg["region"] = region
                conf = bg.build_global_conf(cfg, HW, "eu1.cloud.thethings.network", 1700, 1700)
                json.dumps(conf)
                self.assertIn("SX130x_conf", conf)
                self.assertIn("gateway_conf", conf)


class StationLog(unittest.TestCase):
    def setUp(self):
        self.stats = bg.Stats()

    def test_uplink(self):
        self.stats.feed(station_entry(ST_UPLINK))
        self.assertEqual(len(self.stats.packets), 1)
        p = self.stats.packets[0]
        self.assertEqual(p["dir"], "up")
        self.assertEqual(p["freq"], 867.1)
        self.assertEqual(p["datr"], "DR5 SF7/BW125")
        self.assertEqual((p["rssi"], p["snr"]), (-48, 13.5))
        self.assertEqual(p["dev_addr"], "260B6C76")
        self.assertEqual(p["fcnt"], 1711)
        self.assertEqual(p["size"], 25)
        self.assertEqual(self.stats.counters["uplinks"], 1)

    def test_join_request(self):
        self.stats.feed(station_entry(ST_JOIN))
        p = self.stats.packets[0]
        self.assertEqual(p["mtype"], "Join request")
        self.assertEqual(p["dev_eui"], "24E124773F027916")
        self.assertEqual(p["datr"], "DR2 SF10/BW125")

    def test_noise_is_not_a_warning(self):
        for line in ST_NOISE:
            self.stats.feed(station_entry(line))
        self.assertEqual(list(self.stats.events), [])
        self.assertEqual(len(self.stats.packets), 0)

    def test_errors_are_events(self):
        self.stats.feed(station_entry("2026-11-08 15:00:00.000 [TCE:ERRO] Connection to MUXS failed"))
        self.assertEqual(len(self.stats.events), 1)
        self.assertEqual(self.stats.events[0]["level"], "error")


class UpdateStatus(unittest.TestCase):
    def result(self, *lines):
        path = os.path.join(TMP, "update.log")
        with open(path, "w") as f:
            f.write("\n".join(lines) + "\n")
        old, bg.UPDATE_LOG = bg.UPDATE_LOG, path
        try:
            return bg.update_status()["result"]
        finally:
            bg.UPDATE_LOG = old

    def test_results(self):
        self.assertEqual(self.result("Downloading x", "Update to v9.9.9 finished."), "ok")
        self.assertEqual(self.result("Downloading x", "Update failed: no network"), "failed")
        self.assertEqual(self.result("The new version does not work: web UI", "Going back to 0.1.5",
                                     "Back on 0.1.5.", "Update failed: web UI"), "rolled_back")
        self.assertIsNone(self.result("Starting the update to v9.9.9"))


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class WebStartup(unittest.TestCase):
    """The web UI must start and serve its page: a release that can't do this leaves
    gateways without a way to update again."""

    def test_serves_page_and_requires_login(self):
        port = free_port()
        env = dict(os.environ, BOBCAT_GW_PORT=str(port))
        p = subprocess.Popen([sys.executable, os.path.join(ROOT, "web", "bobcat_gw.py")], env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            base = f"http://127.0.0.1:{port}"
            for _ in range(60):
                if p.poll() is not None:
                    self.fail("the web UI exited:\n" + p.stdout.read())
                try:
                    with urllib.request.urlopen(base + "/", timeout=2) as r:
                        page = r.read().decode()
                    break
                except OSError:
                    time.sleep(0.5)
            else:
                self.fail("the web UI did not answer within 30 s")
            self.assertIn('id="eui"', page)
            with self.assertRaises(urllib.error.HTTPError) as e:
                urllib.request.urlopen(base + "/api/status", timeout=5)
            self.assertEqual(e.exception.code, 401)
        finally:
            p.terminate()
            try:
                p.wait(10)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
            p.stdout.close()


if __name__ == "__main__":
    unittest.main()
