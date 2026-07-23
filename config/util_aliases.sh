#!/bin/bash
# =============================================================================
# config/util_aliases.sh
# Comprehensive alias collection for ROS2, C++, Python (uv), and Diagnostics
#
# Loaded via ~/.bashrc using: source ${WORKSPACE_PATH:-/workspace}/config/util_aliases.sh
# Note: ROS-specific aliases are only defined when ROS/colcon tools are available,
# keeping pure Python/C++ dev targets clean.
# Note: This file should only be loaded inside the container environment.
# =============================================================================

# =============================================================================
# Environment
# =============================================================================

# Container Environment Guard: Prevent loading on the host machine
if [ ! -f /.dockerenv ] && [ "${FORCE_LOAD_ALIASES:-}" != "true" ]; then
    return 0
fi

# Load centralized paths (Single Source of Truth)
source "${WORKSPACE_PATH:-/workspace}/config/util_paths.sh" 2>/dev/null || source "/tmp/util_paths.sh"
devkit_require "util_logging.sh"
if ! declare -f print_banner >/dev/null 2>&1; then
    print_banner() { :; }
fi
if ! declare -f print_env_info >/dev/null 2>&1; then
    print_env_info() { echo "  Workspace: ${WS_ROOT}"; }
fi

# Non-interactive shell detection
[[ $- == *i* ]] && INTERACTIVE=true || INTERACTIVE=false

# Environment Defaults & Paths
VENV_PATH="${WS_VENV}"
export SYS_PYTHON_EXE=${SYS_PYTHON_EXE:-/usr/bin/python3}

# =============================================================================
# Internal Helpers & Core Logic (Implementation)
# =============================================================================

function __parse_share_flag() {
    DEVKIT_SHARE_MODE=false
    DEVKIT_REMAINING_ARGS=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --share) DEVKIT_SHARE_MODE=true ;;
            *) DEVKIT_REMAINING_ARGS+=("$1") ;;
        esac
        shift
    done

    # ROS 1 Noetic on Ubuntu 20.04 is tied to the system Python ABI. A shared
    # venv keeps rospy/catkin visible and avoids creating an incompatible uv
    # Python environment for production builds.
    if [ "${ROS_DISTRO:-}" = "noetic" ]; then
        DEVKIT_SHARE_MODE=true
    fi
}

# Smart Python Detection for Builds
function __get_build_py_exe() {
    local script="${WS_SCRIPTS}/util_get_python.sh"

    # 1. Prefer central detection script (Single Source of Truth)
    if [ -f "$script" ]; then
        bash "$script"
    else
        # 2. Minimal fallback to system python (avoiding logic duplication)
        echo "${SYS_PYTHON_EXE:-/usr/bin/python3}"
    fi
}

# Smart GPU-aware CMake Arguments
function __get_gpu_cmake_args() {
    local script="${WS_SCRIPTS}/setup_gpu.sh"

    if [ -f "$script" ]; then
        bash "$script" opencv_args 2>/dev/null
    else
        echo "-DWITH_CUDA=OFF"
    fi
}

function __setup_workspace_links() {
    local setup_links="${WS_SCRIPTS}/util_setup_links.sh"
    [ -f "$setup_links" ] || return 0
    "$setup_links" "$@"
}

function __setup_workspace_links_fast() {
    __setup_workspace_links --skip-compile-commands "$@"
}

