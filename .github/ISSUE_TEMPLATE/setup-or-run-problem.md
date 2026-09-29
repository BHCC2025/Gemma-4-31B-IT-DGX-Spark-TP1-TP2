---
name: Setup or run problem
about: Something failed in ./setup.sh, ./run.sh or the benchmark
labels: bug
---

**What happened** (the command you ran and the error):


**Setup report** — run `./setup.sh --check` (it changes nothing) and paste `.setup/report.txt` here.
It lists your nodes' OS/GPU/memory, cabling and network test results, and every warning and failure.
Replace anything you'd rather not share (hostnames, LAN IPs) with placeholders.

```
(paste .setup/report.txt)
```

**Server log** (if it started): the last ~50 lines of `./run.sh logs` on the head.

```
(paste)
```

**Recipe version** (`git log --oneline -1`) and kit version (`cat kit/VERSION`):
