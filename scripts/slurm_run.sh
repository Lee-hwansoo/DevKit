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

# =============================================================================
# User-Defined Configurations (사용자 정의 설정 - 실행 환경에 맞게 직접 수정하세요)
# =============================================================================
# 1. 호스트 내 Apptainer SIF 이미지 파일 경로 (빌드된 SIF 파일명 지정)
SIF_IMAGE="./devkit.sif"

# 2. 호스트 내 대용량 실제 데이터셋 저장소 경로
HOST_REAL_DATA_ROOT="/home/dataset"

# 3. 호스트 내 학습 로그/결과물이 저장될 경로
HOST_RUN_ROOT="/home/runs"

# 4. 호스트 내 DevKit 프로젝트 워크스페이스 루트 경로 (기본값: 현재 작업 폴더)
HOST_WORKSPACE="$(pwd)"

# Create a local logs directory on the host if it does not exist
mkdir -p logs

# =============================================================================
# Container Internal Path Configurations (컨테이너 내부의 논리적 경로 설정)
# =============================================================================
# 1. 컨테이너 내부의 워크스페이스 루트 경로 (SSOT)
CONTAINER_WORKSPACE="/workspace"

# 2. 컨테이너 내부에서 실행할 파일 경로
CONTAINER_ENTRYPOINT="${CONTAINER_WORKSPACE}/slurm_entrypoint.sh"

# 3. 컨테이너 내부에서 데이터셋을 읽어올 매핑 경로
CONTAINER_DATA_ROOT="${CONTAINER_WORKSPACE}/data"

# 4. 컨테이너 내부에서 로그를 출력할 매핑 경로
CONTAINER_RUN_ROOT="/runs"

# SIF 파일 존재 유무 검증
[ -f "${SIF_IMAGE}" ] || { echo "SIF image not found: ${SIF_IMAGE}"; exit 1; }

# =============================================================================
# Intelligent Bind Mapping (Fresh Source & Configs | Fixed Build & Install)
# =============================================================================
BIND_UTIL="${HOST_WORKSPACE}/scripts/util_apptainer_binds.sh"
if [ -f "$BIND_UTIL" ]; then
    source "$BIND_UTIL"
    BIND_OPTS=( $(get_apptainer_binds "${HOST_WORKSPACE}" "${CONTAINER_WORKSPACE}") )
else
    BIND_OPTS=( "--bind" "${HOST_WORKSPACE}:${CONTAINER_WORKSPACE}" )
fi

# Bind custom data and logs if they exist on the host
if [ -d "${HOST_REAL_DATA_ROOT}" ]; then
    BIND_OPTS+=( "--bind" "${HOST_REAL_DATA_ROOT}:${CONTAINER_DATA_ROOT}:ro" )
fi
if [ -d "${HOST_RUN_ROOT}" ]; then
    BIND_OPTS+=( "--bind" "${HOST_RUN_ROOT}:${CONTAINER_RUN_ROOT}" )
fi

# =============================================================================
# Execution Context
# =============================================================================
CURRENT_JOB_ID="${SLURM_JOB_ID:-LOCAL_TEST}"
JOB_NAME="${SLURM_JOB_NAME:-devkit}"
GPUS_PER_NODE="${SLURM_GPUS_ON_NODE:-1}"

if [ -n "${SLURM_JOB_TIME_LIMIT:-}" ]; then
    TIME_LIMIT="${SLURM_JOB_TIME_LIMIT} minutes"
else
    TIME_LIMIT="00:30:00 (Default)"
fi

echo ""
echo "====================================================================="
echo " 🚀 SLURM Job Execution Summary"
echo "====================================================================="
echo " - Job ID          : ${CURRENT_JOB_ID}"
echo " - Job Name        : ${JOB_NAME}"
echo " - Partition       : ${SLURM_JOB_PARTITION:-local}"
echo " - Allocated Node  : ${SLURM_JOB_NODELIST:-localhost} (Total: ${SLURM_NNODES:-1} nodes)"
echo " - Tasks & CPUs    : ${SLURM_NTASKS:-1} tasks, ${SLURM_CPUS_PER_TASK:-4} CPUs/task"
echo " - GPUs per Node   : ${GPUS_PER_NODE}"
echo " - Time Limit      : ${TIME_LIMIT}"
echo " - Comment / Tag   : ${SLURM_JOB_COMMENT:-submitter:devkit}"
echo "---------------------------------------------------------------------"
echo " 📝 Log Files"
echo "---------------------------------------------------------------------"
echo " - Standard Output : logs/${JOB_NAME}_${CURRENT_JOB_ID}.out"
echo " - Standard Error  : logs/${JOB_NAME}_${CURRENT_JOB_ID}.err"
echo "---------------------------------------------------------------------"
echo " 📦 Container & Path Mapping"
echo "---------------------------------------------------------------------"
echo " - SIF Image       : ${SIF_IMAGE}"
echo " - Workspace       : ${HOST_WORKSPACE} -> ${CONTAINER_WORKSPACE}"
[ -d "${HOST_REAL_DATA_ROOT}" ] && echo " - Data (ro)       : ${HOST_REAL_DATA_ROOT} -> ${CONTAINER_DATA_ROOT}"
[ -d "${HOST_RUN_ROOT}" ] && echo " - Runs/Logs       : ${HOST_RUN_ROOT} -> ${CONTAINER_RUN_ROOT}"
echo "====================================================================="
echo ""

# Detect GPU acceleration flag for the cluster node
GPU_FLAG=""
if command -v nvidia-smi >/dev/null 2>&1; then
    GPU_FLAG="--nv"
elif command -v rocm-smi >/dev/null 2>&1; then
    GPU_FLAG="--rocm"
fi

# Execute inside the SIF container using GPU acceleration
apptainer exec $GPU_FLAG \
    "${BIND_OPTS[@]}" \
    "${SIF_IMAGE}" \
    /entrypoint.sh \
    torchrun --standalone --nproc_per_node="${GPUS_PER_NODE}" \
        "${CONTAINER_ENTRYPOINT}" \
        --data-root "${CONTAINER_DATA_ROOT}" \
        --run-base "${CONTAINER_RUN_ROOT}"
