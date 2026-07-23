#!/bin/bash
# =============================================================================
# scripts/show_welcome.sh
# Container Welcome Message (MOTD) and quick-start guide
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || source "/tmp/util_paths.sh"
devkit_require "util_logging.sh"

case "${1:-}" in
    ""|-h|--help) ;;
    *) log_error "Unknown option: $1"; exit 2 ;;
esac

print_banner WELCOME
print_env_info

# Curated quick-start guide. Sections are "@Title" markers; entries are
# "name|description". The column width is derived from the widest name and each
# row is drawn by the shared devkit_guide_row helper, so this MOTD stays aligned
# and visually identical to the full `h`/`help` guide with nothing hardcoded.
WELCOME_ROWS=(
    "@Quick Start"
    "mksync|Fully initialize workspace (venv + deps + build)"
    "@Build & Sync"
    "cbuild|colcon build (--debug, --release, --pkg, --meta)"
    "cbt / cbtr|colcon test / test results"
    "sync_deps|Sync external repos from .repos file"
    "check_deps|Verify missing runtime libraries in install/"
    "@ROS & Apps"
    "rt / rn / rl|List topics / nodes / launch files"
    "s / sb|Source workspace / Source bashrc"
    "@Environment"
    "mkenv / activate|Setup & Enter Python virtualenv"
    "uvs / uvr|uv sync / uv run"
    "@Diagnostics"
    "hw_check|Run full hardware & environment diagnostics"
    "gpu status|Show detailed GPU & Display info"
)

welcome_col=0
for row in "${WELCOME_ROWS[@]}"; do
    [[ $row == @* ]] && continue
    name="${row%%|*}"
    (( ${#name} > welcome_col )) && welcome_col=${#name}
done

for row in "${WELCOME_ROWS[@]}"; do
    if [[ $row == @* ]]; then
        print_section "${row#@}"
    else
        devkit_guide_row "$welcome_col" "${row%%|*}" "${row#*|}"
    fi
done

devkit_guide_footer "to see the full alias & shortcut guide."
echo -e "  Workspace: ${CYAN}${WS_ROOT}${NC} (mapped from host)"
echo -e ""
