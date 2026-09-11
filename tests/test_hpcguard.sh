#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
export HPCGUARD_CONFIG_DIR="$TEST_TMP/config"
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

assert_contains() {
    local haystack=$1 needle=$2 name=$3
    if [[ "$haystack" == *"$needle"* ]]; then
        pass=$((pass + 1))
        printf 'ok - %s\n' "$name"
    else
        fail=$((fail + 1))
        printf 'not ok - %s (missing %s)\n' "$name" "$needle" >&2
    fi
}

is_login_host() {
    HPCGUARD_HOSTNAME_OVERRIDE=$1 is_login_node
}

is_login_host_in_allocation() {
    HPCGUARD_HOSTNAME_OVERRIDE=$1 SLURM_JOB_ID=123 is_login_node
}

classify_on_login() {
    HPCGUARD_HOSTNAME_OVERRIDE=research-login07 classify_command "$1"
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
assert_status 0 'loop without a delay is high-frequency' \
    is_high_frequency_ssh_probe 'while true; do nc -z cluster.example.edu 22; done'
assert_status 1 'non-network loop is not a probe' \
    is_high_frequency_ssh_probe 'while true; do printf ok; sleep 1; done'

assert_status 0 'login-style hostname is guarded' \
    is_login_host research-login07
assert_status 1 'ordinary numbered workstation is not a login node' \
    is_login_host workstation42
assert_status 1 'scheduler allocation disables login-node guard' \
    is_login_host_in_allocation research-login07
assert_eq login "$(HPCGUARD_HOSTNAME_OVERRIDE=research-login07 node_class)" 'node class identifies configured login host'
assert_eq unknown "$(HPCGUARD_HOSTNAME_OVERRIDE=workstation42 node_class)" 'node class preserves unknown state'
assert_eq allocation "$(HPCGUARD_HOSTNAME_OVERRIDE=research-login07 SLURM_JOB_ID=123 node_class)" 'node class identifies scheduler allocation'

assert_status 0 'absolute-path distributed launcher is blocked' \
    classify_on_login '/opt/tools/bin/torchrun --nproc_per_node=4 train.py'
assert_status 0 'env-wrapped distributed launcher is blocked' \
    classify_on_login 'env CUDA_VISIBLE_DEVICES=0 torchrun train.py'
assert_status 0 'bash-wrapped distributed launcher is blocked' \
    classify_on_login 'bash -c "torchrun train.py"'
assert_status 0 'broad Python os.walk traversal is blocked' \
    classify_on_login 'python -c "import os; list(os.walk(\"/shared\"))"'
assert_status 1 'project-scoped Python traversal remains allowed' \
    classify_on_login 'python -c "import os; list(os.walk(\"./project\"))"'
assert_status 1 'lightweight help command remains allowed' \
    classify_on_login 'samtools view --help'
assert_status 1 'bounded project find remains allowed' \
    classify_on_login 'find ./project -maxdepth 2 -type f'

guard_output=''
guard_status=0
guard_output=$(HPCGUARD_HOSTNAME_OVERRIDE=research-login07 cmd_exec_guard 'while true; do nc -z cluster.example.edu 22; sleep 20; done') || guard_status=$?
assert_eq 101 "$guard_status" 'exec guard blocks a tight TCP liveness loop'
assert_eq 1 "$(printf '%s\n' "$guard_output" | awk '/BLOCKED ON LOGIN NODE/{n++} END{print n+0}')" 'blocked probe has a structured explanation'

check_output=''
check_status=0
check_output=$(HPCGUARD_HOSTNAME_OVERRIDE=research-login07 check_command -- torchrun train.py) || check_status=$?
assert_eq 101 "$check_status" 'machine-readable check returns block status'
assert_contains "$check_output" '"decision":"block"' 'machine-readable check emits block decision'

check_output=$(HPCGUARD_HOSTNAME_OVERRIDE=workstation42 check_command -- printf ok)
assert_contains "$check_output" '"decision":"unclassified"' 'unknown host is explicit in machine-readable output'

run_output=$(HPCGUARD_HOSTNAME_OVERRIDE=workstation42 run_command -- printf '<%s>\n' 'argument with spaces' ";touch $TEST_TMP/argv-injection-ran")
expected_run_output=$(printf '<%s>\n' 'argument with spaces' ";touch $TEST_TMP/argv-injection-ran")
assert_eq "$expected_run_output" "$run_output" 'argv execution preserves boundaries without shell evaluation'
assert_status 1 'argv metacharacters did not create a file' test -e "$TEST_TMP/argv-injection-ran"

probe_output=''
probe_status=0
probe_output=$(HPCGUARD_SSH_BIN="$ROOT/tests/fixtures/fake_ssh_no_socket.sh" probe_existing_master cluster) || probe_status=$?
assert_eq 3 "$probe_status" 'probe fails closed without a control socket'
assert_eq 1 "$(printf '%s\n' "$probe_output" | awk '/No network connection was attempted/{n++} END{print n+0}')" 'probe explains that no network connection was made'
assert_status 2 'probe rejects option-like host aliases' probe_existing_master -unsafe

assert_status 0 'shell process is protected from automatic termination' protected_process_name bash
assert_status 0 'SSH process is protected from automatic termination' protected_process_name ssh
assert_status 1 'ordinary worker name is not globally protected' protected_process_name python
printf '%s\tstale\n' "$$" > "$PID_FILE"
assert_status 1 'PID file cannot claim an unrelated process' watchdog_is_running

printf '%s\n' \
    'CPU_SINGLE_LIMIT=95' \
    'CPU_AGGREGATE_LIMIT=invalid' \
    'AUTO_KILL=true' \
    "UNKNOWN_KEY=\$(touch $TEST_TMP/config-injection-ran)" > "$CONFIG_FILE"
CPU_SINGLE_LIMIT=80
CPU_AGGREGATE_LIMIT=200
AUTO_KILL=false
load_config 2>/dev/null
assert_eq 95 "$CPU_SINGLE_LIMIT" 'configuration parser accepts validated integer'
assert_eq 200 "$CPU_AGGREGATE_LIMIT" 'configuration parser rejects invalid integer'
assert_eq true "$AUTO_KILL" 'configuration parser accepts strict boolean'
assert_status 1 'configuration values are never executed as shell code' test -e "$TEST_TMP/config-injection-ran"

assert_status 0 'valid Slurm name is accepted' valid_slurm_name analysis_01
assert_status 1 'path traversal is rejected as a Slurm name' valid_slurm_name ../../overwrite
assert_status 0 'valid Slurm memory value is accepted' valid_memory_value 32G
assert_status 1 'directive injection is rejected as memory' valid_memory_value $'32G\n#SBATCH --exclusive'
assert_status 0 'valid Slurm time is accepted' valid_time_value 12:00:00

vscode_target="$TEST_TMP/workspace"
mkdir -p "$vscode_target/.vscode"
printf '{"existing": true}\n' > "$vscode_target/.vscode/settings.json"
vscode_output=$(init_vscode_settings "$vscode_target")
assert_eq '{"existing": true}' "$(tr -d '\n' < "$vscode_target/.vscode/settings.json")" 'existing VSCode settings are preserved'
assert_status 0 'reviewable VSCode proposal is generated' test -f "$vscode_target/.vscode/settings.hpcguard.json"
assert_contains "$vscode_output" 'reviewable proposal' 'VSCode helper explains non-destructive behavior'

assert_status 2 'job inspector rejects option injection' inspect_job --help
assert_status 2 'job inspector rejects wildcard input' inspect_job '12*'

if [ "$fail" -ne 0 ]; then
    printf '%s failed, %s passed\n' "$fail" "$pass" >&2
    exit 1
fi
printf '%s passed\n' "$pass"
