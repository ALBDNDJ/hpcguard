#!/usr/bin/env bash
# HPCGuard: account-scoped login-node safety guard for shared HPC systems.
# This is a user-space safety net, not a replacement for scheduler policy.

set -Eeuo pipefail

VERSION="0.2.0"
PROGRAM_NAME="hpcguard"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hpcguard"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hpcguard"
LOG_FILE="$STATE_DIR/watchdog.log"
LOCK_DIR="${TMPDIR:-/tmp}/hpcguard-${USER}.lock"

# Defaults favor visibility over termination. `init` writes these explicitly.
LOGIN_HOST_REGEX='(^|[-_])(login|head|gateway|mgmt|master)'
ACTION='warn'                    # warn | terminate
GRACE_SECONDS=10
CPU_SOFT_LIMIT=80
CPU_SOFT_MIN_SECONDS=600
CPU_HARD_LIMIT=200
CPU_HARD_MIN_SECONDS=120
AGGREGATE_CPU_LIMIT=400
AGGREGATE_MEMBER_CPU_LIMIT=50
AGGREGATE_MIN_SECONDS=120
MEM_RSS_LIMIT_KB=67108864        # 64 GiB
MEM_MIN_SECONDS=60
MEM_RSS_HARD_LIMIT_KB=134217728  # 128 GiB
SCAN_MAX_SECONDS=600
BROAD_SCAN_MAX_SECONDS=120
D_STATE_SCAN_MIN_SECONDS=30

usage() {
    cat <<'EOF'
Usage:
  hpcguard init
  hpcguard doctor
  hpcguard check -- <command...>
  hpcguard watch --once [--dry-run]
  hpcguard install-cron
  hpcguard uninstall-cron
  hpcguard status

`watch --once` is designed for cron or a systemd user timer. It only inspects
the installing account, and only on configured login nodes.
EOF
}

log() {
    mkdir -p "$STATE_DIR"
    printf '[%s] %s\n' "$(date '+%F %T %Z')" "$*" >> "$LOG_FILE"
}

die() { printf '%s\n' "hpcguard: $*" >&2; exit 2; }

require_uint() {
    [[ "$2" =~ ^[0-9]+$ ]] || die "invalid $1 in $CONFIG_FILE: expected a non-negative integer"
}

load_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == *=* ]] || die "invalid config line: $line"
        key=${line%%=*}
        value=${line#*=}
        case "$key" in
            LOGIN_HOST_REGEX) LOGIN_HOST_REGEX=$value ;;
            ACTION)
                [[ "$value" == warn || "$value" == terminate ]] || die 'ACTION must be warn or terminate'
                ACTION=$value ;;
            GRACE_SECONDS|CPU_SOFT_LIMIT|CPU_SOFT_MIN_SECONDS|CPU_HARD_LIMIT|CPU_HARD_MIN_SECONDS|AGGREGATE_CPU_LIMIT|AGGREGATE_MEMBER_CPU_LIMIT|AGGREGATE_MIN_SECONDS|MEM_RSS_LIMIT_KB|MEM_MIN_SECONDS|MEM_RSS_HARD_LIMIT_KB|SCAN_MAX_SECONDS|BROAD_SCAN_MAX_SECONDS|D_STATE_SCAN_MIN_SECONDS)
                require_uint "$key" "$value"
                printf -v "$key" '%s' "$value" ;;
            *) die "unknown config key: $key" ;;
        esac
    done < "$CONFIG_FILE"
}

is_login_node() {
    local host
    host=$(hostname -s 2>/dev/null || hostname)
    [[ "$host" =~ $LOGIN_HOST_REGEX ]]
}

is_scheduler_exe() {
    case "$1" in sbatch|squeue|sacct|scancel|srun) return 0 ;; *) return 1 ;; esac
}

is_compute_exe() {
    case "$1" in
        python|python[0-9]*|pypy|pypy[0-9]*|ipython|jupyter|torchrun|accelerate|deepspeed|pytest|snakemake|nextflow|R|Rscript|matlab|java|perl|node|awk)
            return 0 ;;
        *) return 1 ;;
    esac
}

