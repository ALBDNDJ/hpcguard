# AI Agent Operational Rules for HPC Clusters

When executing terminal commands in this repository or on this HPC cluster, autonomous agents (Claude Code, Codex, OpenHands, Cursor) MUST adhere to the following safety policies:

## 1. Login Node Awareness
- You are currently running in a shared user-space shell on an HPC login/head node.
- Compute-intensive jobs, multi-GPU scripts, deep learning model training, heavy R/Bioinformatics pipelines (Seurat, DESeq2), and root-level disk traversals are STRICTLY PROHIBITED on login nodes.

## 2. Command Interception
- For any command that involves Python ML training, R analysis pipelines (`Rscript`), native package compilation, or deep file traversal, wrap the execution with `hpcguard exec`:
  ```bash
  hpcguard exec "<command>"
  ```
- If HPCGuard blocks the command with `[HPCGuard: BLOCKED ON LOGIN NODE]`, do NOT attempt to bypass or retry directly. Instead:
  1. Parse the suggested Slurm command (`srun` / `sbatch`).
  2. Write a standard `.slurm` batch submission script.
  3. Submit using `sbatch <job_script>.slurm`.

## 3. Allowed Direct Operations
The following lightweight operations are safe to run directly on the login node:
- `git status`, `git diff`, `git log`
- `squeue -u $USER`, `sinfo`, `scancel`
- Light file edits, `cat`, `head`, `tail`, `grep` within specific local project directories
- Light verification scripts, e.g. `python -c "import torch; print(torch.__version__)"` or `R --version`
