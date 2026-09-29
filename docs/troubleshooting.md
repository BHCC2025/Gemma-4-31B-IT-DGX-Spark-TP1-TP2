# Troubleshooting

Start with `./setup.sh --check` (it changes nothing), then look at the server log (`./run.sh logs` on the head, `docker logs
vllm_gemma4_31b` on the worker).

| Symptom | Cause | Fix |
|---|---|---|
| Download fails | No internet access, a proxy, or a wrong revision (neither model needs a login) | Accept the terms on the Hugging Face pages of `nvidia/Gemma-4-31B-IT-NVFP4` and `google/gemma-4-31B-it-assistant`, then `hf auth login` |
| `MODEL MISSING at .../gemma-4-31B-it-assistant` | Draft model not on that node | `scripts/get-draft-model.sh` (or run with `SPEC=ngram` / `SPEC=off`) |
| Head waits forever for the worker | Wrong `TP2_*` values, a firewall on `MPORT` (29531), or the worker exited | `docker logs vllm_gemma4_31b` on the worker; `./run.sh stop` and start again |
| TP2 much slower than expected | NCCL fell back to TCP sockets | Start it with `NCCL_DEBUG=INFO ./run.sh tp2`; the log should show `NET/IB`. Re-run `./setup.sh --check` and check the `TP2_*` HCA names |
| OOM during CUDA graph capture | `GMU` too high for this TP size | Lower `GMU` (the TP2 default is already 0.75) |
| OOM or a Spark reboots while loading | Other containers are holding memory; page cache | Stop everything else, then check `free -g` |
| Tool calls come back as text | Wrong parser | The recipe sets `--tool-call-parser gemma4` |
| Draft model fails to load (`ValidationError` on `SpeculativeConfig`) | Image too old for the Gemma 4 draft model | Use the pinned `vllm/vllm-openai:v0.29.0` |
| DeepGEMM errors | Not supported on sm_121 | The recipe already sets `VLLM_USE_DEEP_GEMM=0` |
