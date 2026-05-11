#!/bin/bash
# =============================================================================
# config/util_aliases.sh
# Comprehensive alias collection for ROS2, C++, Python (uv), and Diagnostics
#
# Loaded via ~/.bashrc using: source /docker_dev/config/util_aliases.sh
# Note: ROS-specific aliases are only defined if the ros2 command is available,
# ensuring compatibility with non-ROS dev targets.
# Note: This file should only be loaded inside the container environment.
# =============================================================================

# Container Environment Guard: Prevent loading on the host machine
if [ ! -f /.dockerenv ] && [ "$FORCE_LOAD_ALIASES" != "true" ]; then
    return 0
fi

# Load logging utility for shared color variables & branding
SOURCE_LOG="/docker_dev/scripts/util_logging.sh"
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="$(dirname "${BASH_SOURCE[0]}")/../scripts/util_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"

# Non-interactive shell detection
[[ $- == *i* ]] && INTERACTIVE=true || INTERACTIVE=false

# Environment Defaults & Paths
VENV_PATH="${WORKSPACE_PATH:-/workspace}/install/.venv"
export SYS_PYTHON_EXE=${SYS_PYTHON_EXE:-/usr/bin/python3}

# Smart Python Detection for Builds
# Returns venv python ONLY if --share (system-site-packages) is enabled; otherwise defaults to system python.
function __get_build_py_exe() {
    local script_live="${WORKSPACE_PATH:-/workspace}/scripts/util_get_python.sh"
    local script_static="/docker_dev/scripts/util_get_python.sh"

    # 1. Prefer central detection script (Single Source of Truth)
    if [ -f "$script_live" ]; then
        bash "$script_live"
    elif [ -f "$script_static" ]; then
        bash "$script_static"
    else
        # 2. Minimal fallback to system python (avoiding logic duplication)
        echo "${SYS_PYTHON_EXE:-/usr/bin/python3}"
    fi
}

# Smart GPU-aware CMake Arguments
# Dynamically enables CUDA support for OpenCV if NVIDIA hardware is detected.
function __get_gpu_cmake_args() {
    local script="/docker_dev/scripts/setup_gpu.sh"
    [ ! -f "$script" ] && script="${WORKSPACE_PATH:-/workspace}/scripts/setup_gpu.sh"

    if [ -f "$script" ]; then
        bash "$script" opencv_args 2>/dev/null
    else
        echo "-DWITH_CUDA=OFF"
    fi
}

