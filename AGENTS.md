# AI Agent Operational Rules for HPC Clusters

When executing terminal commands in this repository or on this HPC cluster, autonomous agents (Claude Code, Codex, OpenHands, Cursor) MUST adhere to the following safety policies:

## 1. Login Node Awareness
- You are currently running in a shared user-space shell on an HPC login/head node.
- Compute-intensive jobs, multi-GPU scripts, deep learning model training, heavy R/Bioinformatics pipelines (Seurat, DESeq2), genomics alignment/variant calling tools (`bwa`, `samtools`, `gatk`), and root-level disk traversals are STRICTLY PROHIBITED on login nodes.

## 2. Command Interception
- For any command that involves Python ML training, R analysis pipelines (`Rscript`), genomics binaries (`bwa`, `samtools`, `gatk`, `deepvariant`), native package compilation, or deep file traversal, wrap the execution with `hpcguard exec`:
  ```bash
  hpcguard exec "<command>"
  ```
- If HPCGuard blocks the command with `[HPCGuard: BLOCKED ON LOGIN NODE]`, do NOT attempt to bypass or retry directly. Instead:
  1. Parse the suggested Slurm command (`srun` / `sbatch`).
  2. Write a standard `.slurm` batch submission script.
  3. Submit using `sbatch <job_script>.slurm`.

## 3. Slurm Array Best Practices
- When generating Slurm array jobs, NEVER launch unthrottled arrays. Always append a concurrency limit (e.g. `#SBATCH --array=1-100%10`).

## 4. Job Failure Diagnostics
- If a submitted Slurm job fails (e.g., FAILED, TIMEOUT, OUT_OF_MEMORY), do NOT guess the error or blindly retry. Run `hpcguard inspect <job_id>` to diagnose the exact exit code and error log tail.

## 5. Allowed Direct Operations
The following lightweight operations are safe to run directly on the login node:
- `git status`, `git diff`, `git log`
- `squeue -u $USER`, `sinfo`, `scancel`
- Light file edits, `cat`, `head`, `tail`, `grep` within specific local project directories
- Light verification scripts, e.g. `python -c "import torch; print(torch.__version__)"` or `R --version`
