#!/bin/bash
# =============================================================================
# scripts/check_env.sh
# Diagnostic engine for host environment detection
#
# Precisely detects GPU availability, hardware architecture, container toolkits,
# and display server configurations (X11/Wayland). Results are output in
# KEY=VALUE format for Makefile integration.
# =============================================================================

# Load path configuration
[ -f "/workspace/config/util_paths.sh" ] && source "/workspace/config/util_paths.sh"
[ -z "$WS_ROOT" ] && source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh"

# Load logging utility
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="$(dirname "${BASH_SOURCE[0]}")/util_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG" || true
LOG_PREFIX="[Env Detector]"

# 0. Detect Workspace Paths (Host & Container Separation)
HOST_WORKSPACE_PATH="${HOST_WORKSPACE_PATH:-$(pwd)}"
WORKSPACE_PATH="${WORKSPACE_PATH:-/workspace}"

# 1. Check Environment and Determine host CPU architecture
IS_WSL="false"
if grep -qi "microsoft" /proc/version 2>/dev/null; then
    if grep -qiE "WSL2|microsoft-standard" /proc/version 2>/dev/null || [ -d "/mnt/wslg" ] || [ -d "/run/WSL" ]; then
        IS_WSL="true"
    fi
fi

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
    HOST_CUDA_MAX=$(nvidia-smi 2>/dev/null | grep -o "CUDA Version: [0-9.]*" | cut -d: -f2 | xargs || echo "Unknown")
fi

if command -v nvidia-ctk >/dev/null 2>&1; then
    HAS_TOOLKIT_BIN="true"
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if docker info 2>/dev/null | grep -iq "Runtimes: .*nvidia"; then
        HAS_TOOLKIT="true"
    fi
fi

if [ -d /dev/dri ] && ls /dev/dri/renderD* >/dev/null 2>&1; then
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
    HOST_CACHE_DIR="${DOCKER_DEV_CACHE_DIR}"
fi
mkdir -p "${HOST_CACHE_DIR}"

DISPLAY_TYPE="X11"
HOST_XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}"
HOST_WAYLAND_DISPLAY="${WAYLAND_DISPLAY}"

if [ "${IS_WSL}" = "true" ]; then
    if [ -d "/mnt/wslg/runtime-dir" ]; then
        HOST_XDG_RUNTIME_DIR="/mnt/wslg/runtime-dir"
        [ -z "${HOST_WAYLAND_DISPLAY}" ] && HOST_WAYLAND_DISPLAY="wayland-0"
    fi
fi

if [ -n "${SUDO_USER}" ]; then
    HOST_HOME=$(getent passwd "${SUDO_USER}" | cut -d: -f6)
else
    HOST_HOME="${HOME}"
fi
REAL_HOST_XAUTH="${XAUTHORITY:-${HOST_HOME}/.Xauthority}"

HOST_XAUTHORITY_SCOPED="${HOST_CACHE_DIR}/container_xauthority"
if [ -s "${REAL_HOST_XAUTH}" ] && command -v xauth >/dev/null 2>&1; then
    DISPLAY_NUM="${DISPLAY#:}"
    DISPLAY_NUM="${DISPLAY_NUM%%.*}"
    rm -f "${HOST_XAUTHORITY_SCOPED}"
    if xauth -b -f "${REAL_HOST_XAUTH}" extract - ":${DISPLAY_NUM}" 2>/dev/null | xauth -b -f "${HOST_XAUTHORITY_SCOPED}" merge - 2>/dev/null; then
        chmod 644 "${HOST_XAUTHORITY_SCOPED}"
        HOST_XAUTHORITY="${HOST_XAUTHORITY_SCOPED}"
    fi
fi

if [ ! -f "${HOST_XAUTHORITY:-}" ]; then
    HOST_XAUTHORITY="${HOST_CACHE_DIR}/dummy_xauthority"
    touch "${HOST_XAUTHORITY}"
fi

if [ -S "${SSH_AUTH_SOCK}" ]; then
    HOST_SSH_AUTH_SOCK="${SSH_AUTH_SOCK}"
