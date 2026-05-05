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

set -e

# =============================================================================
# Bootstrap: Logging (must precede helper function definitions)
# =============================================================================
SOURCE_LOG="/docker_dev/scripts/utils_logging.sh"
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="/opt/scripts/utils_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"

# Fallback: Define logging stubs if utility functions are unavailable (Safety net for production)
if ! declare -f log_info > /dev/null 2>&1; then
    log_info()  { echo "[INFO] $1"; }
    log_ok()    { echo "[OK] $1";   }
    log_warn()  { echo "[WARN] $1" >&2; }
    log_error() { echo "[ERROR] $1" >&2; }
fi
LOG_PREFIX="[Entrypoint]"

# =============================================================================
# Helper Functions
# =============================================================================

# Resolves XDG_RUNTIME_DIR, proxying to /tmp/runtime-internal when the mounted
# directory is owned by a different UID (e.g. WSL2 host user=1000, container=root).
# Prints the resolved path to stdout; all log messages go to stderr to prevent
# stdout capture pollution when called as: export VAR="$(setup_xdg_runtime)"
setup_xdg_runtime() {
    local xdg_dir="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
    local my_uid
    my_uid="$(id -u)"

    if [ -d "$xdg_dir" ] && [ "$(stat -c %u "$xdg_dir" 2>/dev/null)" != "$my_uid" ]; then
        local proxy="/tmp/runtime-internal"
        mkdir -p "$proxy" && chmod 700 "$proxy"
        # Remove stale symlinks before re-linking (handles socket recreation by compositor)
        find "$proxy" -maxdepth 1 -type l -exec rm -f {} \;
        find "$xdg_dir" -maxdepth 1 -not -path "$xdg_dir" -exec ln -sf {} "$proxy/" 2>/dev/null \;
        log_ok "XDG_RUNTIME_DIR proxied for security compliance: $proxy" >&2
        echo "$proxy"
    else
        if [ ! -d "$xdg_dir" ]; then
            mkdir -p "$xdg_dir" && chmod 700 "$xdg_dir"
            log_ok "XDG_RUNTIME_DIR created: $xdg_dir" >&2
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
    if [ ! -f "${XAUTHORITY:-$HOME/.Xauthority}" ]; then
        log_warn "Xauthority file not found. GUI apps may fail."
        log_warn "On host: xhost +SI:localuser:root"
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

# =============================================================================
# Clean up orphaned environment variables injected by Docker Compose V2
# Prevents empty strings from interfering with logic or ROS node discovery
for var in ROS_IP WAYLAND_DISPLAY HOST_WAYLAND_DISPLAY; do
    if [ -n "${!var+x}" ] && [ -z "${!var}" ]; then
        unset "$var"
    fi
done

# Move to workspace root
[ -d "/workspace" ] && cd /workspace

# =============================================================================
# [1] GPU Hardware Acceleration Setup
# =============================================================================
# Delegates to gpu_setup.sh which handles NVIDIA/Intel/AMD vendor-specific logic
# Values: auto (default) | nvidia | intel | amd | cpu
log_info "GPU mode: ${GPU_MODE:-auto}"

# GPU setup runs in current shell for env export, but failures are caught
# to prevent blocking container startup in CI/headless environments
if [ -f "/docker_dev/scripts/gpu_setup.sh" ]; then
    source /docker_dev/scripts/gpu_setup.sh "${GPU_MODE:-auto}" || log_warn "GPU setup encountered errors, continuing with defaults."
elif [ -f "/opt/scripts/gpu_setup.sh" ]; then
    source /opt/scripts/gpu_setup.sh "${GPU_MODE:-auto}" || log_warn "GPU setup encountered errors, continuing with defaults."
else
    log_warn "gpu_setup.sh not found. Skipping GPU configuration."
fi

# Detect actual home directory of the current user (root in dev, devkit in prod)
DEV_HOME=$(getent passwd "${SUDO_USER:-${USER:-root}}" | cut -d: -f6)
[ -z "$DEV_HOME" ] && DEV_HOME=$(eval echo "~${SUDO_USER:-${USER:-root}}")

# =============================================================================
# [2] Environment Detection (Dev vs Prod)
# =============================================================================
# if /docker_dev exists, it's a dev environment
if [ -d "/docker_dev" ]; then
    IS_DEV=true
    log_info "Environment: Development (Source mounting active)"
else
    IS_DEV=false
    log_info "Environment: Production"
fi

# [3] Display Protocol & GUI Integration (Development Only)
if [ "$IS_DEV" = true ]; then
    if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        # Resolve XDG_RUNTIME_DIR (handles WSL2 uid mismatch via proxy)
        export XDG_RUNTIME_DIR="$(setup_xdg_runtime)"

        # Persist for 'docker exec' sessions (e.g. make ros-shell)
        # /etc/profile.d: login shells; /etc/bash.bashrc gateway: non-login interactive shells
        echo "export XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\"" > /etc/profile.d/devkit-xdg.sh
        chmod 644 /etc/profile.d/devkit-xdg.sh
        # Bridge for non-login interactive shells (docker exec -it ... bash)
        grep -qF 'devkit-xdg.sh' /etc/bash.bashrc 2>/dev/null || \
            echo '[ -f /etc/profile.d/devkit-xdg.sh ] && . /etc/profile.d/devkit-xdg.sh' >> /etc/bash.bashrc

        verify_x11
        setup_wayland
    else
        log_warn "No DISPLAY or WAYLAND_DISPLAY set — GUI apps will not work."
    fi
fi

# =============================================================================
# [4] Cache and Other Settings (Dev Only)
# =============================================================================
if [ "$IS_DEV" = true ]; then
    mkdir -p /cache/ccache /cache/uv /cache/apt
    log_ok "Cache dirs ready: /cache/{ccache,uv,apt}"
fi

# =============================================================================
# [5] Git safe.directory Setup (Dev Only)
# =============================================================================
if [ "$IS_DEV" = true ] && command -v git &>/dev/null; then
    git config --global --add safe.directory /workspace 2>/dev/null || true
    log_ok "Git safe.directory configured"
fi

# =============================================================================
# [6] Check SSH Key Permissions (Dev Only)
# =============================================================================
if [ "$IS_DEV" = true ] && [ -d "${DEV_HOME}/.ssh" ]; then
    BAD_PERMS=$(find "${DEV_HOME}/.ssh" -name "id_*" ! -perm 600 2>/dev/null | head -1)
    if [ -n "${BAD_PERMS}" ]; then
        log_warn "SSH key permissions may cause issues (read-only mount)."
        log_warn "On host: chmod 600 ~/.ssh/id_*"
    else
        log_ok "SSH keys OK"
    fi
fi

# =============================================================================
# [7] Workspace Status Guide (Dev Only)
# =============================================================================
if [ "$IS_DEV" = true ]; then
    if [ ! -f /workspace/install/setup.bash ] && [ ! -d /workspace/install/.venv ]; then
        log_warn "Workspace not yet built or environment not set up."
        if [ -f "$ROS_SETUP" ]; then
            log_warn "  Run: cb     (colcon build for ROS)"
        else
            log_warn "  Run: mbuild (for C++) or mkenv (for Python)"
        fi
    fi
fi

# [8] SocketCAN Interface Detection
if ip link show can0 >/dev/null 2>&1; then
    log_ok "SocketCAN can0 available"
elif ip link show 2>/dev/null | grep -q ": can"; then
    log_info "SocketCAN interfaces detected (not can0)"
fi

# =============================================================================
# [9] Environment Sourcing (ROS and Python venv)
# =============================================================================
# ROS environment source
ROS_SETUP="/opt/ros/${ROS_DISTRO:-humble}/setup.bash"
if [ -f "$ROS_SETUP" ]; then
    source "$ROS_SETUP"
    log_ok "ROS ${ROS_DISTRO:-humble} sourced"

    if [ -f /workspace/install/setup.bash ]; then
        source /workspace/install/setup.bash
        log_ok "Workspace overlay sourced"
    fi
else
    log_info "ROS2 not installed or not in /opt/ros, skipping ROS2 setup"
fi

# Auto-activate Python virtual environment
if [ -f "/workspace/install/.venv/bin/activate" ]; then
    if [ "$IS_DEV" = true ]; then
        ln -sf /workspace/install/.venv /workspace/.venv
    fi
    source "/workspace/install/.venv/bin/activate"
    log_ok "Python virtualenv activated (/workspace/install/.venv)"
fi

# [10] Automated Dependency Synchronization (On-Demand Development Only)
if [ "$IS_DEV" = true ]; then
    # Keep src/thirdparty as default, but run only if dependencies file exists
    TARGET_DIR="${SYNC_TARGET_DIR:-src/thirdparty}"
    if [ "$PWD" == "/workspace" ] && [ -f "dependencies/dependencies.repos" ]; then
        if [ ! -d "$TARGET_DIR" ] || [ -z "$(ls -A $TARGET_DIR 2>/dev/null)" ]; then
            log_info "Dependency directory ($TARGET_DIR) is empty. Running sync_deps.sh..."
            bash /docker_dev/scripts/sync_deps.sh
        fi
    fi
fi

# Execute
exec "$@"
