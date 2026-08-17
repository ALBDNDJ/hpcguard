# HPCGuard

> An account-scoped, user-space safety net for researchers using AI agents on shared HPC login nodes.

HPCGuard helps prevent *your own* commands and AI-agent workflows from accidentally burdening a shared login node when administrator-enforced guardrails are unavailable. It does not require root access, control other users, bypass scheduler policy, or replace Slurm/cgroups.

## Why it exists

Many clusters depend on training and user discipline rather than enforcing login-node CPU, memory, or I/O limits. That model becomes fragile when coding agents can inspect data, run scripts, retry failures, and chain commands autonomously. The account owner may be responsible for a misplaced training job or broad filesystem scan before they notice it.

HPCGuard was shaped by real user-side failure modes:

- a `python -c` traversal using `os.walk()` bypassed Bash aliases for `find` and `grep`;
- GPFS metadata scans stalled in Linux `D` state with low CPU, while login-node load climbed;
- multiprocessing workers stayed below single-PID CPU thresholds but saturated capacity together;
- naive watchdog matching of `bash -c '...'` caused false positives in harmless Slurm polling commands.

It therefore provides a preflight helper and a periodic, account-only watchdog. The watchdog examines running processes rather than trusting shell aliases alone.

## Scope and guarantees

HPCGuard is an opt-in heuristic guardrail. It can reduce common mistakes, but cannot guarantee that every workload or storage incident will be detected. Administrator-managed cgroups, scheduler policy, and documented login-node rules remain the only system-level controls.

By default it only records warnings. Automatic termination is an explicit per-user configuration choice.

## Install

Clone or download a tagged release, then run:

```bash
chmod +x hpc_guard.sh
./hpc_guard.sh init
./hpc_guard.sh doctor
./hpc_guard.sh watch --once --dry-run
```

Review `~/.config/hpcguard/config`. When its dry-run output matches your policy, set `ACTION=terminate` and install the one-minute cron watcher:

```bash
./hpc_guard.sh install-cron
```

No background daemon or PID file is used. Cron invokes one short-lived `watch --once` run at a time; a lock prevents overlap.

## Commands

| Command | Purpose |
| --- | --- |
| `hpcguard init` | Create an explicit, mode-`600` configuration file. |
| `hpcguard doctor` | Show host classification, configuration, and cron status. |
| `hpcguard check -- <command>` | Classify a command without executing it. |
| `hpcguard watch --once --dry-run` | Evaluate current account processes without signaling them. |
| `hpcguard watch --once` | Run the configured watchdog action. |
| `hpcguard install-cron` | Install the one-minute user crontab entry. |
| `hpcguard uninstall-cron` | Remove HPCGuard’s crontab entry. |

## Policy model

The watcher is active only when the short hostname matches `LOGIN_HOST_REGEX`; otherwise it exits without inspecting or signaling anything. It processes only `$USER`’s processes and excludes SSH, shells, and Slurm client commands.

It has separate signals for:

- sustained compute CPU, high RSS, and aggregate CPU across compute-like processes;
- direct recursive `find`, `rg`, and recursive `grep` executions;
- Python recursive traversal signatures such as `os.walk()` and `Path.rglob()`;
- broad shared paths, long-running scans, and scan processes in `D` state.

The default policy allows a bounded project scan longer than a broad home/GPFS scan. Thresholds are all visible and configurable in the generated config file. In termination mode, HPCGuard sends `TERM`, waits `GRACE_SECONDS`, then sends `KILL` only if the process survives.

## Design constraints

- It intentionally ignores shell parents such as `bash -c`; direct child executables carry the reliable identity. This prevents text such as `grep -q` inside an unrelated polling loop from being treated as recursive scanning.
- It logs the PID and PGID for auditability, but terminates the identified PID rather than blindly killing an interactive shell’s process group.
- It does not scan arbitrary filesystems itself. Its own work is limited to the installing user’s process table and proc working-directory links.
- It does not automatically reroute a command to Slurm. `check` supplies a decision point; users must choose appropriate `srun`/`sbatch` resources for their cluster.

## Testing

Run the local regression suite:

```bash
bash tests/test_hpcguard.sh
```

The regression suite covers real categories: shell-wrapper false positives, recursive search, Python `os.walk`, and scheduler polling. Additional policy paths are kept small and inspectable in the shell script.

## License

[MIT](LICENSE)
