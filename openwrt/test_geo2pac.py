#!/usr/bin/env python3
"""Tests for geo2pac.py: build a PAC from sample lists and run it in node.

usage: python3 openwrt/test_geo2pac.py [path/to/real.pac ...]
Extra args are existing PAC files that get the same smoke checks.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).parent
NODE = shutil.which("node")

HARNESS = r"""
const fs = require("fs");
const [file, mode, hostsJson, dns] = process.argv.slice(1);
let src = fs.readFileSync(file, "utf8");
if (mode === "oneline") src = src.replace(/\r?\n/g, " ");
const dnsMap = JSON.parse(dns);
const sandbox = {
  isPlainHostName: h => h.indexOf(".") < 0,
  dnsResolve: h => (h in dnsMap ? dnsMap[h] : null),
};
// PAC engines evaluate the script as a plain global script
const fn = new Function(...Object.keys(sandbox), src + "\n;return FindProxyForURL;");
const f = fn(...Object.values(sandbox));
const out = {};
for (const h of JSON.parse(hostsJson)) out[h] = f("http://" + h + "/", h);
console.log(JSON.stringify(out));
"""


def run_pac(pac, hosts, mode="multiline", dns=None):
    res = subprocess.run(
        [NODE, "-e", HARNESS, str(pac), mode, json.dumps(hosts), json.dumps(dns or {})],
        capture_output=True, text=True)
    if res.returncode:
        raise RuntimeError(res.stderr)
    return json.loads(res.stdout)


@unittest.skipUnless(NODE, "node not installed")
class SamplePac(unittest.TestCase):
    PROXY = "SOCKS5 127.0.0.1:9050"

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp())
        (cls.tmp / "geosite-ru.txt").write_text(
            "domain:ya.ru:@cn\nfull:www.example.org\nkeyword:yandex\n"
            "regexp:^foo\\d+\\.bar\\.com$\n")
        (cls.tmp / "private.txt").write_text("10.0.0.0/8\n192.168.0.0/16\n::1/128\n")
        (cls.tmp / "ru.txt").write_text("5.3.0.0/16\n5.4.0.0/16\n")
        cls.pac = cls.tmp / "proxy.pac"
        subprocess.run([sys.executable, HERE / "geo2pac.py", cls.tmp, "-o", cls.pac],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp)

    CASES = {
        "ya.ru": "DIRECT", "a.ya.ru": "DIRECT", "www.example.org": "DIRECT",
        "x.example.org": "SOCKS5 127.0.0.1:9050", "my-yandex-x.com": "DIRECT",
        "foo12.bar.com": "DIRECT", "10.1.2.3": "DIRECT", "5.4.9.9": "DIRECT",
        "5.5.0.1": "SOCKS5 127.0.0.1:9050", "8.8.8.8": "SOCKS5 127.0.0.1:9050",
        "localhost": "DIRECT", "[::1]": "DIRECT", "ru.resolved": "DIRECT",
        "google.com": "SOCKS5 127.0.0.1:9050", "UPPER.GOOGLE.COM": "SOCKS5 127.0.0.1:9050",
        "nxdomain.test": "SOCKS5 127.0.0.1:9050",
    }
    DNS = {"ru.resolved": "5.3.1.1", "google.com": "142.250.1.1"}

    def check(self, mode):
        got = run_pac(self.pac, list(self.CASES), mode, self.DNS)
        self.assertEqual(got, self.CASES)

    def test_multiline(self):
        self.check("multiline")

    def test_collapsed_to_one_line(self):
        # inline PAC configs strip newlines; `//` comments would swallow the code
        self.check("oneline")

    def test_no_line_comments(self):
        for n, line in enumerate(self.pac.read_text().splitlines(), 1):
            self.assertNotIn("//", line.replace("://", ""), "line %d" % n)

    def test_proxy_override(self):
        pac = self.tmp / "other.pac"
        subprocess.run([sys.executable, HERE / "geo2pac.py", self.tmp, "-o", pac,
                        "-p", "SOCKS5 1.2.3.4:1080"], check=True, capture_output=True)
        self.assertEqual(run_pac(pac, ["google.com"])["google.com"], "SOCKS5 1.2.3.4:1080")


@unittest.skipUnless(NODE, "node not installed")
class ExtraPacs(unittest.TestCase):
    def test_extra(self):
        for f in EXTRA:
            for mode in ("multiline", "oneline"):
                got = run_pac(f, ["google.com", "10.1.1.1", "localhost"], mode)
                self.assertEqual(got["10.1.1.1"], "DIRECT", (f, mode))
                self.assertEqual(got["localhost"], "DIRECT", (f, mode))
                self.assertNotEqual(got["google.com"], "DIRECT", (f, mode))


EXTRA = []

if __name__ == "__main__":
    EXTRA = [a for a in sys.argv[1:] if not a.startswith("-")]
    unittest.main(argv=[sys.argv[0]])
