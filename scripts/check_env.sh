#!/bin/bash
# =============================================================================
# scripts/check_env.sh
# Diagnostic engine for host environment detection
#
# Precisely detects GPU availability, hardware architecture, container toolkits,
# and display server configurations (X11/Wayland). Results are output in
# KEY=VALUE format for Makefile integration.
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || source "/tmp/util_paths.sh"
devkit_require "util_logging.sh"
LOG_PREFIX="[Env Detector]"
OUTPUT_MODE="${1:-env}"

usage() {
    cat <<'EOF'
Usage: check_env.sh [--makefile]

Detect host/container integration settings and print them as shell assignments.

Options:
  --makefile  Print Makefile-compatible assignments.
  -h, --help  Show this help.
EOF
}

case "$OUTPUT_MODE" in
    env|--makefile) ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown option: $OUTPUT_MODE"; usage >&2; exit 2 ;;
esac

emit_env() {
    local key="$1"
    local value="$2"

    if [ "$OUTPUT_MODE" = "--makefile" ]; then
        value="${value//\\/\\\\}"
        value="${value//\$/\$\$}"
        value="${value//#/\\#}"
        printf '%s := %s\n' "$key" "$value"
    else
        printf '%s=%q\n' "$key" "$value"
    fi
}

trim_ws() {
    local value="${1:-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

ensure_dir() {
    local dir="$1"
    if ! mkdir -p -- "$dir" 2>/dev/null; then
        log_error "Failed to create required directory: $dir"
        exit 2
    fi
}

ensure_file() {
    local file="$1"
    if ! touch -- "$file" 2>/dev/null; then
        log_error "Failed to create required file: $file"
        exit 2
    fi
}

# 0. Detect Workspace Paths (Host & Container Separation)
HOST_WORKSPACE_PATH="${HOST_WORKSPACE_PATH:-$(pwd)}"
WORKSPACE_PATH="${WORKSPACE_PATH:-/workspace}"

# 1. Check Environment and Determine host CPU architecture
IS_WSL="false"
PROC_VERSION="$(cat /proc/version 2>/dev/null || true)"
PROC_VERSION_LC="${PROC_VERSION,,}"
case "$PROC_VERSION_LC" in
    *microsoft*)
        if [[ "$PROC_VERSION_LC" == *wsl2* || "$PROC_VERSION_LC" == *microsoft-standard* ]] || [ -d "/mnt/wslg" ] || [ -d "/run/WSL" ]; then
            IS_WSL="true"
        fi
        ;;
esac
unset PROC_VERSION PROC_VERSION_LC

# WSL2 D3D12/DirectX Device Mount
if [ "${IS_WSL}" = "true" ] && [ -e "/dev/dxg" ]; then
    HOST_DXG_MOUNT="/dev/dxg:/dev/dxg"
else
    HOST_DXG_MOUNT="/dev/null:/dev/null"
fi

RAW_ARCH=$(uname -m)
case "${RAW_ARCH}" in
    x86_64)  HOST_ARCH="amd64" ;;
    aarch64) HOST_ARCH="arm64" ;;
    armv8*)  HOST_ARCH="arm64" ;;
    *)       HOST_ARCH="unknown" ;;
esac

# 2. Identify GPU hardware and container toolkit compatibility
HAS_NVIDIA="false"
HAS_TOOLKIT="false"
HAS_TOOLKIT_BIN="false"
HAS_DRI="false"

if command -v nvidia-smi >/dev/null 2>&1; then
    HAS_NVIDIA="true"
    HOST_CUDA_MAX=$(trim_ws "$(nvidia-smi 2>/dev/null | grep -o "CUDA Version: [0-9.]*" | cut -d: -f2 || true)")
    [ -z "$HOST_CUDA_MAX" ] && HOST_CUDA_MAX="Unknown"
fi

if command -v nvidia-ctk >/dev/null 2>&1; then
    HAS_TOOLKIT_BIN="true"
fi

if [ "$HAS_NVIDIA" = "true" ] && command -v docker >/dev/null 2>&1; then
    DOCKER_INFO="$(docker info 2>/dev/null || true)"
    case "${DOCKER_INFO,,}" in
        *runtimes:*nvidia*) HAS_TOOLKIT="true" ;;
    esac
    unset DOCKER_INFO
fi

if [ -d /dev/dri ] && compgen -G "/dev/dri/renderD*" >/dev/null; then
    HAS_DRI="true"
elif [ "${IS_WSL}" = "true" ] && [ -e "/dev/dxg" ]; then
    HAS_DRI="true"
