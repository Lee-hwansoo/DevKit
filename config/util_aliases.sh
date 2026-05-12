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

# =============================================================================
# Environment
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

# =============================================================================
# Internal Helpers & Core Logic (Implementation)
# =============================================================================

# Smart Python Detection for Builds
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
function __get_gpu_cmake_args() {
    local script="/docker_dev/scripts/setup_gpu.sh"
    [ ! -f "$script" ] && script="${WORKSPACE_PATH:-/workspace}/scripts/setup_gpu.sh"

    if [ -f "$script" ]; then
        bash "$script" opencv_args 2>/dev/null
    else
        echo "-DWITH_CUDA=OFF"
    fi
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

function __print_help() {
    [ "$INTERACTIVE" = false ] && return
    print_banner GUIDE
    echo -e "  Project: ${BLUE}${COMPOSE_PROJECT_NAME}${NC} | WS: ${GREEN}${WORKSPACE_PATH}${NC} | ROS: ${YELLOW}${ROS_DISTRO:-None}${NC} | GPU: ${YELLOW}${GPU_MODE:-auto}${NC}"

    local current_section=""
    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*"## @section" ]]; then
            local section_data="${line#*## @section }"
            local s_emoji=$(echo "$section_data" | cut -d'|' -f1 | xargs)
            local s_title=$(echo "$section_data" | cut -d'|' -f2 | xargs)
            local s_color_name=$(echo "$section_data" | cut -d'|' -f3 | xargs)
            local s_color="${!s_color_name:-$PURPLE}"
            printf "\n  ${s_color}%s  %s:${NC}\n" "$s_emoji" "$s_title"
        elif [[ $line =~ ^[[:space:]]*"## @alias" ]]; then
            local content="${line#*## @alias }"
            local cmd=$(echo "${content%%:*}" | xargs)
            local desc=$(echo "${content#*:}" | xargs)
            printf "    ${GREEN}%-22s${NC} : %s\n" "$cmd" "$desc"
        fi
    done < "$BASH_SOURCE"

    echo -e ""
    echo -e "  Type ${CYAN}h${NC} or ${CYAN}help${NC} to see this guide again."
}

# Helper function to fetch ROS package list for completion
function __ros_package_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    # Fetch package names using colcon list (silencing errors if not in a workspace)
    local pkgs=$(colcon list -n 2>/dev/null)
    COMPREPLY=( $(compgen -W "${pkgs}" -- ${cur}) )
}

# =============================================================================
# Build & Development Utilities
# =============================================================================

## @section 🚀 | Essential Workflow | PURPLE
# One-step Workspace Initialization (mkenv + uvs + sync_deps + build)
# Automatically selects between cb (ROS), mbuild (C++), or no-build (Python)
## @alias mksync [--share] : One-step workspace initialization
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

## @alias mbuild / mclean : C++ build / clean (Modern CMake)
alias mbuild='cmake -S ${WORKSPACE_PATH:-/workspace}/src -B ${WORKSPACE_PATH:-/workspace}/build -Wno-dev --no-warn-unused-cli -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=${WORKSPACE_PATH:-/workspace}/install -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17} -DPYTHON_EXECUTABLE=$(__get_build_py_exe) $(__get_gpu_cmake_args) && cmake --build ${WORKSPACE_PATH:-/workspace}/build -j$(nproc) --target install'
alias mclean='rm -rf ${WORKSPACE_PATH:-/workspace}/build ${WORKSPACE_PATH:-/workspace}/install && echo -e "${BLUE}ℹ${NC} Build and Install directories cleared."'

## @alias sync_deps / check_deps : Sync / Check dependencies
alias sync_deps='bash /docker_dev/scripts/setup_sync_deps.sh'
alias check_deps='bash /docker_dev/scripts/check_deps.sh'

# =============================================================================
# ROS (ROS1 & ROS2 Common)
# =============================================================================

