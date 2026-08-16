# HPCGuard 🛡️

> A zero-root, user-space safety layer for AI coding agents (Claude Code, Codex CLI, Cursor, OpenHands) and researchers on shared HPC clusters.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Slurm Ready](https://img.shields.io/badge/Scheduler-Slurm-orange.svg)](#)
[![Zero Root Required](https://img.shields.io/badge/Root-Not_Required-green.svg)](#)

---

## 💡 Why HPCGuard?

Shared HPC cluster login nodes are designed exclusively for lightweight tasks: code editing, light compilation, environment checks, and job submission.

However, autonomous AI coding agents (such as Claude Code, Codex, and terminal agents) often lack environment awareness:
- Accidentally running `torchrun` or `python train.py` directly on the login node.
- Spawning massive recursive disk scans across network storage (`find /gpfs -type f`, `grep -R`).
- Triggering high-concurrency builds (`make -j64`), crashing shared CPU and memory resources.

**This results in cluster login node freezes, account suspensions, and complaints from peers.**

`HPCGuard` acts as an autonomous safety belt:
1. **Pre-execution Interception**: Inspects agent shell commands before execution. If a heavy workload is detected on a login node, it blocks execution and outputs a structured Slurm (`srun` / `sbatch`) alternative.
2. **Background Watchdog & Breaker**: Silently monitors user-space processes on the login node and terminates runaway tasks exceeding CPU thresholds.
3. **Slurm Assistant**: Interactively generates production-ready Slurm batch scripts in seconds.

---

## ⚡ Quick Start (1-Line Installation)

No root permissions or administrator cooperation required. Simply run on your cluster login node:

```bash
wget -O hpc_guard.sh <RELEASE_URL> && chmod +x hpc_guard.sh && ./hpc_guard.sh
```

### Enable Global Shortcut
Run option `[6]` in the menu or execute:
```bash
./hpc_guard.sh install-alias
```
After reloading your shell (`source ~/.bashrc` or `source ~/.zshrc`), you can invoke HPCGuard anytime with:
```bash
hpcguard
```

---

## 🧠 Hard-Learned Lessons & Design Rationale

HPCGuard is not an abstract theory—it is engineered directly from **real-world production incidents and failure modes** encountered while running autonomous agents on multi-user HPC systems:

### 1. Why simple `.bashrc` aliases fail against AI Agents
* **The Failure**: Traditional advice recommends defining bash wrapper functions like `find() { ... }` or `alias grep=...`. However, autonomous agents frequently execute inline Python one-liners such as `python -c "import os; [print(f) for f in os.walk('/gpfs')]"`. Python directly invokes libc `opendir()`/`stat()` system calls, **completely bypassing shell-level aliases**.
* **HPCGuard Solution**: Command-level pre-execution interception and regex-based AST parsing (`hpcguard exec`) that inspects the actual payload and language runtime arguments.

### 2. The "D-State / Metadata I/O Stall" Illusion
* **The Failure**: When an agent recursively searches a shared parallel filesystem (GPFS, Lustre, NFS), processes enter Linux `D` state (uninterruptible disk sleep). While per-process CPU usage appears deceptively low ($10\% \sim 15\%$), the storage metadata server gets locked, causing the entire login node load average to surge from $2.0$ to over $90.0$. Simple CPU threshold monitors completely miss this.
* **HPCGuard Solution**: Path-boundary enforcement that rejects broad scans starting from root or shared mount points (`/`, `/gpfs`, `/shared`, `/home`) before disk traversal begins.

### 3. Multiprocessing Dilution Attacks
* **The Failure**: An agent executing a Python script with `multiprocessing.Pool(processes=16)` divides work across 16 sub-processes, each utilizing $25\%$ CPU. Each individual process evades standard single-process $100\%$ CPU alarms, but aggregates to $400\%$ CPU load across shared physical cores.
* **HPCGuard Solution**: Pre-execution blocking of distributed ML frameworks (`torchrun`, `accelerate`, `mpirun`) combined with user-space aggregate workload tracking.

### 4. Preventing "Exit Code 137" Retry Loops
* **The Failure**: If a background daemon blindly sends `kill -9` to a rogue agent process without feedback, the agent interprets the sudden SIGKILL (exit code 137) as an intermittent crash and immediately attempts to rerun the exact same command in a retry loop.
* **HPCGuard Solution**: Clear, structured block messages explaining *why* the command was rejected and providing copy-paste ready `srun` / `sbatch` replacement commands.

---

## 🚀 Key Features & Demo

### 1. Command Pre-Check & Redirection (`hpcguard exec`)
Wrap terminal commands or agent execution commands with `hpcguard exec`:

```bash
hpcguard exec "torchrun --nproc_per_node=4 train_model.py"
```

**Output:**
```text
======================================================
 [HPCGuard: BLOCKED ON LOGIN NODE]
======================================================
Host:     login01
Command:  torchrun --nproc_per_node=4 train_model.py
Reason:   Distributed ML training framework detected on login node.
Suggested Execution:
  srun --partition=GPU3 --gres=gpu:1 --cpus-per-task=4 python <script.py> (or submit via 'sbatch your_job.slurm')

💡 Hint: To submit jobs properly, run: hpcguard template
```

### 2. Autonomous Watchdog & Breaker
- Tracks user processes on the login node.
- Automatically logs and optionally terminates runaway tasks exceeding thresholds (default: $80\%$ CPU).
- Start background watchdog with:
  ```bash
  hpcguard start
  ```

### 3. Slurm Template Generator
Interactively configure partition, GPU count, CPU cores, memory, and walltime to generate customized `.slurm` batch scripts:
```bash
hpcguard template
```

---

## 🤖 AI Agent Integration (Claude Code / Codex / Cursor)

To ensure your AI coding agent operates safely on shared clusters, add the following instructions to your project's `CLAUDE.md` or `AGENTS.md`:

```markdown
### HPC Cluster Execution Rules
- Always prepend long-running, training, or scanning shell commands with `hpcguard exec "<cmd>"`.
- Never start multi-GPU or distributed ML processes directly on the login node.
- Use `hpcguard template` or standard Slurm batch scripts for GPU workloads.
```

---

## 🛠️ Usage Cheat Sheet

| Command | Description |
| :--- | :--- |
| `hpcguard` | Open interactive TUI management menu |
| `hpcguard exec "<command>"` | Intercept and guard a specific shell command |
| `hpcguard start` | Start background resource watchdog daemon |
| `hpcguard stop` | Stop background resource watchdog daemon |
| `hpcguard status` | Check node status, watchdog state, and limits |
| `hpcguard template` | Launch interactive Slurm script generator |
| `hpcguard install-alias` | Register `hpcguard` command alias into your shell rc |

---

## 📄 License
Released under the [MIT License](LICENSE).
