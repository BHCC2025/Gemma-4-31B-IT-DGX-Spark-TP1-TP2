#!/usr/bin/env python3
"""test_topology.py — lib/topology.py against synthetic clusters (no hardware, no real addresses).

Each Spark is built like a real one: two QSFP ports, each exposed as two PCIe functions (domain 0000 and 0002) with
their own HCA and netdev. A cable between two ports makes each side "hear" the other's IPv6 link-local addresses,
which is how probe.py reports cabling.
"""
import json, os, subprocess, sys, tempfile, unittest

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOPO = os.path.join(KIT, "lib", "topology.py")


def spark(n, lan_ip=None, gid=5, ipv4=None, carrier=(True, True)):
    """Probe dict for Spark number n (1-based). ipv4: {port: ["10.10.20.1/24"]}."""
    ipv4 = ipv4 or {}
    rdma = []
    for port in (0, 1):
        for dom in ("0000", "0002"):
            p2 = dom == "0002"
            hca = f"roce{'P2' if p2 else ''}p1s0f{port}"
            nd = f"en{'P2' if p2 else ''}p1s0f{port}np{port}"
            rdma.append({
                "hca": hca, "pci": f"{dom}:01:00.{port}", "domain": dom, "bdf": f"01:00.{port}",
                "state": "4: ACTIVE", "rate": "200 Gb/sec (2X NDR)", "link_layer": "Ethernet",
                "gid_ipv4": None if (gid is None or p2) else gid,
                "netdevs": [{"name": nd, "carrier": carrier[port], "operstate": "up", "mtu": 9000,
                             "ipv4": [] if p2 else list(ipv4.get(port, [])),
                             "ll": [f"fe80::{n}:{port}:{1 if p2 else 0}"], "neighbors": []}]})
    return {"hostname": f"spark{n}", "lan_if": "enP7s7", "lan_ipv4": [f"{lan_ip or f'192.168.1.10{n}'}/24"],
            "containers": [], "rdma": rdma}


def cable(a, pa, b, pb):
    """Connect port pa of probe a to port pb of probe b (both PCIe functions, like a real QSFP cable)."""
    def lls(p, port):
        return [x for f in p["rdma"] if f["bdf"] == f"01:00.{port}" for n in f["netdevs"] for x in n["ll"]]
    for x, px, y, py in ((a, pa, b, pb), (b, pb, a, pa)):
        for f in x["rdma"]:
            if f["bdf"] == f"01:00.{px}":
                for nd in f["netdevs"]:
                    nd["neighbors"] = sorted(set(nd["neighbors"]) | set(lls(y, py)))


def topo(*probes):
    with tempfile.TemporaryDirectory() as d:
        args = []
        for i, p in enumerate(probes):
            f = os.path.join(d, f"p{i}.json")
            with open(f, "w") as fh:
                json.dump(p, fh)
            args.append(f"spark{i + 1}={f}")
        out = subprocess.run([sys.executable, TOPO] + args, capture_output=True, text=True, check=True).stdout
    return json.loads(out)


