#!/bin/bash
# =============================================================================
# scripts/util_setup_links.sh
# Centralized management for workspace symlinks (colcon.meta, dependencies, etc.)
# =============================================================================

# Load logging utility
SOURCE_LOG="/docker_dev/scripts/util_logging.sh"
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="$(dirname "${BASH_SOURCE[0]}")/util_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"

WORKSPACE_ROOT="${WORKSPACE_PATH:-/workspace}"
COLCON_META_SRC="/docker_dev/config/colcon.meta"
DEPS_DIR_SRC="/opt/dependencies"
VENV_DIR_SRC="${VENV_PATH:-${WORKSPACE_ROOT}/install/.venv}"

# Function to safely create a symlink
# Usage: safe_link <src> <dest> <description>
safe_link() {
    local src="$1"
    local dest="$2"
    local desc="${3:-$2}"

    # Guard: prevent catastrophic operations on empty or root paths
    if [[ -z "$src" || -z "$dest" || "$dest" == "/" ]]; then
        return 0
    fi

    # Source must exist (file, directory, or symlink) to create a link
    [[ -e "$src" ]] || return 0

    # If destination is a real directory (not a symlink), we cannot replace it
    [[ -d "$dest" && ! -L "$dest" ]] && return 0

    # Idempotency: skip if already pointing to the correct source
    if [[ -L "$dest" && "$(readlink -f "$dest")" == "$(readlink -f "$src")" ]]; then
        return 0
    fi

    # Remove existing entry (symlink or regular file) and re-create
    # Use -f instead of -rf: the target is always a symlink or file, never a directory we own
    rm -f "$dest"
    ln -sf "$src" "$dest"

    if [[ "$VERBOSE" == true && -n "$LOG_PREFIX" ]]; then
        log_ok "$desc synchronized."
    fi
}

VERBOSE=false
[ "$1" = "--verbose" ] && VERBOSE=true

# 1. colcon.meta (Build Optimization Configuration)
safe_link "$COLCON_META_SRC" "${WORKSPACE_ROOT}/colcon.meta" "Colcon configuration"

# 2. dependencies (Third-party Dependency Source Mapping)
safe_link "$DEPS_DIR_SRC" "${WORKSPACE_ROOT}/dependencies" "Dependency directory"

# 3. .venv (IDE Integration)
safe_link "$VENV_DIR_SRC" "${WORKSPACE_ROOT}/.venv" "Virtual environment"

# 4. compile_commands.json (C++ IntelliSense)
# Priority: 1. Workspace build root, 2. Package-specific build dir (most recent)
COMPILE_COMMANDS_SRC="${WORKSPACE_ROOT}/build/compile_commands.json"
if [ ! -f "$COMPILE_COMMANDS_SRC" ]; then
    # Fallback to the most recently modified compile_commands.json in any build subdirectory
    COMPILE_COMMANDS_SRC=$(find "${WORKSPACE_ROOT}/build" -maxdepth 2 -name "compile_commands.json" -type f -printf '%T@ %p\n' 2>/dev/null | sort -k1 -nr | head -1 | cut -d' ' -f2-)
fi
safe_link "$COMPILE_COMMANDS_SRC" "${WORKSPACE_ROOT}/compile_commands.json" "Compile commands"
