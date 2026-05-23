# =============================================================================
# Bootstrap: Centralized Path Management (Single Source of Truth)
# =============================================================================
WS_ROOT="${WORKSPACE_PATH:-/workspace}"
UTIL_PATHS="${WS_ROOT}/config/util_paths.sh"
[ -f "$UTIL_PATHS" ] && source "$UTIL_PATHS"

# Force UTF-8 locale for terminal emoji and ASCII art support
export LANG=${LANG:-C.UTF-8}
export LC_ALL=${LANG:-C.UTF-8}
export LANGUAGE=${LANG:-en_US.UTF-8}

# Suppress AT-SPI accessibility bus warnings in GUI applications (like Terminator)
export NO_AT_BRIDGE=1

# Fix for "detected dubious ownership" git error in Docker/WSL2 (Optimized for Read-Only .gitconfig)
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="safe.directory"
export GIT_CONFIG_VALUE_0="*"
export GIT_CONFIG_PARAMETERS="'safe.directory=*'"
git config --system --get-all safe.directory 2>/dev/null | grep -q "^[*]$" || \
git config --system --add safe.directory "*" 2>/dev/null || true

# ccache
export PATH="/usr/lib/ccache:$PATH"
export CCACHE_DIR="${WS_CCACHE_DIR}"

# uv (Python)
export UV_CACHE_DIR="${WS_UV_CACHE_DIR}"
export UV_PYTHON=${UV_PYTHON:-3.10}
export UV_PROJECT_ENVIRONMENT="${WS_VENV}"

# C++ Standard
export CMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17}

# Custom Aliases
source "${WS_CONFIG}/util_aliases.sh"

# Synchronize workspace links
if [ -f "${WS_SCRIPTS}/util_setup_links.sh" ]; then
    "${WS_SCRIPTS}/util_setup_links.sh"
fi

# Shell Prompt
export PS1="\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ "

# =============================================================================
# ROS Environment (Common for ROS1 & ROS2)
# =============================================================================

# Dynamic Sourcing of ROS Core Environment
if [ -f "/opt/ros/${ROS_DISTRO:-humble}/setup.bash" ]; then
    source /opt/ros/${ROS_DISTRO:-humble}/setup.bash
fi

# Workspace Overlay (Automatically sourced after colcon build)
if [ -f "${WS_INSTALL}/setup.bash" ]; then
    source "${WS_INSTALL}/setup.bash"
fi

# Colcon Argument Completion
if [ -f /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash ]; then
    source /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash
fi

# ROS Version-specific Configuration
ROS_ENV_INIT="${WS_CONFIG}/init_ros_env.sh"
if [ -f "$ROS_ENV_INIT" ]; then
    source "$ROS_ENV_INIT"
fi

# Auto-activate uv Virtual Environment (.venv)
if [ -f "${WS_VENV}/bin/activate" ]; then
    source "${WS_VENV}/bin/activate"
fi

# GPU Environment Variables (Sourced after ROS to maintain LD_LIBRARY_PATH priority)
if [ -f "${HOME}/.gpu_env.sh" ]; then
    source "${HOME}/.gpu_env.sh"
fi

# Welcome Message (MOTD)
WELCOME_SH="${WS_SCRIPTS}/show_welcome.sh"
if [ -f "$WELCOME_SH" ]; then
    bash "$WELCOME_SH"
fi
