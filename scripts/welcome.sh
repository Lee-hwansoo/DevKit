#!/bin/bash
# scripts/welcome.sh - Container Welcome Message (MOTD)

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}======================================================================${NC}"
echo -e "                              ${GREEN}Welcome${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo -e "  Project: ${BLUE}${COMPOSE_PROJECT_NAME}${NC} | ROS: ${YELLOW}${ROS_DISTRO:-None}${NC} | Mode: ${YELLOW}${GPU_MODE:-auto}${NC}"
echo -e ""
echo -e "  ${BLUE}Core Helpers:${NC}"
echo -e "    ${GREEN}hw_check${NC}   : Run full hardware & env diagnostics"
echo -e "    ${GREEN}cb / cbm${NC}   : colcon build (standard / with metas)"
echo -e "    ${GREEN}mbuild${NC}     : Standard C++ build (cmake -> make -> install)"
echo -e "    ${GREEN}mkenv${NC}      : Create python venv in /workspace/install/.venv"
echo -e "    ${GREEN}sync_deps${NC}  : Sync external repos from .repos file"
echo -e ""
echo -e "  ${BLUE}Quick Shortcuts:${NC}"
echo -e "    ${GREEN}rt / rn / rl${NC}: ros2 topic / node / launch"
echo -e "    ${GREEN}s / activate${NC}: Source workspace / Activate venv"
echo -e "    ${GREEN}gpu_status  ${NC}: Show detailed GPU & Display info"
echo -e ""
echo -e "  Workspace: ${CYAN}/workspace${NC} (mapped from host)"
echo -e "${CYAN}======================================================================${NC}"
