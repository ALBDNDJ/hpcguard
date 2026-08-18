# Security policy

## Scope

HPCGuard is a user-space safety guard. It does not provide isolation between
accounts and must not be relied on as a replacement for administrator-managed
cgroups, scheduler limits, or access controls.

The current supported version is the latest tagged release.

## Reporting a vulnerability

Do **not** publish real cluster details in a public issue. In particular, do
not include hostnames, IP addresses, account names, home directories, job IDs,
dataset paths, credentials, or complete process/log output.

Use GitHub's private vulnerability-reporting feature from the repository's
**Security** tab when it is enabled. If private reporting is unavailable, open
a minimal public issue requesting a private contact channel; include no
operational details in that issue.

Reports are most useful when they describe the affected release, operating
system, minimal anonymized reproduction, expected behavior, observed behavior,
and possible impact.
