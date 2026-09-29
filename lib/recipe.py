#!/usr/bin/env python3
"""recipe.py recipe.yaml — print the recipe's setup fields as shell assignments (R_*) for setup.sh to eval."""
import shlex, sys
try:
    import yaml
except ImportError:
    sys.exit("echo 'python3-yaml is missing: sudo apt install python3-yaml' >&2; exit 2")

r = yaml.safe_load(open(sys.argv[1]))
s = r.get("setup", {})
out = {
    "R_NAME": r["name"], "R_HF_REPO": r["model"]["hf_repo"], "R_REVISION": r["model"].get("revision", "main"),
    "R_IMAGE": r["engine"]["image"], "R_DISK_GB": s.get("disk_gb", r["model"].get("size_on_disk_gb", 0)),
    "R_MODEL_DIR": s["model_dir"], "R_TP": " ".join(str(t) for t in s["tp_sizes"]), "R_SMOKE": s.get("smoke_test", ""),
}
for n, cmds in (s.get("prepare") or {}).items():
    out[f"R_PREPARE_{n}"] = "\n".join(cmds if isinstance(cmds, list) else [cmds])
for n, cmd in (s.get("first_run") or {}).items():
    out[f"R_RUN_{n}"] = cmd
for k, v in out.items():
    print(f"{k}={shlex.quote(str(v))}")
