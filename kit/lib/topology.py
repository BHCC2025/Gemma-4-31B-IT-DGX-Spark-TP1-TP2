#!/usr/bin/env python3
"""topology.py — turn per-node probe JSON into cabling, IP plan and cluster.env values.

usage: topology.py NODE_NAME=probe.json [NODE_NAME=probe.json ...]     (head first, in NODES order)

Prints JSON: {"links": [...], "errors": [...], "warnings": [...], "assign": [...], "env": {...}}
  links   one entry per cable between two of the nodes, with both ends' port, netdev, HCA and IPv4
  assign  fabric IPs that must be configured before the recipe can run (setup.sh offers to apply them)
  env     cluster.env values (bash syntax) for NODES, LAN_*, TP2_*, TP3_*, IB_GID_INDEX

A DGX Spark's CX7 shows every physical QSFP port as two PCIe functions (domain 0000 and 0002), each with its own
netdev and HCA. They are grouped here into one port by bus:device.function; the domain-0000 function is the one
the recipes use. Cables are found by matching the IPv6 link-local addresses that answered an all-nodes ping on a
port against the other nodes' addresses, so no IPv4 has to be configured yet.
"""
import ipaddress, json, sys

# Subnet plan for links we have to address ourselves: link k -> 10.10.(20+2k).0/24, host = node index + 1.
# Pairs in this order: (0,1) -> .20, (1,2) -> .22, (0,2) -> .24.
PAIR_ORDER = [(0, 1), (1, 2), (0, 2)]


def ports_of(probe):
    """Group RDMA functions into physical ports keyed by bdf."""
    ports = {}
    for f in probe["rdma"]:
        if f.get("link_layer") and f["link_layer"] != "Ethernet":
            continue
        p = ports.setdefault(f["bdf"], {"bdf": f["bdf"], "functions": []})
        p["functions"].append(f)
    for p in ports.values():
        p["functions"].sort(key=lambda f: f["domain"])
        prim = p["functions"][0]
        nd = prim["netdevs"][0] if prim["netdevs"] else {}
        p.update(hca=prim["hca"], netdev=nd.get("name", ""), ipv4=nd.get("ipv4", []), mtu=nd.get("mtu", 0),
                 active="ACTIVE" in prim["state"], rate=prim["rate"], gid=prim["gid_ipv4"],
                 carrier=any(n["carrier"] for f in p["functions"] for n in f["netdevs"]),
                 ll={a for f in p["functions"] for n in f["netdevs"] for a in n["ll"]},
                 heard={a for f in p["functions"] for n in f["netdevs"] for a in n["neighbors"]})
    return [ports[k] for k in sorted(ports)]


def same_subnet(a_list, b_list):
    for a in a_list:
        for b in b_list:
            ia, ib = ipaddress.ip_interface(a), ipaddress.ip_interface(b)
            if ia.network == ib.network and ia.ip != ib.ip:
                return str(ia), str(ib)
    return None


