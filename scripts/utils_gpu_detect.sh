#!/bin/bash
# =============================================================================
# scripts/utils_gpu_detect.sh
# Shared GPU hardware detection helpers
#
# Provides portable detection functions for GPU vendors and device nodes.
# Sourced by: gpu_setup.sh, hardware_check.sh
# =============================================================================

# NVIDIA: kernel device node + driver tool
has_nvidia() {
    # On WSL2, /dev/nvidiactl might be missing even if nvidia-smi works
    [ -e /dev/nvidiactl ] || [ -e /dev/nvidia0 ] || command -v nvidia-smi >/dev/null 2>&1
}

# Intel iGPU: DRI device with vendor ID 0x8086
has_intel_dri() {
    [ -d /dev/dri ] && grep -rl "0x8086" /sys/class/drm/*/device/vendor 2>/dev/null | grep -q .
}

# AMD GPU: DRI device with vendor ID 0x1002 (Discrete) or 0x1022 (APU/SoC)
has_amd_dri() {
    [ -d /dev/dri ] && grep -rl "0x1002\|0x1022" /sys/class/drm/*/device/vendor 2>/dev/null | grep -q .
}

# Generic DRI: any render node present
has_any_dri() {
    [ -d /dev/dri ] && ls /dev/dri/renderD* >/dev/null 2>&1
}

# NVIDIA Jetson / Tegra embedded GPU (no nvidiactl)
has_tegra() {
    ls /dev/nvhost-* 2>/dev/null | grep -q .
}

# AMD ROCm runtime
has_rocm() {
    command -v rocm-smi &>/dev/null || [ -d "/opt/rocm" ]
}

# WSL2 Paravirtualized Graphics (D3D12 / DirectX)
has_dxg() {
    # Check for device node and ensure we are on a Microsoft kernel to avoid false positives
    [ -e /dev/dxg ] && grep -qi "microsoft" /proc/version 2>/dev/null
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