# =============================================================================
# ROS (ROS1 & ROS2 Common)
# =============================================================================
if [ -n "${ROS_DISTRO}" ]; then
    # --- Build (Unified Colcon) ----------------------------------------------
    # CMAKE_CXX_STANDARD is injected via .env -> docker-compose -> ENV
    alias cb='colcon build --symlink-install --install-base ${WORKSPACE_PATH:-/workspace}/install --cmake-args -Wno-dev -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17} -DPYTHON_EXECUTABLE=$(__get_build_py_exe) $(__get_gpu_cmake_args)'
    alias cbp='colcon build --symlink-install --install-base ${WORKSPACE_PATH:-/workspace}/install --cmake-args -Wno-dev -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17} -DPYTHON_EXECUTABLE=$(__get_build_py_exe) $(__get_gpu_cmake_args) --packages-select'
    alias cbm='colcon build --symlink-install --install-base ${WORKSPACE_PATH:-/workspace}/install --cmake-args -Wno-dev -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17} -DPYTHON_EXECUTABLE=$(__get_build_py_exe) $(__get_gpu_cmake_args) --metas'

    # Release mode (Optimized)
    alias cbr='colcon build --symlink-install --install-base ${WORKSPACE_PATH:-/workspace}/install --cmake-args -Wno-dev -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17} -DPYTHON_EXECUTABLE=$(__get_build_py_exe) $(__get_gpu_cmake_args)'
    alias cbrp='colcon build --symlink-install --install-base ${WORKSPACE_PATH:-/workspace}/install --cmake-args -Wno-dev -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17} -DPYTHON_EXECUTABLE=$(__get_build_py_exe) $(__get_gpu_cmake_args) --packages-select'
    alias cbt='colcon test'
    # Smart Sourcing: Auto-detects (devel/) or (install/)
    function __smart_source() {
        if [ -f "${WORKSPACE_PATH:-/workspace}/install/setup.bash" ]; then
            source "${WORKSPACE_PATH:-/workspace}/install/setup.bash"
            echo -e "${GREEN}✓${NC} Sourced install/"
        elif [ -f "${WORKSPACE_PATH:-/workspace}/devel/setup.bash" ]; then
            source "${WORKSPACE_PATH:-/workspace}/devel/setup.bash"
            echo -e "${GREEN}✓${NC} Sourced devel/"
        else
            echo -e "${YELLOW}⚠${NC} No setup.bash found in install/ or devel/"
        fi
    }
    alias s='__smart_source'
    alias sb='source ~/.bashrc'

    # --- Navigation ----------------------------------------------------------
    alias cw='cd ${WORKSPACE_PATH:-/workspace}'
    alias cs='cd ${WORKSPACE_PATH:-/workspace}/src'

    # --- ROS Commands --------------------------------------------------------
    # ROS 2 (Default)
    alias rt='ros2 topic list'
    alias rte='ros2 topic echo'
    alias rth='ros2 topic hz'
    alias rn='ros2 node list'
    alias rs='ros2 service list'
    alias rp='ros2 param list'
    alias rr='ros2 run'
    alias rl='ros2 launch'
    alias ri='ros2 interface show'

    # ROS 1 (Fallback if Noetic is detected)
    if [ "${ROS_DISTRO}" = "noetic" ]; then
        alias rt='rostopic list'
        alias rte='rostopic echo'
        alias rth='rostopic hz'
        alias rn='rosnode list'
        alias rs='rosservice list'
        alias rp='rosparam list'
        alias rr='rosrun'
        alias rl='roslaunch'
        alias ri='rosmsg show'
    fi

    alias rqt='rqt'

    # --- Gazebo / Simulation -------------------------------------------------
    alias gz='gazebo'
    alias gzs='ros2 launch gazebo_ros gazebo.launch.py' # ROS 2 standard
fi

# Navigation (Common)
alias cc='cd /docker_dev/config'

# =============================================================================
# Python / uv
# =============================================================================
alias uvs='uv sync --project ${WORKSPACE_PATH:-/workspace}/src --extra ${UV_EXTRA:-cpu}'
alias uvr='uv run'
alias uvp='uv pip install'
alias uvl='uv pip list'

# Project-specific venv creation
# $1: --share (optional) - Enable system-site-packages for system library integration
function mkenv() {
    local share_flag=""
    local py_exe="${UV_PYTHON:-3.10}"
    local msg="pure .venv"
    if [ "$1" == "--share" ]; then
        share_flag="--system-site-packages"
        py_exe="${SYS_PYTHON_EXE}"
        msg="shared .venv (with system packages)"
    fi
    mkdir -p "$(dirname "$VENV_PATH")" && \
    uv venv "$VENV_PATH" --python "$py_exe" $share_flag --seed --prompt "${COMPOSE_PROJECT_NAME:-.venv}" && \
    /docker_dev/scripts/util_setup_links.sh && \
    echo -e "Created ${GREEN}${msg}${NC} in $(dirname "$VENV_PATH") and linked to ${WORKSPACE_PATH:-/workspace}/.venv. Run: ${CYAN}activate${NC}"
}

# Internal helper to purge virtual environment traces (PATH, PS1)
function __venv_purge_state() {
    local v_root="$1"
    [ -z "$v_root" ] && return

    # 1. PATH Cleanup: Safely remove duplicate paths from start/middle/end
    export PATH=":${PATH}:"
    export PATH="${PATH//:${v_root}\/bin:/:}"
    export PATH="${PATH#:}" export PATH="${PATH%:}"

    # 2. PS1 Cleanup: Precisely remove venv prompt (Anchored to ^ to protect paths with parentheses)
    export PS1=$(echo "$PS1" | sed -E 's/^\(([^)]+)\) //g; s/^\(([^)]+)\)//g')
}

