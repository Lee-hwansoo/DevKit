#!/bin/bash
# =============================================================================
# docker/entrypoint.sh
# Runtime initialization and environment configuration engine
#
# Responsibilities:
#   - Dynamic GPU acceleration setup and vendor-specific overrides
#   - X11/Wayland display protocol verification and permissions
#   - Cache directory orchestration and permission management
#   - Automatic ROS and Python virtual environment sourcing
# =============================================================================

set -eE

# Force UTF-8 locale for terminal emoji and ASCII art support
export LANG=${LANG:-C.UTF-8}
export LC_ALL=${LANG:-C.UTF-8}
export LANGUAGE=${LANG:-en_US.UTF-8}

# =============================================================================
# Bootstrap: Centralized Path Management & Sourcing (Single Source of Truth)
# =============================================================================
source "${WORKSPACE_PATH:-/workspace}/config/util_paths.sh" 2>/dev/null || source "/tmp/util_paths.sh"
devkit_require "util_logging.sh"
LOG_PREFIX="[Entrypoint]"
ROS_SETUP="/opt/ros/${ROS_DISTRO:-humble}/setup.bash"

# Persist boot logs for post-mortem debugging (best-effort; util_logging is hardened
# so an unwritable path never aborts boot). Gives the dev boot path the same
# observability the SIF/SLURM path already has.
if [ -n "${WS_LOGS:-}" ] && mkdir -p "${WS_LOGS}" 2>/dev/null; then
    export LOG_FILE="${WS_LOGS}/entrypoint.log"
fi

# Diagnostic ERR trap: record WHERE a fatal (set -e) abort happened instead of
# dying silently. Fires only on set -e-triggering failures; guarded steps
# (if / || / &&) are unaffected. It logs — it does not alter control flow.
trap 'ec=$?; log_error "Entrypoint aborted (exit ${ec}) at line ${LINENO}: ${BASH_COMMAND}"' ERR

# source_runtime_file <path> [args...]: source a file with `set +eu` so ROS/venv
# setup scripts that reference unbound vars or return non-zero cannot abort boot.
# Mirrors docker/prod_entrypoint.sh; returns the sourced script's own exit code.
source_runtime_file() {
    local file="$1"; shift
    [ -f "$file" ] || return 0
    # Explicitly save/restore errexit+nounset via $- (the `set +o | eval` idiom
    # does NOT reliably restore errexit here, silently disabling it for the rest
    # of boot). Restore exactly what was set, and preserve the sourced exit code.
    local _had_e=0 _had_u=0 _rc=0
    case "$-" in *e*) _had_e=1 ;; esac
    case "$-" in *u*) _had_u=1 ;; esac
    set +eu
    # shellcheck source=/dev/null
    source "$file" "$@"
    _rc=$?
    [ "$_had_e" = 1 ] && set -e
    [ "$_had_u" = 1 ] && set -u
    return "$_rc"
}

# =============================================================================
# Workspace & Environment Setup
# =============================================================================

# Fix for "detected dubious ownership" git error in Docker/WSL2 without mutating system config.
if declare -f configure_git_safe_directory >/dev/null 2>&1; then
    configure_git_safe_directory
else
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0="safe.directory"
    export GIT_CONFIG_VALUE_0="*"
fi

# =============================================================================
# Helper Functions
# =============================================================================

get_user_home() {
    local user="${1:-root}"
    local home
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
    if [ -z "$home" ] && [ -d "/home/$user" ]; then
        home="/home/$user"
    fi
    printf '%s\n' "${home:-${HOME:-/root}}"
}

sync_owner_if_root() {
    local path="$1"
    local desc="${2:-$1}"

    [ "$(id -u)" = "0" ] || return 0
    [ -n "${CONTAINER_USER:-}" ] || return 0
    [ "${CONTAINER_USER}" != "root" ] || return 0
    [ -e "$path" ] || return 0

    # Fast path: skip the recursive chown when the target already owns the entry.
    # Named-volume/first-run trees are created root-owned, so a single 'chown -R'
    # flips the whole subtree to the container user; subsequent boots then match
    # here and avoid re-walking large caches (ccache/uv/build/install) on every
    # startup — an unconditional recursive chown on those trees can dominate
    # container startup time.
    local target_uid
    target_uid="$(id -u "${CONTAINER_USER}" 2>/dev/null || true)"
    if [ -n "$target_uid" ] && [ "$(stat -c %u "$path" 2>/dev/null)" = "$target_uid" ]; then
        return 0
    fi

    if ! chown -R "${CONTAINER_USER}:${CONTAINER_USER}" "$path" 2>/dev/null; then
        log_warn "Could not synchronize ownership for ${desc}: ${path}"
    fi
}

