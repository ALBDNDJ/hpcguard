#!/usr/bin/env bash
# ==============================================================================
# HPCGuard v1.6.0
# Zero-root safety guard for AI coding agents & researchers on shared HPC clusters.
# Supporting compute, storage, IDE, scheduler, and safe SSH liveness workflows.
# ==============================================================================

set -e

# --- Colors & Styles ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

VERSION="v1.6.0"
CONFIG_DIR="${HPCGUARD_CONFIG_DIR:-$HOME/.hpcguard}"
CONFIG_FILE="$CONFIG_DIR/config.env"
PID_FILE="$CONFIG_DIR/watchdog.pid"
LOG_FILE="$CONFIG_DIR/hpcguard.log"
START_LOCK_DIR="$CONFIG_DIR/watchdog.start.lock"
FAILURE_STATE_FILE="$CONFIG_DIR/failed-command.state"
SUBMIT_STATE_FILE="$CONFIG_DIR/submission.events"
SUBMIT_LOCK_DIR="$CONFIG_DIR/submission.lock"

# --- Default Configurations ---
CPU_SINGLE_LIMIT=80        # Single process CPU %
CPU_AGGREGATE_LIMIT=200    # Total user aggregate CPU %
MEM_SINGLE_LIMIT_MB=8192    # Single-process resident memory warning
MEM_AGGREGATE_LIMIT_MB=16384 # Account-wide resident memory warning
PROCESS_COUNT_LIMIT=64      # Account-wide process-count warning
CHECK_INTERVAL=30
AUTO_KILL=false
PROBE_MIN_INTERVAL=60
RETRY_BACKOFF_SECONDS=60
SUBMIT_WINDOW_SECONDS=60
SUBMIT_MAX_COUNT=5
LOGIN_HOST_REGEX='(^|[-_])(login|head|gateway|mgmt|master|ln)([-_.0-9]|$)'

if [ -L "$CONFIG_DIR" ]; then
    echo "HPCGuard refuses a symlinked configuration directory: $CONFIG_DIR" >&2
    exit 1
fi
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR" 2>/dev/null || true

config_warning() {
    printf 'HPCGuard config warning: %s\n' "$1" >&2
}

valid_integer() {
    local value=$1 minimum=$2 maximum=$3
    [[ "$value" =~ ^[0-9]+$ ]] &&
        [ "$value" -ge "$minimum" ] &&
        [ "$value" -le "$maximum" ]
}

load_config() {
    [ -e "$CONFIG_FILE" ] || return 0
    if [ -L "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
        config_warning "ignored non-regular or symlinked file: $CONFIG_FILE"
        return 0
    fi

    local owner_uid
    owner_uid=$(stat -c '%u' "$CONFIG_FILE" 2>/dev/null || stat -f '%u' "$CONFIG_FILE" 2>/dev/null || true)
    if [ -z "$owner_uid" ] || [ "$owner_uid" != "$(id -u)" ]; then
        config_warning "ignored file not owned by the current user: $CONFIG_FILE"
        return 0
    fi
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true

    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
            *=*) ;;
            *) config_warning "ignored malformed line"; continue ;;
        esac
        key=${line%%=*}
        value=${line#*=}
        case "$key" in
            CPU_SINGLE_LIMIT)
                if valid_integer "$value" 1 10000; then CPU_SINGLE_LIMIT=$value; else config_warning "invalid CPU_SINGLE_LIMIT"; fi
                ;;
            CPU_AGGREGATE_LIMIT)
                if valid_integer "$value" 1 100000; then CPU_AGGREGATE_LIMIT=$value; else config_warning "invalid CPU_AGGREGATE_LIMIT"; fi
                ;;
            MEM_SINGLE_LIMIT_MB)
                if valid_integer "$value" 1 1048576; then MEM_SINGLE_LIMIT_MB=$value; else config_warning "invalid MEM_SINGLE_LIMIT_MB"; fi
                ;;
            MEM_AGGREGATE_LIMIT_MB)
                if valid_integer "$value" 1 4194304; then MEM_AGGREGATE_LIMIT_MB=$value; else config_warning "invalid MEM_AGGREGATE_LIMIT_MB"; fi
                ;;
            PROCESS_COUNT_LIMIT)
                if valid_integer "$value" 1 100000; then PROCESS_COUNT_LIMIT=$value; else config_warning "invalid PROCESS_COUNT_LIMIT"; fi
                ;;
            CHECK_INTERVAL)
                if valid_integer "$value" 1 3600; then CHECK_INTERVAL=$value; else config_warning "invalid CHECK_INTERVAL"; fi
                ;;
            PROBE_MIN_INTERVAL)
                if valid_integer "$value" 1 86400; then PROBE_MIN_INTERVAL=$value; else config_warning "invalid PROBE_MIN_INTERVAL"; fi
                ;;
            RETRY_BACKOFF_SECONDS)
                if valid_integer "$value" 1 86400; then RETRY_BACKOFF_SECONDS=$value; else config_warning "invalid RETRY_BACKOFF_SECONDS"; fi
                ;;
            SUBMIT_WINDOW_SECONDS)
                if valid_integer "$value" 1 86400; then SUBMIT_WINDOW_SECONDS=$value; else config_warning "invalid SUBMIT_WINDOW_SECONDS"; fi
                ;;
            SUBMIT_MAX_COUNT)
                if valid_integer "$value" 1 10000; then SUBMIT_MAX_COUNT=$value; else config_warning "invalid SUBMIT_MAX_COUNT"; fi
                ;;
            AUTO_KILL)
                if [ "$value" = true ] || [ "$value" = false ]; then AUTO_KILL=$value; else config_warning "invalid AUTO_KILL"; fi
                ;;
            LOGIN_HOST_REGEX)
                if [ -n "$value" ] && [ "${#value}" -le 256 ]; then LOGIN_HOST_REGEX=$value; else config_warning "invalid LOGIN_HOST_REGEX"; fi
                ;;
            *) config_warning "ignored unknown key: $key" ;;
        esac
    done < "$CONFIG_FILE"
}