# Internal helper to detect venv mode from pyvenv.cfg
function __get_venv_mode() {
    local v_path="$1"
    if grep -q "include-system-site-packages = true" "${v_path}/pyvenv.cfg" 2>/dev/null; then
        echo "SHARED"
    else
        echo "PURE"
    fi
}

# Smart activation function that handles Shared (Integrated) vs Pure (Isolated) environments
function activate() {
    local target_venv="${VENV_PATH:-${WORKSPACE_PATH:-/workspace}/install/.venv}"
    local act_script="${target_venv}/bin/activate"
    [ ! -f "$act_script" ] && { echo -e "${RED}Error:${NC} Virtual environment not found at ${target_venv}, Run ${CYAN}mkenv${NC} or ${CYAN}mksync${NC} first."; return 1; }

    # 1. Surgical Reset: Purge existing traces
    __venv_purge_state "$target_venv"
    unset VIRTUAL_ENV ENVIRONMENT_TYPE _OLD_UV_PYTHON

    # 2. Source & State Locking
    source "$act_script"
    export _OLD_UV_PYTHON="$UV_PYTHON"
    export ENVIRONMENT_TYPE=$(__get_venv_mode "$target_venv")
    if [ "$ENVIRONMENT_TYPE" == "SHARED" ]; then
        export UV_PYTHON="$(which python3)"
    fi

    # Ensure workspace symlinks exist in development for IDE integration
    if [ -d "/docker_dev" ]; then
        /docker_dev/scripts/util_setup_links.sh 2>/dev/null
    fi

    [ "$INTERACTIVE" = true ] && echo -e "${GREEN}✓${NC} Activated (${ENVIRONMENT_TYPE})"

    # 3. Simple Proxy Override: Extend deactivate with custom restoration
    [ "$(type -t deactivate)" != "function" ] && return 0

    # Protect against nested activation overwriting the original backup
    if [ "$(type -t __v_deactivate)" != "function" ]; then
        eval "$(declare -f deactivate | sed '1s/^deactivate/__v_deactivate/')"
    fi

    function deactivate() {
        local v_root="${VIRTUAL_ENV:-$target_venv}"
        __v_deactivate              # Original cleanup

        # Custom restoration cleanup
        [ -n "$_OLD_UV_PYTHON" ] && export UV_PYTHON="$_OLD_UV_PYTHON" || unset UV_PYTHON
        __venv_purge_state "$v_root"

        unset -f __v_deactivate deactivate
        unset ENVIRONMENT_TYPE _OLD_UV_PYTHON
        echo -e "${BLUE}ℹ${NC} Environment deactivated."
    }
}

# Python environment verification
function __pyv_impl() {
    local sys_py="${SYS_PYTHON_EXE}"
    local venv_path="${VENV_PATH}"
    local venv_py="${venv_path}/bin/python3"

    # 1. System Python Status
    local sys_ver="$($sys_py --version 2>&1 | cut -d' ' -f2)"
    printf "  %-18s %s [%s]\n" "System Python:" "$sys_ver" "$sys_py"

    # 2. Virtual Environment Status
    if [ -d "$venv_path" ] && [ -f "$venv_py" ]; then
        local venv_ver="$($venv_py --version 2>&1 | cut -d' ' -f2)"
        local current_mode="${ENVIRONMENT_TYPE:-$(__get_venv_mode "$venv_path")}"
        local mode_color="${NC}"
        [ "$current_mode" == "SHARED" ] && mode_color="${YELLOW}"
        [ "$current_mode" == "PURE" ] && mode_color="${BLUE}"

        if [[ "$VIRTUAL_ENV" == "$venv_path" ]]; then
            printf "  ${GREEN}%-18s${NC} %s (Activated: ${mode_color}%s${NC}) [%s]\n" "uv Virtual Env:" "$venv_ver" "$current_mode" "$venv_path"
        else
            printf "  ${CYAN}%-18s${NC} %s (Inactive: ${mode_color}%s${NC}) [%s]\n" "uv Virtual Env:" "$venv_ver" "$current_mode" "$venv_path"
        fi
    else
        printf "  ${YELLOW}%-18s${NC} %s\n" "uv Virtual Env:" "None (Run 'mkenv' to create)"
    fi

    # 3. Path & uv Summary
    printf "  %-18s %s\n" "Active Binary:" "$(which python3)"
    printf "  %-18s %s\n" "uv Version:" "$(uv --version 2>/dev/null | cut -d' ' -f2)"
}
alias pyv='__pyv_impl'

