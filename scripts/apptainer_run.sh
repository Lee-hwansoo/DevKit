#!/bin/bash
# =============================================================================
# scripts/apptainer_run.sh
# Intelligent SIF Execution Engine with Shadowing Bind Strategy
# =============================================================================

# Load path configuration
[ -f "/workspace/config/util_paths.sh" ] && source "/workspace/config/util_paths.sh"
[ -z "$WS_ROOT" ] && source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh"

# Environment detection
eval $(bash "${WS_SCRIPTS}/check_env.sh")

# Load logging utility
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="$(dirname "${BASH_SOURCE[0]}")/util_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG" || true

SIF_FILE="${COMPOSE_PROJECT_NAME}.sif"

if [ ! -f "$SIF_FILE" ]; then
    log_error "SIF not found: $SIF_FILE"
    exit 1
fi

# 1. Intelligent Binds (Fresh Source & Configs | Fixed Build & Install)
BIND_UTIL="${WS_SCRIPTS}/util_apptainer_binds.sh"
[ ! -f "$BIND_UTIL" ] && BIND_UTIL="$(dirname "${BASH_SOURCE[0]}")/util_apptainer_binds.sh"

if [ -f "$BIND_UTIL" ]; then
    source "$BIND_UTIL"
    BIND_OPTS=( $(get_apptainer_binds "${HOST_WORKSPACE_PATH}" "${WS_ROOT}") )
else
    BIND_OPTS=( "--bind" "${HOST_WORKSPACE_PATH}:${WS_ROOT}" )
fi

# 2. Hardware & System Acceleration
GPU_FLAG=""
if [ "$HAS_NVIDIA" = "true" ]; then
    GPU_FLAG="--nv"
elif command -v rocm-smi >/dev/null 2>&1; then
    GPU_FLAG="--rocm"
fi

if [ "$HAS_DRI" = "true" ] && [ -d "/dev/dri" ]; then
    BIND_OPTS+=( "--bind" "/dev/dri:/dev/dri" )
fi

if [ "$IS_WSL" = "true" ]; then
    [ -e "/dev/dxg" ] && BIND_OPTS+=( "--bind" "/dev/dxg:/dev/dxg" )
    [ -d "/usr/lib/wsl" ] && BIND_OPTS+=( "--bind" "/usr/lib/wsl:/usr/lib/wsl:ro" )
fi

# 3. SSH Agent Forwarding
if [ -n "$HOST_SSH_AUTH_SOCK" ] && [ -S "$HOST_SSH_AUTH_SOCK" ]; then
    BIND_OPTS+=( "--bind" "${HOST_SSH_AUTH_SOCK}:/tmp/ssh-auth.sock" )
    export SSH_AUTH_SOCK="/tmp/ssh-auth.sock"
fi

log_info "Launching ${SIF_FILE}..."

apptainer run $GPU_FLAG "${BIND_OPTS[@]}" "$SIF_FILE" "$@"
