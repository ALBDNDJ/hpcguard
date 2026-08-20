#!/usr/bin/env bash
# ==============================================================================
# HPCGuard v1.1.0
# Zero-root safety guard for AI coding agents & researchers on shared HPC clusters.
# Supporting Python ML, R/Bioinformatics, and C/C++ Workload Governance.
# ==============================================================================

set -e

# --- Colors & Styles ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

VERSION="v1.1.0"
CONFIG_DIR="$HOME/.hpcguard"
CONFIG_FILE="$CONFIG_DIR/config.env"
PID_FILE="$CONFIG_DIR/watchdog.pid"
LOG_FILE="$CONFIG_DIR/hpcguard.log"

# --- Default Configurations ---
CPU_SINGLE_LIMIT=80        # Single process CPU %
CPU_AGGREGATE_LIMIT=200    # Total user aggregate CPU %
MEM_LIMIT=80
CHECK_INTERVAL=30
AUTO_KILL=false

mkdir -p "$CONFIG_DIR"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# --- Helper Functions ---
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

is_login_node() {
    # 1. If currently inside a Slurm/PBS batch or interactive allocation, it is a compute node
    if [ -n "$SLURM_JOB_ID" ] || [ -n "$PBS_JOBID" ]; then
        return 1
    fi
    # 2. Hostname pattern matching for common cluster login/head nodes
    local host
    host=$(hostname -s 2>/dev/null || hostname)
    if [[ "$host" =~ ^(login|head|master|gateway|mgmt|ln|hpc) ]] || [[ "$host" =~ [0-9]+$ ]]; then
        return 0
    fi
    return 0
}

# --- Module 1: Command Pre-execution Guard (exec) ---
cmd_exec_guard() {
    local target_cmd="$*"
    if [ -z "$target_cmd" ]; then
        echo -e "${RED}Error: No command specified.${NC}"
        echo "Usage: hpcguard exec \"<command>\""
        exit 1
    fi

    # If already running inside a compute node allocation, allow directly
    if ! is_login_node; then
        eval "$target_cmd"
        return $?
    fi

    # Check dangerous command patterns on login nodes
    local blocked=false
    local reason=""
    local suggested_cmd=""

    # 1. Distributed ML / Multi-GPU training (PyTorch, DeepSpeed, Horovod)
    if [[ "$target_cmd" =~ (torchrun|accelerate[[:space:]]+launch|deepspeed|mpirun|horovodrun) ]]; then
        blocked=true
        reason="Distributed ML training framework detected on login node."
        suggested_cmd="srun --partition=gpu --gres=gpu:1 --cpus-per-task=4 python <script.py> (or submit via 'sbatch your_job.slurm')"

    # 2. Python ML / Deep Learning scripts
    elif [[ "$target_cmd" =~ python[0-9]*[[:space:]]+.*(train|finetune|pretrain|fit|wcr|embedding) ]]; then
        blocked=true
        reason="Python training / heavy computation script detected outside Slurm allocation."
        suggested_cmd="srun --partition=gpu --gres=gpu:1 --cpus-per-task=4 $target_cmd"

    # 3. R Language & Bioinformatics pipelines (Seurat, DESeq2, Rscript analysis, R package compilation)
    elif [[ "$target_cmd" =~ (Rscript|R[[:space:]]+CMD|install\.packages|devtools::|BiocManager::|Seurat|DESeq2|RunPCA|RunUMAP) ]]; then
        blocked=true
        reason="Heavy R/Bioinformatics pipeline or native package compilation detected on login node."
        suggested_cmd="srun --partition=cpu --cpus-per-task=8 --mem=32G $target_cmd (or submit via 'sbatch r_job.slurm')"

    # 4. Large-scale recursive disk scanning on shared network filesystems (GPFS, Lustre, NFS)
    elif [[ "$target_cmd" =~ find[[:space:]]+(\/|\/gpfs|\/shared|\/home)[[:space:]] ]] || [[ "$target_cmd" =~ grep[[:space:]]+-r[a-zA-Z]*[[:space:]]+(\/|\/gpfs|\/shared) ]]; then
        blocked=true
        reason="Recursive scan on shared/root filesystem detected (may trigger D-state metadata I/O stall)."
        suggested_cmd="Target specific project subdirectories or submit as a lightweight background Slurm batch."

    # 5. High-concurrency builds (make / ninja)
    elif [[ "$target_cmd" =~ make[[:space:]]+-j[0-9]{2,} ]] || [[ "$target_cmd" =~ ninja[[:space:]]+-j[0-9]{2,} ]]; then
        blocked=true
        reason="High-concurrency compilation detected (overloaded thread count on shared CPU)."
        suggested_cmd="Use 'make -j4' or submit compilation to a CPU compute node via srun."
    fi

    if [ "$blocked" = true ]; then
        echo -e "\n${RED}${BOLD}======================================================${NC}"
        echo -e "${RED}${BOLD} [HPCGuard: BLOCKED ON LOGIN NODE]${NC}"
        echo -e "${RED}${BOLD}======================================================${NC}"
        echo -e "${YELLOW}Host:${NC}     $(hostname)"
        echo -e "${YELLOW}Command:${NC}  $target_cmd"
        echo -e "${YELLOW}Reason:${NC}   $reason"
        echo -e "${GREEN}${BOLD}Suggested Execution:${NC}"
        echo -e "  $suggested_cmd\n"
        echo -e "${BLUE}💡 Hint: To generate a batch script, run: ${BOLD}hpcguard template${NC}\n"
        return 101
    else
        # Allow safe command to proceed
        eval "$target_cmd"
        return $?
    fi
}