# Resolves XDG_RUNTIME_DIR, proxying to a per-container /tmp/runtime-<uid>-<host>
# directory when the mounted directory is owned by a different UID (e.g. WSL2 host
# user=1000, container=root). The UID + hostname suffix keeps the proxy private to
# this container: under Apptainer/Singularity /tmp is frequently shared with the
# host, so a fixed path would let concurrent same-UID jobs wipe each other's
# symlinks via the stale-link cleanup below.
# Prints the resolved path to stdout; all log messages go to stderr to prevent
# stdout capture pollution when called as: export VAR="$(setup_xdg_runtime)"
setup_xdg_runtime() {
    local xdg_dir="${XDG_RUNTIME_DIR:-/tmp/.container_xdg}"
    local target_user="${CONTAINER_USER:-${USER:-root}}"
    local target_uid
    target_uid="$(id -u "$target_user" 2>/dev/null || id -u)"

    if [ -d "$xdg_dir" ] && [ "$(stat -c %u "$xdg_dir" 2>/dev/null)" != "$target_uid" ]; then
        local proxy="/tmp/runtime-${target_uid}-$(hostname 2>/dev/null || echo default)"
        mkdir -p "$proxy" && chmod 700 "$proxy"
        sync_owner_if_root "$proxy" "XDG runtime proxy directory"
        # Remove stale symlinks before re-linking (handles socket recreation by compositor)
        find "$proxy" -maxdepth 1 -type l -exec rm -f {} +
        find "$xdg_dir" -maxdepth 1 -not -path "$xdg_dir" -exec ln -sf {} "$proxy/" 2>/dev/null \;
        log_ok "XDG_RUNTIME_DIR proxied for security compliance: $proxy" >&2
        echo "$proxy"
    else
        if [ ! -d "$xdg_dir" ]; then
            mkdir -p "$xdg_dir" && chmod 700 "$xdg_dir"
            sync_owner_if_root "$xdg_dir" "XDG runtime directory"
            log_ok "XDG_RUNTIME_DIR created: $xdg_dir" >&2
        else
            sync_owner_if_root "$xdg_dir" "XDG runtime directory"
        fi
        echo "$xdg_dir"
    fi
}

# Verifies the X11 socket and Xauthority file; logs warnings if missing.
verify_x11() {
    local display="${DISPLAY:-}"
    [ -z "$display" ] && return

    local display_num="${display#:}"
    display_num="${display_num%%.*}"
    if [ -S "/tmp/.X11-unix/X${display_num}" ]; then
        log_ok "X11 display ${display} verified"
    else
        log_warn "DISPLAY=${display} set but X11 socket not found."
    fi

    local xauth_path="${XAUTHORITY:-$HOME/.Xauthority}"
    if [ -s "$xauth_path" ]; then
        log_ok "Xauthority file verified: $xauth_path"
        export XAUTHORITY="$xauth_path"
    else
        log_warn "Xauthority file missing or empty ($xauth_path). GUI may fail."
        log_warn "Solution: Run 'make xauth' on host or 'xhost +SI:localuser:root'"
    fi
}

# Exports Wayland-specific Qt/GTK environment variables.
setup_wayland() {
    [ -z "${WAYLAND_DISPLAY:-}" ] && return
    log_ok "Wayland display ${WAYLAND_DISPLAY} set"
    export QT_QPA_PLATFORM="wayland;xcb"
    export GDK_BACKEND="wayland,x11"
    log_ok "Wayland GUI variables initialized"
}

# Clean up orphaned environment variables injected by Docker Compose V2
# Prevents empty strings from interfering with logic or ROS node discovery
for var in ROS_IP WAYLAND_DISPLAY HOST_WAYLAND_DISPLAY; do
    if [ -n "${!var+x}" ] && [ -z "${!var}" ]; then
        unset "$var"
    fi
done

# =============================================================================
# [1] Environment Detection (Dev/Bake vs Prod)
# =============================================================================
# If workspace scripts exist, it's a development or baked environment
if [ -d "${WS_SCRIPTS}" ]; then
    IS_DEV=true
    log_info "Environment: Development/Baked (Project scripts active)"
else
    IS_DEV=false
    log_info "Environment: Minimal runtime"
fi

