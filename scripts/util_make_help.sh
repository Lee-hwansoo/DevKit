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
devkit_require "util_logging.sh"

MAKEFILE="${1:-Makefile}"

trim_ws() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

print_banner WELCOME

while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*"## @section" ]]; then
        section_data="${line#*## @section }"
        IFS="|" read -r emoji title color_name <<< "$section_data"
        emoji="$(trim_ws "$emoji")"
        title="$(trim_ws "$title")"
        color_name="$(trim_ws "$color_name")"
        color="${!color_name:-$BLUE}"
        printf "\n  ${color}%s  %s:${NC}\n" "$emoji" "$title"
    elif [[ $line =~ ^[[:space:]]*"## @target" ]]; then
        content="${line#*## @target }"
        cmd="$(trim_ws "${content%%:*}")"
        desc="$(trim_ws "${content#*:}")"
        if [ ${#cmd} -gt 52 ]; then
            printf "    ${GREEN}make %s${NC}\n      : %s\n" "$cmd" "$desc"
        else
            printf "    ${GREEN}make %-52s${NC} : %s\n" "$cmd" "$desc"
        fi
    fi
done < "$MAKEFILE"

echo -e "\n  ${CYAN}Defaults:${NC} ENV=ros, SIF_MODE=dev, IMAGE_TAG=latest"
echo -e "  ${CYAN}Modes:${NC}    ENV=ros|dev selects the Docker/SIF family; SIF_MODE=dev|prod|slurm selects SIF execution."
echo -e "\n  ${CYAN}Common flows:${NC}"
echo -e "    ${GREEN}make build ENV=ros && make start ENV=ros && make shell ENV=ros${NC}"
echo -e "    ${GREEN}make bake-dev ENV=ros SHARE=1${NC}"
echo -e "    ${GREEN}make bake-prod ENV=ros${NC}"
echo -e "    ${GREEN}PROD_FULL_CUDA=1 make bake-prod ENV=ros${NC}"
echo -e "    ${GREEN}APP_COMMAND=\"python3 -V\" make run-sif SIF_MODE=prod ENV=ros${NC}"
echo -e "    ${GREEN}APP_COMMAND=\"python3 -V\" DEVKIT_SLURM_PARTITION=gpu DEVKIT_SLURM_GRES=gpu:1 make run-sif SIF_MODE=slurm ENV=ros${NC}"
echo -e "\n  ${CYAN}Notice:${NC} Run make commands on the host. Inside a container, use ${GREEN}h${NC} or ${GREEN}help${NC} for aliases.\n"
