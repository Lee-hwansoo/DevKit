#!/bin/bash
# =============================================================================
# scripts/util_gpu_detect.sh
# Shared GPU hardware detection helpers
#
# Provides portable detection functions for GPU vendors and device nodes.
# Sourced by: setup_gpu.sh, check_hardware.sh
# =============================================================================

trim_ws() {
    local value="${1:-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

has_glob_match() {
    compgen -G "$1" >/dev/null
}

has_drm_vendor() {
    local expected="$1"
    local vendor_file
    local vendor_id

    [ -d /dev/dri ] || return 1
    for vendor_file in /sys/class/drm/*/device/vendor; do
        [ -f "$vendor_file" ] || continue
        vendor_id="$(trim_ws "$(cat "$vendor_file" 2>/dev/null || true)")"
        [ "$vendor_id" = "$expected" ] && return 0
    done
    return 1
}

list_glob_basenames() {
    local pattern="$1"
    local item
    local names=()
    local had_nullglob=false
    shopt -q nullglob && had_nullglob=true
    shopt -s nullglob
    for item in $pattern; do
        [ -e "$item" ] || continue
        names+=( "${item##*/}" )
    done
    [ "$had_nullglob" = true ] || shopt -u nullglob
    printf '%s' "${names[*]}"
}

# NVIDIA: kernel device node + driver tool
has_nvidia() {
    # Memoize: the device-node check is cheap, but the nvidia-smi probe below can
    # be slow (esp. on WSL2), and this is called several times per boot.
    if [ -n "${__DEVKIT_HAS_NVIDIA:-}" ]; then
        [ "$__DEVKIT_HAS_NVIDIA" = "1" ]
        return
    fi
    # Native Linux: a real kernel device node is authoritative.
    if [ -e /dev/nvidiactl ] || [ -e /dev/nvidia0 ]; then
        __DEVKIT_HAS_NVIDIA=1
        return 0
    fi
    # WSL2 / no device node: require a *functional* nvidia-smi. Presence of the
    # binary alone is not enough — a stub or a driver-less install would misdetect
    # NVIDIA on native/headless hosts and force a CUDA wheel + broken GLX/EGL.
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        __DEVKIT_HAS_NVIDIA=1
        return 0
    fi
    __DEVKIT_HAS_NVIDIA=0
    return 1
}

# CUDA build capability: NVIDIA runtime plus compiler/toolkit availability
can_build_cuda() {
    has_nvidia && command -v nvcc >/dev/null 2>&1
}

# Intel iGPU: DRI device with vendor ID 0x8086
has_intel_dri() {
    has_drm_vendor "0x8086"
}

# AMD GPU: DRI device with vendor ID 0x1002 (Discrete) or 0x1022 (APU/SoC)
has_amd_dri() {
    has_drm_vendor "0x1002" || has_drm_vendor "0x1022"
}

# Generic DRI: any render node present
has_any_dri() {
    [ -d /dev/dri ] && has_glob_match "/dev/dri/renderD*"
}

# NVIDIA Jetson / Tegra embedded GPU (no nvidiactl)
has_tegra() {
    has_glob_match "/dev/nvhost-*"
}

# AMD ROCm runtime
has_rocm() {
    command -v rocm-smi &>/dev/null || [ -d "/opt/rocm" ]
}

# WSL2 Paravirtualized Graphics (D3D12 / DirectX)
has_dxg() {
    local proc_version

    # Check for device node and ensure we are on a Microsoft kernel to avoid false positives
    [ -e /dev/dxg ] || return 1
    proc_version="$(cat /proc/version 2>/dev/null || true)"
    case "${proc_version,,}" in
        *microsoft*) return 0 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# GPU Configuration Prescriptions (Centralized Knowledge)
# =============================================================================
# Returns recommended environment variables for specific hardware scenarios.
# Usage: get_gpu_prescription <scenario> [indent_string]
get_gpu_prescription() {
    local scenario="$1"
    local indent="${2:-}"

    case "$scenario" in
        nvidia_wsl)
            echo "${indent}export MESA_LOADER_DRIVER_OVERRIDE=d3d12"
            echo "${indent}export GALLIUM_DRIVER=d3d12"
            echo "${indent}export MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA"
            ;;
        igpu_wsl)
            echo "${indent}export MESA_LOADER_DRIVER_OVERRIDE=d3d12"
            echo "${indent}export GALLIUM_DRIVER=d3d12"
            ;;
        nvidia_optimize_wsl)
            echo "${indent}export MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA"
            ;;
    esac
}

# =============================================================================
# GPU Metadata Providers (SSOT: Single Source of Truth)
# =============================================================================
# Provides standardized version strings for CUDA-related components.
# Usage: get_cuda_metadata <key>
get_cuda_metadata() {
    local key="$1"
    case "$key" in
        cuda_ver)
            if command -v nvcc &>/dev/null; then
                local nvcc_out
                nvcc_out=$(nvcc --version 2>/dev/null)
                while read -r line; do
                    if [[ "$line" == *release* ]]; then
                        read -r -a parts <<< "$line"
                        local raw_ver="${parts[${#parts[@]}-1]}"
                        raw_ver="${raw_ver#V}"
                        raw_ver="${raw_ver%,}"
                        echo "$raw_ver"
                        break
                    fi
                done <<< "$nvcc_out"
            elif [ -f /usr/local/cuda/version.json ]; then
                while read -r line; do
                    if [[ "$line" == *"version"* ]]; then
                        if [[ "$line" =~ \"version\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
                            echo "${BASH_REMATCH[1]}"
                            break
                        fi
                    fi
                done < /usr/local/cuda/version.json
            fi
            ;;
        cudnn_ver)
            local header="/usr/include/cudnn_version.h"
            [ ! -f "$header" ] && header="/usr/local/cuda/include/cudnn_version.h"
            if [ -f "$header" ]; then
                local maj="" min="" pat=""
                while read -r _name ckey val; do
                    case "$ckey" in
                        CUDNN_MAJOR) maj="$val" ;;
                        CUDNN_MINOR) min="$val" ;;
                        CUDNN_PATCHLEVEL) pat="$val" ;;
                    esac
                done < "$header"
                if [ -n "$maj" ]; then
                    printf "%s.%s.%s" "$maj" "$min" "$pat"
                fi
            fi
            ;;
    esac
}

# =============================================================================
# Low-level Hardware Verification (Fallback Logic)
# =============================================================================
# Resolves GPU vendor name via sysfs to handle cases where glxinfo is missing.
get_gpu_vendor_sysfs() {
    local vendor_id
    # Try common DRI device paths
    if [ -d /sys/class/drm ]; then
        for vendor_file in /sys/class/drm/card*/device/vendor; do
            [ -f "$vendor_file" ] || continue
            vendor_id=$(trim_ws "$(cat "$vendor_file" 2>/dev/null || true)")
            case "$vendor_id" in
                0x8086) echo "Intel" ; return ;;
                0x10de) echo "NVIDIA"; return ;;
                0x1002|0x1022) echo "AMD" ; return ;;
            esac
        done
    fi
    echo "Unknown"
}