# Move to workspace root
if [ -d "${WS_ROOT}" ]; then
    cd "${WS_ROOT}"

    # Synchronize workspace links (handles host mount overwrites)
    if [ "$IS_DEV" = true ]; then
        SETUP_LINKS="${WS_SCRIPTS}/util_setup_links.sh"
        if [ -f "$SETUP_LINKS" ]; then
            "$SETUP_LINKS" --verbose --skip-compile-commands || log_warn "Workspace link synchronization failed."
        fi
    fi

    # Clean up any conflicting libraries leaked from the host via bind mounts
    if [ "$IS_DEV" = true ]; then
        LEAKED_GPU_LIB="$(find . -maxdepth 1 \( -name "libnvidia-*.so*" -o -name "libcuda.so*" \) -type f -print -quit 2>/dev/null)"
        if [ -n "$LEAKED_GPU_LIB" ]; then
            log_warn "Detected host-leaked libraries in workspace root. Cleaning up for driver stability."
            find . -maxdepth 1 \( -name "libnvidia-*.so*" -o -name "libcuda.so*" \) -type f -print0 2>/dev/null | xargs -0 -r rm -f --
        fi
    fi
fi

# Detect actual home directory of the current user (root in dev, devkit in prod)
DEV_HOME="$(get_user_home "${SUDO_USER:-${USER:-root}}")"

# Helper to robustly inject environment bridge into /etc/bash.bashrc
# Usage: persist_env_block <marker_name> <profile_script_path>
persist_env_block() {
    local marker="$1"
    local script="$2"
    local target="/etc/bash.bashrc"
    [ ! -f "$script" ] && return
    [ ! -w "$target" ] && return

    local start_mark="# $marker"
    local end_mark="# ${marker/START/END}"
    local block_content="${start_mark}\n[ -f $script ] && . $script\n${end_mark}"

    if grep -q "$start_mark" "$target" 2>/dev/null; then
        # Replace existing block using sed (idempotent update)
        # We use a temp file to ensure atomic write and handle potential sed differences
        local tmp_file
        if ! tmp_file=$(mktemp 2>/dev/null); then
            log_warn "Failed to create temporary file for env block update. Skipping."
            return 0
        fi
        if sed "/$start_mark/,/$end_mark/d" "$target" > "$tmp_file" 2>/dev/null; then
            echo -e "$block_content" >> "$tmp_file"
            cat "$tmp_file" > "$target" 2>/dev/null || log_warn "Failed to update $target."
        fi
        if ! rm -f "$tmp_file" 2>/dev/null; then
            log_warn "Failed to remove temporary file: $tmp_file"
        fi
    else
        # Append new block if it doesn't exist
        echo -e "\n$block_content" >> "$target" 2>/dev/null || log_warn "Failed to append to $target."
    fi
}

# =============================================================================
# [2] Display Protocol & GUI Integration (Development Only)
# =============================================================================
if [ "$IS_DEV" = true ]; then
    if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        # Resolve XDG_RUNTIME_DIR (handles WSL2 uid mismatch via proxy)
        export XDG_RUNTIME_DIR="$(setup_xdg_runtime)"

        # Persist for 'docker exec' sessions (e.g. make shell ENV=ros)
        if [ -w /etc/profile.d ]; then
            echo "export XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\"" > /etc/profile.d/devkit-xdg.sh
            chmod 644 /etc/profile.d/devkit-xdg.sh
            persist_env_block "__DEVKIT_XDG_START" "/etc/profile.d/devkit-xdg.sh"
        fi

        verify_x11
        setup_wayland
    else
        log_warn "No DISPLAY or WAYLAND_DISPLAY set — GUI apps will not work."
    fi
fi

# =============================================================================
# [3] Cache and Other Settings (Dev Only)
# =============================================================================
if [ "$IS_DEV" = true ]; then
    if [ -w /cache ] || [ -d /cache/ccache ]; then
        if ! mkdir -p /cache/ccache /cache/uv /cache/apt 2>/dev/null; then
            log_warn "Failed to create one or more cache directories under /cache"
        fi
        sync_owner_if_root /cache/ccache "ccache cache"
        sync_owner_if_root /cache/uv "uv cache"
        sync_owner_if_root /cache/apt "APT cache"
        log_ok "Cache dirs ready: /cache/{ccache,uv,apt}"
    else
        log_warn "Cache directory /cache is not writable, skipping cache directory setup"
    fi

    # Ensure build, devel, install, and log directories are owned by the container user (handles named volume permissions)
    if [ "$(id -u)" = "0" ] && [ -n "${CONTAINER_USER}" ] && [ "${CONTAINER_USER}" != "root" ]; then
        for dir in "${WS_BUILD:-${WS_ROOT}/build}" "${WS_ROOT}/devel" "${WS_INSTALL:-${WS_ROOT}/install}" "${WS_LOGS:-${WS_ROOT}/log}"; do
            sync_owner_if_root "$dir" "workspace directory"
        done
        log_ok "Workspace build, devel, install, and log directories ownership synchronized for ${CONTAINER_USER}."
    fi
