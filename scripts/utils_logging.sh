#!/bin/bash
# =============================================================================
# scripts/utils_logging.sh
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

# Load settings (defaults)
LOG_SHOW_TIME="${LOG_SHOW_TIME:-false}"
DEBUG_MODE="${DEBUG_MODE:-false}"

_log_base() {
    local type="$1" color="$2" symbol="$3" msg="$4"

    # 1. Resolve Log Path & Ensure Directory (Once per function call)
    local log_out=""
    if [[ -n "${LOG_FILE}" ]]; then
        log_out="${LOG_FILE}"
        [[ "${log_out}" != /* ]] && log_out="${WORKSPACE_PATH:-/workspace}/${log_out}"
        mkdir -p "$(dirname "$log_out")"
    fi

    # 2. Metadata Pre-calculation
    local timestamp="" prefix=""
    [[ "${LOG_SHOW_TIME}" == "true" ]] && timestamp="${CYAN}[$(date '+%H:%M:%S')]${NC} "
    [[ -n "${LOG_PREFIX}" ]] && prefix="${CYAN}${LOG_PREFIX}${NC} "

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
export RED GREEN YELLOW BLUE CYAN PURPLE NC

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
    local T1='\033[38;2;45;212;191m' # Teal

    case "$type" in
        WELCOME)
            echo -e "${T1}=================================================${NC}"
            echo -e "  ${T1}██████╗ ███████╗██╗   ██╗██╗  ██╗██╗████████╗${NC}"
            echo -e "  ${T1}██╔══██╗██╔════╝██║   ██║██║ ██╔╝██║╚══██╔══╝${NC}"
            echo -e "  ${T1}██║  ██║█████╗  ██║   ██║█████╔╝ ██║   ██║   ${NC}"
            echo -e "  ${T1}██║  ██║██╔══╝  ╚██╗ ██╔╝██╔═██╗ ██║   ██║   ${NC}"
            echo -e "  ${T1}██████╔╝███████╗ ╚████╔╝ ██║  ██╗██║   ██║   ${NC}"
            echo -e "  ${T1}╚═════╝ ╚══════╝  ╚═══╝  ╚═╝  ╚═╝╚═╝   ╚═╝   ${NC}"
            echo -e "${T1}=================================================${NC}"
            ;;
        DIAG)
            echo -e "${T1}================================${NC}"
            echo -e "  ${T1}██████╗ ██╗ █████╗ ██████╗  ${NC}"
            echo -e "  ${T1}██╔══██╗██║██╔══██╗██╔════╝ ${NC}"
            echo -e "  ${T1}██║  ██║██║███████║██║  ███╗${NC}"
            echo -e "  ${T1}██║  ██║██║██╔══██║██║   ██║${NC}"
            echo -e "  ${T1}██████╔╝██║██║  ██║╚██████╔╝${NC}"
            echo -e "  ${T1}╚═════╝ ╚═╝╚═╝  ╚═╝ ╚═════╝ ${NC}"
            echo -e "${T1}================================${NC}"
            ;;
        SETUP)
            echo -e "${T1}==============================================${NC}"
            echo -e "  ${T1}███████╗███████╗████████╗██╗   ██╗██████╗ ${NC}"
            echo -e "  ${T1}██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔══██╗${NC}"
            echo -e "  ${T1}███████╗█████╗     ██║   ██║   ██║██████╔╝${NC}"
            echo -e "  ${T1}╚════██║██╔══╝     ██║   ██║   ██║██╔═══╝ ${NC}"
            echo -e "  ${T1}███████║███████╗   ██║   ╚██████╔╝██║     ${NC}"
            echo -e "  ${T1}╚══════╝╚══════╝   ╚═╝    ╚═══╝   ╚═╝     ${NC}"
            echo -e "${T1}==============================================${NC}"
            ;;
        GUIDE)
            echo -e "${T1}====================================${NC}"
            echo -e "  ${T1}██╗  ██╗███████╗██╗     ██████╗ ${NC}"
            echo -e "  ${T1}██║  ██║██╔════╝██║     ██╔══██╗${NC}"
            echo -e "  ${T1}███████║█████╗  ██║     ██████╔╝${NC}"
            echo -e "  ${T1}██╔══██║██╔══╝  ██║     ██╔═══╝ ${NC}"
            echo -e "  ${T1}██║  ██║███████╗███████╗██║     ${NC}"
            echo -e "  ${T1}╚═╝  ╚═╝╚══════╝╚══════╝╚═╝     ${NC}"
            echo -e "${T1}====================================${NC}"
            ;;
        *)
            local label="DevKit"
            local full_text="${label} | ${type}"
            local padding=$(( (33 - ${#full_text}) / 2 ))
            local left_pad=""
            [ $padding -gt 0 ] && left_pad=$(printf '%*s' $padding "")
            echo -e "${T1}=================================${NC}"
            echo -e "${left_pad}${T1}${full_text}${NC}"
            echo -e "${T1}=================================${NC}"
            ;;
    esac
}

# print_section [title] - Creates a professional horizontal divider
print_section() {
    local title="[ $1 ]"
    local total_len=60
    local title_len=${#title}
    local pad_len=$(( (total_len - title_len) / 2 ))
    local padding=$(printf '%*s' "$pad_len" "" | tr ' ' '=')

    echo -e ""
    echo -e "${CYAN}${padding}${title}${padding}${NC}"
}

# log_detail [message] - Indented auxiliary information
log_detail() {
    echo -e "    ${CYAN}→${NC} $1"
}

# log_step_done [message] - Completion of a step
log_step_done() {
    echo -e "  ${GREEN}✓${NC} $1"
}
