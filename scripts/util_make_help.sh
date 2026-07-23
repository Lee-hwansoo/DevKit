#!/bin/bash
# =============================================================================
# scripts/util_make_help.sh
# Renders the `make help` guide by parsing `## @section` / `## @target` comment
# annotations from the given Makefile.
#
# Extracted from the Makefile's `help` target: the previous inline recipe mixed
# make-expanded (${CYAN}) and shell-expanded ($${GREEN}) variables in one bash
# string, which was hard to read and edit (see docs/TECHNICAL_REVIEW.md §3.6).
# Here all colors come from a single source — sourcing util_logging.sh.
#
# Usage: util_make_help.sh [makefile]   (default: Makefile)
# =============================================================================
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || source "/tmp/util_paths.sh"
devkit_require "util_logging.sh"   # bundles util_doc_render.sh (guide renderer)

MAKEFILE="${1:-Makefile}"

# The section/entry layout is rendered by the shared guide renderer so the host
# `make help` and the in-container `h`/`help` stay visually identical. Only the
# host-specific banner, @arg legend and footer live here.
print_banner WELCOME
devkit_render_guide "$MAKEFILE" target "make " "$BLUE"
devkit_render_arglegend "$MAKEFILE" "🔩" "Arguments" "$BLUE"

echo -e "\n  ${CYAN}Common flows:${NC}"
echo -e "    ${GREEN}make build ENV=ros && make start ENV=ros && make shell ENV=ros${NC}"
echo -e "    ${GREEN}make bake-dev ENV=ros SHARE=1${NC}"
echo -e "    ${GREEN}make bake-prod ENV=ros${NC}"
echo -e "    ${GREEN}PROD_FULL_CUDA=1 make bake-prod ENV=ros${NC}"
echo -e "    ${GREEN}APP_COMMAND=\"python3 -V\" make run-sif SIF_MODE=prod ENV=ros${NC}"
echo -e "    ${GREEN}APP_COMMAND=\"python3 -V\" DEVKIT_SLURM_PARTITION=gpu DEVKIT_SLURM_GRES=gpu:1 make run-sif SIF_MODE=slurm ENV=ros${NC}"
echo -e "\n  ${CYAN}Notice:${NC} Run make commands on the host. Inside a container, use ${GREEN}h${NC} or ${GREEN}help${NC} for aliases.\n"