is_direct_scan() {
    local exe=$1 args=$2
    case "$exe" in find|rg|ripgrep) return 0 ;; esac
    [ "$exe" = grep ] || return 1
    [[ "$args" =~ (^|[[:space:]])(--recursive|--directories=recurse)([[:space:]]|$) ]] && return 0
    [[ "$args" =~ (^|[[:space:]])-[^[:space:]]*[rR][^[:space:]]*([[:space:]]|$) ]]
}

python_has_recursive_walk() {
    local args=$1
    [[ "$args" == *'os.walk('* || "$args" == *'.rglob('* || "$args" == *'.glob("**'* || "$args" == *".glob('**"* || "$args" == *'glob.glob('*'**'* ]]
}

is_broad_scan() {
    local args=" $1 " cwd=$2
    [[ "$args" == *' / '* || "$args" == *' /gpfs '* || "$args" == *' /gpfs/ '* || "$args" == *' /gpfs/hpc '* || "$args" == *' /gpfs/hpc/ '* || "$args" == *" $HOME "* || "$args" == *" $HOME/ "* ]] && return 0
    # Python -c payloads often quote paths, so token boundaries are not useful.
    [[ "$1" == *"$HOME"* || "$1" == *'/gpfs/'* ]] && return 0
    case "$cwd" in
        /|/gpfs|/gpfs/|/gpfs/hpc|/gpfs/hpc/|"$HOME"|"$HOME"/)
            [[ "$args" =~ (^|[[:space:]])\.[[:space:]] ]] && return 0 ;;
    esac
    return 1
}

# Emits: ignore, compute, scan-local, scan-broad, python-walk-local, or
# python-walk-broad. Shell parents are ignored so `bash -c` text cannot create
# false positives; direct children carry the executable identity.
classify_command() {
    local comm=$1 args=$2 cwd=${3:-} exe
    exe=${comm##*/}
    is_scheduler_exe "$exe" && { printf 'ignore\n'; return; }
    case "$exe" in bash|sh|zsh|fish|sshd|login_node_watchdog.sh|hpc_guard.sh) printf 'ignore\n'; return ;; esac
    if is_direct_scan "$exe" "$args"; then
        if is_broad_scan "$args" "$cwd"; then printf 'scan-broad\n'; else printf 'scan-local\n'; fi
        return
    fi
    if is_compute_exe "$exe"; then
        if [[ "$exe" == python* || "$exe" == pypy* || "$exe" == ipython ]] && python_has_recursive_walk "$args"; then
            if is_broad_scan "$args" "$cwd"; then printf 'python-walk-broad\n'; else printf 'python-walk-local\n'; fi
            return
        fi
        printf 'compute\n'
        return
    fi
    printf 'ignore\n'
}

emit_check() {
    local command="$*" exe args kind
    [ -n "$command" ] || die 'check expects a command after --'
    exe=${command%%[[:space:]]*}
    args=${command#"$exe"}
    kind=$(classify_command "$exe" "$args" "$(pwd -P)")
    case "$kind" in
        ignore) printf 'ALLOW: no configured risk signature detected.\n' ;;
        compute) printf 'WARN: compute-like command. Use a Slurm allocation if this is not a brief check.\n' ;;
        scan-local|python-walk-local) printf 'WARN: recursive scan in a project path. Keep it bounded; move prolonged scans to Slurm.\n' ;;
        scan-broad|python-walk-broad) printf 'BLOCK: broad shared-filesystem traversal detected. Submit it to Slurm or narrow the path.\n'; return 20 ;;
    esac
}

terminate_pid() {
    local pid=$1 reason=$2 metadata=$3 dry_run=$4
    if [ "$dry_run" = true ] || [ "$ACTION" = warn ]; then
        log "WARN reason=$reason pid=$pid $metadata"
        printf 'WARN  pid=%s reason=%s %s\n' "$pid" "$reason" "$metadata"
        return
    fi
    log "TERM reason=$reason pid=$pid $metadata"
    printf 'TERM  pid=%s reason=%s %s\n' "$pid" "$reason" "$metadata"
    kill -TERM "$pid" 2>/dev/null || return
    sleep "$GRACE_SECONDS"
    if kill -0 "$pid" 2>/dev/null; then
        log "KILL reason=$reason pid=$pid $metadata"
        printf 'KILL  pid=%s reason=%s %s\n' "$pid" "$reason" "$metadata"
        kill -KILL "$pid" 2>/dev/null || true
    fi
}