save_config() {
    local temporary
    temporary=$(mktemp "$CONFIG_DIR/config.env.tmp.XXXXXX") || return 1
    chmod 600 "$temporary" 2>/dev/null || true
    {
        printf 'CPU_SINGLE_LIMIT=%s\n' "$CPU_SINGLE_LIMIT"
        printf 'CPU_AGGREGATE_LIMIT=%s\n' "$CPU_AGGREGATE_LIMIT"
        printf 'MEM_SINGLE_LIMIT_MB=%s\n' "$MEM_SINGLE_LIMIT_MB"
        printf 'MEM_AGGREGATE_LIMIT_MB=%s\n' "$MEM_AGGREGATE_LIMIT_MB"
        printf 'PROCESS_COUNT_LIMIT=%s\n' "$PROCESS_COUNT_LIMIT"
        printf 'CHECK_INTERVAL=%s\n' "$CHECK_INTERVAL"
        printf 'PROBE_MIN_INTERVAL=%s\n' "$PROBE_MIN_INTERVAL"
        printf 'RETRY_BACKOFF_SECONDS=%s\n' "$RETRY_BACKOFF_SECONDS"
        printf 'SUBMIT_WINDOW_SECONDS=%s\n' "$SUBMIT_WINDOW_SECONDS"
        printf 'SUBMIT_MAX_COUNT=%s\n' "$SUBMIT_MAX_COUNT"
        printf 'AUTO_KILL=%s\n' "$AUTO_KILL"
        printf 'LOGIN_HOST_REGEX=%s\n' "$LOGIN_HOST_REGEX"
    } > "$temporary"
    mv -f "$temporary" "$CONFIG_FILE"
}

load_config

# --- Helper Functions ---
log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

node_class() {
    if [ -n "${SLURM_JOB_ID:-}" ]; then
        printf 'allocation\n'
        return 0
    fi
    local host
    host=${HPCGUARD_HOSTNAME_OVERRIDE:-$(hostname -s 2>/dev/null || hostname)}
    if [[ "$host" =~ $LOGIN_HOST_REGEX ]]; then
        printf 'login\n'
    else
        printf 'unknown\n'
    fi
}

is_login_node() {
    [ "$(node_class)" = login ]
}

# Detect tight TCP/SSH liveness loops before they can create large volumes of
# unauthenticated connection-reset logs. A single probe is not classified as
# high frequency; the risky behavior is automated repetition below the floor.
is_high_frequency_ssh_probe() {
    local target_cmd="$1"
    local has_probe=false
    local has_loop=false
    local interval=""

    if [[ "$target_cmd" =~ (^|[[:space:];|/])(nc|ncat)([[:space:]]|$) ]] && \
       [[ "$target_cmd" =~ (^|[[:space:]])-[^[:space:]]*z[^[:space:]]*([[:space:]]|$) ]]; then
        has_probe=true
    elif [[ "$target_cmd" == *"/dev/tcp/"* ]]; then
        has_probe=true
    elif [[ "$target_cmd" =~ (^|[[:space:];|/])ssh([[:space:]]|$) ]] && \
         [[ ! "$target_cmd" =~ ssh[[:space:]].*-O[[:space:]]+check([[:space:]]|$) ]]; then
        has_probe=true
    fi

    if [[ "$target_cmd" =~ (^|[[:space:];])(while|until)([[:space:]]|$) ]] || \
       [[ "$target_cmd" =~ (^|[[:space:];])watch([[:space:]]|$) ]]; then
        has_loop=true
    fi

    [ "$has_probe" = true ] && [ "$has_loop" = true ] || return 1

    if [[ "$target_cmd" =~ sleep[[:space:]]+([0-9]+)(s)?([[:space:];]|$) ]]; then
        interval=${BASH_REMATCH[1]}
    elif [[ "$target_cmd" =~ watch[[:space:]]+(-n|--interval)[=[:space:]]+([0-9]+) ]]; then
        interval=${BASH_REMATCH[2]}
    fi

    # A repeating probe with no visible delay is treated as a tight loop.
    [ -z "$interval" ] || [ "$interval" -lt "$PROBE_MIN_INTERVAL" ]
}

is_high_concurrency_launcher() {
    local target_cmd=$1 workers=""

    if [[ "$target_cmd" =~ (^|[[:space:];|/])xargs[[:space:]].*-P[[:space:]=]*([0-9]+) ]]; then
        workers=${BASH_REMATCH[2]}
    elif [[ "$target_cmd" =~ (^|[[:space:];|/])parallel[[:space:]].*(-j|--jobs)[[:space:]=]*([0-9]+) ]]; then
        workers=${BASH_REMATCH[3]}
    elif [[ "$target_cmd" =~ (--workers|--jobs|--nproc_per_node)[[:space:]=]+([0-9]+) ]]; then
        workers=${BASH_REMATCH[2]}
    fi

    [ -n "$workers" ] && [ "$workers" -ge 16 ]
}