# --- Module 2: Resource Watchdog, Dilution Guard & Auto-Kill ---
start_watchdog() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo -e "${YELLOW}Watchdog daemon is already running (PID: $(cat "$PID_FILE")).${NC}"
        return 0
    fi

    echo -e "${GREEN}Starting HPCGuard Watchdog daemon in background...${NC}"
    nohup bash -c "
    while true; do
        # 1. Single Process CPU Threshold Check
        high_pids=\$(ps -u \$(whoami) -o pid,pcpu,comm --no-headers 2>/dev/null | awk '\$2 >= $CPU_SINGLE_LIMIT {print \$1}')
        if [ -n \"\$high_pids\" ]; then
            for pid in \$high_pids; do
                pname=\$(ps -p \$pid -o comm= 2>/dev/null || echo 'unknown')
                echo \"[\$(date)] [SINGLE PROCESS OVERLOAD] Process \$pname (PID \$pid) exceeded $CPU_SINGLE_LIMIT% CPU on login node.\" >> '$LOG_FILE'
                if [ '$AUTO_KILL' = 'true' ]; then
                    kill -9 \$pid 2>/dev/null && echo \"[\$(date)] [AUTO-KILL] Terminated runaway process \$pid (\$pname).\" >> '$LOG_FILE'
                fi
            done
        fi

        # 2. Multi-Process Aggregate CPU Dilution Check
        total_cpu=\$(ps -u \$(whoami) -o pcpu --no-headers 2>/dev/null | awk '{s+=\$1} END {print int(s)}')
        if [ -n \"\$total_cpu\" ] && [ \"\$total_cpu\" -ge $CPU_AGGREGATE_LIMIT ]; then
            echo \"[\$(date)] [AGGREGATE OVERLOAD] User total CPU reached \$total_cpu% (Limit: $CPU_AGGREGATE_LIMIT%).\" >> '$LOG_FILE'
        fi

        # 3. D-State (Uninterruptible Storage I/O) Lock Check
        d_pids=\$(ps -u \$(whoami) -o pid,stat,comm --no-headers 2>/dev/null | awk '\$2 ~ /^D/ {print \$1}')
        if [ -n \"\$d_pids\" ]; then
            echo \"[\$(date)] [STORAGE I/O D-STATE DETECTED] Process(es) \$d_pids waiting on parallel filesystem metadata locks.\" >> '$LOG_FILE'
        fi

        sleep $CHECK_INTERVAL
    done
    " >/dev/null 2>&1 &

    echo $! > "$PID_FILE"
    echo -e "${GREEN}✅ Watchdog daemon started successfully (PID: $!).${NC}"
}

stop_watchdog() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -f "$PID_FILE"
        echo -e "${GREEN}✅ Watchdog stopped.${NC}"
    else
        echo -e "${YELLOW}Watchdog is not running.${NC}"
        rm -f "$PID_FILE"
    fi
}

status_watchdog() {
    echo -e "\n${BOLD}=== HPCGuard System Status ===${NC}"
    echo -e "Hostname:         ${BLUE}$(hostname)${NC}"
    if is_login_node; then
        echo -e "Node Type:        ${YELLOW}Login / Head Node (Guarded)${NC}"
    else
        echo -e "Node Type:        ${GREEN}Compute Node / Inside Slurm Allocation${NC}"
    fi

    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo -e "Watchdog:         ${GREEN}Running (PID: $(cat "$PID_FILE"))${NC}"
    else
        echo -e "Watchdog:         ${RED}Stopped${NC}"
    fi
    echo -e "Single CPU Limit: ${BOLD}${CPU_SINGLE_LIMIT}%${NC}"
    echo -e "Aggregate Limit:  ${BOLD}${CPU_AGGREGATE_LIMIT}%${NC}"
    echo -e "Auto-Kill Mode:   ${BOLD}$AUTO_KILL${NC}"
    echo -e "Log File:         $LOG_FILE\n"
}

# --- Module 3: Multi-Language Slurm Batch Generator ---
generate_slurm_template() {
    echo -e "\n${BOLD}--- Interactive Slurm Job Generator ---${NC}"
    echo -e "Select workload type:"
    echo -e " [1] Python / Deep Learning (GPU/CUDA)"
    echo -e " [2] R / Bioinformatics / High-Memory Statistics (CPU)"
    read -r -p "Select [1-2, default: 1]: " work_type
    work_type=${work_type:-1}

    read -r -p "Job Name [my_job]: " job_name
    job_name=${job_name:-my_job}

    local filename="${job_name}.slurm"

    if [ "$work_type" = "2" ]; then
        read -r -p "Partition [cpu]: " partition
        partition=${partition:-cpu}

        read -r -p "CPUs per task [8]: " cpus
        cpus=${cpus:-8}

        read -r -p "Memory [32G]: " mem
        mem=${mem:-32G}

        read -r -p "Time limit [08:00:00]: " time_limit
        time_limit=${time_limit:-08:00:00}

        read -r -p "R Script to run [Rscript main.R]: " r_cmd
        r_cmd=${r_cmd:-Rscript main.R}

        cat <<EOF > "$filename"
#!/bin/bash
#SBATCH --job-name=${job_name}
#SBATCH --partition=${partition}
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
    else
        read -r -p "Partition [gpu]: " partition
        partition=${partition:-gpu}

        read -r -p "GPU Count [1]: " gpus
        gpus=${gpus:-1}

        read -r -p "CPUs per task [4]: " cpus
        cpus=${cpus:-4}

        read -r -p "Memory [32G]: " mem
        mem=${mem:-32G}

        read -r -p "Time limit [12:00:00]: " time_limit
        time_limit=${time_limit:-12:00:00}

        read -r -p "Python Command [python main.py]: " py_cmd
        py_cmd=${py_cmd:-python main.py}

        cat <<EOF > "$filename"
#!/bin/bash
#SBATCH --job-name=${job_name}
#SBATCH --partition=${partition}
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

# --- Module 4: Global Alias Helper ---
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
            echo "" >> "$rc_file"
            echo "# Added by HPCGuard" >> "$rc_file"
            echo "alias hpcguard=\"bash $script_path\"" >> "$rc_file"
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
    echo -e " [5] Generate Slurm Batch Script (Python / R)"
    echo -e " [6] Install 'hpcguard' Global Shell Alias"
    echo -e " [7] View Guard & Watchdog Logs"
    echo -e " [0] Exit"
    echo ""
    read -r -p "Select option [0-7]: " choice
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
            echo "AUTO_KILL=$AUTO_KILL" > "$CONFIG_FILE"
            echo "CPU_SINGLE_LIMIT=$CPU_SINGLE_LIMIT" >> "$CONFIG_FILE"
            echo "CPU_AGGREGATE_LIMIT=$CPU_AGGREGATE_LIMIT" >> "$CONFIG_FILE"
            echo -e "${GREEN}Auto-Kill set to: $AUTO_KILL${NC}"
            ;;
        5) generate_slurm_template ;;
        6) install_alias ;;
        7) [ -f "$LOG_FILE" ] && tail -n 25 "$LOG_FILE" || echo "No logs yet." ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}" ;;
    esac
}

# --- CLI Parameter Router ---
case "$1" in
    exec)
        shift
        cmd_exec_guard "$@"
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
    install-alias)
        install_alias
        ;;
    *)
        show_menu
        ;;
esac
