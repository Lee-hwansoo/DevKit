#!/bin/bash
# =============================================================================
# scripts/setup_sync_deps.sh
# Third-party dependency source code synchronization and overlay merge tool
#
# Features:
#   1. Batch Import/Pull of external repositories via vcstool (.repos)
#   2. Merge files from dependencies/overlay/ into the target workspace
#   3. Automatic verification of missing system dependencies based on rosdep
# =============================================================================

# Load path configuration
[ -f "/workspace/config/util_paths.sh" ] && source "/workspace/config/util_paths.sh"
[ -z "$WS_ROOT" ] && source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh"

# Load logging utility
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="$(dirname "${BASH_SOURCE[0]}")/util_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"
LOG_PREFIX="[Sync Deps]"

# Fix for "detected dubious ownership" git error in Docker/WSL2
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="safe.directory"
export GIT_CONFIG_VALUE_0="*"
export GIT_CONFIG_PARAMETERS="'safe.directory=*'"
git config --system --get-all safe.directory 2>/dev/null | grep -q "^[*]$" || \
git config --system --add safe.directory "*" 2>/dev/null || true

# 0. Argument Parsing
FORCE_MODE=false
DO_ROSDEP=false

for arg in "$@"; do
    case "$arg" in
        --force)  FORCE_MODE=true ;;
        --rosdep) DO_ROSDEP=true ;;
    esac
done

REPOS_FILE="${WS_DEPS}/dependencies.repos"
OVERLAY_DIR="${WS_DEPS}/overlay"

# 1. Path Architecture Setup
if [[ "$SYNC_TARGET_DIR" == /* ]]; then
    TARGET_DIR="$SYNC_TARGET_DIR"
else
    TARGET_DIR="${WS_ROOT}/${SYNC_TARGET_DIR:-src/thirdparty}"
fi

# Sanitize double slashes
TARGET_DIR="${TARGET_DIR//\/\//\/}"
mkdir -p "$TARGET_DIR"

# 1. vcstool Integration
print_section "VCS Repository Import"
if ! command -v vcs &>/dev/null; then
    log_warn "vcstool (vcs) not found. Skipping repository import."
elif [ -f "$REPOS_FILE" ]; then
    log_info "Running vcs import to $TARGET_DIR ..."
    vcs import "$TARGET_DIR" < "$REPOS_FILE" || log_warn "vcs import completed with some warnings."

    if [ "$FORCE_MODE" = true ]; then
        log_warn "Force mode: resetting all third-party repos to HEAD..."
        find "$TARGET_DIR" -type d -name ".git" -prune -execdir git reset --hard HEAD \; -execdir git clean -fd \; &>/dev/null || true
    else
        DIRTY_REPOS=$(find "$TARGET_DIR" -type d -name ".git" -execdir git status --porcelain \; 2>/dev/null)
        if [ -n "$DIRTY_REPOS" ]; then
            log_warn "Some repositories have uncommitted changes. Use --force to discard them."
        fi
    fi

    log_info "Performing vcs pull to update only branch-tracking repositories..."
    for repo_dir in "$TARGET_DIR"/*; do
        if [ -d "$repo_dir" ]; then
            REPO_NAME=$(basename "$repo_dir")
            if (cd "$repo_dir" && git symbolic-ref -q HEAD > /dev/null); then
                log_info "Pulling updates for $REPO_NAME (on branch)..."
                vcs pull "$repo_dir" || log_warn "vcs pull failed for $REPO_NAME"
            else
                log_info "Skipping pull for $REPO_NAME (fixed version / detached HEAD)."
            fi
        fi
    done
else
    log_info "No .repos file found at $REPOS_FILE."
fi

# 2. Package Overlay Application
print_section "Overlay Application"
if [ -d "$OVERLAY_DIR" ]; then
    log_info "Applying overlays from $OVERLAY_DIR ..."
    find "$OVERLAY_DIR" -mindepth 1 -maxdepth 1 \
        ! \( -name "CATKIN_IGNORE" -o -name "COLCON_IGNORE" -o -name "*.md" \) -print0 | \
        xargs -0 -r cp -a -t "$TARGET_DIR/"
    log_step_done "Overlays applied successfully."
else
    log_info "Overlay directory not found."
fi

# 3. System Dependency Resolution (rosdep)
print_section "System Dependencies (rosdep)"
if [ "$DO_ROSDEP" = true ] && command -v rosdep &>/dev/null && [ -n "${ROS_DISTRO}" ]; then
    log_info "Gathering dependencies for ${ROS_DISTRO}..."
    apt-get update -qq || true

    SCAN_PATHS="$TARGET_DIR"
    if [ -d "${WS_SRC}" ] && [ "$TARGET_DIR" != "${WS_SRC}" ]; then
        SCAN_PATHS="${WS_SRC} $SCAN_PATHS"
    fi

    log_info "Running rosdep install for: $SCAN_PATHS"
    if ! rosdep install --from-paths $SCAN_PATHS --ignore-src -r -y --rosdistro "$ROS_DISTRO"; then
        log_warn "Some rosdep packages failed to install. Check the output above."
    else
        log_step_done "rosdep check completed for: $SCAN_PATHS"
    fi
elif [ "$DO_ROSDEP" = true ]; then
    log_info "ROS environment not detected. Skipping rosdep system dependency check."
elif [ "$DO_ROSDEP" = false ] && command -v rosdep &>/dev/null; then
    log_info "Skipping rosdep install. (Use --rosdep to force check)"
fi