is_python_process_fanout() {
    local target_cmd=$1
    [[ "$target_cmd" =~ (multiprocessing\.(Pool|Process)|ProcessPoolExecutor|torch\.multiprocessing|joblib\.Parallel) ]] ||
        [[ "$target_cmd" =~ Parallel\(.*n_jobs[[:space:]]*=[[:space:]]*(-1|[1-9][0-9]+) ]]
}

is_high_frequency_scheduler_loop() {
    local target_cmd=$1 interval=""
    [[ "$target_cmd" =~ (^|[[:space:];])(while|until|for|watch)([[:space:]]|$) ]] || return 1
    [[ "$target_cmd" =~ (^|[[:space:];|/])(sbatch|srun)([[:space:]]|$) ]] || return 1

    if [[ "$target_cmd" =~ sleep[[:space:]]+([0-9]+)(s)?([[:space:];]|$) ]]; then
        interval=${BASH_REMATCH[1]}
    elif [[ "$target_cmd" =~ watch[[:space:]]+(-n|--interval)[=[:space:]]+([0-9]+) ]]; then
        interval=${BASH_REMATCH[2]}
    fi

    [ -z "$interval" ] || [ "$interval" -lt "$RETRY_BACKOFF_SECONDS" ]
}

# --- Module 1: Command Pre-execution Guard ---
POLICY_REASON=""
POLICY_SUGGESTION=""

classify_command() {
    local target_cmd=$1
    local python_traversal_re='python[0-9]*[[:space:]].*(-c|-[[:alnum:]]*c).*(os\.walk|\.rglob|glob\.glob)'
    POLICY_REASON=""
    POLICY_SUGGESTION=""

    if is_high_frequency_ssh_probe "$target_cmd"; then
        POLICY_REASON="High-frequency TCP/SSH liveness probing can create repeated pre-authentication reset logs and trigger IDS alerts."
        POLICY_SUGGESTION="Reuse an existing SSH ControlMaster with 'hpcguard probe <ssh-host>', or use a scheduler/event-driven check."

    elif is_high_frequency_scheduler_loop "$target_cmd"; then
        POLICY_REASON="A tight Slurm submission or launch loop can overload the scheduler and amplify repeated failures."
        POLICY_SUGGESTION="Use a rate-limited Slurm array or add an explicit backoff of at least $RETRY_BACKOFF_SECONDS seconds after diagnosing the failure."

    elif [[ "$target_cmd" == *':(){ :|:& };:'* ]]; then
        POLICY_REASON="A shell fork-bomb pattern was detected."
        POLICY_SUGGESTION="Do not execute recursive process-spawning expressions on a shared system."

    elif is_python_process_fanout "$target_cmd"; then
        POLICY_REASON="Python multiprocessing or process-pool fan-out was detected on a login node."
        POLICY_SUGGESTION="Run the workload in a Slurm allocation with an explicit CPU and memory request."

    elif is_high_concurrency_launcher "$target_cmd"; then
        POLICY_REASON="A high-concurrency process launcher was detected on a login node."
        POLICY_SUGGESTION="Reduce concurrency below 16 workers or request the required CPUs through Slurm."

    elif [[ "$target_cmd" =~ (torchrun|accelerate[[:space:]]+launch|deepspeed|mpirun|horovodrun) ]]; then
        POLICY_REASON="Distributed ML training framework detected on login node."
        POLICY_SUGGESTION="Submit the workload through the site scheduler with an explicit GPU and CPU request."

    elif [[ "$target_cmd" =~ python[0-9]*[[:space:]]+.*(train|finetune|pretrain|fit|wcr|embedding) ]]; then
        POLICY_REASON="Python training or heavy-computation script detected outside a scheduler allocation."
        POLICY_SUGGESTION="Submit the workload through the site scheduler with resources appropriate for the script."

    elif [[ "$target_cmd" =~ (Rscript|R[[:space:]]+CMD|install\.packages|devtools::|BiocManager::|Seurat|DESeq2|RunPCA|RunUMAP) ]]; then
        POLICY_REASON="Heavy R or bioinformatics work detected on a login node."
        POLICY_SUGGESTION="Submit the workload through the site scheduler with an explicit CPU and memory request."

    elif [[ "$target_cmd" =~ (bwa[[:space:]]+(mem|aln)|samtools[[:space:]]+(sort|index)|gatk[[:space:]]+|minimap2|bowtie2|deepvariant|snakemake[[:space:]]+-j|nextflow[[:space:]]+run) ]]; then
        POLICY_REASON="Heavy genomics alignment or variant-calling work detected on a login node."
        POLICY_SUGGESTION="Submit the workload through the site scheduler with an explicit CPU and memory request."

    elif [[ "$target_cmd" =~ find[[:space:]]+(\/|\/gpfs|\/shared|\/home)[[:space:]] ]] || [[ "$target_cmd" =~ grep[[:space:]]+-r[a-zA-Z]*[[:space:]]+(\/|\/gpfs|\/shared) ]]; then
        POLICY_REASON="A broad recursive scan on a root or shared filesystem was detected."
        POLICY_SUGGESTION="Target a specific project directory or submit the scan as a scheduler job."

    elif [[ "$target_cmd" =~ $python_traversal_re ]] && \
         [[ "$target_cmd" =~ (\/gpfs|\/shared|\/home|['\"]\/['\"]) ]]; then
        POLICY_REASON="Python code appears to recursively traverse a root or shared filesystem."
        POLICY_SUGGESTION="Restrict traversal to a specific project directory or run it inside a scheduler allocation."

    elif [[ "$target_cmd" =~ make[[:space:]]+-j[0-9]{2,} ]] || [[ "$target_cmd" =~ ninja[[:space:]]+-j[0-9]{2,} ]]; then
        POLICY_REASON="A high-concurrency compilation was detected on a login node."
        POLICY_SUGGESTION="Reduce build concurrency or submit the build through the site scheduler."
    else
        return 1
    fi
    return 0
}

render_block() {
    local target_cmd=$1
    echo -e "\n${RED}${BOLD}======================================================${NC}"
    echo -e "${RED}${BOLD} [HPCGuard: BLOCKED ON LOGIN NODE]${NC}"
    echo -e "${RED}${BOLD}======================================================${NC}"
    echo -e "${YELLOW}Host:${NC}     $(hostname)"
    echo -e "${YELLOW}Command:${NC}  $target_cmd"
    echo -e "${YELLOW}Reason:${NC}   $POLICY_REASON"
    echo -e "${GREEN}${BOLD}Suggested action:${NC}"
    echo -e "  $POLICY_SUGGESTION\n"
    echo -e "${BLUE}Hint: To generate a batch script, run: ${BOLD}hpcguard template${NC}\n"
}

join_argv() {
    local joined="" argument quoted
    for argument in "$@"; do
        printf -v quoted '%q' "$argument"
        joined+="${joined:+ }$quoted"
    done
    printf '%s\n' "$joined"
}

json_escape() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

command_fingerprint() {
    printf '%s\0' "$@" | cksum | awk '{print $1 ":" $2}'
}

recent_failure_status() {
    [ -f "$FAILURE_STATE_FILE" ] && [ ! -L "$FAILURE_STATE_FILE" ] || return 1
    local recorded_at recorded_fingerprint recorded_status now fingerprint
    IFS=$'\t' read -r recorded_at recorded_fingerprint recorded_status < "$FAILURE_STATE_FILE" || return 1
    [[ "$recorded_at" =~ ^[0-9]+$ ]] || return 1
    [[ "$recorded_status" =~ ^[0-9]+$ ]] || return 1
    fingerprint=$(command_fingerprint "$@")
    [ "$fingerprint" = "$recorded_fingerprint" ] || return 1
    now=$(date +%s)
    [ $((now - recorded_at)) -lt "$RETRY_BACKOFF_SECONDS" ] || return 1
    printf '%s\n' "$recorded_status"
}

record_command_failure() {
    local status=$1 temporary fingerprint
    shift
    fingerprint=$(command_fingerprint "$@")
    temporary=$(mktemp "$CONFIG_DIR/failed-command.tmp.XXXXXX") || return 1
    chmod 600 "$temporary" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$(date +%s)" "$fingerprint" "$status" > "$temporary"
    mv -f "$temporary" "$FAILURE_STATE_FILE"
}

clear_matching_failure() {
    [ -f "$FAILURE_STATE_FILE" ] && [ ! -L "$FAILURE_STATE_FILE" ] || return 0
    local _ recorded_fingerprint fingerprint
    IFS=$'\t' read -r _ recorded_fingerprint _ < "$FAILURE_STATE_FILE" || return 0
    fingerprint=$(command_fingerprint "$@")
    if [ "$fingerprint" = "$recorded_fingerprint" ]; then
        rm -f "$FAILURE_STATE_FILE"
    fi
}

reserve_submission_slot() {
    local now cutoff temporary count=0 timestamp
    now=$(date +%s)
    cutoff=$((now - SUBMIT_WINDOW_SECONDS))
    mkdir "$SUBMIT_LOCK_DIR" 2>/dev/null || return 2
    temporary=$(mktemp "$CONFIG_DIR/submission.events.tmp.XXXXXX") || {
        rmdir "$SUBMIT_LOCK_DIR" 2>/dev/null || true
        return 2
    }
    chmod 600 "$temporary" 2>/dev/null || true

    if [ -f "$SUBMIT_STATE_FILE" ] && [ ! -L "$SUBMIT_STATE_FILE" ]; then
        while IFS= read -r timestamp; do
            if [[ "$timestamp" =~ ^[0-9]+$ ]] && [ "$timestamp" -ge "$cutoff" ]; then
                printf '%s\n' "$timestamp" >> "$temporary"
                count=$((count + 1))
            fi
        done < "$SUBMIT_STATE_FILE"
    fi

    if [ "$count" -ge "$SUBMIT_MAX_COUNT" ]; then
        mv -f "$temporary" "$SUBMIT_STATE_FILE"
        rmdir "$SUBMIT_LOCK_DIR" 2>/dev/null || true
        return 1
    fi

    printf '%s\n' "$now" >> "$temporary"
    mv -f "$temporary" "$SUBMIT_STATE_FILE"
    rmdir "$SUBMIT_LOCK_DIR" 2>/dev/null || true
    return 0
}

render_runtime_block() {
    local target_cmd=$1 title=$2 reason=$3 suggestion=$4
    POLICY_REASON=$reason
    POLICY_SUGGESTION=$suggestion
    render_block "$target_cmd" | sed "s/\[HPCGuard: BLOCKED ON LOGIN NODE\]/[HPCGuard: $title]/"
}

check_command() {
    [ "${1:-}" = --json ] && shift
    [ "${1:-}" = -- ] && shift
    if [ "$#" -eq 0 ]; then
        echo 'Usage: hpcguard check -- <command> [args...]' >&2
        return 2
    fi
    local target_cmd class decision reason suggestion status=0
    target_cmd=$(join_argv "$@")
    class=$(node_class)
    decision=allow
    reason="No blocking policy matched."
    suggestion=""
    if [ "$class" = login ] && classify_command "$target_cmd"; then
        decision=block
        reason=$POLICY_REASON
        suggestion=$POLICY_SUGGESTION
        status=101
    elif [ "$class" = unknown ]; then
        decision=unclassified
        reason="Host is not recognized as a login node or scheduler allocation."
        suggestion="Configure LOGIN_HOST_REGEX before relying on enforcement."
        status=104
    fi
    printf '{"decision":"%s","node_class":"%s","reason":"%s","suggestion":"%s"}\n' \
        "$decision" "$class" "$(json_escape "$reason")" "$(json_escape "$suggestion")"
    return "$status"
}

run_command() {
    local force_retry=false
    if [ "${1:-}" = --force-retry ]; then
        force_retry=true
        shift
    fi
    [ "${1:-}" = -- ] && shift
    if [ "$#" -eq 0 ]; then
        echo 'Usage: hpcguard run [--force-retry] -- <command> [args...]' >&2
        return 2
    fi
    local target_cmd class failed_status executable reserve_status=0 command_status=0
    target_cmd=$(join_argv "$@")
    class=$(node_class)
    if [ "$class" = unknown ]; then
        render_runtime_block "$target_cmd" "UNCLASSIFIED HOST" \
            "Host is not recognized as a login node or scheduler allocation." \
            "Configure LOGIN_HOST_REGEX before asking an agent to execute commands."
        return 104
    fi
    if [ "$class" = login ] && classify_command "$target_cmd"; then
        render_block "$target_cmd"
        return 101
    fi
    if [ "$class" = login ] && [ "$force_retry" = false ]; then
        failed_status=$(recent_failure_status "$@" || true)
        if [ -n "$failed_status" ]; then
            render_runtime_block "$target_cmd" "RETRY BACKOFF" \
                "The same command failed with exit status $failed_status less than $RETRY_BACKOFF_SECONDS seconds ago." \
                "Diagnose the failure first, wait for the backoff, or explicitly use --force-retry after review."
            return 103
        fi
    fi

    executable=${1##*/}
    if [ "$class" = login ] && [ "$executable" = sbatch ]; then
        reserve_submission_slot || reserve_status=$?
        if [ "$reserve_status" -ne 0 ]; then
            render_runtime_block "$target_cmd" "SUBMISSION RATE LIMIT" \
                "The account reached its local limit of $SUBMIT_MAX_COUNT sbatch attempts in $SUBMIT_WINDOW_SECONDS seconds." \
                "Stop the submission loop, inspect failed jobs, and retry after the rolling window expires."
            return 102
        fi
    fi

    if command "$@"; then
        [ "$class" = login ] && clear_matching_failure "$@"
        return 0
    else
        command_status=$?
        [ "$class" = login ] && record_command_failure "$command_status" "$@"
        return "$command_status"
    fi
}

# Compatibility interface for pipelines and compound shell syntax. Prefer
# `hpcguard run -- command args...`, which preserves argv boundaries.
cmd_exec_guard() {
    local target_cmd="$*"
    if [ -z "$target_cmd" ]; then
        echo -e "${RED}Error: No command specified.${NC}"
        echo "Usage: hpcguard exec \"<shell command>\""
        return 2
    fi

    local class
    class=$(node_class)
    if [ "$class" = unknown ]; then
        render_runtime_block "$target_cmd" "UNCLASSIFIED HOST" \
            "Host is not recognized as a login node or scheduler allocation." \
            "Configure LOGIN_HOST_REGEX before asking an agent to execute commands."
        return 104
    fi
    if [ "$class" = login ] && classify_command "$target_cmd"; then
        render_block "$target_cmd"
        return 101
    fi
    bash -c "$target_cmd"
}

# Check only an already-running OpenSSH multiplexing master. This function has
# no network fallback: if the configured Unix control socket is absent, it
# returns immediately without opening a TCP connection or starting auth.
probe_existing_master() {
    local host="${1:-}"
    local ssh_bin="${HPCGUARD_SSH_BIN:-ssh}"
    local control_path=""

    if [ -z "$host" ] || [[ "$host" == -* ]]; then
        echo "Usage: hpcguard probe <ssh-config-host>"
        return 2
    fi
    if ! command -v "$ssh_bin" >/dev/null 2>&1; then
        echo -e "${RED}Error: OpenSSH client not found.${NC}"
        return 127
    fi

    control_path=$(
        "$ssh_bin" -G -- "$host" 2>/dev/null |
        awk 'tolower($1) == "controlpath" {sub(/^[^[:space:]]+[[:space:]]+/, ""); print; exit}'
    )

    if [ -z "$control_path" ] || [ "$control_path" = none ] || [[ "$control_path" == *%* ]]; then
        echo -e "${YELLOW}No resolved ControlPath is configured for '$host'. No network connection was attempted.${NC}"
        return 3
    fi
    if [ ! -S "$control_path" ]; then
        echo -e "${YELLOW}No live ControlMaster socket exists for '$host'. No network connection was attempted.${NC}"
        return 3
    fi

    if "$ssh_bin" -S "$control_path" -O check -o ConnectionAttempts=1 -- "$host"; then
        echo -e "${GREEN}ControlMaster is alive. The existing local socket was reused.${NC}"
        return 0
    fi

    echo -e "${YELLOW}The ControlMaster socket is stale or unavailable. No new SSH connection was attempted.${NC}"
    return 4
}

# --- Module 2: Resource Watchdog, Dilution Guard & Opt-in Termination ---
watchdog_pid() {
    [ -f "$PID_FILE" ] || return 1
    local pid
    IFS=$'\t' read -r pid _ < "$PID_FILE" || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$pid"
}

watchdog_process_matches() {
    local pid=$1 arguments recorded_start current_start
    kill -0 "$pid" 2>/dev/null || return 1
    IFS=$'\t' read -r _ recorded_start < "$PID_FILE" || return 1
    arguments=$(ps -ww -p "$pid" -o args= 2>/dev/null || true)
    current_start=$(ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -n "$recorded_start" ] && [ "$current_start" = "$recorded_start" ] &&
        [[ "$arguments" == *"hpc_guard.sh __watchdog"* ]]
}

watchdog_is_running() {
    local pid
    pid=$(watchdog_pid) || return 1
    watchdog_process_matches "$pid"
}

protected_process_name() {
    case "$1" in
        bash|zsh|sh|fish|ssh|sshd|srun|sbatch|salloc|scancel|tmux|screen|hpc_guard.sh) return 0 ;;
        *) return 1 ;;
    esac
}

terminate_verified_process() {
    local pid=$1 expected_name=$2 expected_start=$3
    local current_uid current_name current_start
    current_uid=$(ps -p "$pid" -o uid= 2>/dev/null | awk '{print $1}')
    current_name=$(ps -p "$pid" -o comm= 2>/dev/null | awk '{print $1}')
    current_start=$(ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    [ "$current_uid" = "$(id -u)" ] || return 1
    [ "$current_name" = "$expected_name" ] || return 1
    [ "$current_start" = "$expected_start" ] || return 1
    protected_process_name "$current_name" && return 1

    kill -TERM "$pid" 2>/dev/null || return 1
    for _ in 1 2 3; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 1
    done

    current_start=$(ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ "$current_start" = "$expected_start" ] || return 1
    kill -KILL "$pid" 2>/dev/null
}

watchdog_loop() {
    trap 'exit 0' TERM INT HUP
    local pid cpu rss name started total_cpu total_memory process_count d_pids lsp_pids
    while true; do
        while read -r pid cpu rss name; do
            [ -n "$pid" ] || continue
            if awk -v value="$cpu" -v limit="$CPU_SINGLE_LIMIT" 'BEGIN {exit !(value >= limit)}'; then
                log "[SINGLE PROCESS OVERLOAD] Process $name (PID $pid) exceeded $CPU_SINGLE_LIMIT% CPU on a login node."
                if [ "$AUTO_KILL" = true ]; then
                    started=$(ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    if [ -n "$started" ] && terminate_verified_process "$pid" "$name" "$started"; then
                        log "[AUTO-TERMINATE] Stopped verified process $pid ($name)."
                    else
                        log "[AUTO-TERMINATE SKIPPED] Process identity changed or process is protected: $pid ($name)."
                    fi
                fi
            fi
            if [[ "$rss" =~ ^[0-9]+$ ]] && [ $((rss / 1024)) -ge "$MEM_SINGLE_LIMIT_MB" ]; then
                log "[SINGLE PROCESS MEMORY] Process $name (PID $pid) uses $((rss / 1024)) MiB RSS (warning: $MEM_SINGLE_LIMIT_MB MiB)."
            fi
        done < <(ps -u "$(id -un)" -o pid=,pcpu=,rss=,comm= 2>/dev/null || true)

        total_cpu=$(ps -u "$(id -un)" -o pcpu= 2>/dev/null | awk '{sum += $1} END {print int(sum)}')
        if [ -n "$total_cpu" ] && [ "$total_cpu" -ge "$CPU_AGGREGATE_LIMIT" ]; then
            log "[AGGREGATE OVERLOAD] Account CPU reached $total_cpu% (limit: $CPU_AGGREGATE_LIMIT%)."
        fi

        total_memory=$(ps -u "$(id -un)" -o rss= 2>/dev/null | awk '{sum += $1} END {print int(sum / 1024)}')
        if [ -n "$total_memory" ] && [ "$total_memory" -ge "$MEM_AGGREGATE_LIMIT_MB" ]; then
            log "[AGGREGATE MEMORY] Account RSS reached $total_memory MiB (warning: $MEM_AGGREGATE_LIMIT_MB MiB)."
        fi

        process_count=$(ps -u "$(id -un)" -o pid= 2>/dev/null | awk 'END {print NR + 0}')
        if [ -n "$process_count" ] && [ "$process_count" -ge "$PROCESS_COUNT_LIMIT" ]; then
            log "[PROCESS FAN-OUT] Account has $process_count processes (warning: $PROCESS_COUNT_LIMIT)."
        fi

        d_pids=$(ps -u "$(id -un)" -o pid=,stat= 2>/dev/null | awk '$2 ~ /^D/ {print $1}' | paste -sd, -)
        if [ -n "$d_pids" ]; then
            log "[D-STATE OBSERVED] Process IDs $d_pids are in uninterruptible sleep; inspect storage and kernel evidence before attribution."
        fi

        lsp_pids=$(ps -u "$(id -un)" -o pid=,pcpu=,comm= 2>/dev/null | awk '$3 ~ /^(node|pylance|rsession)$/ && $2 >= 60 {print $1}' | paste -sd, -)
        if [ -n "$lsp_pids" ]; then
            log "[IDE INDEXING LOAD] High-CPU language-server process IDs: $lsp_pids."
        fi

        sleep "$CHECK_INTERVAL"
    done
}

start_watchdog() {
    if ! is_login_node; then
        echo -e "${YELLOW}Watchdog not started: this host is not configured as a login node.${NC}"
        return 1
    fi
    if watchdog_is_running; then
        echo -e "${YELLOW}Watchdog daemon is already running (PID: $(watchdog_pid)).${NC}"
        return 0
    fi
    if ! mkdir "$START_LOCK_DIR" 2>/dev/null; then
        echo -e "${YELLOW}Another watchdog start operation is in progress.${NC}"
        return 1
    fi
    if watchdog_is_running; then
        rmdir "$START_LOCK_DIR" 2>/dev/null || true
        return 0
    fi

    local script_path pid started temporary
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    echo -e "${GREEN}Starting HPCGuard Watchdog daemon in background...${NC}"
    nohup bash "$script_path" __watchdog >/dev/null 2>&1 &
    pid=$!
    started=$(ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    temporary=$(mktemp "$CONFIG_DIR/watchdog.pid.tmp.XXXXXX") || {
        kill "$pid" 2>/dev/null || true
        rmdir "$START_LOCK_DIR" 2>/dev/null || true
        return 1
    }
    printf '%s\t%s\n' "$pid" "$started" > "$temporary"
    mv -f "$temporary" "$PID_FILE"
    rmdir "$START_LOCK_DIR" 2>/dev/null || true
    echo -e "${GREEN}Watchdog daemon started successfully (PID: $pid).${NC}"
}

stop_watchdog() {
    local pid
    if ! watchdog_is_running; then
        echo -e "${YELLOW}Watchdog is not running; stale state was removed.${NC}"
        rm -f "$PID_FILE"
        return 0
    fi
    pid=$(watchdog_pid)
    kill -TERM "$pid" 2>/dev/null || true
    for _ in 1 2 3; do
        watchdog_process_matches "$pid" || break
        sleep 1
    done
    if watchdog_process_matches "$pid"; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    echo -e "${GREEN}Watchdog stopped.${NC}"
}

status_watchdog() {
    echo -e "\n${BOLD}=== HPCGuard System Status ===${NC}"
    echo -e "Hostname:         ${BLUE}$(hostname)${NC}"
    local class
    class=$(node_class)
    case "$class" in
        login) echo -e "Node Type:        ${YELLOW}Login / Head Node (Guarded)${NC}" ;;
        allocation) echo -e "Node Type:        ${GREEN}Inside Scheduler Allocation${NC}" ;;
        *) echo -e "Node Type:        ${YELLOW}Unknown / Unclassified (Not Guarded)${NC}" ;;
    esac

    if watchdog_is_running; then
        echo -e "Watchdog:         ${GREEN}Running (PID: $(watchdog_pid))${NC}"
    else
        echo -e "Watchdog:         ${RED}Stopped${NC}"
    fi
    echo -e "Single CPU Limit: ${BOLD}${CPU_SINGLE_LIMIT}%${NC}"
    echo -e "Aggregate CPU:     ${BOLD}${CPU_AGGREGATE_LIMIT}%${NC}"
    echo -e "Single Memory:     ${BOLD}${MEM_SINGLE_LIMIT_MB} MiB RSS${NC}"
    echo -e "Aggregate Memory:  ${BOLD}${MEM_AGGREGATE_LIMIT_MB} MiB RSS${NC}"
    echo -e "Process Count:     ${BOLD}${PROCESS_COUNT_LIMIT}${NC}"
    echo -e "Retry Backoff:     ${BOLD}${RETRY_BACKOFF_SECONDS}s${NC}"
    echo -e "Submission Rate:   ${BOLD}${SUBMIT_MAX_COUNT}/${SUBMIT_WINDOW_SECONDS}s${NC}"
    echo -e "Auto-Kill Mode:   ${BOLD}$AUTO_KILL${NC}"
    echo -e "Log File:         $LOG_FILE\n"
}

# --- Module 3: Multi-Language Slurm Batch Generator (with Array Rate Limiter) ---
valid_slurm_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]]
}

valid_memory_value() {
    [[ "$1" =~ ^[1-9][0-9]*([KMGTP]([iI]?[bB])?)?$ ]]
}

valid_time_value() {
    [[ "$1" =~ ^([0-9]+-)?[0-9]{1,2}:[0-9]{2}:[0-9]{2}$ ]]
}

invalid_template_value() {
    echo -e "${RED}Error: invalid $1 value.${NC}" >&2
    return 2
}

generate_slurm_template() {
    echo -e "\n${BOLD}--- Interactive Slurm Job Generator ---${NC}"
    echo -e "Select workload type:"
    echo -e " [1] Python / Deep Learning (GPU/CUDA)"
    echo -e " [2] R / Bioinformatics / High-Memory Statistics (CPU)"
    echo -e " [3] Genomics Alignment / Variant Calling (CPU)"
    read -r -p "Select [1-3, default: 1]: " work_type
    work_type=${work_type:-1}
    [[ "$work_type" =~ ^[123]$ ]] || { invalid_template_value "workload type"; return $?; }

    read -r -p "Job Name [my_job]: " job_name
    job_name=${job_name:-my_job}
    valid_slurm_name "$job_name" || { invalid_template_value "job name"; return $?; }

    read -r -p "Enable Slurm Array Job? [y/N]: " is_array
    is_array=${is_array:-N}
    [[ "$is_array" =~ ^[YyNn]$ ]] || { invalid_template_value "array choice"; return $?; }

    local array_directive=""
    if [[ "$is_array" =~ ^[Yy]$ ]]; then
        read -r -p "Array Range [1-50]: " array_range
        array_range=${array_range:-1-50}
        [[ "$array_range" =~ ^[0-9]+(-[0-9]+)?(:[1-9][0-9]*)?$ ]] || { invalid_template_value "array range"; return $?; }

        read -r -p "Max Concurrent Subtasks [%10]: " array_concurrency
        array_concurrency=${array_concurrency:-10}
        array_concurrency=${array_concurrency#%} # Strip % if user typed it
        valid_integer "$array_concurrency" 1 100000 || { invalid_template_value "array concurrency"; return $?; }

        array_directive="#SBATCH --array=${array_range}%${array_concurrency}"
        echo -e "${BLUE}💡 Array rate-limiting enabled: max ${array_concurrency} tasks running simultaneously.${NC}"
    fi

    local filename="${job_name}.slurm"
    if [ -e "$filename" ] || [ -L "$filename" ]; then
        echo -e "${YELLOW}Refusing to overwrite existing path: $filename${NC}" >&2
        return 3
    fi

    if [ "$work_type" = "2" ]; then
        read -r -p "Partition [cpu]: " partition
        partition=${partition:-cpu}
        valid_slurm_name "$partition" || { invalid_template_value "partition"; return $?; }

        read -r -p "CPUs per task [8]: " cpus
        cpus=${cpus:-8}
        valid_integer "$cpus" 1 4096 || { invalid_template_value "CPU count"; return $?; }

        read -r -p "Memory [32G]: " mem
        mem=${mem:-32G}
        valid_memory_value "$mem" || { invalid_template_value "memory"; return $?; }

        read -r -p "Time limit [08:00:00]: " time_limit
        time_limit=${time_limit:-08:00:00}
        valid_time_value "$time_limit" || { invalid_template_value "time limit"; return $?; }

        read -r -p "R Script to run [Rscript main.R]: " r_cmd
        r_cmd=${r_cmd:-Rscript main.R}

        cat <<EOF > "$filename"
#!/bin/bash
#SBATCH --job-name=${job_name}
#SBATCH --partition=${partition}
${array_directive}
#SBATCH --cpus-per-task=${cpus}
#SBATCH --mem=${mem}
#SBATCH --time=${time_limit}
#SBATCH --output=${job_name}_%j.log

echo "Job started at: \$(date)"
echo "Running on node: \$(hostname)"

# Load R environment
# module load R/4.3.0 2>/dev/null || true
# conda activate r_env 2>/dev/null || true

${r_cmd}

echo "Job finished at: \$(date)"
EOF
    elif [ "$work_type" = "3" ]; then
        read -r -p "Partition [cpu]: " partition
        partition=${partition:-cpu}
        valid_slurm_name "$partition" || { invalid_template_value "partition"; return $?; }

        read -r -p "CPUs per task [16]: " cpus
        cpus=${cpus:-16}
        valid_integer "$cpus" 1 4096 || { invalid_template_value "CPU count"; return $?; }

        read -r -p "Memory [64G]: " mem
        mem=${mem:-64G}
        valid_memory_value "$mem" || { invalid_template_value "memory"; return $?; }

        read -r -p "Time limit [12:00:00]: " time_limit
        time_limit=${time_limit:-12:00:00}
        valid_time_value "$time_limit" || { invalid_template_value "time limit"; return $?; }

        read -r -p "Command to run [bwa mem -t 16 ref.fa read1.fq read2.fq]: " gen_cmd
        gen_cmd=${gen_cmd:-bwa mem -t 16 ref.fa read1.fq read2.fq}

        cat <<EOF > "$filename"
#!/bin/bash
#SBATCH --job-name=${job_name}
#SBATCH --partition=${partition}
${array_directive}
#SBATCH --cpus-per-task=${cpus}
#SBATCH --mem=${mem}
#SBATCH --time=${time_limit}
#SBATCH --output=${job_name}_%j.log

echo "Genomics pipeline started at: \$(date)"
echo "Running on node: \$(hostname)"

# Load modules
# module load bwa/0.7.17 samtools/1.18 2>/dev/null || true

${gen_cmd}

echo "Genomics pipeline finished at: \$(date)"
EOF
    else
        read -r -p "Partition [gpu]: " partition
        partition=${partition:-gpu}
        valid_slurm_name "$partition" || { invalid_template_value "partition"; return $?; }

        read -r -p "GPU Count [1]: " gpus
        gpus=${gpus:-1}
        valid_integer "$gpus" 1 128 || { invalid_template_value "GPU count"; return $?; }

        read -r -p "CPUs per task [4]: " cpus
        cpus=${cpus:-4}
        valid_integer "$cpus" 1 4096 || { invalid_template_value "CPU count"; return $?; }

        read -r -p "Memory [32G]: " mem
        mem=${mem:-32G}
        valid_memory_value "$mem" || { invalid_template_value "memory"; return $?; }

        read -r -p "Time limit [12:00:00]: " time_limit
        time_limit=${time_limit:-12:00:00}
        valid_time_value "$time_limit" || { invalid_template_value "time limit"; return $?; }

        read -r -p "Python Command [python main.py]: " py_cmd
        py_cmd=${py_cmd:-python main.py}

        cat <<EOF > "$filename"
#!/bin/bash
#SBATCH --job-name=${job_name}
#SBATCH --partition=${partition}
${array_directive}
#SBATCH --gres=gpu:${gpus}
#SBATCH --cpus-per-task=${cpus}
#SBATCH --mem=${mem}
#SBATCH --time=${time_limit}
#SBATCH --output=${job_name}_%j.log

echo "Job started at: \$(date)"
echo "Running on node: \$(hostname)"
nvidia-smi 2>/dev/null || true

# Load Python environment
# source activate your_env

${py_cmd}

echo "Job finished at: \$(date)"
EOF
    fi

    echo -e "\n${GREEN}✅ Generated Slurm script: ${BOLD}$filename${NC}"
    echo -e "To submit, run: ${BLUE}sbatch $filename${NC}\n"
}

# --- Module 4: Job Diagnostics & Failure Inspector (inspect) ---
inspect_job() {
    local job_id="${1:-}"
    if [ -z "$job_id" ] || [[ ! "$job_id" =~ ^[0-9]+(_[0-9]+)?$ ]]; then
        echo -e "${RED}Error: No Job ID specified.${NC}"
        echo "Usage: hpcguard inspect <numeric_job_id>" >&2
        return 2
    fi

    echo -e "\n${BLUE}${BOLD}======================================================${NC}"
    echo -e "${BLUE}${BOLD} [HPCGuard: Slurm Job Diagnostics (Job ID: $job_id)]${NC}"
    echo -e "${BLUE}${BOLD}======================================================${NC}"

    if command -v sacct >/dev/null 2>&1; then
        echo -e "${YELLOW}Accounting Summary (sacct):${NC}"
        sacct --jobs="$job_id" --format=JobID,JobName%20,Partition,State,ExitCode,MaxRSS,Elapsed,NodeList
        echo ""
    else
        echo -e "${YELLOW}Notice: 'sacct' command not found on current host.${NC}\n"
    fi

    # Attempt to locate log files in current directory
    local log_path found=false
    while IFS= read -r -d '' log_path; do
        found=true
        echo -e "${GREEN}Found Job Log: ${BOLD}$log_path${NC}"
        echo -e "${YELLOW}--- Tail (Last 15 lines; terminal escapes removed) ---${NC}"
        tail -n 15 "$log_path" | LC_ALL=C sed $'s/\033\[[0-9;?]*[ -\/]*[@-~]//g'
        echo -e "${YELLOW}----------------------------${NC}\n"
    done < <(find . -maxdepth 2 -type f -name "*${job_id}*.log" -print0 2>/dev/null)
    [ "$found" = true ] || echo -e "${YELLOW}No matching job log found within two directory levels.${NC}\n"
}

# --- Module 5: VSCode Remote Anti-Stall Config Generator ---
init_vscode_settings() {
    local target_dir="${1:-.}"
    local vscode_dir="$target_dir/.vscode"
    local settings_file="$vscode_dir/settings.json"
    local force=false backup_file=""

    if [ "$target_dir" = --force ]; then
        force=true
        target_dir=.
        vscode_dir="$target_dir/.vscode"
        settings_file="$vscode_dir/settings.json"
    elif [ "${2:-}" = --force ]; then
        force=true
    fi

    mkdir -p "$vscode_dir"

    if [ -L "$settings_file" ]; then
        echo -e "${RED}Refusing to replace symlinked settings file: $settings_file${NC}" >&2
        return 3
    fi
    if [ -e "$settings_file" ] && [ "$force" != true ]; then
        settings_file="$vscode_dir/settings.hpcguard.json"
        if [ -e "$settings_file" ] || [ -L "$settings_file" ]; then
            echo -e "${YELLOW}Existing VSCode settings were preserved; proposed settings already exist at $settings_file.${NC}" >&2
            return 3
        fi
        echo -e "${YELLOW}Existing settings.json will not be overwritten. Writing a reviewable proposal instead.${NC}"
    elif [ -e "$settings_file" ]; then
        backup_file=$(mktemp "$vscode_dir/settings.json.backup.XXXXXX") || return 1
        cp -p "$settings_file" "$backup_file"
        echo -e "${YELLOW}Existing settings backed up to $backup_file.${NC}"
    fi

    cat <<EOF > "$settings_file"
{
    "search.followSymlinks": false,
    "remote.autoForwardPorts": false,
    "files.watcherExclude": {
        "**/.git/objects/**": true,
        "**/.git/subtree-cache/**": true,
        "**/node_modules/**": true,
        "**/.venv/**": true,
        "**/miniconda3/**": true,
        "**/data/**": true,
        "**/dataset/**": true,
        "**/checkpoints/**": true,
        "**/*.mat": true,
        "**/*.pt": true,
        "**/*.pth": true,
        "**/*.csv": true,
        "**/*.h5": true,
        "**/*.tar*": true
    },
    "python.analysis.indexing": false,
    "python.analysis.userFileIndexingLimit": 2000,
    "python.analysis.packageIndexDepths": [
        { "name": "", "depth": 1, "includeAllSymbols": false }
    ],
    "git.autorefresh": false,
    "git.autoRepositoryDetection": "openEditors"
}
EOF

    echo -e "\n${GREEN}✅ Generated safe VSCode Remote settings: ${BOLD}$settings_file${NC}"
    echo -e "Review and merge these settings as appropriate for the project.\n"
}

# --- Module 6: Global Alias Helper ---
install_alias() {
    local script_path
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    local rc_file=""
    if [ -f "$HOME/.bashrc" ]; then
        rc_file="$HOME/.bashrc"
    elif [ -f "$HOME/.zshrc" ]; then
        rc_file="$HOME/.zshrc"
    fi

    if [ -n "$rc_file" ]; then
        if ! grep -q "hpcguard" "$rc_file"; then
            {
                echo ""
                echo "# Added by HPCGuard"
                echo "alias hpcguard=\"bash $script_path\""
            } >> "$rc_file"
            echo -e "${GREEN}✅ Added alias 'hpcguard' to $rc_file.${NC}"
            echo -e "Run ${BLUE}source $rc_file${NC} or restart your shell to use ${BOLD}hpcguard${NC} directly."
        else
            echo -e "${YELLOW}Alias already exists in $rc_file.${NC}"
        fi
    fi
}

# --- Interactive Main Menu ---
show_menu() {
    echo -e "${BLUE}${BOLD}"
    echo "================================================================"
    echo "       HPCGuard: AI Agent & User Safety Layer for HPC"
    echo "                     Version: $VERSION"
    echo "================================================================"
    echo -e "${NC}"
    echo -e " [1] View System & Guard Status"
    echo -e " [2] Start Background Resource Watchdog"
    echo -e " [3] Stop Background Resource Watchdog"
    echo -e " [4] Toggle Auto-Kill Mode (Current: ${BOLD}$AUTO_KILL${NC})"
    echo -e " [5] Check Existing SSH ControlMaster (no TCP fallback)"
    echo -e " [6] Generate Slurm Batch Script (Python / R / Genomics / Array)"
    echo -e " [7] Inspect Slurm Job Diagnostics (hpcguard inspect <id>)"
    echo -e " [8] Initialize Safe VSCode Remote Settings (.vscode/settings.json)"
    echo -e " [9] Install 'hpcguard' Global Shell Alias"
    echo -e " [10] View Guard & Watchdog Logs"
    echo -e " [0] Exit"
    echo ""
    read -r -p "Select option [0-10]: " choice
    case $choice in
        1) status_watchdog ;;
        2) start_watchdog ;;
        3) stop_watchdog ;;
        4)
            if [ "$AUTO_KILL" = "true" ]; then
                AUTO_KILL=false
            else
                AUTO_KILL=true
            fi
            save_config
            echo -e "${GREEN}Auto-Kill set to: $AUTO_KILL${NC}"
            ;;
        5)
            read -r -p "Enter SSH config host alias: " probe_host
            probe_existing_master "$probe_host"
            ;;
        6) generate_slurm_template ;;
        7)
            read -r -p "Enter Slurm Job ID to inspect: " input_jid
            inspect_job "$input_jid"
            ;;
        8) init_vscode_settings ;;
        9) install_alias ;;
        10) [ -f "$LOG_FILE" ] && tail -n 25 "$LOG_FILE" || echo "No logs yet." ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}" ;;
    esac
}

# --- CLI Parameter Router ---
main() {
case "${1:-}" in
    check)
        shift
        check_command "$@"
        ;;
    run)
        shift
        run_command "$@"
        ;;
    exec)
        shift
        cmd_exec_guard "$@"
        ;;
    inspect)
        shift
        inspect_job "$@"
        ;;
    probe)
        shift
        probe_existing_master "$@"
        ;;
    start)
        start_watchdog
        ;;
    stop)
        stop_watchdog
        ;;
    status)
        status_watchdog
        ;;
    template)
        generate_slurm_template
        ;;
    init-vscode)
        shift
        init_vscode_settings "$@"
        ;;
    install-alias)
        install_alias
        ;;
    __watchdog)
        watchdog_loop
        ;;
    *)
        show_menu
        ;;
esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
