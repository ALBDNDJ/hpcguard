# Changelog

All notable changes to HPCGuard are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and tagged releases
use semantic versioning where practical.

## [Unreleased]

### Documentation

- Added an evidence-bounded validation matrix and architecture diagram.
- Added a formal threat model describing trust boundaries and residual risks.

## [1.6.0] - 2026-09-11

### Added

- Detection for common Python process pools, multiprocessing fan-out,
  high-concurrency launchers, and tight Slurm submission loops.
- Warning-only single-process and aggregate RSS monitoring plus account process
  count monitoring.
- Local retry backoff for identical failed commands and a rolling rate limit for
  wrapped `sbatch` attempts.
- Stable machine-oriented exit statuses for policy blocks, submission limits,
  retry backoff, and unclassified hosts.

### Changed

- Unknown hosts now fail closed for `check`, `run`, and `exec` integrations.
- Agent guidance now documents the cooperative `check` / `run` integration
  contract and its enforcement boundary.
- Regression coverage increased to 73 assertions.

### Security

- Failure state stores command fingerprints and timestamps rather than raw
  command arguments.

## [1.5.0] - 2026-09-11

### Added

- Machine-readable `hpcguard check --json -- ...` decisions.
- Argument-preserving `hpcguard run -- ...` execution.
- Adversarial configuration, process identity, input validation, and
  non-destructive file handling tests.

### Changed

- Configuration is parsed through an allowlist instead of being executed as
  shell code.
- Automatic process termination is opt-in, verifies process identity, and uses
  `TERM` before `KILL`.
- Existing VSCode settings are preserved; HPCGuard writes a reviewable proposal.

### Security

- Configuration and watchdog state use restrictive permissions.
- Slurm identifiers and resource values are validated.
- Job-log output is sanitized before terminal display.

## [1.4.1] - 2026-09-07

### Fixed

- Resolved ShellCheck findings in the safe SSH probing release.

## [1.4.0] - 2026-09-07

### Added

- Detection for tight `nc`, `/dev/tcp`, and fresh-SSH liveness loops.
- `hpcguard probe`, which checks only an existing OpenSSH ControlMaster socket
  and never falls back to a new TCP connection or authentication attempt.
- Issue forms and contribution guidance for anonymized safety reports.

## [0.2.0] - 2026-08-18

### Added

- Initial account-scoped command guard, resource watchdog, Slurm helper, tests,
  CI workflow, documentation, and MIT license.

[Unreleased]: https://github.com/ALBDNDJ/hpcguard/compare/v1.6.0...HEAD
[1.6.0]: https://github.com/ALBDNDJ/hpcguard/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/ALBDNDJ/hpcguard/compare/v1.4.1...v1.5.0
[1.4.1]: https://github.com/ALBDNDJ/hpcguard/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/ALBDNDJ/hpcguard/compare/v0.2.0...v1.4.0
[0.2.0]: https://github.com/ALBDNDJ/hpcguard/tree/v0.2.0