# Internal helper to purge virtual environment traces (PATH, PS1)
function __venv_purge_state() {
    local v_root="$1"
    [ -z "$v_root" ] && return

    # 1. PATH Cleanup: Safely remove duplicate paths from start/middle/end
    export PATH=":${PATH}:"
    export PATH="${PATH//:${v_root}\/bin:/:}"
    export PATH="${PATH#:}"
    export PATH="${PATH%:}"

    # 2. PS1 Cleanup: strip ONLY our own venv prompt token, never an arbitrary
    #    leading "(...)". The previous regex ate conda's "(base)" and any custom
    #    prompt beginning with parentheses. venv records the token it injected in
    #    VIRTUAL_ENV_PROMPT, so we remove exactly that and nothing else. When no
    #    venv is active the standard _OLD_VIRTUAL_PS1 machinery has already restored PS1.
    if [ -n "${VIRTUAL_ENV_PROMPT:-}" ] && [ -n "${PS1:-}" ]; then
        PS1="${PS1#"(${VIRTUAL_ENV_PROMPT}) "}"
        PS1="${PS1#"(${VIRTUAL_ENV_PROMPT})"}"
        export PS1
    fi
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
    printf "  %-18s %s\n" "Active Binary:" "$(command -v python3)"
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
    [ -d "${WS_SRC}" ] || { echo "PYTHON"; return; }

    if [ -n "${ROS_DISTRO}" ] && command -v colcon &>/dev/null; then
        # Check for ROS-specific markers
        if [ -f "${WS_SRC}/CMakeLists.txt" ] || [ -n "$(find "${WS_SRC}" -maxdepth 2 -name "package.xml" -print -quit 2>/dev/null)" ]; then
            echo "ROS"
            return
        fi
    fi

    if [ -n "$(find "${WS_SRC}" -maxdepth 2 -name "CMakeLists.txt" -print -quit 2>/dev/null)" ]; then
        echo "CPP"
    else
        echo "PYTHON"
    fi
}

function __has_ros_tools() {
    command -v colcon &>/dev/null || command -v ros2 &>/dev/null || command -v roscore &>/dev/null
}

# --- Core Build & Sync Implementations ---------------------------------------

# Modern CMake build implementation
function __mbuild_impl() {
    local build_type="RelWithDebInfo"
    local build_args=()
    local cmake_extra=()
    local gpu_cmake_args=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --debug) build_type="Debug"; shift ;;
            --release) build_type="Release"; shift ;;
            *) build_args+=("$1"); shift ;;
        esac
    done

    if [ -n "${CMAKE_EXTRA_ARGS:-}" ]; then
        read -r -a cmake_extra <<< "${CMAKE_EXTRA_ARGS}"
    fi
    read -r -a gpu_cmake_args <<< "$(__get_gpu_cmake_args)"

    cmake -S "${WS_SRC}" -B "${WS_BUILD}" -Wno-dev --no-warn-unused-cli -DCMAKE_BUILD_TYPE="${build_type}" -DCMAKE_INSTALL_PREFIX="${WS_INSTALL}" -DCMAKE_C_STANDARD="${CMAKE_C_STANDARD:-11}" -DCMAKE_CXX_STANDARD="${CMAKE_CXX_STANDARD:-17}" -DPYTHON_EXECUTABLE="$(__get_build_py_exe)" "${gpu_cmake_args[@]}" "${cmake_extra[@]}" -DCMAKE_EXPORT_COMPILE_COMMANDS=ON && \
    cmake --build "${WS_BUILD}" -j"$(nproc)" --target install "${build_args[@]}" && \
    __setup_workspace_links
}

# Dependency synchronization implementation
function __sync_deps_impl() {
    bash "${WS_SCRIPTS}/setup_sync_deps.sh" "$@"
}

