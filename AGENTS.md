# AI Agent Operational Rules for HPC Clusters

When executing terminal commands in this repository or on this HPC cluster, autonomous agents (Claude Code, Codex, OpenHands, Cursor) MUST adhere to the following safety policies:

## 1. Login Node Awareness
- Treat a shared login/head node as a lightweight control plane, not a compute environment.
- Compute-intensive jobs, multi-GPU scripts, model training, and broad disk traversals are prohibited there.
- Do not assume the hostname alone is sufficient: check the configured cluster policy and scheduler allocation state before running a command.

## 2. Command Preflight
- For a potentially heavy command, use the non-executing preflight helper first:
  ```bash
  hpcguard check -- <command>
  ```
- A warning or block is a decision point, not an invitation to re-run the same work directly. Submit a suitable `srun`/`sbatch` job instead.
- Do not rely on preflight alone. The periodic `hpcguard watch --once` watchdog is the second-line, account-scoped safeguard.

## 3. Allowed Direct Operations
The following lightweight operations are safe to run directly on the login node:
- `git status`, `git diff`, `git log`
- `squeue -u $USER`, `sinfo`, `scancel`
- Light file edits, `cat`, `head`, `tail`, `grep` within specific local project directories
- Light verification scripts, e.g. `python -c "import torch; print(torch.__version__)"`
