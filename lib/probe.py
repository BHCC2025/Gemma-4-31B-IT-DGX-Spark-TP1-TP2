#!/usr/bin/env python3
"""probe.py — describe one DGX Spark as JSON. Read-only, stdlib only, runs as the normal user.

usage: python3 probe.py [--image IMAGE] [--model-dir DIR] [--no-neighbors]

Reports OS/GPU/memory, which tools exist, Docker access, disk space where the model will go, the LAN interface,
and every RDMA port: its netdevs, link state, IPv4/IPv6 addresses, the RoCE v2 IPv4 GID index, and which other
machines answer an IPv6 all-nodes ping on it (how setup.sh works out the cabling without any IPv4 configured).
"""
import argparse, glob, json, os, re, shutil, socket, subprocess


def sh(cmd, timeout=20):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip()
    except subprocess.TimeoutExpired:
        return 124, ""


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def kv_file(path):
    out = {}
    for line in read(path).splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v.strip().strip('"')
    return out


def ip_json(args):
    rc, out = sh(f"ip -j {args}")
    try:
        return json.loads(out) if rc == 0 and out else []
    except json.JSONDecodeError:
        return []


def addrs(dev):
    v4, ll = [], []
    for link in ip_json(f"addr show dev {dev}"):
        for a in link.get("addr_info", []):
            if a.get("family") == "inet":
                v4.append(f"{a['local']}/{a['prefixlen']}")
            elif a.get("family") == "inet6" and a.get("scope") == "link":
                ll.append(a["local"])
    return v4, ll


def free_bytes(path):
    p = os.path.abspath(path)
    while not os.path.exists(p):
        p = os.path.dirname(p)
    st = os.statvfs(p)
    return st.f_bavail * st.f_frsize, p


def model_state(d):
    if not d or not os.path.isfile(os.path.join(d, "config.json")):
        return "missing"
    idx = os.path.join(d, "model.safetensors.index.json")
    if os.path.isfile(idx):
        try:
            shards = set(json.load(open(idx))["weight_map"].values())
        except (OSError, ValueError, KeyError):
            return "partial"
        if not all(os.path.isfile(os.path.join(d, s)) for s in shards):
            return "partial"
    if glob.glob(os.path.join(d, "*.incomplete")) or glob.glob(os.path.join(d, ".cache/huggingface/download/*.incomplete")):
        return "partial"
    return "complete"


def neighbors(dev):
    """IPv6 link-local addresses that answer ff02::1 on this interface (other than our own)."""
    rc, out = sh(f"ping -6 -c 2 -w 3 -I {dev} ff02::1 2>/dev/null", timeout=8)
    return sorted(set(re.findall(r"from (fe80::[0-9a-f:]+)", out)))


def rdma_ports(do_neighbors):
    ports = []
    for hdir in sorted(glob.glob("/sys/class/infiniband/*")):
        hca = os.path.basename(hdir)
        pci = os.path.basename(os.path.realpath(os.path.join(hdir, "device")))       # e.g. 0002:01:00.0
        dom, bdf = (pci.split(":", 1) + [""])[:2]
        netdevs = sorted(os.listdir(os.path.join(hdir, "device/net"))) if os.path.isdir(os.path.join(hdir, "device/net")) else []
        pdir = os.path.join(hdir, "ports/1")
        gid_v4 = None
        for tpath in sorted(glob.glob(os.path.join(pdir, "gid_attrs/types/*")), key=lambda p: int(os.path.basename(p))):
            i = os.path.basename(tpath)
            t = read(tpath)
            g = read(os.path.join(pdir, "gids", i))
            if "v2" in t and g.startswith("0000:0000:0000:0000:0000:ffff:"):
                gid_v4 = int(i)
                break
        nd = []
        for n in netdevs:
            v4, ll = addrs(n)
            carrier = read(f"/sys/class/net/{n}/carrier", "0") == "1"
            nd.append({"name": n, "carrier": carrier, "operstate": read(f"/sys/class/net/{n}/operstate"),
                       "mtu": int(read(f"/sys/class/net/{n}/mtu", "0") or 0), "ipv4": v4, "ll": ll,
                       "neighbors": neighbors(n) if (do_neighbors and carrier and ll) else []})
        ports.append({"hca": hca, "pci": pci, "domain": dom, "bdf": bdf, "state": read(os.path.join(pdir, "state")),
                      "rate": read(os.path.join(pdir, "rate")), "link_layer": read(os.path.join(pdir, "link_layer")),
                      "gid_ipv4": gid_v4, "netdevs": nd})
    return ports


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", default="")
    ap.add_argument("--model-dir", default="")
    ap.add_argument("--no-neighbors", action="store_true")
    a = ap.parse_args()

    osr, dgx = kv_file("/etc/os-release"), kv_file("/etc/dgx-release")
    rc, gpu = sh("nvidia-smi --query-gpu=name,driver_version --format=csv,noheader")
    mem = {k: int(v.split()[0]) // 1048576 for k, v in
           (l.split(":", 1) for l in read("/proc/meminfo").splitlines() if l.startswith(("MemTotal", "MemAvailable")))}
    tools = {t: shutil.which(t) or "" for t in
             ("docker", "rsync", "ib_write_bw", "python3", "hf", "huggingface-cli", "nmcli", "netplan", "ping", "ethtool")}
    rc_venv, _ = sh("python3 -c 'import venv, ensurepip'")
    rc_docker, _ = sh("docker info >/dev/null 2>&1")
    rc_sudo, _ = sh("sudo -n true 2>/dev/null")
    rc_nm, _ = sh("systemctl is-active --quiet NetworkManager")
    _, containers = sh("docker ps --format '{{.Names}}' 2>/dev/null")
    rc_img = sh(f"docker image inspect {a.image} >/dev/null 2>&1")[0] if a.image else 1
    route = ip_json("route show default")
    lan_if = route[0].get("dev", "") if route else ""
    lan_v4, _ = addrs(lan_if) if lan_if else ([], [])
    disk_free, disk_path = free_bytes(a.model_dir or os.path.expanduser("~"))

    print(json.dumps({
        "hostname": socket.gethostname(), "user": os.environ.get("USER", ""), "home": os.path.expanduser("~"),
        "os": osr.get("PRETTY_NAME", ""), "dgx": dgx.get("DGX_PRETTY_NAME", ""), "dgx_build": dgx.get("DGX_SWBUILD_DATE", ""),
        "arch": os.uname().machine, "gpu": gpu if rc == 0 else "", "mem_total_gib": mem.get("MemTotal", 0),
        "mem_avail_gib": mem.get("MemAvailable", 0), "tools": tools, "python_venv": rc_venv == 0,
        "docker_ok": rc_docker == 0, "sudo_nopass": rc_sudo == 0, "networkmanager": rc_nm == 0,
        "containers": [c for c in containers.splitlines() if c], "image_present": rc_img == 0,
        "model_dir": a.model_dir, "model_state": model_state(a.model_dir),
        "disk_free_gb": disk_free // 10**9, "disk_path": disk_path,
        "lan_if": lan_if, "lan_ipv4": lan_v4, "rdma": rdma_ports(not a.no_neighbors),
    }, indent=1))


if __name__ == "__main__":
    main()
