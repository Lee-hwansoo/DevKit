#!/bin/bash
# =============================================================================
# scripts/apptainer_bake.sh
# Automated Baking Pipeline: Docker -> mksync -> Apptainer SIF
# =============================================================================

# Load path configuration
[ -f "/workspace/config/util_paths.sh" ] && source "/workspace/config/util_paths.sh"
[ -z "$WS_ROOT" ] && source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh"

# Environment detection for Docker build args
eval $(bash "${WS_SCRIPTS}/check_env.sh")

# Load logging utility
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="$(dirname "${BASH_SOURCE[0]}")/util_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG" || true

PROD_MODE="false"
SYNC_MODE=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --prod) PROD_MODE="true" ;;
        --share) SYNC_MODE="--share" ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

IMAGE_NAME="${COMPOSE_PROJECT_NAME}_frozen:latest"
SIF_FILE="${COMPOSE_PROJECT_NAME}.sif"

log_info "Baking ${SIF_FILE} (Sync: ${SYNC_MODE:-standard}, Prod: ${PROD_MODE})..."

set -e

# 1. Detect Base Image (Prefer ROS, fallback to Basic)
BASE_IMAGE="${COMPOSE_PROJECT_NAME}/ros:latest"
if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    BASE_IMAGE="${COMPOSE_PROJECT_NAME}/basic:latest"
fi

# 2. Internalize Workspace & Fix Scripts
log_info "[1/2] Internalizing workspace into Docker image..."
docker build -t "$IMAGE_NAME" --build-arg FULL_CUDA="${FULL_CUDA:-false}" -f - . <<EOF
FROM ${BASE_IMAGE}
COPY . ${WS_ROOT}
RUN bash -i -c "mksync ${SYNC_MODE}"
RUN if [ "${PROD_MODE}" = "true" ]; then \
        echo "Optimizing and securing production image..." && \
        if python3 -m compileall -q -b ${WS_ROOT}/src; then \
            find ${WS_ROOT}/src -type f \( -name "*.py" -o -name "*.cpp" -o -name "*.cc" -o -name "*.c" -o -name "*.hpp" -o -name "*.h" \) -delete && \
            echo "Source code stripped. Bytecode compilation completed."; \
        else \
            echo "Error: Python bytecode compilation failed. Aborting." && exit 1; \
        fi \
    fi
WORKDIR ${WS_ROOT}
EOF

# 3. Convert to SIF & Cleanup
log_info "[2/2] Converting to Apptainer SIF..."
apptainer build --force "$SIF_FILE" docker-daemon://"$IMAGE_NAME"

docker rmi "$IMAGE_NAME" 2>/dev/null || true
log_ok "Baking completed: ${SIF_FILE}"
