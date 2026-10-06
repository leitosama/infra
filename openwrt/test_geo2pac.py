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
const [file, mode] = process.argv.slice(1);
const {hosts: hostsList, dns} = JSON.parse(fs.readFileSync(0, "utf8"));
let src = fs.readFileSync(file, "utf8");
if (mode === "oneline") src = src.replace(/\r?\n/g, " ");
const dnsMap = dns;
const sandbox = {
  isPlainHostName: h => h.indexOf(".") < 0,
  dnsResolve: h => (h in dnsMap ? dnsMap[h] : null),
};
// PAC engines evaluate the script as a plain global script
const fn = new Function(...Object.keys(sandbox), src + "\n;return FindProxyForURL;");
const f = fn(...Object.values(sandbox));
const out = {};
for (const h of hostsList) out[h] = f("http://" + h + "/", h);
console.log(JSON.stringify(out));
"""


def run_pac(pac, hosts, mode="multiline", dns=None):
    res = subprocess.run(
        [NODE, "-e", HARNESS, str(pac), mode],
        input=json.dumps({"hosts": hosts, "dns": dns or {}}), capture_output=True, text=True)
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
            "domain:ya.ru:@cn\ndomain:in-addr.arpa\ndomain:ip6.arpa\nfull:www.example.org\nkeyword:yandex\n"
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
        # range edges (5.3.0.0-5.4.255.255, 10/8, 192.168/16)
        "5.2.255.255": "SOCKS5 127.0.0.1:9050", "5.3.0.0": "DIRECT",
        "5.4.255.255": "DIRECT", "5.5.0.0": "SOCKS5 127.0.0.1:9050",
        "9.255.255.255": "SOCKS5 127.0.0.1:9050", "10.0.0.0": "DIRECT",
        "10.255.255.255": "DIRECT", "11.0.0.0": "SOCKS5 127.0.0.1:9050",
        "192.168.255.255": "DIRECT", "192.169.0.0": "SOCKS5 127.0.0.1:9050",
        "1.0.0.1.in-addr.arpa": "DIRECT",
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

    def test_ips_match_python_ipaddress(self):
        """Differential: PAC answer for random IPs and every CIDR edge +-1 must equal
        membership according to Python's ipaddress module (independent oracle)."""
        import ipaddress
        import random
        rnd = random.Random(7)
        nets = [ipaddress.ip_network((rnd.getrandbits(32), rnd.choice((8, 12, 16, 20, 24, 32))), strict=False)
                for _ in range(300)]
        # neighbours / overlaps so that range merging is exercised
        for n in nets[:100]:
            nxt = int(n.broadcast_address) + 1
            if nxt < 2 ** 32:
                nets.append(ipaddress.ip_network((nxt, n.prefixlen), strict=False))
        # ... and ones separated by exactly one address, which must not be merged
        for n in nets[100:200]:
            gap = int(n.broadcast_address) + 2
            if gap < 2 ** 32:
                nets.append(ipaddress.ip_network((gap, 32)))
        nets += [ipaddress.ip_network("0.0.0.0/32"), ipaddress.ip_network("255.255.255.255/32"),
                 ipaddress.ip_network("0.0.0.0/32"), nets[0].supernet()]
        d = Path(tempfile.mkdtemp())
        try:
            (d / "geosite-x.txt").write_text("domain:example.org\n")
            (d / "ips.txt").write_text("\n".join(str(n) for n in nets) + "\n")
            pac = d / "proxy.pac"
            subprocess.run([sys.executable, HERE / "geo2pac.py", d, "-o", pac], check=True, capture_output=True)
            ips = {rnd.getrandbits(32) for _ in range(3000)}
            for n in nets:
                lo, hi = int(n.network_address), int(n.broadcast_address)
                ips |= {v for v in (lo - 1, lo, hi, hi + 1) if 0 <= v < 2 ** 32}
            hosts = [str(ipaddress.ip_address(v)) for v in sorted(ips)]
            got = run_pac(pac, hosts)
            wrong = [h for h in hosts
                     if (got[h] == "DIRECT") != any(ipaddress.ip_address(h) in n for n in nets)]
            self.assertEqual(wrong[:10], [], "%d of %d IPs disagree" % (len(wrong), len(hosts)))
        finally:
            shutil.rmtree(d)

    def test_domains_match_simple_oracle(self):
        """Differential: suffix/full matching vs a naive implementation."""
        import random
        rnd = random.Random(3)
        labels = ["a", "b", "ru", "com", "x1", "yandex", "apple"]
        doms = {".".join(rnd.choice(labels) for _ in range(rnd.randint(1, 3))) for _ in range(40)}
        fulls = {".".join(rnd.choice(labels) for _ in range(rnd.randint(2, 4))) for _ in range(15)}
        d = Path(tempfile.mkdtemp())
        try:
            (d / "geosite-x.txt").write_text(
                "".join("domain:%s\n" % x for x in doms) + "".join("full:%s\n" % x for x in fulls))
            (d / "ips.txt").write_text("10.0.0.0/8\n")
            pac = d / "proxy.pac"
            subprocess.run([sys.executable, HERE / "geo2pac.py", d, "-o", pac], check=True, capture_output=True)
            hosts = sorted({".".join(rnd.choice(labels) for _ in range(rnd.randint(2, 5))) for _ in range(3000)}
                           | doms | fulls)
            got = run_pac(pac, hosts)  # dnsResolve -> null, so only the lists can say DIRECT

            def oracle(h):
                return h in fulls or any(h == x or h.endswith("." + x) for x in doms)
            wrong = [h for h in hosts if (got[h] == "DIRECT") != oracle(h)]
            self.assertEqual(wrong[:10], [], "%d of %d hosts disagree" % (len(wrong), len(hosts)))
        finally:
            shutil.rmtree(d)

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
