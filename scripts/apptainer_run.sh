#!/bin/bash
# =============================================================================
# scripts/apptainer_run.sh
# Run dev/prod SIF artifacts or submit production SIF to SLURM.
# =============================================================================

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || source "/tmp/util_paths.sh"
devkit_require "util_sif_runtime.sh"
init_sif_context "$(dirname "${BASH_SOURCE[0]}")"
devkit_require "util_logging.sh"

MODE="${SIF_MODE:-dev}"
SIF_ENV="${ENV:-ros}"
usage() {
    cat <<'EOF'
Usage: apptainer_run.sh [--mode dev|prod|slurm] [--env ros|dev] [command...]

Run a SIF artifact locally or submit it to SLURM.

Options:
  --mode   Run mode. Default: SIF_MODE or dev.
  --env    Image family to run. Default: ENV or ros.
  DEVKIT_DRY_RUN=1 validates and prints the planned run without executing it.
  -h, --help Show this help.
EOF
}

sbatch_directive_value() {
    local script="$1"
    local key="$2"
    local fallback="$3"

    awk -v key="$key" -v fallback="$fallback" '
        $1 == "#SBATCH" {
            for (i = 2; i <= NF; i++) {
                if ($i ~ "^--" key "=") {
                    sub("^--" key "=", "", $i)
                    print $i
                    found = 1
                    exit
                }
            }
        }
        END {
            if (!found) {
                print fallback
            }
        }
    ' "$script"
}

slurm_request_value() {
    local script="$1"
    local env_name="$2"
    local directive_key="$3"
    local fallback="$4"
    local env_value="${!env_name-}"

    if [ -n "$env_value" ]; then
        printf '%s\n' "$env_value"
    else
        sbatch_directive_value "$script" "$directive_key" "$fallback"
    fi
}

build_sbatch_args() {
    SBATCH_ARGS=(
        "--job-name=${SLURM_JOB_NAME_REQ}"
        "--partition=${SLURM_PARTITION_REQ}"
        "--nodes=${SLURM_NODES_REQ}"
        "--ntasks=${SLURM_NTASKS_REQ}"
        "--gres=${SLURM_GRES_REQ}"
        "--cpus-per-task=${SLURM_CPUS_PER_TASK_REQ}"
        "--time=${SLURM_TIME_REQ}"
        "--output=${SLURM_OUTPUT_REQ}"
        "--error=${SLURM_ERROR_REQ}"
        "--comment=${SLURM_COMMENT_REQ}"
        "--chdir=${HOST_ROOT}"
        "--export=ALL"
    )
}

ensure_slurm_log_dirs() {
    local log_path
    local log_dir

    for log_path in "$SLURM_OUTPUT_REQ" "$SLURM_ERROR_REQ"; do
        [ -n "$log_path" ] || continue
        [ "$log_path" = "/dev/null" ] && continue
        log_dir="${log_path%/*}"
        [ "$log_dir" = "$log_path" ] && continue
        mkdir -p -- "$log_dir"
    done
}

load_slurm_request() {
    local script="$1"

    SLURM_JOB_NAME_REQ="$(slurm_request_value "$script" DEVKIT_SLURM_JOB_NAME job-name devkit)"
    SLURM_PARTITION_REQ="$(slurm_request_value "$script" DEVKIT_SLURM_PARTITION partition local)"
    SLURM_NODES_REQ="$(slurm_request_value "$script" DEVKIT_SLURM_NODES nodes 1)"
    SLURM_NTASKS_REQ="$(slurm_request_value "$script" DEVKIT_SLURM_NTASKS ntasks 1)"
    SLURM_GRES_REQ="$(slurm_request_value "$script" DEVKIT_SLURM_GRES gres gpu:1)"
    SLURM_CPUS_PER_TASK_REQ="$(slurm_request_value "$script" DEVKIT_SLURM_CPUS_PER_TASK cpus-per-task 4)"
    SLURM_TIME_REQ="$(slurm_request_value "$script" DEVKIT_SLURM_TIME time 00:30:00)"
    SLURM_OUTPUT_REQ="$(slurm_request_value "$script" DEVKIT_SLURM_OUTPUT output logs/%x_%j.out)"
    SLURM_ERROR_REQ="$(slurm_request_value "$script" DEVKIT_SLURM_ERROR error logs/%x_%j.err)"
    SLURM_COMMENT_REQ="$(slurm_request_value "$script" DEVKIT_SLURM_COMMENT comment submitter:devkit)"
}