function __remove_workspace_path() {
    local path="$1"
    local root_real path_real

    if [ -z "$path" ]; then
        log_error "Refusing to remove an empty workspace path."
        return 1
    fi

    root_real="$(realpath -m "${WS_ROOT}")"
    path_real="$(realpath -m "${path:-}")"
    case "$path_real" in
        "${root_real}"/*) rm -rf "$path_real" ;;
        *) log_error "Refusing to remove non-workspace path: ${path:-<empty>}"; return 1 ;;
    esac
}

# uv-based Python synchronization implementation
function __pyproject_has_extra() {
    local pyproject="$1"
    local extra="$2"
    [ -f "$pyproject" ] || return 1
    awk -v extra="$extra" '
        /^\[project\.optional-dependencies\]/ { in_optional=1; next }
        /^\[/ { in_optional=0 }
        in_optional && $0 ~ "^[[:space:]]*" extra "[[:space:]]*=" { found=1 }
        END { exit found ? 0 : 1 }
    ' "$pyproject"
}

function __requirements_has_packages() {
    local req_file="$1"
    [ -f "$req_file" ] || return 1
    grep -Eq '^[[:space:]]*[^#[:space:]]' "$req_file"
}

function __uvs_impl() {
    local sync_flags=()
    if [ -n "${UV_SYNC_FLAGS:-}" ]; then
        read -r -a sync_flags <<< "${UV_SYNC_FLAGS}"
    fi

    local pyproject="${WS_SRC}/pyproject.toml"
    local req_file="${WS_DEPS}/requirements.txt"

    if [ -f "$pyproject" ]; then
        local extra="${UV_EXTRA:-}"
        local extra_args=()
        if [ -n "$extra" ] && __pyproject_has_extra "$pyproject" "$extra"; then
            extra_args=(--extra "$extra")
        elif [ -n "$extra" ]; then
            log_info "Python extra '${extra}' is not defined in ${pyproject}; running uv sync without extras."
        fi
        UV_PROJECT_ENVIRONMENT="${VENV_PATH}" uv sync --project "${WS_SRC}" "${extra_args[@]}" "${sync_flags[@]}" "$@"
    elif __requirements_has_packages "$req_file"; then
        [ -x "${VENV_PATH}/bin/python" ] || mkenv
        uv pip install --python "${VENV_PATH}/bin/python" -r "$req_file" "$@"
    else
        log_info "No Python dependency manifest found. Skipping uv sync."
    fi
}

# Hide the ROS section when no ROS tooling is present (pure Python/C++ images).
function __help_skip_section() { [ "$1" = "ROS & Simulation" ] && ! __has_ros_tools; }

function __print_help() {
    [ "$INTERACTIVE" = false ] && return
    print_banner GUIDE
    print_env_info
    # Same shared renderer as the host `make help`, so the guide is identical
    # inside and outside the container; only the source file, entry marker and
    # default color differ.
    devkit_render_guide "$BASH_SOURCE" alias "" "$PURPLE" __help_skip_section
    devkit_guide_footer "to see this guide again."
}

# Helper function to fetch ROS package list for completion
function __ros_package_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    # Fetch package names using colcon list (silencing errors if not in a workspace)
    local pkgs
    pkgs="$(colcon list -n 2>/dev/null)"
    COMPREPLY=( $(compgen -W "${pkgs}" -- "$cur") )
}

function __devkit_has_word() {
    local needle="$1"
    local word
    for word in "${COMP_WORDS[@]:1:COMP_CWORD-1}"; do
        [ "$word" = "$needle" ] && return 0
    done
    return 1
}

function __devkit_complete_unused_words() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local word
    local candidates=()
    for word in "$@"; do
        __devkit_has_word "$word" || candidates+=("$word")
    done
    COMPREPLY=( $(compgen -W "${candidates[*]}" -- "$cur") )
}

function __devkit_file_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    COMPREPLY=( $(compgen -f -- "$cur") )
}

function __devkit_dir_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    COMPREPLY=( $(compgen -d -- "$cur") )
}

function __share_completion() {
    __devkit_complete_unused_words --share
}

function __uv_sync_option_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"
    local extras
    local prefix_options=("$@")

    case "$prev" in
        --extra)
            extras="$(__uv_extra_candidates)"
            COMPREPLY=( $(compgen -W "${extras:-cpu gpu}" -- "$cur") )
            return
            ;;
        --group|--no-group)
            COMPREPLY=()
            return
            ;;
    esac

    case "$cur" in
        --extra=*)
            extras="$(__uv_extra_candidates)"
            COMPREPLY=( $(compgen -W "$(printf -- '--extra=%s ' ${extras:-cpu gpu})" -- "$cur") )
            ;;
        --group=*|--no-group=*)
            COMPREPLY=()
            ;;
        *)
            __devkit_complete_unused_words "${prefix_options[@]}" --extra --all-extras --no-dev --dev --group --no-group --locked --frozen
            ;;
    esac
}

function __mksync_completion() {
    __uv_sync_option_completion --share
}

function __sync_deps_completion() {
    __devkit_complete_unused_words --force --rosdep
}

function __uv_extra_candidates() {
    local pyproject="${WS_SRC}/pyproject.toml"
    if [ -f "$pyproject" ]; then
        awk '
            /^\[project\.optional-dependencies\]/ { in_optional=1; next }
            /^\[/ { in_optional=0 }
            in_optional && /^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=/ {
                key=$1
                sub(/[[:space:]]*=.*/, "", key)
                print key
            }
        ' "$pyproject"
    else
        printf '%s\n' cpu gpu
    fi
}