elif [ -n "${SUDO_USER}" ]; then
    _USER_SOCK=$(find /tmp/ssh-* /tmp/ssh-agent-* -type s -user "${SUDO_USER}" -name "agent.*" 2>/dev/null | head -n 1)
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
    mkdir -p "${HOST_CACHE_DIR}/dummy_xdg_runtime"
    HOST_XDG_RUNTIME_DIR="${HOST_CACHE_DIR}/dummy_xdg_runtime"
fi

if [ -d /tmp/.X11-unix ]; then
    HOST_X11_DIR="/tmp/.X11-unix"
elif [ "${IS_WSL}" = "true" ] && [ -d "/mnt/wslg/.X11-unix" ]; then
    HOST_X11_DIR="/mnt/wslg/.X11-unix"
else
    mkdir -p "${HOST_CACHE_DIR}/dummy_x11_unix"
    HOST_X11_DIR="${HOST_CACHE_DIR}/dummy_x11_unix"
fi

if [ "${IS_WSL}" = "true" ] && [ -d "/usr/lib/wsl" ]; then
    WSL_LIB_DIR_MOUNT="/usr/lib/wsl"
else
    WSL_LIB_DIR_DUMMY="${HOST_CACHE_DIR}/dummy_wsl_lib"
    mkdir -p "$WSL_LIB_DIR_DUMMY"
    WSL_LIB_DIR_MOUNT="$WSL_LIB_DIR_DUMMY"
fi

if [ -f "${HOST_HOME}/.gitconfig" ]; then
    HOST_GITCONFIG="${HOST_HOME}/.gitconfig"
else
    touch "${HOST_CACHE_DIR}/dummy_gitconfig"
    HOST_GITCONFIG="${HOST_CACHE_DIR}/dummy_gitconfig"
fi

for _path_var in HOST_HOME HOST_CACHE_DIR HOST_X11_DIR HOST_GITCONFIG HOST_XAUTHORITY; do
    _val="${!_path_var}"
    if echo "$_val" | grep -q ' '; then
        log_warn "$_path_var contains spaces ('$_val'). This may cause Makefile eval issues."
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
echo "HOST_WORKSPACE_PATH=${HOST_WORKSPACE_PATH}"
echo "WORKSPACE_PATH=${WORKSPACE_PATH}"
echo "IS_WSL=${IS_WSL}"
echo "HOST_DXG_MOUNT=${HOST_DXG_MOUNT}"
echo "HOST_ARCH=${HOST_ARCH}"
echo "HAS_NVIDIA=${HAS_NVIDIA}"
echo "HAS_TOOLKIT=${HAS_TOOLKIT}"
echo "HAS_TOOLKIT_BIN=${HAS_TOOLKIT_BIN}"
echo "HAS_DRI=${HAS_DRI}"
echo "HOST_DRI_MOUNT=${HOST_DRI_MOUNT}"
echo "DISPLAY_TYPE=${DISPLAY_TYPE}"
echo "HOST_XDG_RUNTIME_DIR=${HOST_XDG_RUNTIME_DIR}"
echo "HOST_WAYLAND_DISPLAY=${HOST_WAYLAND_DISPLAY}"
echo "HOST_XAUTHORITY=${HOST_XAUTHORITY}"
echo "HOST_HOME=${HOST_HOME}"
echo "HOST_CACHE_DIR=${HOST_CACHE_DIR}"
echo "HOST_X11_DIR=${HOST_X11_DIR}"
echo "HOST_GITCONFIG=${HOST_GITCONFIG}"
echo "HOST_SSH_AUTH_SOCK=${HOST_SSH_AUTH_SOCK}"
echo "HOST_CUDA_MAX=${HOST_CUDA_MAX:-Unknown}"
echo "WSL_LIB_DIR_MOUNT=${WSL_LIB_DIR_MOUNT}"
echo "PYTHON_EXECUTABLE=${PYTHON_EXECUTABLE}"