print_slurm_submit_summary() {
    local container_data_root="${CONTAINER_DATA_ROOT:-${CONTAINER_WORKSPACE_PATH}/data}"
    local container_run_root="${CONTAINER_RUN_ROOT:-/runs}"
    shift

    echo "====================================================================="
    echo "SLURM Submission Request"
    echo "====================================================================="
    echo " - Job Name        : ${SLURM_JOB_NAME_REQ}"
    echo " - Partition       : ${SLURM_PARTITION_REQ}"
    echo " - Nodes           : ${SLURM_NODES_REQ}"
    echo " - Tasks & CPUs    : ${SLURM_NTASKS_REQ} tasks, ${SLURM_CPUS_PER_TASK_REQ} CPUs/task"
    echo " - GPU Request     : ${SLURM_GRES_REQ}"
    echo " - Time Limit      : ${SLURM_TIME_REQ}"
    echo " - Comment / Tag   : ${SLURM_COMMENT_REQ}"
    echo "---------------------------------------------------------------------"
    echo "Log Files"
    echo "---------------------------------------------------------------------"
    echo " - Standard Output : ${SLURM_OUTPUT_REQ}"
    echo " - Standard Error  : ${SLURM_ERROR_REQ}"
    echo "---------------------------------------------------------------------"
    echo "Container & Command"
    echo "---------------------------------------------------------------------"
    echo " - SIF Image       : ${SIF_FILE}"
    echo " - Project Root    : ${HOST_WORKSPACE_PATH}"
    echo " - Image Workspace : ${CONTAINER_WORKSPACE_PATH} (embedded in production SIF)"
    echo " - Container Env   : WORKSPACE_PATH=${CONTAINER_WORKSPACE_PATH}, ROS_DISTRO=${ROS_DISTRO:-humble}, ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-0}, RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}, GPU_MODE=${GPU_MODE:-auto}"
    [ -n "${SLURM_DATA_ROOT:-}" ] && echo " - Data (ro)       : ${SLURM_DATA_ROOT} -> ${container_data_root}"
    [ -n "${SLURM_RUN_ROOT:-}" ] && echo " - Runs/Logs       : ${SLURM_RUN_ROOT} -> ${container_run_root}"
    if [ "$#" -gt 0 ]; then
        echo " - Command         : $*"
    elif [ -n "${ROS_LAUNCH_COMMAND:-}" ]; then
        echo " - Command         : ROS_LAUNCH_COMMAND=${ROS_LAUNCH_COMMAND}"
    elif [ -n "${APP_COMMAND:-}" ]; then
        echo " - Command         : APP_COMMAND=${APP_COMMAND}"
    fi
    echo "---------------------------------------------------------------------"
    echo "Exact sbatch Options"
    echo "---------------------------------------------------------------------"
    printf ' -'
    printf ' %q' "${SBATCH_ARGS[@]}"
    echo
    echo "====================================================================="
}