function __uvs_completion() {
    __uv_sync_option_completion
}

function __mbuild_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"

    case "$prev" in
        --target)
            COMPREPLY=( $(compgen -W "install all clean" -- "$cur") )
            ;;
        *)
            __devkit_complete_unused_words --debug --release --target --clean-first --verbose
            ;;
    esac
}

function __cbuild_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"

    if [ "$prev" = "--pkg" ] || { __devkit_has_word "--pkg" && [[ "$cur" != --* ]]; }; then
        __ros_package_completion
    else
        __devkit_complete_unused_words --debug --release --pkg --meta
    fi
}

function __cbt_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"

    if [ "$prev" = "--pkg" ] || { __devkit_has_word "--pkg" && [[ "$cur" != --* ]]; }; then
        __ros_package_completion
    else
        COMPREPLY=( $(compgen -W "--pkg" -- "$cur") )
    fi
}

function __cbtr_completion() {
    __devkit_complete_unused_words --all --verbose
}

function __hw_check_completion() {
    __devkit_complete_unused_words --brief
}

function __gpu_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    COMPREPLY=( $(compgen -W "status auto nvidia intel amd igpu cpu" -- "$cur") )
}

# =============================================================================
# Build & Development Utilities
# =============================================================================

## @section 🚀 | Essential Workflow | PURPLE
# One-step Workspace Initialization (mkenv + uvs + sync_deps + build)
# Automatically selects between cbuild (ROS), mbuild (C++), or no-build (Python)
## @alias mksync [--share] : One-step workspace initialization
function mksync() {
    local target_py="${UV_PYTHON:-3.10}"
    local mkenv_args=()
    __parse_share_flag "$@"
    if [ "$DEVKIT_SHARE_MODE" = true ]; then
        target_py="${SYS_PYTHON_EXE}"
        mkenv_args=(--share)
    fi

    # 1. Core Environment Setup
    mkenv "${mkenv_args[@]}" && \
    activate && \
    UV_PYTHON="$target_py" __uvs_impl "${DEVKIT_REMAINING_ARGS[@]}" && \
    __sync_deps_impl --rosdep || return 1

    # 2. Intelligent Build Strategy
    local project_type=$(__detect_project_type)
    case "$project_type" in
        "ROS")
            log_info "ROS environment detected. Executing colcon build (cbuild)..."
            cbuild && __smart_source ;;
        "CPP")
            log_info "Pure C++ project detected. Executing mbuild..."
            __mbuild_impl ;;
        *)
            log_ok "Pure Python or minimal project detected. Skipping build step." ;;
    esac
}

