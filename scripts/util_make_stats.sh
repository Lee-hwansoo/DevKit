#!/bin/bash
# =============================================================================
# scripts/util_make_stats.sh
# Renders ONE resource-monitor snapshot for `make stats` (invoked repeatedly by
# `watch`). Extracted from the Makefile's inline `watch "bash -c '...'"` recipe
# to avoid make-var/shell-var-mixed inline shell (see docs/TECHNICAL_REVIEW.md §3.6).
#
# Usage: util_make_stats.sh [has_nvidia] [has_dri]
#   has_nvidia / has_dri : 'true' to include that vendor's section (as detected
#                          by the Makefile). Anything else omits it.
# =============================================================================
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || source "/tmp/util_paths.sh"
devkit_require "util_logging.sh"

HAS_NVIDIA="${1:-false}"
HAS_DRI="${2:-false}"

print_section "All Containers Status (CPU/Mem/PIDs)"; echo ""
docker stats --no-stream \
    --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.PIDs}}" \
    | sed "s/^/  /"

if [ "$HAS_NVIDIA" = "true" ]; then
    echo ""; print_section "NVIDIA GPU Details"; echo ""
    nvidia-smi --query-gpu=index,name,utilization.gpu,utilization.memory,memory.used,memory.total \
        --format=csv,noheader,nounits | sed "s/^/  GPU /"
fi

if [ "$HAS_DRI" = "true" ]; then
    echo ""; print_section "Intel/AMD (DRI) Load Status"; echo ""
    for dev in /sys/class/drm/renderD*; do
        [ -d "$dev" ] || continue
        idx="${dev##*renderD}"
        vendor="$(cat "$dev/device/vendor" 2>/dev/null)"
        if [ "$vendor" = "0x8086" ]; then
            vname="Intel"
        elif [ "$vendor" = "0x1002" ] || [ "$vendor" = "0x1022" ]; then
            vname="AMD"
        else
            vname="DRI"
        fi
        echo -n "  GPU $idx ($vname) Status: "
        if [ -e "$dev/device/gpu_busy_percent" ]; then
            echo "$(cat "$dev/device/gpu_busy_percent")%"
        else
            echo "Active (Use make top for details)"
        fi
    done
fi
