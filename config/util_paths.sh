#!/bin/bash
# =============================================================================
# config/util_paths.sh
# Centralized Path Management (Single Source of Truth)
# =============================================================================

# Root Workspace Path
# Priority: 1. Env Var, 2. Script location, 3. Default
if [ -z "${WORKSPACE_PATH:-}" ]; then
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
export WS_BUILD="${WS_ROOT}/build"
export WS_LOGS="${WS_ROOT}/log"

# Python & Environment
export WS_VENV="${VENV_PATH:-${WS_INSTALL}/.venv}"
export WS_CCACHE_DIR="/cache/ccache"
export WS_UV_CACHE_DIR="/cache/uv"

# Script Loader Path Configuration
export DEVKIT_SCRIPT_PATH="${WS_SCRIPTS:-/workspace/scripts}"

configure_git_safe_directory() {
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0="safe.directory"
    export GIT_CONFIG_VALUE_0="*"
}


# Track sourced files to prevent duplicate sourcing
if ! declare -p __DEVKIT_SOURCED_FILES &>/dev/null; then
    declare -A -g __DEVKIT_SOURCED_FILES
fi

# devkit_require [script_name] [force_reload:optional]
#   Locates and sources a script from local directory, WS_SCRIPTS, or /tmp.
#   Includes idempotency protection against duplicate loads.
devkit_require() {
    local script_name="$1"
    local force_reload="${2:-false}"

    if [[ "${__DEVKIT_SOURCED_FILES[$script_name]:-}" == "true" && "$force_reload" != "true" ]]; then
        return 0
    fi

    local search_paths=()
    local caller_dir
    caller_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd 2>/dev/null || true)"
    [[ -n "$caller_dir" ]] && search_paths+=("$caller_dir")
    [[ -n "${DEVKIT_SCRIPT_PATH:-}" ]] && search_paths+=("${DEVKIT_SCRIPT_PATH}")
    search_paths+=("/tmp")

    local resolved_path=""
    local dir
    for dir in "${search_paths[@]}"; do
        if [[ -f "${dir}/${script_name}" ]]; then
            resolved_path="${dir}/${script_name}"
            break
        fi
    done

    if [[ -n "$resolved_path" ]]; then
        [[ "${DEBUG_MODE:-}" == "true" ]] && echo "[DEVKIT-DEBUG] Sourcing '$script_name' -> '$resolved_path'" >&2
        source "$resolved_path"
        __DEVKIT_SOURCED_FILES["$script_name"]="true"
        return 0
    fi

    echo -e "\033[0;31m[DEVKIT-FATAL]\033[0m Failed to require script '$script_name'. Searched: ${search_paths[*]}" >&2
    return 1
}

# Default fallback logging stubs (overridden when util_logging.sh is loaded)
if ! declare -F log_info >/dev/null 2>&1; then
    log_info()       { echo "[INFO] $*"; }
    log_ok()         { echo "[OK] $*"; }
    log_warn()       { echo "[WARN] $*" >&2; }
    log_error()      { echo "[ERROR] $*" >&2; }
    print_section()  { echo "[ $* ]"; }
    log_step_done()  { echo "[OK] $*"; }
fi

unset _INFERRED_ROOT