## @section 🤖 | ROS & Simulation | BLUE
if [ -n "${ROS_DISTRO}" ]; then
    # --- Build  --------------------------------------------------------------
    ## @alias cb / cbp / cbm : colcon build (build, packages-select, metas | RelWithDebInfo| )
    alias cb='colcon --log-base ${WORKSPACE_PATH:-/workspace}/log build --symlink-install --build-base ${WORKSPACE_PATH:-/workspace}/build --install-base ${WORKSPACE_PATH:-/workspace}/install --cmake-args -Wno-dev --no-warn-unused-cli -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17} -DPYTHON_EXECUTABLE=$(__get_build_py_exe) $(__get_gpu_cmake_args)'
    alias cbp='colcon --log-base ${WORKSPACE_PATH:-/workspace}/log build --symlink-install --build-base ${WORKSPACE_PATH:-/workspace}/build --install-base ${WORKSPACE_PATH:-/workspace}/install --cmake-args -Wno-dev --no-warn-unused-cli -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17} -DPYTHON_EXECUTABLE=$(__get_build_py_exe) $(__get_gpu_cmake_args) --packages-select'
    alias cbm='colcon --log-base ${WORKSPACE_PATH:-/workspace}/log build --symlink-install --build-base ${WORKSPACE_PATH:-/workspace}/build --install-base ${WORKSPACE_PATH:-/workspace}/install --metas ${WORKSPACE_PATH:-/workspace}/colcon.meta --cmake-args -Wno-dev --no-warn-unused-cli -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17} -DPYTHON_EXECUTABLE=$(__get_build_py_exe) $(__get_gpu_cmake_args)'

    ## @alias cbr / cbrp / cbrm : colcon build (Release optimized)
    alias cbr='colcon --log-base ${WORKSPACE_PATH:-/workspace}/log build --symlink-install --build-base ${WORKSPACE_PATH:-/workspace}/build --install-base ${WORKSPACE_PATH:-/workspace}/install --cmake-args -Wno-dev --no-warn-unused-cli -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17} -DPYTHON_EXECUTABLE=$(__get_build_py_exe) $(__get_gpu_cmake_args)'
    alias cbrp='colcon --log-base ${WORKSPACE_PATH:-/workspace}/log build --symlink-install --build-base ${WORKSPACE_PATH:-/workspace}/build --install-base ${WORKSPACE_PATH:-/workspace}/install --cmake-args -Wno-dev --no-warn-unused-cli -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17} -DPYTHON_EXECUTABLE=$(__get_build_py_exe) $(__get_gpu_cmake_args) --packages-select'
    alias cbt='colcon test'

    ## @alias s / sb : Source setup.bash / .bashrc
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

    # --- ROS Commands --------------------------------------------------------
    ## @alias rt / rte : Topic list / Echo topic
    alias rt='ros2 topic list'
    alias rte='ros2 topic echo'
    ## @alias rth / rn : Topic Hz / Node list
    alias rth='ros2 topic hz'
    alias rn='ros2 node list'
    ## @alias rs / rp : Service list / Param list
    alias rs='ros2 service list'
    alias rp='ros2 param list'
    ## @alias rr / rl : ros run / ros launch
    alias rr='ros2 run'
    alias rl='ros2 launch'
    ## @alias ri : Show message/interface
    alias ri='ros2 interface show'
    ## @alias gz / gzs : Gazebo / Gazebo Start
    alias gz='gazebo'
    alias gzs='ros2 launch gazebo_ros gazebo.launch.py'
    ## @alias rqt : rqt
    alias rqt='rqt'

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
        alias gzs='roslaunch gazebo_ros empty_world.launch'
    fi

fi

# =============================================================================
# Python / uv
# =============================================================================

## @section 🐍 | Python & Dev Tools | BLUE
## @alias uvs / uvr : uv sync / uv run
alias uvs='uv sync --project ${WORKSPACE_PATH:-/workspace}/src --extra ${UV_EXTRA:-cpu}'
alias uvr='uv run'
## @alias uvp / uvl : uv pip install / list
alias uvp='uv pip install'
alias uvl='uv pip list'

# Project-specific venv creation
## @alias mkenv [--share] : Create pure or system shared python venv
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

# Smart activation function that handles Shared (Integrated) vs Pure (Isolated) environments
## @alias activate : Activate the virtual environment
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

## @alias pyv / pyt : Python & PyTorch diagnostics
alias pyv='__pyv_impl'
alias pyt='torch_check'

## @alias uvpython / syspython : Manage interpreters via uv or system
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
# Hardware Diagnostics
# =============================================================================

## @section 🔍 | Hardware & Rendering | BLUE
## @alias hw_check : Full hardware/env diagnostics
alias hw_check='bash /docker_dev/scripts/check_hardware.sh'

## @alias gpu_check / vulkan_check : GPU/Vulkan availability check
alias gpu_check='glxinfo 2>&1 | grep -E "OpenGL (vendor|renderer|version)" || echo "Error: glxinfo failed (no display?)"'
alias vulkan_check='vulkaninfo --summary 2>/dev/null | head -20 || echo "Vulkan not available"'

## @alias gpu_test : GPU performance test
alias gpu_test='timeout 5 glxgears -info 2>&1 | head -10 || echo "GPU test failed (no display?)"'

## @alias gpu_status : Show GPU, Display & Lib status
alias gpu_status='source /docker_dev/scripts/setup_gpu.sh status'
## @alias gpu_setup : Auto-configure optimal GPU mode
alias gpu_setup='source /docker_dev/scripts/setup_gpu.sh auto && gpu_status'

## @alias use_nvidia / _intel / _amd / _cpu : Force Hardware acceleration mode
alias use_nvidia='source /docker_dev/scripts/setup_gpu.sh nvidia && gpu_status'
alias use_intel='source /docker_dev/scripts/setup_gpu.sh intel && gpu_status'
alias use_amd='source /docker_dev/scripts/setup_gpu.sh amd && gpu_status'
alias use_cpu='source /docker_dev/scripts/setup_gpu.sh cpu && gpu_status'

## @alias ccc / ccs : ccache clear / ccache stat
alias ccs='ccache -s'
alias ccc='ccache -C'

# =============================================================================
# System Utilities
# =============================================================================

## @section 🛠️ | System Utilities | BLUE

# --- Navigation ----------------------------------------------------------
## @alias cw / cs / cc : cd to root / src / config
alias cw='cd ${WORKSPACE_PATH:-/workspace}'
alias cs='cd ${WORKSPACE_PATH:-/workspace}/src'
alias cc='cd /docker_dev/config'

# --- Shell & Editing ---------------------------------------------------------
## @alias g : git wrapper (status, pull, etc)
## @alias ll / la : Detailed directory listing
## @alias k / k9 : killall / killall -9
alias k='killall'
alias k9='killall -9'
alias g='git'
alias ll='ls -alF'
alias la='ls -A'

# =============================================================================
# Help / Documentation
# =============================================================================

alias h='__print_help'
alias help='__print_help'

# =============================================================================
# Bash Completions
# =============================================================================

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
    complete -F __ros_package_completion cbp
    complete -F __ros_package_completion cbrp
fi
