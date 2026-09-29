# Networking

Each DGX Spark has a ConnectX-7 with two QSFP ports. Under DGX OS every port appears twice: once as a netdev and
once as an RDMA device (HCA), plus a second "P2" copy of each. `ibdev2netdev` prints the mapping:

```
rocep1s0f0 port 1 ==> enp1s0f0np0 (Up)
rocep1s0f1 port 1 ==> enp1s0f1np1 (Up)
```

The recipes use the `rocep1s0f*` HCAs and NCCL moves tensors over RoCE v2. The settings are the kit's profiles
(`kit/lib/nccl.sh`), the same ones `./setup.sh` tests with a real all-reduce, so a passing setup check means the
recipe's network is proven.

<!-- tp2 -->
## TP2: one cable

Connect any CX7 port on Spark A to any CX7 port on Spark B and give both ends an address in the same small
subnet. The two ends don't have to be the same port number. For example:

| Node | Interface | HCA | IP |
|---|---|---|---|
| head | enp1s0f0np0 | rocep1s0f0 | 10.10.20.1/24 |
| worker | enp1s0f1np1 | rocep1s0f1 | 10.10.20.2/24 |

`./setup.sh` finds the cable, offers to assign the addresses, and writes the `TP2_*` lines of `cluster.env`. NCCL
finds the IPv4 GID from `NCCL_IB_ADDR_FAMILY` and `NCCL_IB_ADDR_RANGE`. If it doesn't, pin it with
`IB_GID_INDEX_TP2=5`. Expect ~112 Gb/s RDMA on the cable and an NCCL all-reduce of ~11–12 GB/s.
<!-- /tp2 -->

<!-- tp3 -->
## TP3: three cables in a triangle

There's no switch. Each Spark's two ports go to its two neighbours, and **each link gets its own subnet**:

```
            spark1
   p0 10.10.20.1   p1 10.10.24.1
        /                 \
 p1 10.10.20.2        p0 10.10.24.3
   spark2 ─────────────── spark3
     p0 10.10.22.2   p1 10.10.22.3
```

Any consistent assignment works (`./setup.sh` proposes one). What matters for NCCL:
- A given port reaches **one** neighbour only, so NCCL must not merge the two ports into one virtual NIC:
  `NCCL_IB_MERGE_NICS=0`, `NCCL_CROSS_NIC=1`, `NCCL_IB_SUBNET_AWARE_ROUTING=1`. Without these, NCCL tries to reach
  a peer through the wrong port and fails with `ibv_modify_qp ... RTR ... 110` (timeout).
- Bootstrap runs over the LAN (`LAN_IF`, `LAN_IPS`), not the fabric.
- `NCCL_IB_GID_INDEX` must point at the **RoCE v2 IPv4** GID. On DGX OS 7 that's usually index 5; index 3 is
  IPv6 link-local and hangs. `./setup.sh` finds it for you.
- P2P and SHM transports are off, and NCCL buffers are small. On a Spark, pinned host memory *is* GPU memory.

The triangle settings follow the 3-Spark DeepSeek-V4.1 stack by MiaAI-Lab (settings only, no code).
<!-- /tp3 -->

## Making the IPs permanent

`./setup.sh` does this for you when it assigns addresses: a NetworkManager connection `spark-fabric-<interface>`
(or, without NetworkManager, a netplan file), only on the fabric ports. To do it by hand with netplan, for example
`/etc/netplan/60-cx7.yaml`:

```yaml
network:
  version: 2
  ethernets:
    enp1s0f0np0: { addresses: [10.10.20.1/24], mtu: 9000 }
```

Then run `sudo netplan apply`, and `ping` the other end on its link address.
