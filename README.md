# HPCGuard 🛡️

> A zero-root, user-space safety governance layer for AI coding agents (Claude Code, Codex CLI, Cursor, OpenHands) and researchers on shared HPC clusters.
> Supporting Python ML/DL, R/Bioinformatics, Genomics Pipelines, VSCode Remote, Slurm Arrays, and safe SSH liveness checks.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/ALBDNDJ/hpcguard/actions/workflows/ci.yml/badge.svg)](https://github.com/ALBDNDJ/hpcguard/actions/workflows/ci.yml)
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

`HPCGuard` acts as an account-scoped safety runtime when commands are routed through it:
1. **Pre-execution Interception (`hpcguard exec` / `hpcguard run`)**: Inspects wrapped commands before execution. Blocks matched workloads on login nodes and suggests a compliant scheduler alternative.
2. **Job Failure Inspector & Diagnostics (`hpcguard inspect <id>`)**: Automatically inspects Slurm accounting states, exit codes, and tails job logs to identify reasons for failure (OOM, timeouts, syntax errors).
3. **Multi-Vector Watchdog**: Observes single-process CPU, aggregate multi-process load, and storage D-state signals. Automatic termination is opt-in and verifies process identity before acting.
4. **Slurm Job Assistant (with Array Rate Limiting)**: Interactively generates production-ready Slurm batch scripts for **Python ML**, **R / Bioinformatics**, and **Genomics Pipelines** with automatic `%` concurrency rate-limiting.
5. **IDE Workspace Anti-Stall Helper (`hpcguard init-vscode`)**: Automatically configures safe `.vscode/settings.json` to eliminate recursive file watchers and background language server metadata storms.
6. **ControlMaster-only SSH Probe (`hpcguard probe`)**: Checks an already-running multiplexed SSH connection through its local Unix socket, with no TCP or authentication fallback.

### Security boundaries

HPCGuard is a user-space, cooperative guard. It can only inspect commands that an agent or shell routes through `hpcguard exec`, `hpcguard check`, or `hpcguard run`; it cannot intercept arbitrary unwrapped processes without administrator or kernel support. Unknown hostnames are reported as **unclassified** rather than silently treated as compute nodes. HPCGuard does not replace cgroups, Slurm policy, network controls, or administrator configuration.

---

## ⚡ Quick Start (1-Line Installation)

No root permissions or administrator cooperation required. Simply run on your cluster login node:

```bash
wget -O hpc_guard.sh https://raw.githubusercontent.com/ALBDNDJ/hpcguard/v1.5.0/hpc_guard.sh && chmod +x hpc_guard.sh && ./hpc_guard.sh
```

### Enable Global Shortcut
Run option `[9]` in the menu or execute:
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

### 8. The SSH Liveness Probe and IDS Alert Trap

* **The Failure**: A lab-side automation repeatedly opened and immediately closed a TCP connection to an SSH service on a short interval. The server accumulated a large volume of `Connection reset ... [preauth]` records, and network monitoring classified the pattern as possible probing or brute-force activity.
* **HPCGuard Solution**: `hpcguard exec` rejects tight loops built around `nc -z`, `/dev/tcp`, or fresh `ssh` connections. `hpcguard probe <host>` checks only an existing OpenSSH ControlMaster Unix socket and fails closed when that socket is absent—without opening a new TCP connection.

`[preauth]` means that authentication had not completed; by itself it does not prove whether a username or authentication method had already been offered. Incident attribution should use the full server and network evidence, not this suffix alone.

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
Suggested action:
  Submit the workload through the site scheduler with an explicit CPU and memory request.

💡 Hint: To generate a batch script, run: hpcguard template
```

For integrations that already have an argument vector, prefer the boundary-preserving form:

```bash
hpcguard check -- torchrun --nproc_per_node=4 train_model.py
hpcguard check --json -- python analysis.py --input "sample with spaces"
hpcguard run -- python analysis.py --input "sample with spaces"
```

`check` returns a machine-readable decision without executing the command.
The legacy `exec "..."` form remains available for compound shell syntax, but it necessarily interprets a shell command string.

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
Generate reviewable `.vscode` settings to stop background file watchers from scanning large datasets. Existing settings are preserved by default:
```bash
hpcguard init-vscode
```

### 5. Safe SSH Liveness Check (`hpcguard probe`)

Configure OpenSSH multiplexing for your host, establish the connection manually, then check the existing local control socket:

```sshconfig
Host cluster
    HostName cluster.example.edu
    ControlMaster auto
    ControlPath ~/.ssh/control-%C
    ControlPersist 10m
```

```bash
hpcguard probe cluster
```

This command never creates a new SSH session. If the ControlMaster socket is missing or stale, it reports that state and stops. It does not fall back to TCP probing or authentication.

---

## 🤖 AI Agent Integration (Claude Code / Codex / Cursor)

Add the following instructions to your project's `CLAUDE.md` or `AGENTS.md`:

```markdown
### HPC Cluster Execution Rules
- Route long-running, training, Rscript, or scanning commands through `hpcguard run -- ...` when an argument vector is available; use `hpcguard exec "<cmd>"` only when compound shell syntax is required.
- Never start multi-GPU, PyTorch training, or heavy R/Bioinformatics/Genomics processes directly on login nodes.
- When opening large dataset workspaces, run `hpcguard init-vscode` to prevent language server indexing storms.
- When submitting array jobs, always include concurrency limits (e.g., `--array=1-100%10`).
- If a Slurm job fails, diagnose the cause using `hpcguard inspect <job_id>`.
- Never use a short-interval `nc -z`, `/dev/tcp`, or fresh-SSH loop for liveness monitoring; use `hpcguard probe <host>` only with an existing ControlMaster.
```

---

## 🛠️ Usage Cheat Sheet

| Command | Description |
| :--- | :--- |
| `hpcguard` | Open interactive TUI management menu |
| `hpcguard check -- <command> [args...]` | Return a JSON policy decision without executing |
| `hpcguard run -- <command> [args...]` | Check and execute while preserving argument boundaries |
| `hpcguard exec "<command>"` | Intercept and guard a specific shell command |
| `hpcguard inspect <job_id>` | Inspect Slurm job accounting, exit code, and log tail |
| `hpcguard probe <ssh-host>` | Check an existing ControlMaster socket without a network fallback |
| `hpcguard init-vscode` | Generate anti-stall `.vscode/settings.json` for current project |
| `hpcguard start` | Start background multi-vector watchdog daemon |
| `hpcguard stop` | Stop background watchdog daemon |
| `hpcguard status` | Check node status, watchdog state, and CPU limits |
| `hpcguard template` | Launch interactive Slurm script generator (Python/R/Genomics/Array) |
| `hpcguard install-alias` | Register `hpcguard` command alias into your shell rc |

---

## 📄 License
Released under the [MIT License](LICENSE).