print_local_run_summary() {
    echo "====================================================================="
    echo "SIF Run Request"
    echo "====================================================================="
    echo " - Mode            : ${MODE}"
    echo " - Environment     : ${SIF_ENV}"
    echo " - SIF Image       : ${SIF_FILE}"
    if [ "$MODE" = "dev" ]; then
        echo " - Workspace       : ${HOST_WORKSPACE_PATH} -> ${CONTAINER_WORKSPACE_PATH}"
    else
        echo " - Project Root    : ${HOST_WORKSPACE_PATH}"
        echo " - Image Workspace : ${CONTAINER_WORKSPACE_PATH} (embedded in production SIF)"
    fi
    echo " - Container Env   : WORKSPACE_PATH=${CONTAINER_WORKSPACE_PATH}, ROS_DISTRO=${ROS_DISTRO:-humble}, ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-0}, RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}, GPU_MODE=${GPU_MODE:-auto}"
    [ "${#GPU_OPTS[@]}" -gt 0 ] && printf ' - GPU Options     : %q\n' "${GPU_OPTS[@]}"
    if [ "${#BIND_OPTS[@]}" -gt 0 ]; then
        echo " - Bind Count      : $((${#BIND_OPTS[@]} / 2))"
        echo " - Bind Options"
        local idx
        for ((idx = 0; idx < ${#BIND_OPTS[@]}; idx += 2)); do
            printf '   '
            printf ' %q' "${BIND_OPTS[idx]}" "${BIND_OPTS[idx + 1]}"
            echo
        done
    fi
    if [ "$#" -gt 0 ]; then
        echo " - Command         : $*"
    elif [ -n "${ROS_LAUNCH_COMMAND:-}" ]; then
        echo " - Command         : ROS_LAUNCH_COMMAND=${ROS_LAUNCH_COMMAND}"
    elif [ -n "${APP_COMMAND:-}" ]; then
        echo " - Command         : APP_COMMAND=${APP_COMMAND}"
    else
        echo " - Command         : default image command"
    fi
    echo "====================================================================="
}

add_host_integration_binds() {
    if [ -n "${DISPLAY:-}" ]; then
        if [ -n "${HOST_X11_DIR:-}" ] && [ -d "${HOST_X11_DIR}" ]; then
            BIND_OPTS+=( "--bind" "${HOST_X11_DIR}:/tmp/.X11-unix" )
        fi
        if [ -n "${HOST_XAUTHORITY:-}" ] && [ -f "${HOST_XAUTHORITY}" ]; then
            BIND_OPTS+=( "--bind" "${HOST_XAUTHORITY}:/tmp/.container_xauth:ro" )
            sif_set_container_env XAUTHORITY "/tmp/.container_xauth"
        fi
        sif_set_container_env DISPLAY "${DISPLAY}"
        sif_set_container_env QT_X11_NO_MITSHM "1"
    fi

    if [ -n "${HOST_XDG_RUNTIME_DIR:-}" ] && [ -d "${HOST_XDG_RUNTIME_DIR}" ]; then
        BIND_OPTS+=( "--bind" "${HOST_XDG_RUNTIME_DIR}:/tmp/.container_xdg" )
        sif_set_container_env XDG_RUNTIME_DIR "/tmp/.container_xdg"
    fi

    if [ -n "${HOST_WAYLAND_DISPLAY:-}" ]; then
        sif_set_container_env WAYLAND_DISPLAY "${HOST_WAYLAND_DISPLAY}"
    fi
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --mode) require_sif_option_value "$1" "${2:-}" || { usage; exit 2; }; MODE="$2"; shift 2 ;;
        --env) require_sif_option_value "$1" "${2:-}" || { usage; exit 2; }; SIF_ENV="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        *) break ;;
    esac
done

validate_sif_env "$SIF_ENV" || exit 1
validate_sif_mode "$MODE" || exit 1

source_detected_env "${WS_SCRIPTS}/check_env.sh"
apply_sif_detected_env_defaults
IMAGE_TAG="${IMAGE_TAG:-latest}"
validate_image_tag "$IMAGE_TAG"
COMPOSE_PROJECT_NAME="$(resolve_sif_project_name "${HOST_ROOT}")"

SIF_FILE="${SIF_FILE:-$(default_sif_file "$MODE" "$SIF_ENV" "$COMPOSE_PROJECT_NAME" "$IMAGE_TAG" "${SHARE:-}")}"
WORKSPACE_PATH="${CONTAINER_WORKSPACE_PATH}"
ENV="${SIF_ENV}"
ROS_DISTRO="${ROS_DISTRO:-humble}"
ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
sif_forward_env_vars \
    WORKSPACE_PATH ENV COMPOSE_PROJECT_NAME IMAGE_TAG GPU_MODE HAS_NVIDIA HAS_DRI \
    ROS_DISTRO ROS_DOMAIN_ID RMW_IMPLEMENTATION ROS_MASTER_URI ROS_HOSTNAME ROS_IP \
    APP_COMMAND ROS_LAUNCH_COMMAND

if [ "$MODE" = "slurm" ]; then
    if ! has_sif_entry_command "$#"; then
        log_error "SLURM run requires ROS_LAUNCH_COMMAND, APP_COMMAND, or an explicit command."
        exit 64
    fi
    HOST_WORKSPACE="${HOST_WORKSPACE_PATH}"
    export SIF_FILE HOST_WORKSPACE WORKSPACE_PATH ENV IMAGE_TAG COMPOSE_PROJECT_NAME
    SLURM_SCRIPT="${HOST_ROOT}/scripts/slurm_run.sh"
    load_slurm_request "$SLURM_SCRIPT"
    build_sbatch_args
    ensure_slurm_log_dirs
    print_slurm_submit_summary "$SLURM_SCRIPT" "$@"
    if sif_dry_run; then
        log_ok "Dry-run completed; sbatch was not executed."
        exit 0
    fi
    if ! command -v sbatch >/dev/null 2>&1; then
        log_error "SLURM binary 'sbatch' not found. Run on a SLURM login node."
        exit 1
    fi
    sbatch "${SBATCH_ARGS[@]}" "$SLURM_SCRIPT" "$@"
    exit $?
fi

if [ "$MODE" = "prod" ] && ! has_sif_entry_command "$#"; then
    log_error "Production run requires ROS_LAUNCH_COMMAND, APP_COMMAND, or an explicit command."
    exit 64
fi

GPU_OPTS=()
get_sif_gpu_opts_into GPU_OPTS

BIND_OPTS=()
if [ "$MODE" = "dev" ]; then
    if devkit_require "util_apptainer_binds.sh"; then
        get_apptainer_binds_into BIND_OPTS "${HOST_WORKSPACE_PATH}" "${CONTAINER_WORKSPACE_PATH}"
    else
        BIND_OPTS=( "--bind" "${HOST_WORKSPACE_PATH}:${CONTAINER_WORKSPACE_PATH}" )
    fi

    if [ -n "$HOST_SSH_AUTH_SOCK" ] && [ -S "$HOST_SSH_AUTH_SOCK" ]; then
        BIND_OPTS+=( "--bind" "${HOST_SSH_AUTH_SOCK}:/tmp/ssh-auth.sock" )
        sif_set_container_env SSH_AUTH_SOCK "/tmp/ssh-auth.sock"
    fi
fi

add_host_integration_binds

if [ "$HAS_DRI" = "true" ] && [ -d "/dev/dri" ]; then
    BIND_OPTS+=( "--bind" "/dev/dri:/dev/dri" )
fi

if [ "$IS_WSL" = "true" ]; then
    [ -e "/dev/dxg" ] && BIND_OPTS+=( "--bind" "/dev/dxg:/dev/dxg" )
    [ -d "/usr/lib/wsl" ] && BIND_OPTS+=( "--bind" "/usr/lib/wsl:/usr/lib/wsl:ro" )
fi

if sif_dry_run; then
    log_info "Planning ${SIF_FILE} (mode=${MODE})..."
    print_local_run_summary "$@"
    log_ok "Dry-run completed; SIF runtime was not executed."
    exit 0
fi

log_info "Launching ${SIF_FILE} (mode=${MODE})..."
SIF_RUNTIME="$(resolve_sif_runtime)"
[ -f "$SIF_FILE" ] || { log_error "SIF not found: $SIF_FILE"; exit 1; }
warn_sif_runtime_mount_constraints "$SIF_RUNTIME"
ERR_FILE="$(mktemp /tmp/devkit_sif_run.XXXXXX.err)"
trap 'rm -f "$ERR_FILE"' EXIT
if "$SIF_RUNTIME" run "${GPU_OPTS[@]}" "${BIND_OPTS[@]}" "$SIF_FILE" "$@" 2> >(tee "$ERR_FILE" >&2); then
    :
else
    rc=$?
    explain_sif_runtime_failure "$ERR_FILE"
    exit "$rc"
fi