watch_once() (
    local dry_run=false
    [ "${1:-}" = --dry-run ] && dry_run=true
    [ -z "${1:-}" ] || [ "${1:-}" = --dry-run ] || die 'watch accepts only an optional --dry-run'
    is_login_node || { printf 'SKIP: not a configured login node.\n'; return 0; }

    mkdir -p "$STATE_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then printf 'SKIP: watcher already running.\n'; return 0; fi
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

    local -a source_cmd
    if [ -n "${HPCGUARD_SNAPSHOT_FILE:-}" ]; then source_cmd=(cat "$HPCGUARD_SNAPSHOT_FILE"); else source_cmd=(ps ww -u "$USER" -o pid,ppid,pgid,stat,etimes,pcpu,rss,comm,args); fi

    local -a pid_a=() pgid_a=() stat_a=() etime_a=() pcpu_a=() rss_a=() comm_a=() args_a=() kind_a=() cwd_a=()
    local line pid ppid pgid stat etimes pcpu rss comm args cwd kind cpu_int total_cpu=0 first=true
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$first" = true ] && [[ "$line" == *PID* ]]; then first=false; continue; fi
        first=false
        read -r pid ppid pgid stat etimes pcpu rss comm args <<< "$line"
        [[ "${pid:-}" =~ ^[0-9]+$ ]] || continue
        [ "$pid" = "$$" ] && continue
        [[ "$stat" == *Z* ]] && continue
        cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)
        kind=$(classify_command "$comm" "$args" "$cwd")
        [ "$kind" = ignore ] && continue
        cpu_int=${pcpu%.*}; cpu_int=${cpu_int:-0}
        pid_a+=("$pid"); pgid_a+=("$pgid"); stat_a+=("$stat"); etime_a+=("${etimes:-0}"); pcpu_a+=("${pcpu:-0}"); rss_a+=("${rss:-0}"); comm_a+=("$comm"); args_a+=("$args"); kind_a+=("$kind"); cwd_a+=("$cwd")
        if [[ "$kind" == compute || "$kind" == python-walk-* ]] && [ "${etimes:-0}" -ge "$AGGREGATE_MIN_SECONDS" ]; then total_cpu=$((total_cpu + cpu_int)); fi
    done < <("${source_cmd[@]}")

    local i reason metadata
    for i in "${!pid_a[@]}"; do
        reason=''
        if [ "${rss_a[$i]}" -ge "$MEM_RSS_HARD_LIMIT_KB" ]; then reason="rss_hard";
        elif [[ "${kind_a[$i]}" == scan-* || "${kind_a[$i]}" == python-walk-* ]] && [[ "${stat_a[$i]}" == *D* ]] && [ "${etime_a[$i]}" -ge "$D_STATE_SCAN_MIN_SECONDS" ]; then reason="scan_d_state";
        elif [[ "${kind_a[$i]}" == *broad* ]] && [ "${etime_a[$i]}" -ge "$BROAD_SCAN_MAX_SECONDS" ]; then reason="broad_scan_timeout";
        elif [[ "${kind_a[$i]}" == scan-local || "${kind_a[$i]}" == python-walk-local ]] && [ "${etime_a[$i]}" -ge "$SCAN_MAX_SECONDS" ]; then reason="scan_timeout";
        elif [ "${pcpu_a[$i]%.*}" -ge "$CPU_HARD_LIMIT" ] && [ "${etime_a[$i]}" -ge "$CPU_HARD_MIN_SECONDS" ]; then reason="cpu_hard";
        elif [ "${pcpu_a[$i]%.*}" -ge "$CPU_SOFT_LIMIT" ] && [ "${etime_a[$i]}" -ge "$CPU_SOFT_MIN_SECONDS" ]; then reason="cpu_soft";
        elif [ "${rss_a[$i]}" -ge "$MEM_RSS_LIMIT_KB" ] && [ "${etime_a[$i]}" -ge "$MEM_MIN_SECONDS" ]; then reason="rss_timeout";
        elif [[ "${kind_a[$i]}" == compute || "${kind_a[$i]}" == python-walk-* ]] && [ "$total_cpu" -ge "$AGGREGATE_CPU_LIMIT" ] && [ "${pcpu_a[$i]%.*}" -ge "$AGGREGATE_MEMBER_CPU_LIMIT" ] && [ "${etime_a[$i]}" -ge "$AGGREGATE_MIN_SECONDS" ]; then reason="aggregate_cpu";
        fi
        [ -n "$reason" ] || continue
        metadata="pgid=${pgid_a[$i]} kind=${kind_a[$i]} cpu=${pcpu_a[$i]}% rss_kb=${rss_a[$i]} age=${etime_a[$i]}s cwd=${cwd_a[$i]} comm=${comm_a[$i]} args=${args_a[$i]}"
        terminate_pid "${pid_a[$i]}" "$reason" "$metadata" "$dry_run"
    done
)