## @alias mbuild / mclean : C++ build / clean (Modern CMake)
alias mbuild='__mbuild_impl'
function mclean() {
    local purge_venv=false
    [ "${1:-}" = "--all" ] && purge_venv=true

    __remove_workspace_path "${WS_BUILD}" || return 1

    if [ "$purge_venv" = true ]; then
        __remove_workspace_path "${WS_INSTALL}" && \
            log_ok "Build, install, and virtualenv cleared."
    elif [ -d "${WS_INSTALL}" ]; then
        # Preserve the uv virtualenv (install/.venv) so a routine clean does not
        # destroy the Python environment and force a full re-sync. The venv is not
        # relocatable, so we remove install/ contents in place, keeping .venv.
        find "${WS_INSTALL}" -mindepth 1 -maxdepth 1 ! -name ".venv" -exec rm -rf {} + 2>/dev/null || true
        log_ok "Build and install artifacts cleared (virtualenv preserved; use 'mclean --all' to remove it)."
    else
        log_ok "Build directory cleared."
    fi
}

## @alias sync_deps / check_deps : Sync / Check dependencies
alias sync_deps='__sync_deps_impl'
alias check_deps='bash ${WS_SCRIPTS}/check_deps.sh'

# =============================================================================
# ROS (ROS1 & ROS2 Common)
# =============================================================================

function __require_colcon() {
    command -v colcon &>/dev/null && return 0
    echo -e "${RED}Error:${NC} colcon is not available in this environment."
    return 127
}

function cbuild() {
    __require_colcon || return $?

    local build_type="RelWithDebInfo"
    local colcon_args=()
    local colcon_extra=()
    local cmake_extra=()
    local gpu_cmake_args=()
    if [ -n "${COLCON_EXTRA_FLAGS:-}" ]; then
        read -r -a colcon_extra <<< "${COLCON_EXTRA_FLAGS}"
    fi
    if [ -n "${CMAKE_EXTRA_ARGS:-}" ]; then
        read -r -a cmake_extra <<< "${CMAKE_EXTRA_ARGS}"
    fi
    read -r -a gpu_cmake_args <<< "$(__get_gpu_cmake_args)"
    while [ $# -gt 0 ]; do
        case "$1" in
            --debug) build_type="Debug"; shift ;;
            --release) build_type="Release"; shift ;;
            --pkg)
                shift
                if [ $# -eq 0 ] || [[ "$1" == --* ]]; then
                    echo -e "${RED}Error:${NC} --pkg requires at least one package name."
                    return 2
                fi
                colcon_args+=(--packages-select)
                while [ $# -gt 0 ] && [[ "$1" != --* ]]; do colcon_args+=("$1"); shift; done
                ;;
            --meta) colcon_args+=(--metas "${WS_CONFIG}/colcon.meta"); shift ;;
            --) shift; colcon_args+=("$@"); break ;;
            *) colcon_args+=("$1"); shift ;;
        esac
    done
    colcon --log-base "${WS_ROOT}/log" build "${colcon_extra[@]}" "${colcon_args[@]}" --symlink-install --build-base "${WS_BUILD}" --install-base "${WS_INSTALL}" \
        --cmake-args -Wno-dev --no-warn-unused-cli -DCMAKE_BUILD_TYPE="${build_type}" -DCMAKE_C_STANDARD="${CMAKE_C_STANDARD:-11}" -DCMAKE_CXX_STANDARD="${CMAKE_CXX_STANDARD:-17}" \
        -DPYTHON_EXECUTABLE="$(__get_build_py_exe)" "${gpu_cmake_args[@]}" "${cmake_extra[@]}" -DCMAKE_EXPORT_COMPILE_COMMANDS=ON && \
        __setup_workspace_links
}

function cbt() {
    __require_colcon || return $?
    local colcon_args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --pkg)
                shift
                if [ $# -eq 0 ] || [[ "$1" == --* ]]; then
                    echo -e "${RED}Error:${NC} --pkg requires at least one package name."
                    return 2
                fi
                colcon_args+=(--packages-select)
                while [ $# -gt 0 ] && [[ "$1" != --* ]]; do colcon_args+=("$1"); shift; done
                ;;
            *) colcon_args+=("$1"); shift ;;
        esac
    done
    colcon --log-base "${WS_ROOT}/log" test "${colcon_args[@]}" --build-base "${WS_BUILD}" --install-base "${WS_INSTALL}" --event-handlers console_direct+
}

