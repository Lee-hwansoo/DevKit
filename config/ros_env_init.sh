#!/bin/bash
# =============================================================================
# config/ros_env_init.sh
# Centralized ROS environment orchestration for ROS1 (Noetic) and ROS2 (Humble)
# =============================================================================

if [ "${ROS_DISTRO}" = "noetic" ]; then
    # ROS 1 Networking Optimization: Use hostname instead of localhost for container mobility
    if [ -z "$ROS_HOSTNAME" ] || [ "$ROS_HOSTNAME" = "localhost" ]; then
        export ROS_HOSTNAME=$(hostname)
        export ROS_MASTER_URI="http://${ROS_HOSTNAME}:11311"
    fi
else
    # ROS 2 (Humble) Specifics
    export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-0}
    export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}

    # Auto-configure CycloneDDS defaults (Unicast Fallback for Bridge Networks)
    if [ "$RMW_IMPLEMENTATION" = "rmw_cyclonedds_cpp" ] && [ -z "$CYCLONEDDS_URI" ]; then
        if [ -f /docker_dev/config/cyclonedds.xml ]; then
            export CYCLONEDDS_URI=file:///docker_dev/config/cyclonedds.xml
        fi
    fi
fi
