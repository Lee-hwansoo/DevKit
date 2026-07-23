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

set -eo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || source "/tmp/util_paths.sh"
devkit_require "util_logging.sh"
LOG_PREFIX="[Sync Deps]"
devkit_enable_error_trap

truthy() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# Fix for "detected dubious ownership" git error in Docker/WSL2 without mutating system config.
if declare -F configure_git_safe_directory >/dev/null 2>&1; then
    configure_git_safe_directory
fi

# 0. Argument Parsing
FORCE_MODE=false
DO_ROSDEP=false

usage() {
    cat <<'EOF'
Usage: setup_sync_deps.sh [--force] [--rosdep]

Synchronize third-party repositories, apply dependency overlays, and optionally
run rosdep for workspace system dependencies.

Options:
  --force    Reset imported third-party repositories before updating them.
  --rosdep   Run rosdep install after source synchronization.
  -h, --help Show this help.

Environment:
  DEVKIT_ROSDEP_ALLOW_FAILURE=1  Warn instead of failing when rosdep install fails.
  DEVKIT_VCS_ALLOW_FAILURE=1     Warn instead of failing when vcs import/pull fails.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --force)  FORCE_MODE=true ;;
        --rosdep) DO_ROSDEP=true ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $arg"; usage; exit 2 ;;
    esac
done

REPOS_FILE="${WS_DEPS}/dependencies.repos"
OVERLAY_DIR="${WS_DEPS}/overlay"

