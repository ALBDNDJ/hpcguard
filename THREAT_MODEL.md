# HPCGuard Threat Model

## Purpose

HPCGuard reduces accidental shared-cluster harm caused by researchers and
autonomous coding agents operating without administrator privileges. It is a
cooperative, account-scoped guardrail. It is not a security boundary against a
malicious user who controls the same account.

## Assets and unwanted outcomes

HPCGuard is designed to reduce risk to:

- login-node CPU and memory availability;
- scheduler responsiveness and fair-use behavior;
- shared-filesystem metadata capacity;
- institutional network monitoring and SSH service logs;
- the user's account standing, jobs, and local configuration; and
- other researchers sharing the same cluster services.

The principal unwanted outcomes are accidental training or high-concurrency
work on a login node, recursive shared-filesystem traversal, process fan-out,
blind command retries, submission storms, unsafe process termination, and
high-frequency SSH/TCP probes.

## Actors

### In scope

- A well-intentioned researcher who makes a command-line mistake.
- An AI coding agent that generates or retries an unsafe command.
- A buggy scientific script that unexpectedly fans out or consumes resources.
- Malformed local configuration or command arguments that must not become code
  execution inside HPCGuard.

### Out of scope

- A malicious or determined user who intentionally bypasses the wrapper.
- Isolation between Unix accounts or containment of privileged processes.
- A compromised operating system, scheduler, SSH client, or administrator
  account.
- Enforcement of site policy on commands executed outside HPCGuard.
- Protection against every workload whose resource use is invisible until after
  execution.

## Trust boundaries

1. **Agent or shell to HPCGuard.** Static and stateful protections apply only
   when execution is routed through `hpcguard run` or `hpcguard exec`.
   `hpcguard check` reports a decision but does not execute or reserve state.
2. **HPCGuard to the operating system.** Process data from `ps`, host identity,
   and environment variables are observations, not administrator-attested facts.
3. **HPCGuard to Slurm and SSH.** Scheduler accounting, job logs, SSH
   configuration, and ControlMaster state are external inputs and may be stale or
   unavailable.
4. **Current account to other accounts.** HPCGuard must observe and optionally
   terminate only processes owned by the current user. It provides no
   cross-account authority.
5. **User configuration and runtime state.** Files under `~/.hpcguard` are
   trusted only after ownership, file type, allowlisted keys, and permissions are
   checked. A user who can modify these files can change or reset local policy.

## Security properties and controls

| Property | Control |
| :--- | :--- |
| Unknown placement must not be assumed safe | Unrecognized hosts fail closed as `unclassified` |
| Command arguments must retain their boundaries | `hpcguard run -- ...` executes an argument vector without shell re-parsing |
| Compound shell commands require an explicit boundary | Legacy `exec` is documented as a shell-string interface |
| Configuration must not execute code | Strict key allowlist, type validation, owner checks, and no `source`/`eval` |
| Automatic termination must not target unrelated processes | Opt-in mode plus current UID, PID, command name, and start-time verification |
| Shell and scheduler control processes must remain available | Protected-process allowlist and `TERM` before `KILL` |
| Failed commands must not create immediate retry loops | Fingerprint-based local retry backoff |
| Wrapped submissions must not become a storm | Rolling local `sbatch` attempt limit |
| SSH health checks must not create authentication traffic | ControlMaster socket check with no network or authentication fallback |
| Runtime state should not expose command contents | Failure state contains fingerprints, timestamps, and status only |
| Existing workspace configuration must not be destroyed | VSCode settings changes are written as a reviewable proposal |

## Known failure modes and residual risks

- **Wrapper bypass:** an agent or user can invoke a command directly. HPCGuard
  cannot intercept that execution without support from the host application or
  administrator-level controls.
- **False negatives:** pattern-based classification cannot recognize every
  program, inline payload, renamed binary, or workload whose cost depends on
  input data.
- **False positives:** a matched command may be safe in a small, bounded context.
  Rules should therefore have regression fixtures and narrow observable
  boundaries.
- **Sampling gaps:** the watchdog may miss processes that start and finish
  between polling intervals.
- **Advisory memory/process limits:** RSS and process-count thresholds warn but
  do not terminate work automatically.
- **Local-state reset:** deleting state files resets retry and submission
  history. The controls prevent accidents; they are not tamper-resistant.
- **Host classification drift:** local naming conventions may change. Unknown
  hosts fail closed until `LOGIN_HOST_REGEX` is configured.
- **Scheduler scope:** only Slurm behavior has been exercised by the maintainer.
  PBS, LSF, and other schedulers are outside current compatibility claims.
- **Shared-filesystem variation:** path and D-state signals do not prove a GPFS,
  Lustre, or NFS fault and must not be used for incident attribution without
  supporting system evidence.
- **Race conditions:** identity checks reduce PID-reuse risk but cannot provide
  kernel-enforced atomicity.

## Privacy

Reports and fixtures must remove real hostnames, IP addresses, usernames, home
directories, job IDs, dataset paths, credentials, and unredacted logs. Runtime
state is stored locally under the user's private HPCGuard directory. HPCGuard
does not include telemetry or upload usage data.

## Relationship to administrator controls

HPCGuard complements but does not replace cgroups, scheduler submission limits,
login-node policy, filesystem quotas, network controls, auditing, or incident
response. Administrator-enforced controls remain the authoritative boundary on a
shared cluster.

## Review expectations

Changes to command classification, process termination, configuration parsing,
state handling, scheduler interaction, or SSH behavior should include a focused
regression test and an explanation of false-positive and false-negative impact.
Security vulnerabilities should be reported through the process in
[SECURITY.md](SECURITY.md).