function cbtr() {
    __require_colcon || return $?
    colcon test-result --build-base "${WS_BUILD}" "$@"
}

if __has_ros_tools; then
## @section 🤖 | ROS & Simulation | BLUE
    # --- Build  --------------------------------------------------------------
    ## @alias cbuild [--debug|--release] [--pkg ...] [--meta] : colcon build
    ## @alias cbt / cbtr : colcon test / test-result (--pkg to select packages)

    ## @alias s / sb : Source setup.bash / .bashrc
    function __smart_source() {
        if [ -f "${WS_INSTALL}/setup.bash" ]; then
            source "${WS_INSTALL}/setup.bash"
            echo -e "${GREEN}✓${NC} Sourced install/"
        elif [ -f "${WS_ROOT}/devel/setup.bash" ]; then
            source "${WS_ROOT}/devel/setup.bash"
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
alias uvs='__uvs_impl'
alias uvr='uv run'
## @alias uvp / uvl : uv pip install / list
alias uvp='uv pip install'
alias uvl='uv pip list'

# Project-specific venv creation
## @alias mkenv [--share] : Create pure or system shared python venv
function mkenv() {
    local share_args=()
    local py_exe="${UV_PYTHON:-3.10}"
    local msg="pure .venv"
    __parse_share_flag "$@"
    if [ "$DEVKIT_SHARE_MODE" = true ]; then
        share_args=(--system-site-packages)
        py_exe="${SYS_PYTHON_EXE}"
        msg="shared .venv (with system packages)"
    fi
    mkdir -p "$(dirname "$VENV_PATH")" && \
    uv venv "$VENV_PATH" --python "$py_exe" "${share_args[@]}" --seed --prompt "${COMPOSE_PROJECT_NAME:-.venv}" "${DEVKIT_REMAINING_ARGS[@]}" && \
    __setup_workspace_links_fast && \
    echo -e "Created ${GREEN}${msg}${NC} in $(dirname "$VENV_PATH") and linked to ${WS_ROOT}/.venv. Run: ${CYAN}activate${NC}"
}

# Smart activation function that handles Shared (Integrated) vs Pure (Isolated) environments
## @alias activate : Activate the virtual environment
function activate() {
    local target_venv="${VENV_PATH:-${WS_INSTALL}/.venv}"
    local act_script="${target_venv}/bin/activate"
    [ ! -f "$act_script" ] && { echo -e "${RED}Error:${NC} Virtual environment not found at ${target_venv}, Run ${CYAN}mkenv${NC} or ${CYAN}mksync${NC} first."; return 1; }

    # 1. Surgical Reset: Purge existing traces
    __venv_purge_state "$target_venv"
    unset VIRTUAL_ENV ENVIRONMENT_TYPE DEVKIT_ACTIVE_VENV _OLD_UV_PYTHON _OLD_UV_PYTHON_SET

    # 2. Source & State Locking
    source "$act_script"
    export DEVKIT_ACTIVE_VENV="$target_venv"
    if [ "${UV_PYTHON+x}" ]; then
        export _OLD_UV_PYTHON_SET=1
        export _OLD_UV_PYTHON="$UV_PYTHON"
    fi
    export ENVIRONMENT_TYPE="$(__get_venv_mode "$target_venv")"
    if [ "$ENVIRONMENT_TYPE" == "SHARED" ]; then
        export UV_PYTHON="$(command -v python3)"
    fi

    # Ensure workspace symlinks exist in development for IDE integration
    __setup_workspace_links_fast 2>/dev/null

    [ "$INTERACTIVE" = true ] && echo -e "${GREEN}✓${NC} Activated (${ENVIRONMENT_TYPE})"

    # 3. Deactivate Override: restore virtualenv state plus DevKit-specific state.
    function deactivate() {
        local v_root="${VIRTUAL_ENV:-${DEVKIT_ACTIVE_VENV:-}}"

        if [ -n "${_OLD_VIRTUAL_PATH:-}" ]; then
            PATH="${_OLD_VIRTUAL_PATH}"
            export PATH
            unset _OLD_VIRTUAL_PATH
        fi

        if [ -n "${_OLD_VIRTUAL_PYTHONHOME:-}" ]; then
            PYTHONHOME="${_OLD_VIRTUAL_PYTHONHOME}"
            export PYTHONHOME
            unset _OLD_VIRTUAL_PYTHONHOME
        else
            unset PYTHONHOME
        fi

        if [ -n "${_OLD_VIRTUAL_PS1:-}" ]; then
            PS1="${_OLD_VIRTUAL_PS1}"
            export PS1
            unset _OLD_VIRTUAL_PS1
        fi

        unset VIRTUAL_ENV VIRTUAL_ENV_PROMPT
        hash -r 2>/dev/null || true

        # Custom restoration cleanup
        if [ "${_OLD_UV_PYTHON_SET:-}" = "1" ]; then
            export UV_PYTHON="$_OLD_UV_PYTHON"
        else
            unset UV_PYTHON
        fi
        __venv_purge_state "$v_root"

        unset -f deactivate
        unset ENVIRONMENT_TYPE DEVKIT_ACTIVE_VENV _OLD_UV_PYTHON _OLD_UV_PYTHON_SET
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
alias hw_check='bash ${WS_SCRIPTS}/check_hardware.sh'

## @alias gpu_check / vulkan_check : GPU/Vulkan availability check
alias gpu_check='glxinfo 2>&1 | grep -E "OpenGL (vendor|renderer|version)" || echo "Error: glxinfo failed (no display?)"'
alias vulkan_check='vulkaninfo --summary 2>/dev/null | head -20 || echo "Vulkan not available"'

## @alias gpu_test : GPU performance test
alias gpu_test='timeout 5 glxgears -info 2>&1 | head -10 || echo "GPU test failed (no display?)"'

## @alias gpu status|auto|nvidia|intel|amd|igpu|cpu : GPU setup and diagnostics
function gpu() {
    local mode="${1:-status}"
    case "$mode" in
        status)
            source "${WS_SCRIPTS}/setup_gpu.sh" status
            ;;
        auto|nvidia|intel|amd|igpu|cpu)
            source "${WS_SCRIPTS}/setup_gpu.sh" "$mode" && source "${WS_SCRIPTS}/setup_gpu.sh" status
            ;;
        *)
            echo "Usage: gpu {status|auto|nvidia|intel|amd|igpu|cpu}"
            return 1
            ;;
    esac
}

