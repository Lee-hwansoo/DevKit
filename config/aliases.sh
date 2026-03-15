#!/bin/bash
# config/aliases.sh
# ROS2 + C++ + Python(uv) + 진단 통합 alias 모음
# ~/.bashrc에서 source /docker_dev/config/aliases.sh 로 로드됨
#
# ROS2 관련 alias는 ros2 명령이 존재하는 경우에만 정의됨
# → dev 타겟(ROS2 없음)에서 source 시 오류 없이 통과

# =============================================================================
# ROS (ROS1 & ROS2 공용)
# =============================================================================
if [ -d /opt/ros ]; then
    # ── Build (Colcon 통일) ──────────────────────────────────────────────────
    # CMAKE_CXX_STANDARD은 .env → docker-compose → ENV로 주입됨
    alias cb='colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17}'
    alias cbp='colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17} --packages-select'
    
    # 릴리즈용 (최적화)
    alias cbr='colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17}'
    alias cbrp='colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17} --packages-select'
    alias cbt='colcon test'
    alias cbm='colcon build --symlink-install --metas /docker_dev/config/colcon.meta'
    alias s='source /workspace/install/setup.bash'
    alias sb='source ~/.bashrc'

    # ── Navigation ─────────────────────────────────────────────────────────
    alias cw='cd /workspace'
    alias cs='cd /workspace/src'

    # ── ROS Commands ───────────────────────────────────────────────────────
    # ROS 2 (기본)
    alias rt='ros2 topic list'
    alias rte='ros2 topic echo'
    alias rth='ros2 topic hz'
    alias rn='ros2 node list'
    alias rs='ros2 service list'
    alias rp='ros2 param list'
    alias rr='ros2 run'
    alias rl='ros2 launch'
    alias ri='ros2 interface show'
    
    # ROS 1 (noetic 감지 시)
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

    # ── Gazebo / Simulation ────────────────────────────────────────────────
    alias gz='gazebo'
    alias gzs='ros2 launch gazebo_ros gazebo.launch.py' # ROS 2 기준
fi

# Navigation (공통)
alias cc='cd /docker_dev/config'

# =============================================================================
# Python / uv
# =============================================================================
alias uvs='uv sync --project /workspace/src'
alias uvr='uv run'
alias uvp='uv pip install'
alias uvl='uv pip list'

# 프로젝트별 가상환경 생성 (install 하위에 생성하여 배포 아티팩트화 + IDE 호환을 위한 루트 심볼릭 링크)
alias mkenv='uv venv --python ${UV_PYTHON:-3.11} /workspace/install/.venv && ln -sf /workspace/install/.venv /workspace/.venv && echo "Created .venv in /workspace/install and linked to /workspace/.venv. Run: activate"'
alias activate='source /workspace/install/.venv/bin/activate'

# Python 버전 확인
alias pyv='python3 --version && uv --version'
alias uvpython='uv python list'

# =============================================================================
# Utils & Build
# =============================================================================
# 일반 C++ 프로젝트 표준 빌드 (src -> build -> install)
alias mbuild='mkdir -p /workspace/build && cd /workspace/build && cmake ../src -DCMAKE_INSTALL_PREFIX=/workspace/install -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17} && make -j$(nproc) install && cd /workspace'

alias k='killall -9'
alias g='git'
alias ll='ls -alF'
alias la='ls -A'
alias ccache-stat='ccache -s'
alias ccache-clear='ccache -C'
alias sync_deps='bash /docker_dev/scripts/sync_deps.sh'
alias ccache-stat='ccache -s'
alias ccache-clear='ccache -C'

# =============================================================================
# Hardware Diagnostics
# =============================================================================
alias hw_check='bash /docker_dev/scripts/hardware_check.sh'
alias gpu_check='glxinfo 2>&1 | grep -E "OpenGL (vendor|renderer|version)" || echo "Error: glxinfo failed (no display?)"'
alias gpu_info='source /docker_dev/scripts/gpu_setup.sh && gpu_status'
alias gpu_auto='source /docker_dev/scripts/gpu_setup.sh auto'
alias use_intel='source /docker_dev/scripts/gpu_setup.sh intel'
alias use_amd='source /docker_dev/scripts/gpu_setup.sh amd'
alias use_nvidia='source /docker_dev/scripts/gpu_setup.sh nvidia'
alias use_cpu='source /docker_dev/scripts/gpu_setup.sh cpu'
alias gpu_status='source /docker_dev/scripts/gpu_setup.sh status'
alias gpu_test='timeout 5 glxgears -info 2>&1 | head -10 || echo "GPU test failed (no display?)"'
alias vulkan_check='vulkaninfo --summary 2>/dev/null | head -20 || echo "Vulkan not available"'
