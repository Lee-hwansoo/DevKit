#!/bin/bash
# =============================================================================
# ROS Environment (ros1/ros2 공용)
# =============================================================================

# ROS 코어 환경 동적 소싱
if [ -f "/opt/ros/${ROS_DISTRO:-humble}/setup.bash" ]; then
    source /opt/ros/${ROS_DISTRO:-humble}/setup.bash
fi

# 워크스페이스 오버레이 (colcon 빌드 후 자동 소스)
if [ -f /workspace/install/setup.bash ]; then
    source /workspace/install/setup.bash
fi

# Colcon 자동완성
if [ -f /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash ]; then
    source /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash
fi

# ROS 버전에 따른 전용 설정
if [ "${ROS_DISTRO}" = "noetic" ]; then
    # Docker Compose가 주입한 환경변수를 우선 사용하고, 없을 경우 기본값 적용
    export ROS_MASTER_URI=${ROS_MASTER_URI:-http://localhost:11311}
    export ROS_HOSTNAME=${ROS_HOSTNAME:-localhost}
else
    # ROS 2 (humble) 전용
    export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}
    export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-0}
fi