fi

# Initialize ros cache for hybrid environment (Docker/Apptainer)
if [ -d "/opt/ros_cache" ]; then
    TARGET_HOME="$(get_user_home "${CONTAINER_USER:-${USER:-root}}")"

    if [ ! -d "${TARGET_HOME}/.ros" ]; then
        mkdir -p "${TARGET_HOME}/.ros"
        cp -Rp /opt/ros_cache/. "${TARGET_HOME}/.ros/"
        sync_owner_if_root "${TARGET_HOME}/.ros" "ROS cache"
        log_ok "ros cache initialized."
    fi
fi

# =============================================================================
# [4] Check SSH Key Permissions (Dev Only)
# =============================================================================
if [ "$IS_DEV" = true ] && [ -d "${DEV_HOME}/.ssh" ]; then
    BAD_PERMS=$(find "${DEV_HOME}/.ssh" -name "id_*" ! -perm 600 -print -quit 2>/dev/null)
    if [ -n "${BAD_PERMS}" ]; then
        log_warn "SSH key permissions may cause issues (read-only mount)."
        log_warn "On host: chmod 600 ~/.ssh/id_*"
    else
        log_ok "SSH keys OK"
    fi
fi

# =============================================================================
# [5] Workspace Status Guide (Dev Only)
# =============================================================================
if [ "$IS_DEV" = true ]; then
    if [ ! -f "${WS_INSTALL}/setup.bash" ] && [ ! -d "${WS_VENV}" ]; then
        log_warn "Workspace not yet built or environment not set up."
        if [ -f "$ROS_SETUP" ]; then
            log_warn "  Run: cbuild (colcon build for ROS)"
        else
            log_warn "  Run: mbuild (for C++) or mkenv (for Python)"
        fi
    fi
fi

# =============================================================================
# [6] SocketCAN Interface Detection
# =============================================================================
if ip link show can0 >/dev/null 2>&1; then
    log_ok "SocketCAN can0 available"
elif ip link show 2>/dev/null | grep -q ": can"; then
    log_info "SocketCAN interfaces detected (not can0)"
fi

# =============================================================================
# [7] Environment Sourcing (ROS and Python venv)
# =============================================================================
# NOTE: Development aliases (cbuild, mksync, etc.) are loaded via
# config/init_bash.sh for interactive shells, not here. The entrypoint
# stays minimal to avoid polluting non-interactive exec sessions.

# ROS environment source (defensive: a ROS setup hook must never abort boot)
if [ -f "$ROS_SETUP" ]; then
    source_runtime_file "$ROS_SETUP"
    log_ok "ROS ${ROS_DISTRO:-humble} sourced"

    if [ -f "${WS_INSTALL}/setup.bash" ]; then
        source_runtime_file "${WS_INSTALL}/setup.bash"
        log_ok "Workspace overlay sourced"
    fi
else
    log_info "ROS not installed or not in /opt/ros, skipping ROS setup"
fi

# [7.1] ROS Version-specific Configuration (no-op if the file is absent)
source_runtime_file "${WS_CONFIG}/init_ros_env.sh"

# [7.2] Auto-activate Python virtual environment (no-op if not yet created)
source_runtime_file "${WS_VENV}/bin/activate"

# =============================================================================
# [8] GPU Hardware Acceleration Orchestration
# =============================================================================
# Sourced after ROS to ensure LD_LIBRARY_PATH priority for GPU drivers
log_info "GPU mode: ${GPU_MODE:-auto}"
GPU_SETUP="${WS_SCRIPTS}/setup_gpu.sh"

if [ -f "$GPU_SETUP" ]; then
    # Graceful degrade: an unusual/unsupported GPU must never prevent a shell.
    # The stated goal is "support most hardware with software fallback", so on
    # failure we fall back to software rendering rather than killing the container.
    if ! source_runtime_file "$GPU_SETUP" "${GPU_MODE:-auto}"; then
        log_warn "GPU setup failed for GPU_MODE=${GPU_MODE:-auto}. Falling back to software rendering."
        source_runtime_file "$GPU_SETUP" cpu \
            || log_warn "Software GPU fallback also failed; continuing without GPU env (shell still available)."
    fi
fi