def main():
    names, probes = [], []
    for arg in sys.argv[1:]:
        n, path = arg.split("=", 1)
        names.append(n); probes.append(json.load(open(path)))
    N = len(names)
    errors, warnings, links, assign, env = [], [], [], [], {}
    P = [ports_of(p) for p in probes]
    own = [set().union(*(p["ll"] for p in ports)) if ports else set() for ports in P]

    # LAN
    lan_ifs = {p["lan_if"] for p in probes}
    if len(lan_ifs) != 1 or "" in lan_ifs:
        warnings.append(f"LAN interface differs between nodes or is missing: {[p['lan_if'] for p in probes]}")
    env["LAN_IF"] = probes[0]["lan_if"]
    env["LAN_IPS"] = [(p["lan_ipv4"][0].split("/")[0] if p["lan_ipv4"] else "") for p in probes]
    for n, ip in zip(names, env["LAN_IPS"]):
        if not ip:
            errors.append(f"{n}: no IPv4 on the default-route interface")

    # cables between nodes
    found = {}
    for i in range(N):
        for pi in P[i]:
            for j in range(N):
                if j == i:
                    continue
                for pj in P[j]:
                    if pi["heard"] & pj["ll"] or pj["heard"] & pi["ll"]:
                        key = (min(i, j), max(i, j))
                        ends = (pi, pj) if i < j else (pj, pi)
                        if all(e[0]["bdf"] != ends[0]["bdf"] or e[1]["bdf"] != ends[1]["bdf"] for e in found.get(key, [])):
                            found.setdefault(key, []).append(ends)
    # fall back to IPv4 subnets when link-local discovery saw nothing (e.g. IPv6 disabled)
    if not found:
        for i in range(N):
            for j in range(i + 1, N):
                for pi in P[i]:
                    for pj in P[j]:
                        if pi["carrier"] and pj["carrier"] and same_subnet(pi["ipv4"], pj["ipv4"]):
                            found.setdefault((i, j), []).append((pi, pj))
        if N > 1 and found:
            warnings.append("cabling inferred from IPv4 subnets only (no IPv6 link-local replies)")

    need = [(0, 1)] if N == 2 else PAIR_ORDER if N == 3 else []
    chosen = {}
    for pair in need:
        cands = found.get(pair, [])
        if not cands:
            errors.append(f"no cable found between {names[pair[0]]} and {names[pair[1]]}")
            continue
        chosen[pair] = cands[0]
        if len(cands) > 1 and N == 2:
            warnings.append(f"{len(cands)} cables between {names[0]} and {names[1]}; using the first "
                            f"({cands[0][0]['netdev']} <-> {cands[0][1]['netdev']})")
    if N == 3:
        for i in range(3):
            used = [chosen[pr][0 if pr[0] == i else 1]["bdf"] for pr in chosen if i in pr]
            if len(used) == 2 and used[0] == used[1]:
                errors.append(f"{names[i]}: both neighbours reached through the same port — a triangle needs one "
                              f"cable per port (see docs/networking.md)")
        extra = [pr for pr in found if pr not in need]
        if extra:
            warnings.append(f"unexpected extra cables {extra}")

    # IP plan for the chosen links
    taken = {ipaddress.ip_interface(a).network for ports in P for p in ports for a in p["ipv4"]}
    for k, pair in enumerate(PAIR_ORDER):
        if pair not in chosen:
            continue
        a, b = chosen[pair]
        sub = same_subnet(a["ipv4"], b["ipv4"])
        if sub:
            ipa, ipb = sub
        else:
            third = 20 + 2 * k
            while ipaddress.ip_network(f"10.10.{third}.0/24") in taken:
                third += 1
            net = ipaddress.ip_network(f"10.10.{third}.0/24"); taken.add(net)
            ipa, ipb = f"10.10.{third}.{pair[0] + 1}/24", f"10.10.{third}.{pair[1] + 1}/24"
            for node, port, ip in ((pair[0], a, ipa), (pair[1], b, ipb)):
                assign.append({"node": names[node], "index": node, "netdev": port["netdev"], "cidr": ip,
                               "replaces": port["ipv4"]})
        for port, node in ((a, pair[0]), (b, pair[1])):
            if not port["active"]:
                errors.append(f"{names[node]}: {port['hca']} is not ACTIVE")
            if port["gid"] is None and not any(x["node"] == names[node] and x["netdev"] == port["netdev"] for x in assign):
                errors.append(f"{names[node]}: {port['hca']} has no RoCE v2 IPv4 GID")
        links.append({"pair": list(pair), "a": {"node": names[pair[0]], "netdev": a["netdev"], "hca": a["hca"], "ip": ipa,
                                                "rate": a["rate"], "gid": a["gid"]},
                      "b": {"node": names[pair[1]], "netdev": b["netdev"], "hca": b["hca"], "ip": ipb,
                            "rate": b["rate"], "gid": b["gid"]}})

    env["NODES"] = names
    l01 = next((l for l in links if l["pair"] == [0, 1]), None)
    if l01:
        env.update(TP2_HEAD_IP=l01["a"]["ip"].split("/")[0], TP2_WORKER_IP=l01["b"]["ip"].split("/")[0],
                   TP2_SUBNET=str(ipaddress.ip_interface(l01["a"]["ip"]).network),
                   TP2_HEAD_IF=l01["a"]["netdev"], TP2_HEAD_HCA=l01["a"]["hca"],
                   TP2_WORKER_IF=l01["b"]["netdev"], TP2_WORKER_HCA=l01["b"]["hca"])
    if N == 3 and len(links) == 3:
        per_node = []
        for i in range(3):
            per_node.append(sorted({l["a" if l["pair"][0] == i else "b"]["hca"] for l in links if i in l["pair"]}))
        if any(h != per_node[0] for h in per_node):
            warnings.append(f"triangle uses different HCA names per node {per_node}; TP3_HCAS is shared, check it")
        env["TP3_HCAS"] = ",".join(per_node[0])
    gids = {e["gid"] for l in links for e in (l["a"], l["b"]) if e["gid"] is not None}
    if len(gids) == 1:
        env["IB_GID_INDEX"] = gids.pop()
    elif len(gids) > 1:
        warnings.append(f"RoCE v2 IPv4 GID index differs between ports {sorted(gids)}; NCCL needs one value")
        env["IB_GID_INDEX"] = min(gids)
    for i, p in enumerate(probes):
        if p["containers"]:
            warnings.append(f"{names[i]}: containers running: {', '.join(p['containers'])}")

    print(json.dumps({"links": links, "errors": errors, "warnings": warnings, "assign": assign, "env": env}, indent=1))


if __name__ == "__main__":
    main()
