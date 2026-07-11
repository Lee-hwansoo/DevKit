#!/bin/bash
# =============================================================================
# scripts/show_welcome.sh
# Container Welcome Message (MOTD) and quick-start guide
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "${SCRIPT_DIR}/../config/util_paths.sh" ] && source "${SCRIPT_DIR}/../config/util_paths.sh"
[ ! -f "${SOURCE_LOG:-}" ] && SOURCE_LOG="${SCRIPT_DIR}/util_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"

case "${1:-}" in
    ""|-h|--help) ;;
    *) log_error "Unknown option: $1"; exit 2 ;;
esac

print_banner WELCOME
print_env_info

print_section "Quick Start"
echo -e "    ${GREEN}mksync${NC}           : Fully initialize workspace (venv + deps + build)"

print_section "Build & Sync"
echo -e "    ${GREEN}cbuild${NC}           : colcon build (--debug, --release, --pkg, --meta)"
echo -e "    ${GREEN}cbt${NC} / ${GREEN}cbtr${NC}        : colcon test / test results"
echo -e "    ${GREEN}sync_deps${NC}        : Sync external repos from .repos file"
echo -e "    ${GREEN}check_deps${NC}       : Verify missing runtime libraries in install/"

print_section "ROS & Apps"
echo -e "    ${GREEN}rt${NC} / ${GREEN}rn${NC} / ${GREEN}rl${NC}     : List topics / nodes / launch files"
echo -e "    ${GREEN}s${NC} / ${GREEN}sb${NC}           : Source workspace / Source bashrc"

print_section "Environment"
echo -e "    ${GREEN}mkenv${NC} / ${GREEN}activate${NC} : Setup & Enter Python virtualenv"
echo -e "    ${GREEN}uvs${NC} / ${GREEN}uvr${NC}        : uv sync / uv run"

print_section "Diagnostics"
echo -e "    ${GREEN}hw_check${NC}         : Run full hardware & environment diagnostics"
echo -e "    ${GREEN}gpu status${NC}       : Show detailed GPU & Display info"

echo -e ""
echo -e "  Type ${CYAN}h${NC} or ${CYAN}help${NC} to see the full alias & shortcut guide."
echo -e "  Workspace: ${CYAN}${WS_ROOT}${NC} (mapped from host)"
echo -e ""
