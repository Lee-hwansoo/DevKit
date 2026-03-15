#!/bin/bash
# =============================================================================
# scripts/sync_deps.sh
# 서드파티 의존성 소스 코드 동기화 및 오버레이 병합 도구
#
# 기능:
#   1. vcstool(.repos)을 통한 외부 저장소 일괄 Import/Pull
#   2. dependencies/overlay/ 내부 파일의 타겟 워크스페이스 병합
#   3. rosdep 기반 누락된 시스템 의존성 자동 확인
# =============================================================================

LOG_PREFIX="[Sync Deps]"
log_info()  { echo -e "\033[0;36m${LOG_PREFIX} [INFO] $1\033[0m"; }
log_ok()    { echo -e "\033[0;32m${LOG_PREFIX} [OK]   $1\033[0m"; }
log_warn()  { echo -e "\033[0;33m${LOG_PREFIX} [WARN] $1\033[0m"; }

# 1. 작업 공간 감지 및 대상 디렉토리 설정 (절대 경로 기반 정규화)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 컨테이너 내 작업 디렉토리 표준화 (/workspace)
if [ -d "/workspace" ]; then
    WORKSPACE_ROOT="/workspace"
else
    WORKSPACE_ROOT="$PROJECT_ROOT"
fi

TARGET_DIR="$WORKSPACE_ROOT/src/thirdparty"
REPOS_FILE="$PROJECT_ROOT/dependencies/dependencies.repos"
OVERLAY_DIR="$PROJECT_ROOT/dependencies/overlay"

mkdir -p "$TARGET_DIR"

# 2. vcs 도구 확인 및 실행
if ! command -v vcs &>/dev/null; then
    log_warn "vcstool (vcs) not found. Skipping repository import."
elif [ -f "$REPOS_FILE" ]; then
    log_info "Running vcs import to $TARGET_DIR ..."
    vcs import "$TARGET_DIR" < "$REPOS_FILE" || log_warn "vcs import completed with some warnings."
    
    # 신규 추가된 저장소 확인 후 업데이트
    log_info "Performing vcs pull to update existing repositories..."
    vcs pull "$TARGET_DIR" || log_warn "vcs pull completed with some warnings."
else
    log_info "No .repos file found at $REPOS_FILE."
fi

# 3. 오버레이(Overlay) 적용
if [ -d "$OVERLAY_DIR" ]; then
    HAS_FILES=$(find "$OVERLAY_DIR" -mindepth 1 -not -name "*.md" | wc -l)
    if [ "$HAS_FILES" -gt 0 ]; then
        log_info "Applying overlays from $OVERLAY_DIR ..."
        cp -a "$OVERLAY_DIR/." "$TARGET_DIR/"
        log_ok "Overlays applied successfully."
    fi
fi

# 4. rosdep 패키지 종속성 해소 (ros2 타겟 전용)
# 기본적으로 생략하고 --rosdep 플래그가 있는 경우에만 실행
DO_ROSDEP=false
for arg in "$@"; do
    if [ "$arg" == "--rosdep" ]; then
        DO_ROSDEP=true
        break
    fi
done

if [ "$DO_ROSDEP" = true ] && command -v rosdep &>/dev/null && [ -n "${ROS_DISTRO}" ]; then
    log_info "Checking rosdep dependencies for ${TARGET_DIR}..."
    apt-get update -qq || true
    if ! rosdep install --from-paths "$TARGET_DIR" --ignore-src -r -y --rosdistro "$ROS_DISTRO"; then
        log_warn "Some rosdep packages failed to install. Check the output above."
    else
        log_ok "rosdep check completed."
    fi
elif [ "$DO_ROSDEP" = false ] && command -v rosdep &>/dev/null; then
    log_info "Skipping rosdep install. (Use --rosdep to force check)"
fi
