# Networking

Each DGX Spark has a ConnectX-7 with two QSFP ports. Under DGX OS every port appears twice: once as a netdev and
once as an RDMA device (HCA), plus a second "P2" copy of each. `ibdev2netdev` prints the mapping:

```
rocep1s0f0 port 1 ==> enp1s0f0np0 (Up)
rocep1s0f1 port 1 ==> enp1s0f1np1 (Up)
```

The recipes use the `rocep1s0f*` HCAs. NCCL moves tensors over RoCE v2 on the cabled port; at TP2 the vLLM/torch
bootstrap traffic uses the same port.

## TP2: one cable

Connect any CX7 port on Spark A to any CX7 port on Spark B and give both ends an address in the same small
subnet. The two ends don't have to be the same port number. The reference cluster uses port 0 on the head and
port 1 on the worker:

| Node | Interface | HCA | IP |
|---|---|---|---|
| head | enp1s0f0np0 | rocep1s0f0 | 10.10.20.1/24 |
| worker | enp1s0f1np1 | rocep1s0f1 | 10.10.20.2/24 |

Put those values in the `TP2_*` lines of `cluster.env` (`./setup.sh` does it for you). NCCL finds the IPv4 GID
from `NCCL_IB_ADDR_FAMILY` and `NCCL_IB_ADDR_RANGE`. If it doesn't, pin it with `IB_GID_INDEX_TP2=5`.

The NCCL settings are the kit's pair profile (`kit/lib/nccl.sh`), the same one `./setup.sh` tests with a real
all-reduce. Measured on the reference cluster: ~112 Gb/s RDMA on the cable, NCCL all-reduce ~11.7 GB/s.

## Making the IPs permanent

Use netplan on each node, for example `/etc/netplan/60-cx7.yaml` on the head:

```yaml
network:
  version: 2
  ethernets:
    enp1s0f0np0: { addresses: [10.10.20.1/24], mtu: 9000 }
```

Then run `sudo netplan apply`, and `ping` the other end on its link address.
