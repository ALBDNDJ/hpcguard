# Contributing to HPCGuard

HPCGuard is deliberately small and policy-driven. Contributions that improve
correctness, explainability, compatibility, or regression coverage are welcome.

## Before opening an issue

Start the watcher in `warn` or `--dry-run` mode. Do not post real cluster
hostnames, usernames, IP addresses, home directories, job IDs, dataset paths,
or unredacted watchdog logs.

For a useful report, include only anonymized information:

- operating-system and shell version;
- scheduler family, if any;
- a generic login-host naming pattern;
- the command category and expected classification;
- observed classification or action; and
- whether it was a false positive, missed detection, or compatibility issue.

## Development workflow

1. Keep changes focused on one policy or portability concern.
2. Add or update a regression test for a changed classification rule.
3. Run the local checks:

   ```bash
   bash -n hpc_guard.sh tests/test_hpcguard.sh
   bash tests/test_hpcguard.sh
   ```

4. Explain the safety trade-off in the pull request. A rule that catches more
   commands but terminates valid work is not automatically an improvement.

## Policy principles

- Default to warnings; termination remains an explicit user choice.
- Never manage processes belonging to another account.
- Keep scheduler client commands and interactive shells out of termination
  rules.
- Prefer observable signals and small fixtures over speculative command lists.
- Treat storage traversal separately from CPU-heavy computation.
