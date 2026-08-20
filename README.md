# HPCGuard 🛡️

> A zero-root, user-space safety governance layer for AI coding agents (Claude Code, Codex CLI, Cursor, OpenHands) and researchers on shared HPC clusters.
> Supporting Python ML/DL, R/Bioinformatics, Genomics Pipelines, VSCode Remote & Slurm Array Orchestration.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Slurm Ready](https://img.shields.io/badge/Scheduler-Slurm-orange.svg)](#)
[![Python, R, Genomics](https://img.shields.io/badge/Workloads-Python%20%7C%20R%20%7C%20Genomics-brightgreen.svg)](#)
[![Zero Root Required](https://img.shields.io/badge/Root-Not_Required-green.svg)](#)

---

## 💡 Why HPCGuard?

Shared HPC cluster login nodes are strictly provisioned for lightweight interactive tasks: code editing, light compilation, environment checks, and job submission.

However, autonomous AI coding agents and automated scientific workflows frequently trigger severe cluster incidents:
- Running multi-GPU training (`torchrun`, `accelerate`) or heavy Python scripts directly on login nodes.
- Spawning in-memory R / Bioinformatics pipelines (`Rscript`, `Seurat`, `DESeq2`) that implicitly saturate 32+ CPU cores and tens of gigabytes of RAM.
- Launching heavy genomics alignment / variant calling CLI commands (`bwa`, `samtools sort/index`, `gatk`, `deepvariant`).
- Triggering unthrottled Slurm Array storms (`--array=1-1000`) without concurrency caps, monopolizing entire partitions.
- Unregulated VSCode Remote & Language Server indexing (`node`, `pylance`, `rsession`) traversing millions of files across network storage, crashing GPFS/Lustre metadata servers.

**This results in cluster login node freezes, account suspensions, and complaints from peers.**

`HPCGuard` acts as an autonomous safety runtime:
1. **Pre-execution Interception (`hpcguard exec`)**: Inspects shell commands before execution. Blocks dangerous workloads on login nodes and rewrites them into compliant `srun` / `sbatch` commands.
2. **Job Failure Inspector & Diagnostics (`hpcguard inspect <id>`)**: Automatically inspects Slurm accounting states, exit codes, and tails job logs to identify reasons for failure (OOM, timeouts, syntax errors).
3. **Multi-Vector Watchdog & Breaker**: Silently monitors single-process CPU, aggregate multi-process dilution, and storage D-state I/O locks.
4. **Slurm Job Assistant (with Array Rate Limiting)**: Interactively generates production-ready Slurm batch scripts for **Python ML**, **R / Bioinformatics**, and **Genomics Pipelines** with automatic `%` concurrency rate-limiting.
5. **IDE Workspace Anti-Stall Helper (`hpcguard init-vscode`)**: Automatically configures safe `.vscode/settings.json` to eliminate recursive file watchers and background language server metadata storms.

---

## ⚡ Quick Start (1-Line Installation)

No root permissions or administrator cooperation required. Simply run on your cluster login node:

```bash
wget -O hpc_guard.sh https://raw.githubusercontent.com/playfulsoul/hpcguard/main/hpc_guard.sh && chmod +x hpc_guard.sh && ./hpc_guard.sh
```

### Enable Global Shortcut
Run option `[8]` in the menu or execute:
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

### 3. The VSCode Remote & IDE Language Server Metadata Avalanche
* **The Failure**: VSCode Remote and Language Servers (Pylance, R Language Server) automatically scan every workspace subdirectory to construct autocomplete symbol tables. When datasets containing $100,000+$ files (e.g., `.mat`, `.pt`, `.h5`) exist in the project, the background Node.js process initiates millions of `stat()` syscalls, crashing GPFS metadata and causing CPU overload ($130\%+$).
* **HPCGuard Solution**: One-click generation of safe workspace settings (`hpcguard init-vscode`) that disables symlink loops, excludes raw datasets from file watchers, and caps indexing depths.

### 4. The R Language & In-Memory Bioinformatics Trap
* **The Failure**: R workloads (such as single-cell RNA-seq clustering via `Seurat` or package installation via `install.packages()`) default to in-memory loading and implicit multi-threading (BLAS/OpenMP), stealthily spawning 32+ threads and consuming dozens of gigabytes of RAM on login nodes.
* **HPCGuard Solution**: Explicit interception of `Rscript`, `R CMD INSTALL`, and common bioinformatics frameworks, auto-redirecting them to high-memory CPU compute nodes.

### 5. Genomics Heavy CLI Workload Leaks
* **The Failure**: Tools such as `bwa mem`, `samtools sort`, and `gatk` are often invoked in quick command snippets by researchers or agents on login nodes, instantly spawning 16~32 native C threads.
* **HPCGuard Solution**: Direct pattern matching and interception for standard genomics CLI binaries.

### 6. Unthrottled Array Storms & Partition Monopolization
* **The Failure**: Submitting large array jobs (`--array=1-500`) without a concurrency cap floods the Slurm controller with simultaneous allocations, starving all other lab members.
* **HPCGuard Solution**: Automatic enforcement/recommendation of `%max_concurrent` limits (e.g., `--array=1-100%10`) during template generation.

### 7. Preventing "Exit Code 137" Retry Loops
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

# Genomics Pipeline Guard:
hpcguard exec "bwa mem -t 16 ref.fa read1.fq read2.fq"
```

**Output:**
```text
======================================================
 [HPCGuard: BLOCKED ON LOGIN NODE]
======================================================
Host:     login01
Command:  bwa mem -t 16 ref.fa read1.fq read2.fq
Reason:   Heavy genomics alignment / variant calling pipeline detected on login node.
Suggested Execution:
  srun --partition=cpu --cpus-per-task=8 --mem=32G bwa mem -t 16 ref.fa read1.fq read2.fq (or submit via 'sbatch genomics_job.slurm')

💡 Hint: To generate a batch script, run: hpcguard template
```

### 2. Slurm Job Diagnostics (`hpcguard inspect <id>`)
Inspect why a batch job failed or check running status:
```bash
hpcguard inspect 44959288
```

### 3. Slurm Template Generator (with Array Rate Limiting)
Interactively generate customized `.slurm` batch scripts for **Python ML (GPU)**, **R / Bioinformatics (CPU)**, or **Genomics (CPU)** with rate-limited array options:
```bash
hpcguard template
```

### 4. VSCode Remote Anti-Stall Setup (`hpcguard init-vscode`)
Instantly inject optimized `.vscode/settings.json` into your current directory to stop background file watchers from scanning large datasets:
```bash
hpcguard init-vscode
```

---

## 🤖 AI Agent Integration (Claude Code / Codex / Cursor)

Add the following instructions to your project's `CLAUDE.md` or `AGENTS.md`:

```markdown
### HPC Cluster Execution Rules
- Always prepend long-running, training, Rscript, or scanning commands with `hpcguard exec "<cmd>"`.
- Never start multi-GPU, PyTorch training, or heavy R/Bioinformatics/Genomics processes directly on login nodes.
- When opening large dataset workspaces, run `hpcguard init-vscode` to prevent language server indexing storms.
- When submitting array jobs, always include concurrency limits (e.g., `--array=1-100%10`).
- If a Slurm job fails, diagnose the cause using `hpcguard inspect <job_id>`.
```

---

## 🛠️ Usage Cheat Sheet

| Command | Description |
| :--- | :--- |
| `hpcguard` | Open interactive TUI management menu |
| `hpcguard exec "<command>"` | Intercept and guard a specific shell command |
| `hpcguard inspect <job_id>` | Inspect Slurm job accounting, exit code, and log tail |
| `hpcguard init-vscode` | Generate anti-stall `.vscode/settings.json` for current project |
| `hpcguard start` | Start background multi-vector watchdog daemon |
| `hpcguard stop` | Stop background watchdog daemon |
| `hpcguard status` | Check node status, watchdog state, and CPU limits |
| `hpcguard template` | Launch interactive Slurm script generator (Python/R/Genomics/Array) |
| `hpcguard install-alias` | Register `hpcguard` command alias into your shell rc |

---

## 📄 License
Released under the [MIT License](LICENSE).