fi

if [ -d /dev/dri ]; then
    HOST_DRI_MOUNT="/dev/dri:/dev/dri"
else
    HOST_DRI_MOUNT="/dev/null:/dev/null"
fi

# 3. Establish Workspace Path and Secure Cache Paths
if [ -z "${DOCKER_DEV_CACHE_DIR}" ]; then
    HOST_CACHE_DIR="${HOST_WORKSPACE_PATH}/.docker_cache"
else
    HOST_WORKSPACE_ROOT="${HOST_WORKSPACE_PATH%/}"
    CACHE_ROOT="${DOCKER_DEV_CACHE_DIR%/}"
    case "${DOCKER_DEV_CACHE_DIR}" in
        /*) ;;
        *)
            log_error "DOCKER_DEV_CACHE_DIR must be an absolute path when set: ${DOCKER_DEV_CACHE_DIR}"
            exit 2
            ;;
    esac
    if [ "${CACHE_ROOT}" = "" ]; then
        log_error "DOCKER_DEV_CACHE_DIR must not be root (/)."
        exit 2
    fi
    if [ "${CACHE_ROOT}" = "${HOST_WORKSPACE_ROOT}" ]; then
        log_error "DOCKER_DEV_CACHE_DIR must not be the workspace root: ${DOCKER_DEV_CACHE_DIR}"
        exit 2
    fi
    HOST_CACHE_DIR="${CACHE_ROOT}"
fi
ensure_dir "${HOST_CACHE_DIR}"

DISPLAY_TYPE="X11"
HOST_XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}"
HOST_WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}"

if [ "${IS_WSL}" = "true" ]; then
    if [ -d "/mnt/wslg/runtime-dir" ]; then
        HOST_XDG_RUNTIME_DIR="/mnt/wslg/runtime-dir"
        [ -z "${HOST_WAYLAND_DISPLAY}" ] && HOST_WAYLAND_DISPLAY="wayland-0"
    fi
fi

if [ -n "${SUDO_USER:-}" ]; then
    HOST_HOME=$(getent passwd "${SUDO_USER}" | cut -d: -f6)
else
    HOST_HOME="${HOME:-}"
fi
REAL_HOST_XAUTH="${XAUTHORITY:-${HOST_HOME}/.Xauthority}"

HOST_XAUTHORITY_SCOPED="${HOST_CACHE_DIR}/container_xauthority"
if [ -s "${REAL_HOST_XAUTH}" ] && command -v xauth >/dev/null 2>&1; then
    DISPLAY_NUM="${DISPLAY:-:0}"
    DISPLAY_NUM="${DISPLAY_NUM#:}"
    DISPLAY_NUM="${DISPLAY_NUM%%.*}"
    rm -f "${HOST_XAUTHORITY_SCOPED}"
    if xauth -b -f "${REAL_HOST_XAUTH}" extract - ":${DISPLAY_NUM}" 2>/dev/null | xauth -b -f "${HOST_XAUTHORITY_SCOPED}" merge - 2>/dev/null; then
        chmod 644 "${HOST_XAUTHORITY_SCOPED}"
        HOST_XAUTHORITY="${HOST_XAUTHORITY_SCOPED}"
    fi
fi

if [ ! -f "${HOST_XAUTHORITY:-}" ]; then
    HOST_XAUTHORITY="${HOST_CACHE_DIR}/dummy_xauthority"
    ensure_file "${HOST_XAUTHORITY}"
fi

if [ -S "${SSH_AUTH_SOCK:-}" ]; then
    HOST_SSH_AUTH_SOCK="${SSH_AUTH_SOCK}"
elif [ -n "${SUDO_USER:-}" ]; then
    _USER_SOCK=$(find /tmp/ssh-* /tmp/ssh-agent-* -type s -user "${SUDO_USER}" -name "agent.*" -print -quit 2>/dev/null)
    HOST_SSH_AUTH_SOCK="${_USER_SOCK:-}"
else
    HOST_SSH_AUTH_SOCK=""
fi

if [ -n "$HOST_WAYLAND_DISPLAY" ]; then
    DISPLAY_TYPE="Wayland"
    if [ -S "${HOST_XDG_RUNTIME_DIR}/${HOST_WAYLAND_DISPLAY}" ]; then
        :
    elif [ -S "/run/user/$(id -u)/${HOST_WAYLAND_DISPLAY}" ]; then
        HOST_XDG_RUNTIME_DIR="/run/user/$(id -u)"
    fi
fi

if [ -z "${HOST_XDG_RUNTIME_DIR}" ] || [ ! -d "${HOST_XDG_RUNTIME_DIR}" ]; then
    ensure_dir "${HOST_CACHE_DIR}/dummy_xdg_runtime"
    HOST_XDG_RUNTIME_DIR="${HOST_CACHE_DIR}/dummy_xdg_runtime"
fi

if [ -d /tmp/.X11-unix ]; then
    HOST_X11_DIR="/tmp/.X11-unix"
elif [ "${IS_WSL}" = "true" ] && [ -d "/mnt/wslg/.X11-unix" ]; then
    HOST_X11_DIR="/mnt/wslg/.X11-unix"
else
    ensure_dir "${HOST_CACHE_DIR}/dummy_x11_unix"
    HOST_X11_DIR="${HOST_CACHE_DIR}/dummy_x11_unix"
fi

if [ "${IS_WSL}" = "true" ] && [ -d "/usr/lib/wsl" ]; then
    WSL_LIB_DIR_MOUNT="/usr/lib/wsl"
else
    WSL_LIB_DIR_DUMMY="${HOST_CACHE_DIR}/dummy_wsl_lib"
    ensure_dir "$WSL_LIB_DIR_DUMMY"
    WSL_LIB_DIR_MOUNT="$WSL_LIB_DIR_DUMMY"
fi

if [ -f "${HOST_HOME}/.gitconfig" ]; then
    HOST_GITCONFIG="${HOST_HOME}/.gitconfig"
else
    ensure_file "${HOST_CACHE_DIR}/dummy_gitconfig"
    HOST_GITCONFIG="${HOST_CACHE_DIR}/dummy_gitconfig"
fi

for _path_var in HOST_HOME HOST_CACHE_DIR HOST_X11_DIR HOST_GITCONFIG HOST_XAUTHORITY; do
    _val="${!_path_var}"
    if [[ "$_val" == *" "* ]]; then
        log_warn "$_path_var contains spaces ('$_val'). Some shell tools may require extra quoting."
    fi
done

# 4. Python Interpreter Detection
GET_PY_SCRIPT="${WS_SCRIPTS}/util_get_python.sh"
[ ! -f "$GET_PY_SCRIPT" ] && GET_PY_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/util_get_python.sh"
if [ -f "$GET_PY_SCRIPT" ]; then
    PYTHON_EXECUTABLE=$(bash "$GET_PY_SCRIPT")
else
    PYTHON_EXECUTABLE="${SYS_PYTHON_EXE:-/usr/bin/python3}"
fi

# 5. Output for Makefile integration
emit_env "HOST_WORKSPACE_PATH" "${HOST_WORKSPACE_PATH}"
emit_env "WORKSPACE_PATH" "${WORKSPACE_PATH}"
emit_env "IS_WSL" "${IS_WSL}"
emit_env "HOST_DXG_MOUNT" "${HOST_DXG_MOUNT}"
emit_env "HOST_ARCH" "${HOST_ARCH}"
emit_env "HAS_NVIDIA" "${HAS_NVIDIA}"
emit_env "HAS_TOOLKIT" "${HAS_TOOLKIT}"
emit_env "HAS_TOOLKIT_BIN" "${HAS_TOOLKIT_BIN}"
emit_env "HAS_DRI" "${HAS_DRI}"
emit_env "HOST_DRI_MOUNT" "${HOST_DRI_MOUNT}"
emit_env "DISPLAY_TYPE" "${DISPLAY_TYPE}"
emit_env "HOST_XDG_RUNTIME_DIR" "${HOST_XDG_RUNTIME_DIR}"
emit_env "HOST_WAYLAND_DISPLAY" "${HOST_WAYLAND_DISPLAY}"
emit_env "HOST_XAUTHORITY" "${HOST_XAUTHORITY}"
emit_env "HOST_HOME" "${HOST_HOME}"
emit_env "HOST_CACHE_DIR" "${HOST_CACHE_DIR}"
emit_env "HOST_X11_DIR" "${HOST_X11_DIR}"
emit_env "HOST_GITCONFIG" "${HOST_GITCONFIG}"
emit_env "HOST_SSH_AUTH_SOCK" "${HOST_SSH_AUTH_SOCK}"
emit_env "HOST_CUDA_MAX" "${HOST_CUDA_MAX:-Unknown}"
emit_env "WSL_LIB_DIR_MOUNT" "${WSL_LIB_DIR_MOUNT}"
emit_env "PYTHON_EXECUTABLE" "${PYTHON_EXECUTABLE}"