is_safe_force_target() {
    local root_real target_real
    root_real="$(realpath -m "${WS_ROOT}")"
    target_real="$(realpath -m "$1")"

    [ "$target_real" != "/" ] || return 1
    [ "$target_real" != "$root_real" ] || return 1
    case "$target_real" in
        "$root_real"/*) return 0 ;;
        *) [ "${DEVKIT_ALLOW_EXTERNAL_SYNC_TARGET:-}" = "1" ] ;;
    esac
}

# 1. Path Architecture Setup
SYNC_TARGET_DIR="${SYNC_TARGET_DIR:-src/thirdparty}"
if [[ "$SYNC_TARGET_DIR" == /* ]]; then
    TARGET_DIR="$SYNC_TARGET_DIR"
else
    TARGET_DIR="${WS_ROOT}/${SYNC_TARGET_DIR}"
fi

# Sanitize double slashes
TARGET_DIR="${TARGET_DIR//\/\//\/}"
mkdir -p -- "$TARGET_DIR"

# 1. vcstool Integration
print_section "VCS Repository Import"
if ! command -v vcs &>/dev/null; then
    log_warn "vcstool (vcs) not found. Skipping repository import."
elif [ -f "$REPOS_FILE" ]; then
    log_info "Running vcs import to $TARGET_DIR ..."
    if ! vcs import "$TARGET_DIR" < "$REPOS_FILE"; then
        if truthy "${DEVKIT_VCS_ALLOW_FAILURE:-false}"; then
            log_warn "vcs import failed. Continuing because DEVKIT_VCS_ALLOW_FAILURE=1."
        else
            log_error "vcs import failed. Fix dependencies/dependencies.repos or set DEVKIT_VCS_ALLOW_FAILURE=1 to continue intentionally."
            exit 1
        fi
    fi

    if [ "$FORCE_MODE" = true ]; then
        log_warn "Force mode: resetting all third-party repos to HEAD..."
        if ! is_safe_force_target "$TARGET_DIR"; then
            log_error "Refusing --force reset for unsafe target: $TARGET_DIR"
            log_error "Use a workspace subdirectory, or set DEVKIT_ALLOW_EXTERNAL_SYNC_TARGET=1 for an explicit external target."
            exit 1
        fi
        reset_failed=0
        while IFS= read -r -d '' git_dir; do
            repo_dir="$(dirname "$git_dir")"
            repo_name="$(basename "$repo_dir")"
            if ! (cd "$repo_dir" && git reset --hard HEAD && git clean -ffdx); then
                log_warn "Failed to reset third-party repo: $repo_name"
                reset_failed=1
            fi
        done < <(find "$TARGET_DIR" -type d -name ".git" -prune -print0)
        [ "$reset_failed" = "0" ] || exit 1
    else
        DIRTY_REPOS=$(find "$TARGET_DIR" -type d -name ".git" -execdir git status --porcelain \; 2>/dev/null)
        if [ -n "$DIRTY_REPOS" ]; then
            log_warn "Some repositories have uncommitted changes. Use --force to discard them."
        fi
    fi

    log_info "Performing vcs pull to update only branch-tracking repositories..."
    pull_failed=0
    for repo_dir in "$TARGET_DIR"/*; do
        if [ -d "$repo_dir" ]; then
            REPO_NAME=$(basename "$repo_dir")
            if (cd "$repo_dir" && git symbolic-ref -q HEAD > /dev/null); then
                log_info "Pulling updates for $REPO_NAME (on branch)..."
                if ! vcs pull "$repo_dir"; then
                    log_warn "vcs pull failed for $REPO_NAME"
                    pull_failed=1
                fi
            else
                log_info "Skipping pull for $REPO_NAME (fixed version / detached HEAD)."
            fi
        fi
    done
    if [ "$pull_failed" != "0" ]; then
        if truthy "${DEVKIT_VCS_ALLOW_FAILURE:-false}"; then
            log_warn "One or more vcs pull operations failed. Continuing because DEVKIT_VCS_ALLOW_FAILURE=1."
        else
            log_error "One or more vcs pull operations failed. Fix the repository state/network or set DEVKIT_VCS_ALLOW_FAILURE=1 to continue intentionally."
            exit 1
        fi
    fi

    log_info "Synchronizing git submodules for all imported repositories..."
    submodule_failed=0
    failed_submodules=()
    for repo_dir in "$TARGET_DIR"/*; do
        if [ -d "$repo_dir" ] && ( [ -d "$repo_dir/.git" ] || [ -f "$repo_dir/.git" ] ); then
            REPO_NAME=$(basename "$repo_dir")
            log_info "Updating submodules for $REPO_NAME..."
            if ! (cd "$repo_dir" && git submodule update --init --recursive); then
                log_warn "Failed to update submodules for $REPO_NAME"
                submodule_failed=1
                failed_submodules+=("$REPO_NAME")
            fi
        fi
    done
    if [ "$submodule_failed" != "0" ]; then
        log_warn "Submodule updates failed for: ${failed_submodules[*]}"
        if truthy "${DEVKIT_VCS_ALLOW_FAILURE:-false}"; then
            log_warn "Continuing because DEVKIT_VCS_ALLOW_FAILURE=1."
        else
            log_error "One or more submodule updates failed. Fix the submodules (access/network) or set DEVKIT_VCS_ALLOW_FAILURE=1 to continue intentionally."
            exit 1
        fi
    fi
else
    log_info "No .repos file found at $REPOS_FILE."
fi

# 2. Package Overlay Application
print_section "Overlay Application"
if [ -d "$OVERLAY_DIR" ]; then
    log_info "Applying overlays from $OVERLAY_DIR ..."
    while IFS= read -r -d '' overlay_item; do
        cp -a -- "$overlay_item" "$TARGET_DIR/"
    done < <(
        find "$OVERLAY_DIR" -mindepth 1 -maxdepth 1 \
            ! \( -name "CATKIN_IGNORE" -o -name "COLCON_IGNORE" -o -name "*.md" \) -print0
    )
    log_step_done "Overlays applied successfully."
else
    log_info "Overlay directory not found."
fi

# 3. System Dependency Resolution (rosdep)
print_section "System Dependencies (rosdep)"
if [ "$DO_ROSDEP" = true ] && command -v rosdep &>/dev/null && [ -n "${ROS_DISTRO}" ]; then
    log_info "Gathering dependencies for ${ROS_DISTRO}..."
    if [ "$(id -u)" -ne 0 ] && command -v sudo &>/dev/null; then
        if ! sudo -n apt-get update -qq 2>/dev/null; then
            log_warn "apt-get update failed or sudo is unavailable; rosdep will continue with existing APT metadata."
        fi
    else
        if ! apt-get update -qq; then
            log_warn "apt-get update failed; rosdep will continue with existing APT metadata."
        fi
    fi

    SCAN_PATHS=( "$TARGET_DIR" )
    if [ -d "${WS_SRC}" ] && [ "$TARGET_DIR" != "${WS_SRC}" ]; then
        SCAN_PATHS=( "${WS_SRC}" "${SCAN_PATHS[@]}" )
    fi

    log_info "Running rosdep install for: ${SCAN_PATHS[*]}"
    if ! rosdep install --from-paths "${SCAN_PATHS[@]}" --ignore-src -r -y --rosdistro "$ROS_DISTRO"; then
        if truthy "${DEVKIT_ROSDEP_ALLOW_FAILURE:-false}"; then
            log_warn "Some rosdep packages failed to install. Continuing because DEVKIT_ROSDEP_ALLOW_FAILURE=1."
        else
            log_error "rosdep install failed. Fix the missing system dependencies or set DEVKIT_ROSDEP_ALLOW_FAILURE=1 to continue intentionally."
            exit 1
        fi
    else
        log_step_done "rosdep check completed for: ${SCAN_PATHS[*]}"
    fi
elif [ "$DO_ROSDEP" = true ]; then
    log_info "ROS environment not detected. Skipping rosdep system dependency check."
elif [ "$DO_ROSDEP" = false ] && command -v rosdep &>/dev/null; then
    log_info "Skipping rosdep install. (Use --rosdep to force check)"
fi