write_default_config() {
    mkdir -p "$CONFIG_DIR"
    [ ! -e "$CONFIG_FILE" ] || die "$CONFIG_FILE already exists; edit it directly"
    cat > "$CONFIG_FILE" <<'EOF'
# Only machines matching this pattern are monitored.
LOGIN_HOST_REGEX=(^|[-_])(login|head|gateway|mgmt|master)
# Start safely. Change to `terminate` only after checking dry-run output.
ACTION=warn
CPU_SOFT_LIMIT=80
CPU_SOFT_MIN_SECONDS=600
CPU_HARD_LIMIT=200
CPU_HARD_MIN_SECONDS=120
AGGREGATE_CPU_LIMIT=400
AGGREGATE_MEMBER_CPU_LIMIT=50
AGGREGATE_MIN_SECONDS=120
MEM_RSS_LIMIT_KB=67108864
MEM_MIN_SECONDS=60
MEM_RSS_HARD_LIMIT_KB=134217728
SCAN_MAX_SECONDS=600
BROAD_SCAN_MAX_SECONDS=120
D_STATE_SCAN_MIN_SECONDS=30
GRACE_SECONDS=10
EOF
    chmod 600 "$CONFIG_FILE"
    printf 'Created %s\n' "$CONFIG_FILE"
}

install_cron() {
    local self cron_line existing
    self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")
    cron_line="* * * * * $self watch --once >/dev/null 2>&1 # hpcguard"
    existing=$(crontab -l 2>/dev/null || true)
    [[ "$existing" == *'# hpcguard'* ]] && die 'an HPCGuard cron entry already exists'
    { printf '%s\n' "$existing"; printf '%s\n' "$cron_line"; } | crontab -
    printf 'Installed one-minute cron watcher. Run `%s watch --once --dry-run` before setting ACTION=terminate.\n' "$PROGRAM_NAME"
}

uninstall_cron() {
    local existing
    existing=$(crontab -l 2>/dev/null || true)
    printf '%s\n' "$existing" | awk '!/# hpcguard$/' | crontab -
    printf 'Removed HPCGuard cron entries.\n'
}

doctor() {
    local host
    host=$(hostname -s 2>/dev/null || hostname)
    printf 'HPCGuard %s\nHost: %s\nConfig: %s\nAction: %s\n' "$VERSION" "$host" "$CONFIG_FILE" "$ACTION"
    if is_login_node; then printf 'Node classification: login node (active)\n'; else printf 'Node classification: not configured as a login node (inactive)\n'; fi
    if crontab -l 2>/dev/null | grep -Fq '# hpcguard'; then printf 'Cron watcher: installed\n'; else printf 'Cron watcher: not installed\n'; fi
}

main() {
    load_config
    case "${1:-}" in
        init) [ "$#" -eq 1 ] || die 'init accepts no arguments'; write_default_config ;;
        doctor|status) [ "$#" -eq 1 ] || die "$1 accepts no arguments"; doctor ;;
        check) shift; [ "${1:-}" = -- ] && shift; emit_check "$@" ;;
        watch) shift; [ "${1:-}" = --once ] || die 'use: hpcguard watch --once [--dry-run]'; shift; watch_once "${1:-}" ;;
        install-cron) [ "$#" -eq 1 ] || die 'install-cron accepts no arguments'; install_cron ;;
        uninstall-cron) [ "$#" -eq 1 ] || die 'uninstall-cron accepts no arguments'; uninstall_cron ;;
        -h|--help|help|'') usage ;;
        *) die "unknown command: $1" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
