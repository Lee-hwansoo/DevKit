#!/bin/bash
# =============================================================================
# scripts/util_make_top.sh
# Launches the best-available interactive process/GPU monitor for `make top`.
# Extracted from the Makefile's inline docker-exec / host monitoring recipes
# (see docs/TECHNICAL_REVIEW.md §3.6 — the inline versions mixed make-var and
# shell-var expansion across a docker-exec string).
#
# Usage: util_make_top.sh <container|host> [has_dri]
#   container : fallback chain run INSIDE a container (no sudo, no DRI probe).
#   host      : fallback chain run on the host (DRI-vendor probe + sudo intel).
#   has_dri   : 'true' to probe /sys DRI vendors in host mode.
# =============================================================================
set -uo pipefail

MODE="${1:-host}"
HAS_DRI="${2:-false}"

# Best-effort logging: fall back to plain echo if util_logging is unavailable
# (this script may run inside a container where sourcing paths differ).
source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || true
devkit_require "util_logging.sh" 2>/dev/null || true
type log_info  >/dev/null 2>&1 || log_info()  { echo "[INFO] $*"; }
type log_warn  >/dev/null 2>&1 || log_warn()  { echo "[WARN] $*" >&2; }
type log_error >/dev/null 2>&1 || log_error() { echo "[ERROR] $*" >&2; }

# Run nvtop only when it actually sees a GPU (its first output line reports
# "No GPU ..." otherwise). Returns 0 if nvtop was launched.
run_nvtop_if_gpu() {
    command -v nvtop >/dev/null 2>&1 || return 1
    local probe
    probe="$(nvtop 2>&1 | awk 'NR==1{print; exit}')"
    case "$probe" in
        *"No GPU"*) return 1 ;;
        *) nvtop; return 0 ;;
    esac
}

if [ "$MODE" = "container" ]; then
    # Inside the container: nvtop -> intel_gpu_top -> radeontop -> htop.
    run_nvtop_if_gpu && exit 0
    command -v intel_gpu_top >/dev/null 2>&1 && { intel_gpu_top; exit 0; }
    command -v radeontop     >/dev/null 2>&1 && { radeontop;     exit 0; }
    htop
    exit 0
fi

# Host mode: nvtop -> per-DRI-vendor tool -> htop.
if command -v nvtop >/dev/null 2>&1; then
    if run_nvtop_if_gpu; then exit 0; fi
    log_warn "Host nvtop failed to detect a GPU. Trying an alternative..."
fi

if [ "$HAS_DRI" = "true" ]; then
    for dev in /sys/class/drm/renderD*; do
        [ -e "$dev/device/vendor" ] || continue
        vendor="$(cat "$dev/device/vendor" 2>/dev/null)"
        if [ "$vendor" = "0x8086" ] && command -v intel_gpu_top >/dev/null 2>&1; then
            log_info "Intel GPU detected. Running intel_gpu_top..."
            sudo intel_gpu_top
            exit 0
        elif { [ "$vendor" = "0x1002" ] || [ "$vendor" = "0x1022" ]; } && command -v radeontop >/dev/null 2>&1; then
            log_info "AMD GPU detected. Running radeontop..."
            radeontop
            exit 0
        fi
    done
fi

if command -v htop >/dev/null 2>&1; then
    htop
    exit 0
fi

log_error "Appropriate monitoring tools (nvtop, intel_gpu_top, htop) could not be found."
exit 1
