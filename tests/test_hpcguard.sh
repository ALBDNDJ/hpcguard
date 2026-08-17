#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../hpc_guard.sh
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

assert_eq ignore "$(classify_command bash 'bash -c while squeue -h -j 42 | grep -q 42; do sleep 45; done' "$HOME")" 'shell polling text is ignored'
assert_eq ignore "$(classify_command squeue '-h -j 42' "$HOME")" 'scheduler client is ignored'
assert_eq scan-local "$(classify_command find 'find /project/src -type f' /project)" 'project find is local scan'
assert_eq scan-broad "$(classify_command find "find $HOME -type f" "$HOME")" 'home-root find is broad scan'
assert_eq scan-broad "$(classify_command rg 'rg pattern .' "$HOME")" 'home cwd dot scan is broad'
assert_eq compute "$(classify_command python 'python train.py' /project)" 'python training is compute-like'
assert_eq python-walk-broad "$(classify_command python "python -c import os; list(os.walk('$HOME'))" "$HOME")" 'python os.walk is recognized'
assert_eq python-walk-local "$(classify_command python "python -c from pathlib import Path; list(Path('src').rglob('*.py'))" /project)" 'project Path.rglob is recognized'
assert_eq ignore "$(classify_command grep 'grep -q READY job.log' "$HOME")" 'nonrecursive grep is ignored'
assert_eq scan-local "$(classify_command grep 'grep -R TODO src' /project)" 'recursive grep is scan'

test_state=$(mktemp -d)
trap 'rm -rf "$test_state"' EXIT
is_login_node() { return 0; }
watch_output=$(HOME="$test_state/home" XDG_STATE_HOME="$test_state/state" HPCGUARD_SNAPSHOT_FILE="$ROOT/tests/fixtures/processes.txt" watch_once --dry-run)
assert_eq 2 "$(printf '%s\n' "$watch_output" | awk '/^WARN/{n++} END{print n+0}')" 'watcher detects D-state scans and high CPU from a snapshot'

if [ "$fail" -ne 0 ]; then
    printf '%s failed, %s passed\n' "$fail" "$pass" >&2
    exit 1
fi
printf '%s passed\n' "$pass"
