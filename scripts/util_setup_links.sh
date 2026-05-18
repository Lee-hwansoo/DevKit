#!/bin/bash
# =============================================================================
# scripts/util_setup_links.sh
# Centralized management for workspace symlinks (colcon.meta, dependencies, etc.)
# =============================================================================

# Load path configuration
[ -f "/workspace/config/util_paths.sh" ] && source "/workspace/config/util_paths.sh"
[ -z "$WS_ROOT" ] && source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh"

# Load logging utility
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="$(dirname "${BASH_SOURCE[0]}")/util_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"

COLCON_META_SRC="${WS_CONFIG}/colcon.meta"
VENV_DIR_SRC="${WS_VENV}"

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
safe_link "$COLCON_META_SRC" "${WS_ROOT}/colcon.meta" "Colcon configuration"


# 2. .venv (IDE Integration)
safe_link "$VENV_DIR_SRC" "${WS_ROOT}/.venv" "Virtual environment"

# 3. compile_commands.json (C++ IntelliSense)
# If we have multiple package-specific build directories (e.g. ROS colcon), merge them into a single compile_commands.json
if [ -d "${WS_ROOT}/build" ]; then
    if [ "$VERBOSE" == true ]; then
        log_info "Aggregating compile_commands.json from all sub-packages..."
    fi
    python3 -c "
import json, glob, os
build_dir = '${WS_ROOT}/build'
output_file = os.path.join(build_dir, 'compile_commands.json')
sub_files = [f for f in glob.glob(os.path.join(build_dir, '**/compile_commands.json'), recursive=True)
             if os.path.abspath(f) != os.path.abspath(output_file)]

if sub_files:
    all_commands = []
    for f in sub_files:
        try:
            with open(f, 'r') as file:
                data = json.load(file)
                if isinstance(data, list):
                    all_commands.extend(data)
        except Exception:
            pass
    with open(output_file, 'w') as file:
        json.dump(all_commands, file, indent=2)
" 2>/dev/null || true
fi

COMPILE_COMMANDS_SRC="${WS_ROOT}/build/compile_commands.json"
safe_link "$COMPILE_COMMANDS_SRC" "${WS_ROOT}/compile_commands.json" "Compile commands"