## @alias ccc / ccs : ccache clear / ccache stat
alias ccs='ccache -s'
alias ccc='ccache -C'

# =============================================================================
# System Utilities
# =============================================================================

## @section 🔧 | System Utilities | BLUE

# --- Navigation ----------------------------------------------------------
## @alias cw / cs / cc : cd to root / src / config
alias cw='cd "${WS_ROOT}"'
alias cs='cd "${WS_SRC}"'
alias cc='cd "${WS_CONFIG}"'

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

if [ "$INTERACTIVE" = true ]; then
    # Custom Workspace Functions
    complete -F __mksync_completion mksync
    complete -F __share_completion mkenv
    complete -F __mbuild_completion mbuild
    complete -F __devkit_dir_completion check_deps

    # Python & Dev Tools
    complete -F __uvs_completion uvs
    complete -F __devkit_file_completion uvpython syspython
    complete -F __sync_deps_completion sync_deps

    # Hardware & GPU Setup
    complete -F __hw_check_completion hw_check
    complete -F __gpu_completion gpu

    # ROS Specific (Package completion for select builds)
    if command -v colcon &>/dev/null; then
        complete -F __cbuild_completion cbuild
        complete -F __cbt_completion cbt
        complete -F __cbtr_completion cbtr
    fi
fi
