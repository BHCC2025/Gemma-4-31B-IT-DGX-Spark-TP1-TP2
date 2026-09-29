#!/usr/bin/env python3
"""nccl_check.py — all-reduce across the cluster with torch.distributed, run inside the recipe's own image.

usage: nccl_check.py --rank R --world N --master IP [--port 29577] [--mb 256] [--iters 20] [--backend nccl|gloo]

Every rank all-reduces a tensor of rank+1 values; the result must equal N(N+1)/2 everywhere. Rank 0 prints one
JSON line with the bus bandwidth (nccl-tests definition: algbw * 2(N-1)/N). --backend gloo runs on CPU over the
bootstrap network only (a quick check of the rendezvous, no GPU).
"""
import argparse, datetime, json, os, socket, sys, time

import torch
import torch.distributed as dist


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rank", type=int, required=True)
    ap.add_argument("--world", type=int, required=True)
    ap.add_argument("--master", required=True)
    ap.add_argument("--port", type=int, default=29577)
    ap.add_argument("--mb", type=int, default=256)
    ap.add_argument("--iters", type=int, default=20)
    ap.add_argument("--backend", default="nccl")
    a = ap.parse_args()

    dist.init_process_group(a.backend, init_method=f"tcp://{a.master}:{a.port}", rank=a.rank, world_size=a.world,
                            timeout=datetime.timedelta(seconds=120))
    dev = torch.device("cuda", 0) if a.backend == "nccl" else torch.device("cpu")
    n = a.mb * 1024 * 1024 // 4
    x = torch.full((n,), float(a.rank + 1), dtype=torch.float32, device=dev)
    want = a.world * (a.world + 1) / 2

    def sync():
        if dev.type == "cuda":
            torch.cuda.synchronize()

    y = x.clone(); dist.all_reduce(y); sync()
    ok = bool(torch.all(y == want).item())
    for _ in range(3):
        y = x.clone(); dist.all_reduce(y)
    sync()
    iters = a.iters if a.backend == "nccl" else 3
    t0 = time.time()
    for _ in range(iters):
        dist.all_reduce(x.clone())
    sync()
    dt = (time.time() - t0) / iters
    algbw = n * 4 / dt / 1e9
    flags = torch.tensor([1 if ok else 0], device=dev)
    dist.all_reduce(flags)
    if a.rank == 0:
        print(json.dumps({"ok": int(flags.item()) == a.world, "world": a.world, "backend": a.backend, "mb": a.mb,
                          "ms": round(dt * 1000, 2), "algbw_GBps": round(algbw, 2),
                          "busbw_GBps": round(algbw * 2 * (a.world - 1) / a.world, 2),
                          "host": socket.gethostname(), "nccl": ".".join(map(str, torch.cuda.nccl.version()))
                          if a.backend == "nccl" else ""}), flush=True)
    dist.destroy_process_group()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
