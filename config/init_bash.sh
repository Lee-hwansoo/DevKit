#!/bin/bash
# =============================================================================
# config/init_bash.sh
# Common shell initialization for Docker development environment
#
# Sets up core environment variables and sources dependent configuration files
# to ensure a consistent developer experience across ROS1 and ROS2 targets.
# =============================================================================

# ccache
export PATH="/usr/lib/ccache:$PATH"
export CCACHE_DIR=/cache/ccache

# uv (Python)
export UV_CACHE_DIR=/cache/uv
export UV_PYTHON=${UV_PYTHON:-3.10}
export UV_PROJECT_ENVIRONMENT="${WORKSPACE_PATH:-/workspace}/install/.venv"

# C++ Standard
export CMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17}

# Custom Aliases
source /docker_dev/config/util_aliases.sh

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
if [ -f "${WORKSPACE_PATH:-/workspace}/install/setup.bash" ]; then
    source "${WORKSPACE_PATH:-/workspace}/install/setup.bash"
fi

# Colcon Argument Completion
if [ -f /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash ]; then
    source /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash
fi

# ROS Version-specific Configuration
ROS_ENV_INIT="/docker_dev/config/init_ros_env.sh"
[ ! -f "$ROS_ENV_INIT" ] && ROS_ENV_INIT="/opt/scripts/init_ros_env.sh"
if [ -f "$ROS_ENV_INIT" ]; then
    source "$ROS_ENV_INIT"
fi

# Auto-activate uv Virtual Environment (.venv)
if [ -f "${WORKSPACE_PATH:-/workspace}/install/.venv/bin/activate" ]; then
    source "${WORKSPACE_PATH:-/workspace}/install/.venv/bin/activate"
fi

# GPU Environment Variables (Sourced after ROS to maintain LD_LIBRARY_PATH priority)
if [ -f /root/.gpu_env.sh ]; then
    source /root/.gpu_env.sh
fi

# Welcome Message (MOTD)
WELCOME_SH="/docker_dev/scripts/show_welcome.sh"
[ ! -f "$WELCOME_SH" ] && WELCOME_SH="/opt/scripts/show_welcome.sh"
if [ -f "$WELCOME_SH" ]; then
    bash "$WELCOME_SH"
fi
