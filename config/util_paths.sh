#!/bin/bash
# =============================================================================
# config/util_paths.sh
# Centralized Path Management (Single Source of Truth)
# =============================================================================

# Root Workspace Path
# Priority: 1. Env Var, 2. Script location, 3. Default
if [ -z "${WORKSPACE_PATH}" ]; then
    _INFERRED_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    export WS_ROOT="${_INFERRED_ROOT:-/workspace}"
else
    export WS_ROOT="${WORKSPACE_PATH}"
fi

# Core Directories
export WS_SCRIPTS="${WS_ROOT}/scripts"
export WS_CONFIG="${WS_ROOT}/config"
export WS_DEPS="${WS_ROOT}/dependencies"
export WS_INSTALL="${WS_ROOT}/install"
export WS_SRC="${WS_ROOT}/src"
export WS_LOGS="${WS_ROOT}/logs"

# Python & Environment
export WS_VENV="${VENV_PATH:-${WS_INSTALL}/.venv}"
export WS_CCACHE_DIR="/cache/ccache"
export WS_UV_CACHE_DIR="/cache/uv"

# Logging Utility
export SOURCE_LOG="${WS_SCRIPTS}/util_logging.sh"

unset _INFERRED_ROOT
