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

# Load logging utility
SOURCE_LOG="/docker_dev/scripts/util_logging.sh"
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="$(dirname "${BASH_SOURCE[0]}")/util_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"
LOG_PREFIX="[Sync Deps]"

# 0. Argument Parsing (Enterprise Standard)
FORCE_MODE=false
DO_ROSDEP=false

for arg in "$@"; do
    case "$arg" in
        --force)  FORCE_MODE=true ;;
        --rosdep) DO_ROSDEP=true ;;
    esac
done

PROJECT_ROOT="${WORKSPACE_PATH:-/workspace}"
REPOS_FILE="${PROJECT_ROOT}/dependencies/dependencies.repos"
OVERLAY_DIR="${PROJECT_ROOT}/dependencies/overlay"

# 1. Path Architecture Setup
# If SYNC_TARGET_DIR starts with /, treat it as an absolute path; otherwise, relative to PROJECT_ROOT.
if [[ "$SYNC_TARGET_DIR" == /* ]]; then
    TARGET_DIR="$SYNC_TARGET_DIR"
else
    TARGET_DIR="${PROJECT_ROOT}/${SYNC_TARGET_DIR:-src/thirdparty}"
fi

# Sanitize double slashes for clean logging
TARGET_DIR="${TARGET_DIR//\/\//\/}"

mkdir -p "$TARGET_DIR"

# 1. vcstool Integration
print_section "VCS Repository Import"
if ! command -v vcs &>/dev/null; then
    log_warn "vcstool (vcs) not found. Skipping repository import."
elif [ -f "$REPOS_FILE" ]; then
    log_info "Running vcs import to $TARGET_DIR ..."
    vcs import "$TARGET_DIR" < "$REPOS_FILE" || log_warn "vcs import completed with some warnings."

    # Force mode check
    if [ "$FORCE_MODE" = true ]; then
        log_warn "Force mode: resetting all third-party repos to HEAD..."
        find "$TARGET_DIR" -type d -name ".git" -prune -execdir git reset --hard HEAD \; -execdir git clean -fd \; &>/dev/null || true
    else
        # Check for dirty repos and warn
        DIRTY_REPOS=$(find "$TARGET_DIR" -type d -name ".git" -execdir git status --porcelain \; 2>/dev/null)
        if [ -n "$DIRTY_REPOS" ]; then
            log_warn "Some repositories have uncommitted changes. Use --force to discard them."
        fi
    fi

    # Update existing repositories after checking for newly added ones
    log_info "Performing vcs pull to update existing repositories..."
    vcs pull "$TARGET_DIR" || log_warn "vcs pull completed with some warnings."
else
    log_info "No .repos file found at $REPOS_FILE."
fi

# 2. Package Overlay Application
print_section "Overlay Application"
if [ -d "$OVERLAY_DIR" ]; then
    log_info "Applying overlays from $OVERLAY_DIR ..."
    # Use -print0 and xargs -0 -r for safe file name handling and empty result handling
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
    # Ensure apt is updated for fresh dependency resolution
    apt-get update -qq || true

    # Scan both the specific target directory (for third-party staging)
    # AND the main src directory (for internal packages).
    # rosdep is smart enough to handle duplicates and nested directories.
    SCAN_PATHS="$TARGET_DIR"
    if [ -d "${PROJECT_ROOT}/src" ] && [ "$TARGET_DIR" != "${PROJECT_ROOT}/src" ]; then
        SCAN_PATHS="${PROJECT_ROOT}/src $SCAN_PATHS"
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
