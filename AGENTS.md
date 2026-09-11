# AI Agent Operational Rules for HPC Clusters

When executing terminal commands in this repository or on this HPC cluster, autonomous agents (Claude Code, Codex, OpenHands, Cursor) MUST adhere to the following safety policies:

## 1. Login Node Awareness
- You are currently running in a shared user-space shell on an HPC login/head node.
- Compute-intensive jobs, multi-GPU scripts, deep learning model training, heavy R/Bioinformatics pipelines (Seurat, DESeq2), genomics alignment/variant calling tools (`bwa`, `samtools`, `gatk`), and root-level disk traversals are STRICTLY PROHIBITED on login nodes.

## 2. Command Interception
- Before executing a command on the cluster, request a machine-readable decision:
  ```bash
  hpcguard check --json -- <command> [args...]
  ```
  Treat both `block` and `unclassified` as stop decisions.
- Execute an approved command through HPCGuard rather than executing the original command separately. Prefer the argv-preserving form:
  ```bash
  hpcguard run -- <command> [args...]
  ```
  Use the shell-string form only when compound shell syntax is required:
  ```bash
  hpcguard exec "<command>"
  ```
- For integrations that need a decision without execution, use `hpcguard check --json -- <command> [args...]`.
- Exit status `102` means the local `sbatch` rate limit was reached; `103` means an identical command recently failed; `104` means the host is unclassified. Stop and diagnose instead of bypassing any of these decisions.
- If HPCGuard blocks the command with `[HPCGuard: BLOCKED ON LOGIN NODE]`, do NOT attempt to bypass or retry directly. Instead:
  1. Parse the suggested Slurm command (`srun` / `sbatch`).
  2. Write a standard `.slurm` batch submission script.
  3. Submit using `sbatch <job_script>.slurm`.

## 3. Slurm Array Best Practices
- When generating Slurm array jobs, NEVER launch unthrottled arrays. Always append a concurrency limit (e.g. `#SBATCH --array=1-100%10`).

## 4. Job Failure Diagnostics
- If a submitted Slurm job fails (e.g., FAILED, TIMEOUT, OUT_OF_MEMORY), do NOT guess the error or blindly retry. Run `hpcguard inspect <job_id>` to diagnose the exact exit code and error log tail.
- Do not use `--force-retry` unless a human or agent has reviewed the previous failure and identified why a retry is justified.

## 5. Allowed Direct Operations
The following lightweight operations are safe to run directly on the login node:
- `git status`, `git diff`, `git log`
- `squeue -u $USER`, `sinfo`, `scancel`
- Light file edits, `cat`, `head`, `tail`, `grep` within specific local project directories
- Light verification scripts, e.g. `python -c "import torch; print(torch.__version__)"` or `R --version`

## 6. SSH Liveness Checks
- Never create a short-interval loop around `nc -z`, `/dev/tcp`, or a fresh `ssh` connection. Repeated pre-authentication resets may trigger institutional IDS alerts.
- To check connectivity, reuse a manually established OpenSSH ControlMaster with `hpcguard probe <ssh-config-host>`. If no live control socket exists, stop and leave authentication to the user.

HPCGuard is a cooperative user-space guard: commands that bypass these wrappers are outside its pre-execution enforcement boundary. Instruction files guide an agent but are not a host-level hook. Automatic enforcement requires the agent host to use `hpcguard run` as its shell executor. It does not replace scheduler, cgroup, network, or administrator controls.