# PyTorch & CUDA Intelligence Diagnostic
function torch_check() {
    if ! python3 -c "import torch" 2>/dev/null; then
        echo -e "  ${YELLOW}PyTorch not found in the current environment.${NC}"
        return 1
    fi
    python3 -c "
import torch
B, G, Y, N = '\033[0;34m', '\033[0;32m', '\033[1;33m', '\033[0m'
print(f'  {B}PyTorch Version:{N}  {torch.__version__}')
print(f'  {B}CUDA Build:{N}      {torch.version.cuda}')
print(f'  {B}cuDNN Version:{N}   {torch.backends.cudnn.version()}')
print(f'  {B}CUDA Available:{N}   ' + (f'{G}True{N}' if torch.cuda.is_available() else f'{Y}False{N}'))

if torch.cuda.is_available():
    prop = torch.cuda.get_device_properties(0)
    free, total = torch.cuda.mem_get_info(0)
    print(f'  {B}Device Name:{N}      {prop.name}')
    print(f'  {B}VRAM Usage:{N}       {(total-free)/1024**3:.2f} / {total/1024**3:.2f} GB ({(total-free)/total*100:.1f}%)')
    print(f'  {B}Compute Cap:{N}      {prop.major}.{prop.minor}')
"
}
alias pyt='torch_check'

function uvpython() {
    local venv_path="${VENV_PATH}"
    local venv_py="${venv_path}/bin/python3"

    if [ -d "$venv_path" ] && [ -f "$venv_py" ]; then
        if [ $# -eq 0 ]; then
            echo -e "  ${GREEN}uv Virtual Env:${NC} $($venv_py --version 2>&1 | cut -d' ' -f2) (${CYAN}$venv_path${NC})"
        else
            "$venv_py" "$@"
        fi
    else
        echo -e "  ${YELLOW}uv Virtual Env not found.${NC} Listing available base interpreters:"
        uv python list
    fi
}
function syspython() {
    if [ $# -eq 0 ]; then
        echo -e "  ${BLUE}System Python:${NC} $(${SYS_PYTHON_EXE} --version 2>&1) (${CYAN}${SYS_PYTHON_EXE}${NC})"
    else
        "${SYS_PYTHON_EXE}" "$@"
    fi
}

# =============================================================================
# Utils & Build
# =============================================================================
# Standard C++ build workflow (src -> build -> install)
alias mbuild='mkdir -p ${WORKSPACE_PATH:-/workspace}/build && cd ${WORKSPACE_PATH:-/workspace}/build && cmake ../src -Wno-dev -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=${WORKSPACE_PATH:-/workspace}/install -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17} -DPYTHON_EXECUTABLE=$(__get_build_py_exe) $(__get_gpu_cmake_args) && make -j$(nproc) install && cd ${WORKSPACE_PATH:-/workspace}'

alias k='killall'
alias k9='killall -9'
alias g='git'
alias ll='ls -alF'
alias la='ls -A'
alias ccache-stat='ccache -s'
alias ccache-clear='ccache -C'
alias sync_deps='bash /docker_dev/scripts/setup_sync_deps.sh'
alias check_deps='bash /docker_dev/scripts/check_deps.sh'

# Internal helper to categorize the current workspace for intelligent automation
function __detect_project_type() {
    if [ -n "${ROS_DISTRO}" ] && command -v colcon &>/dev/null; then
        # Check for ROS-specific markers
        if [ -f "${WORKSPACE_PATH:-/workspace}/src/CMakeLists.txt" ] || find "${WORKSPACE_PATH:-/workspace}/src" -maxdepth 2 -name "package.xml" | grep -q .; then
            echo "ROS"
            return
        fi
    fi

    if find "${WORKSPACE_PATH:-/workspace}/src" -maxdepth 2 -name "CMakeLists.txt" | grep -q .; then
        echo "CPP"
    else
        echo "PYTHON"
    fi
}

# One-step Workspace Initialization (mkenv + uvs + sync_deps + build)
# Automatically selects between cb (ROS), mbuild (C++), or no-build (Python)
function mksync() {
    local target_py="${UV_PYTHON:-3.10}"
    [ "$1" == "--share" ] && target_py="${SYS_PYTHON_EXE}"

    # 1. Core Environment Setup
    mkenv "$@" && \
    activate && \
    UV_PYTHON="$target_py" uvs && \
    sync_deps --rosdep || return 1

    # 2. Intelligent Build Strategy
    local project_type=$(__detect_project_type)
    case "$project_type" in
        "ROS")
            log_info "ROS environment detected. Executing colcon build (cb)..."
            cb && s ;;
        "CPP")
            log_info "Pure C++ project detected. Executing mbuild..."
            mbuild ;;
        *)
            log_ok "Pure Python or minimal project detected. Skipping build step." ;;
    esac
}

