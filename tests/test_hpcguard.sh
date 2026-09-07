#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck disable=SC1091
source "$ROOT/hpc_guard.sh"

pass=0
fail=0

assert_eq() {
    local expected=$1 actual=$2 name=$3
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
        printf 'ok - %s\n' "$name"
    else
        fail=$((fail + 1))
        printf 'not ok - %s (expected %s, got %s)\n' "$name" "$expected" "$actual" >&2
    fi
}

assert_status() {
    local expected=$1 name=$2
    shift 2
    local actual=0
    "$@" || actual=$?
    assert_eq "$expected" "$actual" "$name"
}

is_login_host() {
    HPCGUARD_HOSTNAME_OVERRIDE=$1 is_login_node
}

is_login_host_in_allocation() {
    HPCGUARD_HOSTNAME_OVERRIDE=$1 SLURM_JOB_ID=123 is_login_node
}

assert_status 0 '20-second nc loop is high-frequency' \
    is_high_frequency_ssh_probe 'while true; do nc -z cluster.example.edu 22; sleep 20; done'
assert_status 0 'watch-based nc loop is high-frequency' \
    is_high_frequency_ssh_probe 'watch -n 15 nc -z cluster.example.edu 22'
assert_status 0 'absolute-path nc loop is high-frequency' \
    is_high_frequency_ssh_probe 'while /usr/bin/nc -z cluster.example.edu 22; do sleep 20; done'
assert_status 0 'tight fresh-SSH loop is high-frequency' \
    is_high_frequency_ssh_probe 'until ssh cluster true; do sleep 10; done'
assert_status 1 'one-shot nc probe is not classified as a loop' \
    is_high_frequency_ssh_probe 'nc -z cluster.example.edu 22'
assert_status 1 'five-minute probe interval is not blocked' \
    is_high_frequency_ssh_probe 'while true; do nc -z cluster.example.edu 22; sleep 300; done'
assert_status 1 'ControlMaster check loop is not a fresh SSH probe' \
    is_high_frequency_ssh_probe 'while ssh -O check cluster; do sleep 20; done'

assert_status 0 'login-style hostname is guarded' \
    is_login_host research-login07
assert_status 1 'ordinary numbered workstation is not a login node' \
    is_login_host workstation42
assert_status 1 'scheduler allocation disables login-node guard' \
    is_login_host_in_allocation research-login07

guard_output=''
guard_status=0
guard_output=$(HPCGUARD_HOSTNAME_OVERRIDE=research-login07 cmd_exec_guard 'while true; do nc -z cluster.example.edu 22; sleep 20; done') || guard_status=$?
assert_eq 101 "$guard_status" 'exec guard blocks a tight TCP liveness loop'
assert_eq 1 "$(printf '%s\n' "$guard_output" | awk '/BLOCKED ON LOGIN NODE/{n++} END{print n+0}')" 'blocked probe has a structured explanation'

probe_output=''
probe_status=0
probe_output=$(HPCGUARD_SSH_BIN="$ROOT/tests/fixtures/fake_ssh_no_socket.sh" probe_existing_master cluster) || probe_status=$?
assert_eq 3 "$probe_status" 'probe fails closed without a control socket'
assert_eq 1 "$(printf '%s\n' "$probe_output" | awk '/No network connection was attempted/{n++} END{print n+0}')" 'probe explains that no network connection was made'

if [ "$fail" -ne 0 ]; then
    printf '%s failed, %s passed\n' "$fail" "$pass" >&2
    exit 1
fi
printf '%s passed\n' "$pass"
