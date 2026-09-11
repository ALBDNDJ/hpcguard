## Summary

Describe the policy, portability, documentation, or test change.

## Safety impact

- What observable behavior changes?
- Could the change block legitimate work or allow a risky workload?
- Does it affect only the current account?

## Verification

- [ ] `bash -n hpc_guard.sh tests/test_hpcguard.sh`
- [ ] `bash tests/test_hpcguard.sh`
- [ ] A regression test covers every changed classification rule.
- [ ] The change fails safely when required scheduler or SSH state is unavailable.

## Privacy

- [ ] Examples and fixtures contain no real usernames, hostnames, IP addresses, home directories, job IDs, dataset paths, credentials, or unredacted logs.