# Persist GPU environment for non-interactive shells (docker exec)
if [ -f "$HOME/.gpu_env.sh" ]; then
    if [ -w /etc/profile.d ]; then
        cp "$HOME/.gpu_env.sh" /etc/profile.d/devkit-gpu.sh
        chmod 644 /etc/profile.d/devkit-gpu.sh
        persist_env_block "__DEVKIT_GPU_START" "/etc/profile.d/devkit-gpu.sh"
    fi
fi

# =============================================================================
# [9] Workspace Status Summary (Dev Only)
# =============================================================================
if [ "$IS_DEV" = true ]; then
    printf "\n${BLUE}--- Workspace Status ---${NC}\n"
    [ -n "$ROS_DISTRO" ] && printf "  %-12s %s\n" "ROS:" "${ROS_DISTRO}"

    CUDA_V=$(get_cuda_metadata cuda_ver)
    [ -n "$CUDA_V" ] && printf "  %-12s %s\n" "CUDA:" "$CUDA_V"

    CUDNN_V=$(get_cuda_metadata cudnn_ver)
    [ -n "$CUDNN_V" ] && printf "  %-12s %s\n" "cuDNN:" "$CUDNN_V"

    printf "${BLUE}------------------------${NC}\n\n"
fi

# =============================================================================
# [10] Automated Dependency Synchronization (On-Demand Development Only)
# =============================================================================
if [ "$IS_DEV" = true ]; then
    # Keep src/thirdparty as default, but run only if dependencies file exists
    TARGET_DIR="${SYNC_TARGET_DIR:-src/thirdparty}"
    if [ "$PWD" == "$WS_ROOT" ] && [ -f "dependencies/dependencies.repos" ]; then
        if [ ! -d "$TARGET_DIR" ] || [ -z "$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
            SYNC_DEPS="${WS_SCRIPTS}/setup_sync_deps.sh"
            log_info "Dependency directory ($TARGET_DIR) is empty. Running $(basename "$SYNC_DEPS")..."
            # Never let a first-boot sync failure (offline / private repo / transient
            # DNS) block the shell — warn and continue; the user can re-run later.
            if ! bash "$SYNC_DEPS"; then
                log_warn "Dependency sync failed (offline / private repo / transient error?). Continuing to shell — re-run later with: sync_deps"
            fi
        fi
    fi
fi

# =============================================================================
# Execute
# =============================================================================
if [ "$(id -u)" = "0" ] && [ -n "${CONTAINER_USER}" ] && [ "${CONTAINER_USER}" != "root" ]; then
    log_ok "Dropping privileges: executing command as user '${CONTAINER_USER}'"
    user_home="$(get_user_home "${CONTAINER_USER}")"
    user_uid="$(id -u "${CONTAINER_USER}")"
    user_gid="$(id -g "${CONTAINER_USER}")"
    runtime_env=(
        "HOME=$user_home"
        "USER=${CONTAINER_USER}"
        "LOGNAME=${CONTAINER_USER}"
        "PATH=$PATH"
        "WORKSPACE_PATH=$WS_ROOT"
        "LANG=$LANG"
        "LC_ALL=$LC_ALL"
        "LANGUAGE=$LANGUAGE"
        "VIRTUAL_ENV=$VIRTUAL_ENV"
        "DISPLAY=${DISPLAY:-}"
        "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
        "XAUTHORITY=${XAUTHORITY:-}"
        "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}"
        "QT_X11_NO_MITSHM=${QT_X11_NO_MITSHM:-}"
        "QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-}"
        "GDK_BACKEND=${GDK_BACKEND:-}"
        "SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-}"
        "ROS_DISTRO=${ROS_DISTRO:-}"
        "ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-}"
        "RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-}"
        "ROS_MASTER_URI=${ROS_MASTER_URI:-}"
        "ROS_HOSTNAME=${ROS_HOSTNAME:-}"
        "ROS_IP=${ROS_IP:-}"
        "GPU_MODE=${GPU_MODE:-}"
        "NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES:-}"
        "NVIDIA_DRIVER_CAPABILITIES=${NVIDIA_DRIVER_CAPABILITIES:-}"
        "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"
        "PYTHONPATH=${PYTHONPATH:-}"
    )
    if command -v setpriv >/dev/null 2>&1; then
        exec setpriv --reuid "$user_uid" --regid "$user_gid" --init-groups env "${runtime_env[@]}" "$@"
    fi
    exec sudo -E -u "${CONTAINER_USER}" env "${runtime_env[@]}" "$@"
else
    exec "$@"
fi
