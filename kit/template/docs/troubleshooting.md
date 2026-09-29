# Troubleshooting

Start with `./setup.sh --check` (it changes nothing), then look at the server log (`./run.sh logs` on the head, `docker logs
{{CONTAINER}}` on a worker).

| Symptom | Cause | Fix |
|---|---|---|
| Download fails with 401/403 | Gated model: licence not accepted, or not logged in | Accept the licence on the model's Hugging Face page, then `hf auth login` |
| `MODEL MISSING at ...` | The model isn't on that node | `./setup.sh` (downloads it and copies it to every node) |
<!-- tp2 -->
| Head waits forever for the workers | Wrong fabric/LAN values in `cluster.env`, a firewall on `MPORT`, or a worker that exited | `docker logs {{CONTAINER}}` on each worker; `./run.sh stop` and start again |
| Multi-node run much slower than expected | NCCL fell back to TCP sockets | Start with `NCCL_DEBUG=INFO`; the log should show `NET/IB`. Re-run `./setup.sh --check` |
<!-- /tp2 -->
<!-- tp3 -->
| `ibv_modify_qp ... RTR ... 110` / NCCL timeout at TP3 | NCCL merged the two CX7 ports, or it's using the IPv6 GID | Check `IB_GID_INDEX` (docs/networking.md). The kit's triangle profile already sets `MERGE_NICS=0`, `CROSS_NIC=1`, `SUBNET_AWARE_ROUTING=1` |
<!-- /tp3 -->
| OOM during CUDA graph capture | `GMU` too high for this TP size | Lower `GMU` |
| OOM or a Spark reboots while loading | Other containers are holding memory; page cache | Stop everything else, then check `free -g` |
| A setting from the environment is ignored | It is set inside the launcher, not read from the environment | Check the header of `recipes/tpN.sh` for the knobs it reads |
| DeepGEMM errors | Not supported on sm_121 | The recipe already sets `VLLM_USE_DEEP_GEMM=0` |
| TODO | model-specific problems (parsers, patches, context length) | |