# =============================================================================
# Hardware Diagnostics
# =============================================================================
alias hw_check='bash /docker_dev/scripts/check_hardware.sh'
alias gpu_check='glxinfo 2>&1 | grep -E "OpenGL (vendor|renderer|version)" || echo "Error: glxinfo failed (no display?)"'
alias gpu_test='timeout 5 glxgears -info 2>&1 | head -10 || echo "GPU test failed (no display?)"'
alias vulkan_check='vulkaninfo --summary 2>/dev/null | head -20 || echo "Vulkan not available"'

# --- GPU Control & Status ---
alias gpu_status='source /docker_dev/scripts/setup_gpu.sh status'
alias gpu_setup='source /docker_dev/scripts/setup_gpu.sh auto && gpu_status'
alias use_intel='source /docker_dev/scripts/setup_gpu.sh intel && gpu_status'
alias use_amd='source /docker_dev/scripts/setup_gpu.sh amd && gpu_status'
alias use_nvidia='source /docker_dev/scripts/setup_gpu.sh nvidia && gpu_status'
alias use_cpu='source /docker_dev/scripts/setup_gpu.sh cpu && gpu_status'

# =============================================================================
# Help / Documentation
# =============================================================================
function __print_help() {
    [ "$INTERACTIVE" = false ] && return
    print_banner GUIDE
    echo -e "  Project: ${BLUE}${COMPOSE_PROJECT_NAME}${NC} | WS: ${GREEN}${WORKSPACE_PATH}${NC} | ROS: ${YELLOW}${ROS_DISTRO:-None}${NC} | GPU: ${YELLOW}${GPU_MODE:-auto}${NC}"
    echo -e ""
    echo -e "  ${PURPLE}🚀 Essential Workflow:${NC}"
    echo -e "    ${GREEN}mksync [--share]${NC}  : One-step init (mkenv + uvs + sync_deps + cb + s)"
    echo -e "    ${GREEN}cb${NC} / ${GREEN}cbr${NC}          : colcon build (Standard / Release)"
    echo -e "    ${GREEN}cbp${NC} / ${GREEN}cbrp${NC}        : colcon build --packages-select (Package specific)"
    echo -e "    ${GREEN}cbm${NC}               : colcon build using project meta files"
    echo -e "    ${GREEN}s${NC} / ${GREEN}sb${NC}           : Source workspace setup.bash / Source ~/.bashrc"
    echo -e ""
    echo -e "  ${BLUE}🤖 ROS & Simulation:${NC}"
    echo -e "    ${GREEN}rt${NC} / ${GREEN}rn${NC} / ${GREEN}rl${NC}     : List topics / nodes / launch files"
    echo -e "    ${GREEN}rte${NC} / ${GREEN}rth${NC} / ${GREEN}rshow${NC} : Echo topic / Hz check / Show interface (ri)"
    echo -e "    ${GREEN}rs${NC} / ${GREEN}rp${NC} / ${GREEN}rr${NC}     : List services / params / Run package"
    echo -e "    ${GREEN}rqt${NC} / ${GREEN}gz${NC}          : Launch RQT / Gazebo"
    echo -e "    ${GREEN}gzs${NC}               : Launch Gazebo ROS factory (ROS 2)"
    echo -e ""
    echo -e "  ${BLUE}🐍 Python & Dev Tools:${NC}"
    echo -e "    ${GREEN}mkenv [--share]${NC}   : Create pure or shared (system-site-packages) python venv"
    echo -e "    ${GREEN}activate${NC}          : Activate the created virtual environment"
    echo -e "    ${GREEN}uvs${NC} / ${GREEN}uvr${NC}        : uv sync / uv run"
    echo -e "    ${GREEN}uvp${NC} / ${GREEN}uvl${NC}        : uv pip install / list"
    echo -e "    ${GREEN}pyv${NC} / ${GREEN}pyt${NC}        : Deep diagnostic of active Python & PyTorch environment"
    echo -e "    ${GREEN}syspython${NC}         : Show version or run system python3 explicitly"
    echo -e "    ${GREEN}uvpython${NC}          : Show venv version or manage interpreters via uv"
    echo -e "    ${GREEN}ccache-stat${NC}       : Show compiler cache statistics"
    echo -e ""
    echo -e "  ${BLUE}🔍 Hardware & Rendering:${NC}"
    echo -e "    ${GREEN}hw_check${NC}          : Run full hardware & environment diagnostics"
    echo -e "    ${GREEN}gpu_status${NC}        : Show detailed GPU, Display & Lib diagnostics"
    echo -e "    ${GREEN}gpu_setup ${NC}        : Auto-detect and configure optimal GPU mode"
    echo -e "    ${GREEN}use_nvidia${NC} / ${GREEN}cpu${NC} : Force NVIDIA Hardware / Software rendering"
    echo -e "    ${GREEN}use_intel${NC} / ${GREEN}amd${NC}  : Force Intel or AMD (Mesa) acceleration"
    echo -e "    ${GREEN}gpu_check${NC} / ${GREEN}test${NC} : glxinfo check / glxgears performance test"
    echo -e "    ${GREEN}vulkan_check${NC}      : Vulkan availability & driver check"
    echo -e ""
    echo -e "  ${BLUE}🛠️  System Utilities:${NC}"
    echo -e "    ${GREEN}cw${NC} / ${GREEN}cs${NC} / ${GREEN}cc${NC}     : cd to ${WORKSPACE_PATH:-/workspace}, ${WORKSPACE_PATH:-/workspace}/src, or /docker_dev/config"
    echo -e "    ${GREEN}sync_deps${NC}        : Sync external repos from .repos file"
    echo -e "    ${GREEN}check_deps${NC}       : Verify missing runtime libraries in ${WORKSPACE_PATH:-/workspace}/install/"
    echo -e "    ${GREEN}g${NC}                : git (e.g., g status, g pull)"
    echo -e "    ${GREEN}ll${NC} / ${GREEN}la${NC}          : Detailed ls (long format / all)"
    echo -e "    ${GREEN}k${NC} / ${GREEN}k9${NC}           : killall / killall -9"
    echo -e ""
    echo -e "  Type ${CYAN}h${NC} or ${CYAN}help${NC} to see this guide again. Stay agile!"
}
alias h='__print_help'
alias help='__print_help'

# =============================================================================
# Bash Completions
# =============================================================================
# Helper function to fetch ROS package list for completion
function _ros_package_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    # Fetch package names using colcon list (silencing errors if not in a workspace)
    local pkgs=$(colcon list -n 2>/dev/null)
    COMPREPLY=( $(compgen -W "${pkgs}" -- ${cur}) )
}

# Custom Workspace Functions
complete -W "--share" mksync mkenv

# Python & Dev Tools
complete -W "--extra cpu --extra gpu" uvs
complete -W "--rosdep" sync_deps

# Hardware & GPU Setup
complete -W "status auto nvidia intel amd cpu" gpu_setup
complete -W "status auto nvidia intel amd cpu" gpu_status

# ROS Specific (Package completion for select builds)
if [ -n "${ROS_DISTRO}" ]; then
    complete -F _ros_package_completion cbp
    complete -F _ros_package_completion cbrp
fi
