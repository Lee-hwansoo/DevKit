#!/bin/bash
# docker/entrypoint.prod.sh
# 운영(Production) 환경 전용 엔트리포인트
#
# 개발용 entrypoint와 다르게 빌드 도구 확인이나 권한 변경 로직을 배제하고,
# 순수하게 런타임 구동과 하드웨어 설정만 담당합니다.

set -e

# =============================================================================
# 1. GPU 동적 설정
# =============================================================================
if [ -f /opt/scripts/gpu_setup.sh ]; then
    # 운영 환경에서도 GPU_MODE 환경 변수를 통해 Intel/AMD/NVIDIA 스위칭 가능
    # source를 통해 환경 변수가 현재 프로세스에 즉시 반영됨
    source /opt/scripts/gpu_setup.sh "${GPU_MODE:-auto}" > /dev/null 2>&1
fi

# =============================================================================
# 2. ROS2 환경 소싱 (ROS2 타겟일 경우)
# =============================================================================
if [ -f "/opt/ros/${ROS_DISTRO:-humble}/setup.bash" ]; then
    source "/opt/ros/${ROS_DISTRO:-humble}/setup.bash"
fi

# =============================================================================
# 3. 애플리케이션 설치 환경 소싱
# =============================================================================
if [ -f "/workspace/install/setup.bash" ]; then
    source "/workspace/install/setup.bash"
fi

if [ -f "/workspace/install/.venv/bin/activate" ]; then
    source "/workspace/install/.venv/bin/activate"
fi

# =============================================================================
# Execute (PID 1)
# =============================================================================
exec "$@"