class Pair(unittest.TestCase):
    def test_port0_to_port1_with_ips(self):
        a = spark(1, ipv4={0: ["10.10.20.1/24"]}); b = spark(2, ipv4={1: ["10.10.20.2/24"]}); cable(a, 0, b, 1)
        t = topo(a, b)
        self.assertEqual(t["errors"], []); self.assertEqual(t["assign"], [])
        e = t["env"]
        self.assertEqual((e["TP2_HEAD_IF"], e["TP2_HEAD_HCA"]), ("enp1s0f0np0", "rocep1s0f0"))
        self.assertEqual((e["TP2_WORKER_IF"], e["TP2_WORKER_HCA"]), ("enp1s0f1np1", "rocep1s0f1"))
        self.assertEqual((e["TP2_HEAD_IP"], e["TP2_WORKER_IP"], e["TP2_SUBNET"]), ("10.10.20.1", "10.10.20.2", "10.10.20.0/24"))
        self.assertEqual(e["IB_GID_INDEX"], 5)

    def test_fresh_ports_get_an_ip_plan(self):
        a = spark(1); b = spark(2); cable(a, 1, b, 1)
        t = topo(a, b)
        self.assertEqual(t["errors"], [])
        self.assertEqual(sorted((x["node"], x["netdev"], x["cidr"]) for x in t["assign"]),
                         [("spark1", "enp1s0f1np1", "10.10.20.1/24"), ("spark2", "enp1s0f1np1", "10.10.20.2/24")])

    def test_ip_plan_skips_a_subnet_already_in_use(self):
        a = spark(1, ipv4={0: ["10.10.20.7/24"]}); b = spark(2); cable(a, 1, b, 1)   # 10.10.20.0/24 taken, other port
        t = topo(a, b)
        self.assertTrue(all(x["cidr"].startswith("10.10.21.") for x in t["assign"]), t["assign"])

    def test_no_cable(self):
        t = topo(spark(1), spark(2))
        self.assertTrue(any("no cable found" in e for e in t["errors"]), t["errors"])

    def test_two_cables_warns_and_uses_one(self):
        a = spark(1); b = spark(2); cable(a, 0, b, 0); cable(a, 1, b, 1)
        t = topo(a, b)
        self.assertEqual(t["errors"], []); self.assertEqual(len(t["links"]), 1)
        self.assertTrue(any("2 cables" in w for w in t["warnings"]), t["warnings"])

    def test_missing_ipv4_gid_is_an_error(self):
        a = spark(1, gid=None, ipv4={0: ["10.10.20.1/24"]}); b = spark(2, ipv4={0: ["10.10.20.2/24"]}); cable(a, 0, b, 0)
        t = topo(a, b)
        self.assertTrue(any("no RoCE v2 IPv4 GID" in e for e in t["errors"]), t["errors"])

    def test_ipv6_off_falls_back_to_ipv4_subnets(self):
        a = spark(1, ipv4={0: ["10.10.20.1/24"]}); b = spark(2, ipv4={1: ["10.10.20.2/24"]})   # no neighbours heard
        t = topo(a, b)
        self.assertEqual(t["errors"], []); self.assertEqual(len(t["links"]), 1)
        self.assertTrue(any("IPv4 subnets only" in w for w in t["warnings"]), t["warnings"])

    def test_lan_missing_is_an_error(self):
        a = spark(1); b = spark(2); a["lan_ipv4"] = []; cable(a, 0, b, 0)
        t = topo(a, b)
        self.assertTrue(any("no IPv4 on the default-route interface" in e for e in t["errors"]), t["errors"])


class Triangle(unittest.TestCase):
    def good(self):
        a, b, c = spark(1), spark(2), spark(3)
        cable(a, 0, b, 1); cable(b, 0, c, 1); cable(c, 0, a, 1)
        return a, b, c

    def test_triangle(self):
        t = topo(*self.good())
        self.assertEqual(t["errors"], []); self.assertEqual(len(t["links"]), 3); self.assertEqual(len(t["assign"]), 6)
        self.assertEqual(t["env"]["TP3_HCAS"], "rocep1s0f0,rocep1s0f1")
        self.assertEqual(t["env"]["LAN_IPS"], ["192.168.1.101", "192.168.1.102", "192.168.1.103"])
        subnets = sorted({x["cidr"].rsplit(".", 1)[0] for x in t["assign"]})
        self.assertEqual(subnets, ["10.10.20", "10.10.22", "10.10.24"])

    def test_missing_cable(self):
        a, b, c = spark(1), spark(2), spark(3); cable(a, 0, b, 1); cable(b, 0, c, 1)
        t = topo(a, b, c)
        self.assertTrue(any("no cable found between spark1 and spark3" in e for e in t["errors"]), t["errors"])

    def test_both_neighbours_on_one_port_is_an_error(self):
        # A switch-like miswiring: spark1 hears both neighbours on port 0.
        a, b, c = spark(1), spark(2), spark(3); cable(a, 0, b, 1); cable(b, 0, c, 1); cable(c, 0, a, 0)
        t = topo(a, b, c)
        self.assertTrue(any("same port" in e for e in t["errors"]), t["errors"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
