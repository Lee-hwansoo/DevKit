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
EXCLUDES="^(build|install|devel|log|.docker_cache|colcon.meta|.venv|compile_commands.json|.*\.sif)$"
BIND_OPTS=()

shopt -s nullglob dotglob
for item in "${HOST_WORKSPACE_PATH}"/*; do
    [ -e "$item" ] || continue
    name=$(basename "$item")
    [[ "$name" =~ $EXCLUDES ]] && continue
    BIND_OPTS+=( "--bind" "${item}:${WS_ROOT}/${name}" )
done
shopt -u nullglob dotglob

# 2. Hardware & System Acceleration
GPU_FLAG=$([ "$HAS_NVIDIA" = "true" ] && echo "--nv")
[ "$IS_WSL" = "true" ] && [ -d "/usr/lib/wsl" ] && BIND_OPTS+=( "--bind" "/usr/lib/wsl:/usr/lib/wsl:ro" )

# 3. SSH Agent Forwarding
if [ -n "$HOST_SSH_AUTH_SOCK" ] && [ -S "$HOST_SSH_AUTH_SOCK" ]; then
    BIND_OPTS+=( "--bind" "${HOST_SSH_AUTH_SOCK}:/tmp/ssh-auth.sock" )
    export SSH_AUTH_SOCK="/tmp/ssh-auth.sock"
fi

log_info "Launching ${SIF_FILE}..."

apptainer run $GPU_FLAG "${BIND_OPTS[@]}" "$SIF_FILE" "$@"
