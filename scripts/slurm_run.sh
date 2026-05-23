#!/bin/bash
#SBATCH --job-name=devkit
#SBATCH --partition=partition-3090-intel
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=4
#SBATCH --time=00:30:00
#SBATCH --output=logs/%x_%j.out
#SBATCH --error=logs/%x_%j.err
#SBATCH --comment=submitter:devkit

set -euo pipefail

# Load configurations from .env if available on host
if [ -f ".env" ]; then
    # Safely export environment variables from .env
    export $(grep -v '^#' .env | xargs)
fi

# =============================================================================
# Host Path Configurations (호스트 서버의 물리적 경로 설정)
# =============================================================================
# 1. 호스트 내 DevKit 프로젝트 워크스페이스 루트 경로
HOST_WORKSPACE="$(pwd)"

# 2. 호스트 내 대용량 실제 데이터셋 저장소 경로
HOST_REAL_DATA_ROOT="${HOST_DATA_ROOT:-/home/dataset}"

# 3. 호스트 내 학습 Tensorboard 로그/결과물이 저장될 경로
HOST_RUN_ROOT="${HOST_RUN_ROOT:-/home/runs}"

# 4. 호스트 내 Apptainer SIF 이미지 파일 경로
PROJ_NAME="${COMPOSE_PROJECT_NAME:-devkit}"
SIF_IMAGE="./${PROJ_NAME}.sif"

# Create a local logs directory on the host if it does not exist
mkdir -p logs

# =============================================================================
# Container Internal Path Configurations (컨테이너 내부의 논리적 경로 설정)
# =============================================================================
# 1. 컨테이너 내부의 워크스페이스 루트 경로 (SSOT)
CONTAINER_WORKSPACE="/workspace"

# 2. 컨테이너 내부에서 실행할 파일 경로
CONTAINER_ENTRYPOINT="${CONTAINER_WORKSPACE}/scripts/slurm_entrypoint.sh"

# 3. 컨테이너 내부에서 데이터셋을 읽어올 매핑 경로
CONTAINER_DATA_ROOT="${CONTAINER_WORKSPACE}/src/carmaker_image/data"

# 4. 컨테이너 내부에서 로그를 출력할 매핑 경로
CONTAINER_RUN_ROOT="/runs"

# SIF 파일 존재 유무 검증
[ -f "${SIF_IMAGE}" ] || { echo "SIF image not found: ${SIF_IMAGE}"; exit 1; }

# =============================================================================
# Intelligent Bind Mapping (Shadowing Bind Strategy)
# =============================================================================
# SIF 내부에 구워진 빌드본(install, build, .venv)을 보존하기 위한 스마트 필터
EXCLUDES="^(build|install|devel|log|.docker_cache|colcon.meta|.venv|compile_commands.json|.*\.sif)$"
BIND_OPTS=()

# Enable nullglob (so unmatched globs return empty rather than literal pattern)
# and dotglob (to match hidden files, excluding . and ..)
shopt -s nullglob dotglob

for item in "${HOST_WORKSPACE}"/*; do
    [ -e "$item" ] || continue
    name=$(basename "$item")
    [[ "$name" =~ $EXCLUDES ]] && continue
    BIND_OPTS+=( "--bind" "${item}:${CONTAINER_WORKSPACE}/${name}" )
done

shopt -u nullglob dotglob

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
echo "Submitting Apptainer Job to SLURM..."
echo " - SIF: ${SIF_IMAGE}"
echo " - Workspace: ${HOST_WORKSPACE} -> ${CONTAINER_WORKSPACE}"
[ -d "${HOST_REAL_DATA_ROOT}" ] && echo " - Data: ${HOST_REAL_DATA_ROOT} -> ${CONTAINER_DATA_ROOT} (ro)"
[ -d "${HOST_RUN_ROOT}" ] && echo " - Runs: ${HOST_RUN_ROOT} -> ${CONTAINER_RUN_ROOT}"

# Execute inside the SIF container using GPU acceleration
apptainer exec --nv \
    "${BIND_OPTS[@]}" \
    "${SIF_IMAGE}" \
    torchrun --standalone --nproc_per_node="${SLURM_GPUS_ON_NODE:-2}" \
        "${CONTAINER_ENTRYPOINT}" \
        --data-root "${CONTAINER_DATA_ROOT}" \
        --run-base "${CONTAINER_RUN_ROOT}"
