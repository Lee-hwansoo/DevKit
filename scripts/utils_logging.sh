#!/bin/bash
# scripts/utils_logging.sh
# 중앙 집중식 로깅 유틸리티 (색상, 형식, 타임스탬프, 파일 로깅 지원)

# ANSI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# 설정 로드 (기본값)
LOG_SHOW_TIME="${LOG_SHOW_TIME:-false}"
DEBUG_MODE="${DEBUG_MODE:-false}"

_log_base() {
    local type="$1"
    local color="$2"
    local symbol="$3"
    local msg="$4"

    local time_str=""
    if [ "${LOG_SHOW_TIME}" = "true" ]; then
        time_str="${CYAN}[$(date '+%H:%M:%S')]${NC} "
    fi

    local prefix="${LOG_PREFIX:+${CYAN}${LOG_PREFIX}${NC} }"

    # 로그 파일 디렉토리가 없으면 최초 1회만 생성 (디스크 I/O 최적화)
    if [ -n "${LOG_FILE}" ]; then
        local log_dir
        log_dir=$(dirname "${LOG_FILE}")
        [ ! -d "$log_dir" ] && mkdir -p "$log_dir"
    fi

    # Process multi-line messages (마지막 줄바꿈 누락 방지)
    while IFS= read -r line || [ -n "$line" ]; do
        # Only add prefix to the line if it's not empty, otherwise just print the prefix
        if [ -z "$line" ]; then
            local full_msg="${time_str}${prefix}${color}[${type}]${NC}"
        else
            local full_msg="${time_str}${prefix}${color}[${type}]${NC} ${symbol:+${symbol} }$line"
        fi

        # ERROR/WARN은 표준 에러(stderr, >&2)로 출력하여 셸 파이프 처리 호환성 확보
        if [ "$type" = "ERROR" ] || [ "$type" = "WARN" ]; then
            echo -e "$full_msg" >&2
        else
            echo -e "$full_msg"
        fi

        # 파일 로깅 (색상 제거 후 기록)
        if [ -n "${LOG_FILE}" ]; then
            echo -e "$full_msg" | sed 's/\x1b\[[0-9;]*m//g' >> "${LOG_FILE}"
        fi
    done <<< "$msg"
}

log_info()  { _log_base "INFO"  "${BLUE}"   ""   "$1"; }
log_ok()    { _log_base "OK"    "${GREEN}"  "✓"  "$1"; }
log_warn()  { _log_base "WARN"  "${YELLOW}" "⚠"  "$1"; }
log_error() { _log_base "ERROR" "${RED}"    "✗"  "$1"; }
log_debug() {
    if [ "${DEBUG_MODE}" = "true" ]; then
        _log_base "DEBUG" "${PURPLE}" "⚙" "$1"
    fi
}

# Makefile 등에서 색상 변수만 따로 쓰고 싶을 때를 위해 export
export RED GREEN YELLOW BLUE CYAN PURPLE NC
