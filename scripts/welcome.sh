#!/bin/bash
# =============================================================================
# scripts/welcome.sh
# Container Welcome Message (MOTD) and quick-start guide
#
# Displays project metadata (ROS version, GPU mode) and a summarized list
# of core helper commands and shortcuts for a better onboarding experience.
# =============================================================================

# Load logging utility for shared color variables (P-3: unified color source)
SOURCE_LOG="/docker_dev/scripts/utils_logging.sh"
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="$(dirname "${BASH_SOURCE[0]}")/utils_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"

print_banner WELCOME
echo -e "  Project: ${BLUE}${COMPOSE_PROJECT_NAME}${NC} | ROS: ${YELLOW}${ROS_DISTRO:-None}${NC} | GPU: ${YELLOW}${GPU_MODE:-auto}${NC}"

print_section "Quick Start"
echo -e "    ${GREEN}mksync${NC}          : Fully initialize workspace (venv + deps + build)"

print_section "Build & Sync"
echo -e "    ${GREEN}cb${NC} / ${GREEN}cbr${NC}        : colcon build (Dev / Release)"
echo -e "    ${GREEN}sync_deps${NC}       : Sync external repos from .repos file"
echo -e "    ${GREEN}check_deps${NC}      : Verify missing runtime libraries in install/"

print_section "ROS & Apps"
echo -e "    ${GREEN}rt${NC} / ${GREEN}rn${NC} / ${GREEN}rl${NC}    : List topics / nodes / launch files"
echo -e "    ${GREEN}s${NC} / ${GREEN}sb${NC}           : Source workspace / Source bashrc"

print_section "Environment"
echo -e "    ${GREEN}mkenv${NC} / ${GREEN}activate${NC} : Setup & Enter Python virtualenv"
echo -e "    ${GREEN}uvs${NC} / ${GREEN}uvr${NC}        : uv sync / uv run"

print_section "Diagnostics"
echo -e "    ${GREEN}hw_check${NC}        : Run full hardware & environment diagnostics"
echo -e "    ${GREEN}gpu_status${NC}      : Show detailed GPU & Display info"

echo -e ""
echo -e "  Type ${CYAN}h${NC} or ${CYAN}help${NC} to see the full alias & shortcut guide."
echo -e "  Workspace: ${CYAN}/workspace${NC} (mapped from host)"
echo -e ""

