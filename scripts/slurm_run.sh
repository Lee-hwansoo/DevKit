#!/bin/bash
#SBATCH --job-name=devkit
#SBATCH --partition=local
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=4
#SBATCH --time=00:30:00
#SBATCH --output=logs/%x_%j.out
#SBATCH --error=logs/%x_%j.err
#SBATCH --comment=submitter:devkit

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || source "/tmp/util_paths.sh"

usage() {
    cat <<'EOF'
Usage: slurm_run.sh [command...]

Internal SLURM job entrypoint for production SIF execution.
Set ROS_LAUNCH_COMMAND, APP_COMMAND, or pass an explicit command.

Options:
  DEVKIT_DRY_RUN=1 validates and prints the planned container run.
  -h, --help Show this help.
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --) shift ;;
esac

devkit_require "util_sif_runtime.sh"
devkit_require "util_logging.sh"

HOST_WORKSPACE="${HOST_WORKSPACE:-$(pwd)}"
CONTAINER_WORKSPACE="${WORKSPACE_PATH:-/workspace}"
CONTAINER_DATA_ROOT="${CONTAINER_DATA_ROOT:-${CONTAINER_WORKSPACE}/data}"
CONTAINER_RUN_ROOT="${CONTAINER_RUN_ROOT:-/runs}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
validate_image_tag "$IMAGE_TAG"
PROJECT_NAME="$(resolve_sif_project_name "$HOST_WORKSPACE")"
SIF_ENV="${ENV:-ros}"
validate_sif_env "$SIF_ENV"
SIF_IMAGE="${SIF_FILE:-$(default_sif_file slurm "$SIF_ENV" "$PROJECT_NAME" "$IMAGE_TAG")}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$PROJECT_NAME}"
WORKSPACE_PATH="$CONTAINER_WORKSPACE"
ENV="$SIF_ENV"
ROS_DISTRO="${ROS_DISTRO:-humble}"
ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
sif_forward_env_vars \
    WORKSPACE_PATH ENV COMPOSE_PROJECT_NAME IMAGE_TAG GPU_MODE HAS_NVIDIA HAS_DRI \
    ROS_DISTRO ROS_DOMAIN_ID RMW_IMPLEMENTATION ROS_MASTER_URI ROS_HOSTNAME ROS_IP \
    APP_COMMAND ROS_LAUNCH_COMMAND

mkdir -p -- logs
if ! has_sif_entry_command "$#"; then
    echo "No production command configured. Set ROS_LAUNCH_COMMAND, APP_COMMAND, or pass an explicit command." >&2
    exit 64
fi

BIND_OPTS=()

if [ -n "${SLURM_DATA_ROOT:-}" ] && [ -d "${SLURM_DATA_ROOT}" ]; then
    BIND_OPTS+=( "--bind" "${SLURM_DATA_ROOT}:${CONTAINER_DATA_ROOT}:ro" )
fi

if [ -n "${SLURM_RUN_ROOT:-}" ]; then
    mkdir -p -- "${SLURM_RUN_ROOT}"
    BIND_OPTS+=( "--bind" "${SLURM_RUN_ROOT}:${CONTAINER_RUN_ROOT}" )
fi

GPU_OPTS=()
get_sif_gpu_opts_into GPU_OPTS probe

CURRENT_JOB_ID="${SLURM_JOB_ID:-LOCAL_TEST}"
JOB_NAME="${SLURM_JOB_NAME:-devkit}"
PARTITION="${SLURM_JOB_PARTITION:-local}"
NODELIST="${SLURM_JOB_NODELIST:-localhost}"
NODE_COUNT="${SLURM_NNODES:-1}"
TASK_COUNT="${SLURM_NTASKS:-1}"
CPUS_PER_TASK="${SLURM_CPUS_PER_TASK:-4}"
GPUS_PER_NODE="${SLURM_GPUS_ON_NODE:-${SLURM_GPUS_PER_NODE:-${SLURM_GPUS:-gpu:1}}}"
TIME_LIMIT="${SLURM_TIMELIMIT:-${SLURM_JOB_TIME_LIMIT:-00:30:00}}"
JOB_COMMENT="${SLURM_JOB_COMMENT:-submitter:devkit}"
STDOUT_LOG="logs/${JOB_NAME}_${CURRENT_JOB_ID}.out"
STDERR_LOG="logs/${JOB_NAME}_${CURRENT_JOB_ID}.err"

echo "====================================================================="
echo "SLURM Job Execution Summary"
echo "====================================================================="
echo " - Job ID          : ${CURRENT_JOB_ID}"
echo " - Job Name        : ${JOB_NAME}"
echo " - Partition       : ${PARTITION}"
echo " - Allocated Node  : ${NODELIST} (Total: ${NODE_COUNT} nodes)"
echo " - Tasks & CPUs    : ${TASK_COUNT} tasks, ${CPUS_PER_TASK} CPUs/task"
echo " - GPUs per Node   : ${GPUS_PER_NODE}"
echo " - Time Limit      : ${TIME_LIMIT}"
echo " - Comment / Tag   : ${JOB_COMMENT}"
echo "---------------------------------------------------------------------"
echo "Log Files"
echo "---------------------------------------------------------------------"
echo " - Standard Output : ${STDOUT_LOG}"
echo " - Standard Error  : ${STDERR_LOG}"
echo "---------------------------------------------------------------------"
echo "Container & Path Mapping"
echo "---------------------------------------------------------------------"
echo " - SIF Image       : ${SIF_IMAGE}"
echo " - Project Root    : ${HOST_WORKSPACE}"
echo " - Image Workspace : ${CONTAINER_WORKSPACE} (embedded in production SIF)"
[ -d "${SLURM_DATA_ROOT:-}" ] && echo " - Data (ro)       : ${SLURM_DATA_ROOT} -> ${CONTAINER_DATA_ROOT}"
[ -n "${SLURM_RUN_ROOT:-}" ] && [ -d "${SLURM_RUN_ROOT}" ] && echo " - Runs/Logs       : ${SLURM_RUN_ROOT} -> ${CONTAINER_RUN_ROOT}"
echo "====================================================================="
echo ""

if sif_dry_run; then
    echo "[OK] Dry-run completed; SIF runtime was not executed."
    exit 0
fi

[ -f "${SIF_IMAGE}" ] || { echo "SIF image not found: ${SIF_IMAGE}"; exit 1; }
SIF_RUNTIME="$(resolve_sif_runtime)"
warn_sif_runtime_mount_constraints "$SIF_RUNTIME"
ERR_FILE="$(mktemp /tmp/devkit_sif_job.XXXXXX.err)"
trap 'rm -f "$ERR_FILE"' EXIT
if "$SIF_RUNTIME" run "${GPU_OPTS[@]}" \
    "${BIND_OPTS[@]}" \
    "${SIF_IMAGE}" \
    "$@" 2> >(tee "$ERR_FILE" >&2); then
    :
else
    rc=$?
    explain_sif_runtime_failure "$ERR_FILE"
    exit "$rc"
fi
