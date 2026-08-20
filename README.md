# HPCGuard 🛡️

> A zero-root, user-space safety governance layer for AI coding agents (Claude Code, Codex CLI, Cursor, OpenHands) and researchers on shared HPC clusters.
> Supporting Python ML/DL, R/Bioinformatics, and C/C++ Workload Orchestration.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Slurm Ready](https://img.shields.io/badge/Scheduler-Slurm-orange.svg)](#)
[![Python & R Support](https://img.shields.io/badge/Workloads-Python%20%7C%20R%20%7C%20C%2B%2B-brightgreen.svg)](#)
[![Zero Root Required](https://img.shields.io/badge/Root-Not_Required-green.svg)](#)

---

## 💡 Why HPCGuard?

Shared HPC cluster login nodes are strictly provisioned for lightweight interactive tasks: code editing, light compilation, environment checks, and job submission.

However, autonomous AI coding agents and automated research workflows frequently trigger severe resource incidents:
- Running multi-GPU training (`torchrun`, `accelerate`) or heavy Python scripts directly on login nodes.
- Spawning in-memory R / Bioinformatics pipelines (`Rscript`, `Seurat`, `DESeq2`) that implicitly saturate 32+ CPU cores and tens of gigabytes of RAM.
- Launching native R/C++ package compilation (`install.packages`, `make -j64`).
- Executing recursive scans across parallel network filesystems (`find /gpfs -type f`, `grep -R`), locking metadata servers.

**This results in cluster login node freezes, account suspensions, and complaints from peers.**

`HPCGuard` acts as an autonomous safety runtime:
1. **Pre-execution Interception (`hpcguard exec`)**: Inspects shell commands before execution. Blocks dangerous workloads on login nodes and rewrites them into compliant `srun` / `sbatch` commands.
2. **Multi-Vector Watchdog & Breaker**: Silently monitors single-process CPU, aggregate multi-process dilution, and storage D-state I/O locks.
3. **Slurm Job Assistant**: Interactively generates production-ready Slurm batch scripts for both **Python ML** and **R / Bioinformatics**.

---

## ⚡ Quick Start (1-Line Installation)

No root permissions or administrator cooperation required. Simply run on your cluster login node:

```bash
wget -O hpc_guard.sh https://raw.githubusercontent.com/playfulsoul/hpcguard/main/hpc_guard.sh && chmod +x hpc_guard.sh && ./hpc_guard.sh
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

HPCGuard is engineered directly from **real-world production incidents and failure modes** encountered while running autonomous agents and multi-user scientific workflows on HPC systems:

### 1. Why simple `.bashrc` aliases fail against AI Agents
* **The Failure**: Traditional setups define bash wrapper functions like `find() { ... }` or `alias grep=...`. However, autonomous agents frequently execute inline Python one-liners such as `python -c "import os; [print(f) for f in os.walk('/gpfs')]"`. Python directly invokes libc `opendir()`/`stat()` system calls, **completely bypassing shell-level aliases**.
* **HPCGuard Solution**: Command-level pre-execution interception and regex-based payload parsing (`hpcguard exec`) that inspects runtime arguments.

### 2. The "D-State / Metadata I/O Stall" Illusion
* **The Failure**: When an agent or script recursively searches a shared parallel filesystem (GPFS, Lustre, NFS), processes enter Linux `D` state (uninterruptible disk sleep). While per-process CPU usage appears deceptively low ($10\% \sim 15\%$), the storage metadata server gets locked, causing the entire login node load average to surge from $2.0$ to over $90.0$. Simple CPU threshold monitors completely miss this.
* **HPCGuard Solution**: Path-boundary enforcement that rejects broad scans starting from root or shared mount points (`/`, `/gpfs`, `/shared`, `/home`) before disk traversal begins.

### 3. The R Language & In-Memory Bioinformatics Trap
* **The Failure**: R workloads (such as single-cell RNA-seq clustering via `Seurat` or package installation via `install.packages()`) default to in-memory loading and implicit multi-threading (BLAS/OpenMP), stealthily spawning 32+ threads and consuming dozens of gigabytes of RAM on login nodes.
* **HPCGuard Solution**: Explicit interception of `Rscript`, `R CMD INSTALL`, and common bioinformatics frameworks, auto-redirecting them to high-memory CPU compute nodes.

### 4. Multiprocessing Dilution Attacks
* **The Failure**: An agent executing a Python script with `multiprocessing.Pool(processes=16)` divides work across 16 sub-processes, each utilizing $25\%$ CPU. Each individual process evades standard single-process $100\%$ CPU alarms, but aggregates to $400\%$ CPU load across shared physical cores.
* **HPCGuard Solution**: Pre-execution blocking of distributed frameworks (`torchrun`, `accelerate`, `mpirun`) combined with real-time tracking of total user aggregate CPU load.

### 5. Preventing "Exit Code 137" Retry Loops
* **The Failure**: If a background daemon blindly sends `kill -9` to a rogue agent process without feedback, the agent interprets the sudden SIGKILL (exit code 137) as an intermittent crash and immediately attempts to rerun the exact same command in a retry loop.
* **HPCGuard Solution**: Clear, structured block messages explaining *why* the command was rejected and providing copy-paste ready `srun` / `sbatch` replacement commands.

---

## 🚀 Key Features & Demo

### 1. Command Pre-Check & Redirection (`hpcguard exec`)

```bash
# Python GPU Training Guard:
hpcguard exec "torchrun --nproc_per_node=4 train_model.py"

# R Bioinformatics Pipeline Guard:
hpcguard exec "Rscript run_seurat_clustering.R"
```

**Output:**
```text
======================================================
 [HPCGuard: BLOCKED ON LOGIN NODE]
======================================================
Host:     login01
Command:  Rscript run_seurat_clustering.R
Reason:   Heavy R/Bioinformatics pipeline or native package compilation detected on login node.
Suggested Execution:
  srun --partition=cpu --cpus-per-task=8 --mem=32G Rscript run_seurat_clustering.R (or submit via 'sbatch r_job.slurm')

💡 Hint: To generate a batch script, run: hpcguard template
```

### 2. Multi-Vector Watchdog & Breaker
- **Single Process Threshold**: Terminates rogue processes exceeding threshold (default: $80\%$ CPU).
- **Aggregate CPU Threshold**: Detects multi-process pool dilution attacks (default: $200\%$ total CPU).
- **D-State Storage Monitor**: Flags processes waiting on parallel filesystem metadata locks.
- Start background watchdog with:
  ```bash
  hpcguard start
  ```

### 3. Slurm Template Generator (Python & R)
Interactively generate customized `.slurm` batch scripts for **Python ML (GPU)** or **R / Bioinformatics (High-Memory CPU)**:
```bash
hpcguard template
```

---

## 🤖 AI Agent Integration (Claude Code / Codex / Cursor)

Add the following instructions to your project's `CLAUDE.md` or `AGENTS.md`:

```markdown
### HPC Cluster Execution Rules
- Always prepend long-running, training, Rscript, or scanning commands with `hpcguard exec "<cmd>"`.
- Never start multi-GPU, PyTorch training, or heavy R/Bioinformatics processes directly on login nodes.
- Use `hpcguard template` or standard Slurm batch scripts for GPU and CPU compute workloads.
```

---

## 🛠️ Usage Cheat Sheet

| Command | Description |
| :--- | :--- |
| `hpcguard` | Open interactive TUI management menu |
| `hpcguard exec "<command>"` | Intercept and guard a specific shell command |
| `hpcguard start` | Start background multi-vector watchdog daemon |
| `hpcguard stop` | Stop background watchdog daemon |
| `hpcguard status` | Check node status, watchdog state, and CPU limits |
| `hpcguard template` | Launch interactive Slurm script generator (Python/R) |
| `hpcguard install-alias` | Register `hpcguard` command alias into your shell rc |

---

## 📄 License
Released under the [MIT License](LICENSE).
