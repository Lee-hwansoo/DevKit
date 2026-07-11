#!/bin/bash
# =============================================================================
# scripts/util_logging.sh
# Centralized logging utility for standardized shell output
#
# Provides color-coded logging functions (INFO, OK, WARN, ERROR, DEBUG)
# with support for timestamps, custom prefixes, and file-based logging.
# =============================================================================

# ANSI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'
TEAL='\033[38;2;45;212;191m'

# Load settings (defaults)
LOG_SHOW_TIME="${LOG_SHOW_TIME:-false}"
DEBUG_MODE="${DEBUG_MODE:-false}"

_log_base() {
    local type="$1" color="$2" symbol="$3" msg="$4"

    # 1. Resolve Log Path & Ensure Directory (Once per function call)
    local log_out=""
    if [[ -n "${LOG_FILE:-}" ]]; then
        log_out="${LOG_FILE}"
        [[ "${log_out}" != /* ]] && log_out="${WORKSPACE_PATH:-/workspace}/${log_out}"
        mkdir -p "$(dirname "$log_out")"
    fi

    # 2. Metadata Pre-calculation
    local timestamp="" prefix=""
    [[ "${LOG_SHOW_TIME}" == "true" ]] && timestamp="${CYAN}[$(date '+%H:%M:%S')]${NC} "
    [[ -n "${LOG_PREFIX:-}" ]] && prefix="${CYAN}${LOG_PREFIX}${NC} "

    # 3. Stream Processing (Clean & Fast)
    while IFS= read -r line || [[ -n "$line" ]]; do
        local content="${color}[${type}]${NC}${symbol:+ ${symbol}}${line:+ $line}"
        local full_msg="${timestamp}${prefix}${content}"

        # Output to Console
        if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then
            echo -e "$full_msg" >&2
        else
            echo -e "$full_msg"
        fi

        # Robust File Logging (ANSI Strip)
        if [[ -n "$log_out" ]]; then
            echo -e "$full_msg" | sed 's/\x1b\[[0-9;]*m//g' >> "$log_out"
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

# Export color variables for independent use in Makefile, etc.
export RED GREEN YELLOW BLUE CYAN PURPLE NC TEAL

# Formatted status strings for manual usage (e.g. within sections or sub-items)
INFO="${BLUE}[INFO]${NC}"
OK="${GREEN}[OK]${NC}"
WARN="${YELLOW}[WARN]${NC}"
ERROR="${RED}[ERROR]${NC}"
DEBUG="${PURPLE}[DEBUG]${NC}"

export INFO OK WARN ERROR DEBUG

# =============================================================================
# DevKit Branding & Banners
# =============================================================================

# print_banner [type]
#   type: WELCOME (Large), DIAG (Diagnostics), SETUP (Maintenance)
print_banner() {
    local type="${1:-WELCOME}"

    case "$type" in
        WELCOME)
            echo -e "${TEAL}=================================================${NC}"
            echo -e "  ${TEAL}██████╗ ███████╗██╗   ██╗██╗  ██╗██╗████████╗${NC}"
            echo -e "  ${TEAL}██╔══██╗██╔════╝██║   ██║██║ ██╔╝██║╚══██╔══╝${NC}"
            echo -e "  ${TEAL}██║  ██║█████╗  ██║   ██║█████╔╝ ██║   ██║   ${NC}"
            echo -e "  ${TEAL}██║  ██║██╔══╝  ╚██╗ ██╔╝██╔═██╗ ██║   ██║   ${NC}"
            echo -e "  ${TEAL}██████╔╝███████╗ ╚████╔╝ ██║  ██╗██║   ██║   ${NC}"
            echo -e "  ${TEAL}╚═════╝ ╚══════╝  ╚═══╝  ╚═╝  ╚═╝╚═╝   ╚═╝   ${NC}"
            echo -e "${TEAL}=================================================${NC}"
            ;;
        DIAG)
            echo -e "${TEAL}================================${NC}"
            echo -e "  ${TEAL}██████╗ ██╗ █████╗ ██████╗  ${NC}"
            echo -e "  ${TEAL}██╔══██╗██║██╔══██╗██╔════╝ ${NC}"
            echo -e "  ${TEAL}██║  ██║██║███████║██║  ███╗${NC}"
            echo -e "  ${TEAL}██║  ██║██║██╔══██║██║   ██║${NC}"
            echo -e "  ${TEAL}██████╔╝██║██║  ██║╚██████╔╝${NC}"
            echo -e "  ${TEAL}╚═════╝ ╚═╝╚═╝  ╚═╝ ╚═════╝ ${NC}"
            echo -e "${TEAL}================================${NC}"
            ;;
        SETUP)
            echo -e "${TEAL}==============================================${NC}"
            echo -e "  ${TEAL}███████╗███████╗████████╗██╗   ██╗██████╗ ${NC}"
            echo -e "  ${TEAL}██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔══██╗${NC}"
            echo -e "  ${TEAL}███████╗█████╗     ██║   ██║   ██║██████╔╝${NC}"
            echo -e "  ${TEAL}╚════██║██╔══╝     ██║   ██║   ██║██╔═══╝ ${NC}"
            echo -e "  ${TEAL}███████║███████╗   ██║   ╚██████╔╝██║     ${NC}"
            echo -e "  ${TEAL}╚══════╝╚══════╝   ╚═╝    ╚═══╝   ╚═╝     ${NC}"
            echo -e "${TEAL}==============================================${NC}"
            ;;
        GUIDE)
            echo -e "${TEAL}====================================${NC}"
            echo -e "  ${TEAL}██╗  ██╗███████╗██╗     ██████╗ ${NC}"
            echo -e "  ${TEAL}██║  ██║██╔════╝██║     ██╔══██╗${NC}"
            echo -e "  ${TEAL}███████║█████╗  ██║     ██████╔╝${NC}"
            echo -e "  ${TEAL}██╔══██║██╔══╝  ██║     ██╔═══╝ ${NC}"
            echo -e "  ${TEAL}██║  ██║███████╗███████╗██║     ${NC}"
            echo -e "  ${TEAL}╚═╝  ╚═╝╚══════╝╚══════╝╚═╝     ${NC}"
            echo -e "${TEAL}====================================${NC}"
            ;;
        *)
            local label="DevKit"
            local full_text="${label} | ${type}"
            local padding=$(( (33 - ${#full_text}) / 2 ))
            local left_pad=""
            [ $padding -gt 0 ] && left_pad=$(printf '%*s' $padding "")
            echo -e "${TEAL}=================================${NC}"
            echo -e "${left_pad}${TEAL}${full_text}${NC}"
            echo -e "${TEAL}=================================${NC}"
            ;;
    esac
}

# print_section [title] - Creates a professional left-aligned divider
print_section() {
    local title="$1"
    local total_len=50
    local title_len=$(( ${#title} + 4 )) # +4 for "[ " and " ]"
    local pad_len=$(( total_len - title_len ))
    [ $pad_len -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "" | tr ' ' '=')

    printf "\n${TEAL}[ %s ] %s${NC}\n" "$title" "$padding"
}

# log_detail [message] - Indented auxiliary information
log_detail() {
    echo -e "    ${CYAN}→${NC} $1"
}

# log_step_done [message] - Completion of a step
log_step_done() {
    echo -e "  ${GREEN}✓${NC} $1"
}

# print_env_info - Displays a standardized project dashboard (Single Source of Truth)
print_env_info() {
    # 1. Detect Python Environment Mode
    local venv_status="${RED}None${NC}"
    local v_path="${WS_VENV:-${WORKSPACE_PATH:-/workspace}/install/.venv}"
    if [ -d "$v_path" ]; then
        if grep -q "include-system-site-packages = true" "${v_path}/pyvenv.cfg" 2>/dev/null; then
            venv_status="${YELLOW}SHARED${NC}"
        else
            venv_status="${BLUE}PURE${NC}"
        fi
    fi

    # 2. Path Normalization (Relative to Workspace Root)
    local root="${WS_ROOT:-${WORKSPACE_PATH:-/workspace}}"
    local v_rel="${v_path#$root/}"

    # 3. Output Unified Dashboard
    echo -e "  Project: ${BLUE}${COMPOSE_PROJECT_NAME}${NC} | User: ${PURPLE}$(whoami) (${UID:-$(id -u)})${NC} | WS: ${GREEN}${root}${NC} | GPU: ${YELLOW}${GPU_MODE:-auto}${NC} | ROS: ${YELLOW}${ROS_DISTRO:-None}${NC} | Python: ${CYAN}${v_rel}${NC}(${venv_status})"
}
