#!/bin/bash
# =============================================================================
# scripts/setup_gpu.sh
# Automatic detection and setup switching for GPU hardware acceleration environment
#
# Supported devices: NVIDIA, Intel, AMD, CPU (Software)
# Features:
#   - Automatic fallback for Wayland/X11 displays
#   - Optimized setup for NVIDIA hybrid graphics (PRIME)
#   - Automatic fallback to software rendering (llvmpipe) upon acceleration failure
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || source "/tmp/util_paths.sh"
devkit_require "util_logging.sh"
LOG_PREFIX="[GPU]"

setup_gpu_usage() {
    cat <<'EOF'
Usage: source setup_gpu.sh {auto|intel|amd|nvidia|igpu|cpu|status|opencv_args}

Configure or inspect GPU/rendering environment variables.

Modes:
  auto          Detect and apply the best available GPU mode.
  intel|amd     Force vendor-specific integrated GPU settings.
  nvidia        Force NVIDIA/PRIME settings.
  igpu          Select Intel/AMD/generic DRI when available.
  cpu|software  Force software rendering.
  status        Print diagnostics.
  opencv_args   Print CMake flags for OpenCV CUDA support.
  -h, --help    Show this help.
EOF
}

setup_gpu_finish() {
    local code="${1:-0}"
    if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
        exit "$code"
    fi
    return "$code"
}

# Load shared GPU detection helpers (SSOT for GPU detection functions)
if ! devkit_require "util_gpu_detect.sh"; then
    echo "${LOG_PREFIX:-[GPU]} FATAL: util_gpu_detect.sh not found. GPU detection unavailable." >&2
    setup_gpu_finish 1
fi


# =============================================================================
# Global Constants & Environment Management
# =============================================================================
# List of environment variables managed by this script (centralized management)
GPU_ENV_VARS=(
    MESA_LOADER_DRIVER_OVERRIDE
    GALLIUM_DRIVER
    LIBGL_ALWAYS_SOFTWARE
    __NV_PRIME_RENDER_OFFLOAD
    __GLX_VENDOR_LIBRARY_NAME
    __EGL_VENDOR_LIBRARY_FILENAMES
    VK_ICD_FILENAMES
    __VK_LAYER_NV_optimus
    MESA_D3D12_DEFAULT_ADAPTER_NAME
    QT_XCB_FORCE_SOFTWARE_OPENGL
    LIBGL_ALWAYS_INDIRECT
)

# =============================================================================
# Detection Helpers
# =============================================================================
# GPU vendor detection functions (has_nvidia, has_intel_dri, has_amd_dri,
# has_any_dri, has_tegra, has_rocm) are provided by util_gpu_detect.sh above.

# Detects the active display server (Wayland vs X11) with fallback logic
detect_display_server() {
    if [ -n "${DISPLAY_TYPE:-}" ]; then
        echo "${DISPLAY_TYPE}"
        return
    fi

    if [ -n "$WAYLAND_DISPLAY" ]; then
        if [ "$XDG_SESSION_TYPE" = "x11" ] || [ -n "$DISPLAY" ]; then
            echo "XWayland"
        else
            echo "Wayland"
        fi
    elif [ -n "$DISPLAY" ]; then
        echo "X11"
    else
        echo "None"
    fi
}

# Safely prepend a directory to LD_LIBRARY_PATH without duplication
path_prepend() {
    local dir="$1"
    if [ -d "$dir" ] && [[ ":$LD_LIBRARY_PATH:" != *":$dir:"* ]]; then
        export LD_LIBRARY_PATH="$dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
}

# Check if a specific GPU setup is already active (idempotency helper)
is_setup_active() {
    local target_vendor="$1"
    local active_vendor="${__GLX_VENDOR_LIBRARY_NAME:-}"

    # If the vendor matches exactly, it's active
    [[ "$active_vendor" == "$target_vendor" ]] && return 0

    # WSL2 Special Case: Mesa is the vendor, but we target NVIDIA via D3D12
    if [[ "$target_vendor" == "nvidia" ]] && has_dxg; then
        [[ "$active_vendor" == "mesa" ]] && [[ "${MESA_D3D12_DEFAULT_ADAPTER_NAME:-}" == "NVIDIA" ]] && return 0
    fi

    # Check for Vulkan ICD as a secondary indicator for NVIDIA
    if [[ "$target_vendor" == "nvidia" ]] && [[ -n "${VK_ICD_FILENAMES:-}" ]] && [[ "$VK_ICD_FILENAMES" == *"nvidia"* ]]; then
        return 0
    fi

    return 1
}

# =============================================================================
# Reset
# =============================================================================
reset_gpu_env() {
    for var in "${GPU_ENV_VARS[@]}"; do
        unset "$var"
    done
}

# =============================================================================
# GPU Setup Functions
# =============================================================================
write_gpu_env() {
    # Persists GPU-specific environment variables for use in future shell sessions
    local env_file="${GPU_ENV_FILE:-${HOME}/.gpu_env.sh}"
    local env_dir
    env_dir="$(dirname "$env_file")"

    if [ ! -d "$env_dir" ] || [ ! -w "$env_dir" ]; then
        log_warn "GPU environment persistence skipped; directory is not writable: $env_dir"
        return 0
    fi

    # Determine uv extra (PyTorch selection) based on detectable hardware
    local uv_extra="cpu"
    if [ "${LIBGL_ALWAYS_SOFTWARE:-0}" = "0" ]; then
        if [ "${__GLX_VENDOR_LIBRARY_NAME:-}" = "nvidia" ] || has_nvidia || has_tegra; then
            uv_extra="gpu"
        fi
    fi

    {
        echo "# __GPU_ENV_START"
        for var in "${GPU_ENV_VARS[@]}"; do
            # Only export if the variable is set
            if [ -n "${!var:-}" ]; then
                # Use printf %q to safely escape values (e.g. spaces in adapter names)
                printf "export %s=%q\n" "$var" "${!var}"
            elif [ "$var" = "LIBGL_ALWAYS_SOFTWARE" ]; then
                # Default to 0 for this specific variable
                echo "export LIBGL_ALWAYS_SOFTWARE=0"
            fi
        done
        [ -n "${LD_LIBRARY_PATH:-}" ] && printf "export LD_LIBRARY_PATH=%q\n" "$LD_LIBRARY_PATH"
        echo "export UV_EXTRA=${uv_extra}"
        echo "# __GPU_ENV_END"
    } > "$env_file"
}

setup_wsl2_d3d12() {
    log_info "WSL2 environment detected. Using Mesa D3D12 (Dozen) for graphics acceleration."
    reset_gpu_env
    export LIBGL_ALWAYS_SOFTWARE=0
    # Crucial for Mesa to find host libraries (dxcore, d3d12core) on WSL2
    path_prepend "/usr/lib/wsl/lib"
    export __GLX_VENDOR_LIBRARY_NAME="mesa"
    export MESA_LOADER_DRIVER_OVERRIDE="d3d12"
    export GALLIUM_DRIVER="d3d12"
    export LIBGL_ALWAYS_INDIRECT=0

    # Optimization: Prioritize NVIDIA adapter if present on WSL2
    if has_nvidia; then
        export MESA_D3D12_DEFAULT_ADAPTER_NAME="NVIDIA"
    fi

    write_gpu_env
    log_ok "WSL2 D3D12 graphics bridge configured"
}

apply_gpu_setup() {
    local target_setup_func="$1"

    if [ "$target_setup_func" = "setup_software" ]; then
        setup_software
        return
    fi

    # Architecture Intercept Logic
    if has_dxg; then
        # If we have an NVIDIA GPU and the Container Toolkit is installed,
        # prioritize the Native NVIDIA path for better performance and CUDA support.
        if has_nvidia && [ "${HAS_TOOLKIT:-false}" = "true" ]; then
            log_ok "WSL2 with NVIDIA Toolkit detected. Using native NVIDIA acceleration path."
            setup_nvidia
            return
        fi

        # Fallback to Mesa D3D12 for Intel/AMD or if NVIDIA Toolkit is missing.
        if [ "$target_setup_func" != "setup_wsl2_d3d12" ]; then
            log_info "WSL2 environment detected (No Toolkit or Generic). Using Mesa D3D12 bridge."
        fi
        setup_wsl2_d3d12
        return
    fi

    # Native environment
    if declare -f "$target_setup_func" > /dev/null; then
        "$target_setup_func"
    else
        log_error "Unknown GPU setup logic requested: $target_setup_func"
        setup_software
    fi
}

setup_nvidia() {
    # Avoid redundant configuration if NVIDIA environment is already active
    if is_setup_active "nvidia"; then
        if [ "${__NV_PRIME_RENDER_OFFLOAD:-}" = "1" ]; then
            log_info "NVIDIA environment already active. Skipping redundant setup."
            return
        fi
    fi

    reset_gpu_env
    export LIBGL_ALWAYS_SOFTWARE=0
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __VK_LAYER_NV_optimus=NVIDIA_only

    if has_dxg; then
        # WSL2 Hybrid: Use Mesa D3D12 bridge for OpenGL, but target NVIDIA adapter.
        log_info "WSL2 detected: Configuring NVIDIA-backed Mesa D3D12 bridge."
        export __GLX_VENDOR_LIBRARY_NAME="mesa"
        export MESA_LOADER_DRIVER_OVERRIDE="d3d12"
        export GALLIUM_DRIVER="d3d12"
        export MESA_D3D12_DEFAULT_ADAPTER_NAME="NVIDIA"
        export LIBGL_ALWAYS_INDIRECT=0
        path_prepend "/usr/lib/wsl/lib"
    else
        # Native Linux: Use standard NVIDIA GLX/EGL/Vulkan drivers.
        log_info "Native Linux detected: Configuring direct NVIDIA acceleration path."
        export __GLX_VENDOR_LIBRARY_NAME="nvidia"

        # Explicitly point to NVIDIA ICD files to prevent Mesa from hijacking
        # Search for ICD files in prioritized standard locations
        local icd_paths=(
            "/usr/share/vulkan/icd.d/nvidia_icd.json"
            "/etc/vulkan/icd.d/nvidia_icd.json"
            "/usr/share/glvnd/egl_vendor.d/10_nvidia.json"
        )
        for path in "${icd_paths[@]}"; do
            if [ -f "$path" ]; then
                if [[ "$path" == *"vulkan"* ]]; then
                    [ -z "${VK_ICD_FILENAMES:-}" ] && export VK_ICD_FILENAMES="$path"
                elif [[ "$path" == *"egl_vendor"* ]]; then
                    [ -z "${__EGL_VENDOR_LIBRARY_FILENAMES:-}" ] && export __EGL_VENDOR_LIBRARY_FILENAMES="$path"
                fi
            fi
        done
    fi

    local ds=$(detect_display_server)
    log_info "Detected Display Server: $ds"

    # NVIDIA Settings exclusive to Wayland/XWayland
    if [[ "$ds" == *"Wayland"* ]]; then
        [ -z "${QT_QPA_PLATFORM:-}" ] && export QT_QPA_PLATFORM="wayland;xcb"
        [ -z "${GDK_BACKEND:-}" ] && export GDK_BACKEND="wayland,x11"
        # Only set GBM_BACKEND if we are NOT on WSL2 (WSL2 doesn't use GBM for container display)
        if ! has_dxg; then
            export GBM_BACKEND="nvidia-drm"
        fi
        export __GL_GSYNC_ALLOWED=0
        export __GL_VRR_ALLOWED=0
        log_ok "NVIDIA Wayland optimizations applied"
    fi

    write_gpu_env
    log_ok "NVIDIA GPU configured (OpenGL + Vulkan + EGL)"
}

setup_mesa_driver() {
    local driver="$1"
    local label="$2"
    [ -n "$driver" ] && [ "${MESA_LOADER_DRIVER_OVERRIDE:-}" = "$driver" ] && return
    reset_gpu_env
    export LIBGL_ALWAYS_SOFTWARE=0
    [ -n "$driver" ] && export MESA_LOADER_DRIVER_OVERRIDE="$driver"
    [ -n "$driver" ] && export GALLIUM_DRIVER="$driver"
    write_gpu_env
    log_ok "$label"
}

setup_intel() {
    if [ -d /sys/module/xe ]; then
        setup_mesa_driver "" "Intel GPU configured (xe driver for Arc)"
        return
    fi

    setup_mesa_driver "iris" "Intel GPU configured (Mesa/iris driver)"
}

setup_amd() {
    setup_mesa_driver "radeonsi" "AMD GPU configured (Mesa/radeonsi driver)"
}

setup_tegra() {
    reset_gpu_env
    export LIBGL_ALWAYS_SOFTWARE=0
    write_gpu_env
    log_ok "NVIDIA Tegra GPU configured (Jetson/Embedded)"
}

setup_rocm() {
    reset_gpu_env
    export LIBGL_ALWAYS_SOFTWARE=0
    write_gpu_env
    log_ok "AMD ROCm environment configured"
}

setup_software() {
    if [ "${LIBGL_ALWAYS_SOFTWARE:-0}" = "1" ] && [ "${GALLIUM_DRIVER:-}" = "llvmpipe" ]; then return; fi
    reset_gpu_env
    export LIBGL_ALWAYS_SOFTWARE=1
    export GALLIUM_DRIVER="llvmpipe"
    export QT_XCB_FORCE_SOFTWARE_OPENGL=1
    write_gpu_env
    log_warn "Software rendering (CPU/llvmpipe) configured"
}

# =============================================================================
# Automated environment-based GPU setup selection
# =============================================================================
# Strategy Registry: Mapping hardware detection to setup functions
# Priority is determined by the order in this list
declare -A GPU_STRATEGIES=(
    ["dxg"]="setup_wsl2_d3d12"
    ["nvidia"]="setup_nvidia"
    ["intel_dri"]="setup_intel"
    ["amd_dri"]="setup_amd"
    ["tegra"]="setup_tegra"
    ["rocm"]="setup_rocm"
    ["any_dri"]="setup_igpu"
)
GPU_STRATEGY_ORDER=("dxg" "nvidia" "intel_dri" "amd_dri" "tegra" "rocm" "any_dri")

setup_auto() {
    # If LIBGL_ALWAYS_SOFTWARE is 1 from environment, log it but don't return early if GPU_MODE is not cpu
    if [ "${LIBGL_ALWAYS_SOFTWARE:-0}" = "1" ]; then
        if [ "${1:-auto}" != "cpu" ] && [ "${1:-auto}" != "software" ]; then
            log_info "LIBGL_ALWAYS_SOFTWARE=1 detected. Attempting to override for hardware acceleration..."
            export LIBGL_ALWAYS_SOFTWARE=0
        else
            log_info "LIBGL_ALWAYS_SOFTWARE=1 detected. Respecting software rendering request."
            setup_software
            return
        fi
    fi

    local detected=false
    local ds=$(detect_display_server)

    # Strategy Pattern: Iterate through prioritized hardware detectors
    for key in "${GPU_STRATEGY_ORDER[@]}"; do
        local detector="has_$key"
        if $detector; then
            # Special handling for hybrid graphics on Wayland
            # Default to Intel for stability, BUT respect user preference if GPU_MODE is nvidia
            if [ "$key" = "nvidia" ] && has_intel_dri && [[ "$ds" == *"Wayland"* ]]; then
                if [ "${GPU_MODE:-auto}" = "nvidia" ]; then
                    log_info "Hybrid on Wayland: GPU_MODE=nvidia detected. Prioritizing NVIDIA performance."
                    apply_gpu_setup setup_nvidia
                else
                    log_warn "Hybrid on Wayland: Defaulting to Intel for stability. Use GPU_MODE=nvidia to override."
                    apply_gpu_setup setup_intel
                fi
            else
                apply_gpu_setup "${GPU_STRATEGIES[$key]}"
            fi
            detected=true
            break
        fi
    done

    # Verification: Validates that the selected hardware renderer is active
    if [ "$detected" = true ]; then
        if [ "$ds" != "None" ] && command -v glxinfo &>/dev/null; then
            local renderer
            renderer=$(trim_ws "$(glxinfo 2>/dev/null | grep -Ei "OpenGL renderer" | sed -E 's/.*:\s*(.*)/\1/' || true)")
            if [[ "$renderer" =~ (llvmpipe|softpipe|swrast) ]] || [ -z "$renderer" ]; then
                if has_dxg; then
                    log_warn "Renderer is SOFTWARE ($renderer). This is common on WSL2 when host acceleration is not fully enabled."
                    log_warn "Proceeding with D3D12 configuration. GPU may still be used via D3D12/Dozen."
                else
                    log_warn "!!! GPU detected but renderer is SOFTWARE ($renderer) !!!"
                    log_warn "Check host X11 permissions (xhost +SI:localuser:root) or NVIDIA toolkit."
                    setup_software
                fi
            fi
        elif command -v vulkaninfo &>/dev/null; then
            local vk_dev=$(vulkaninfo --summary 2>/dev/null | grep "deviceName" | head -1 || true)
            if [ -z "$vk_dev" ]; then
                log_warn "!!! Vulkan device not found. Headless verification failed !!!"
                setup_software
            fi
        elif command -v vainfo &>/dev/null; then
            if ! vainfo --display drm 2>/dev/null | grep -qi "Driver version"; then
                log_warn "!!! VA-API DRM device not found. Headless verification failed !!!"
                setup_software
            fi
        else
            if [ "$ds" != "None" ]; then
                log_warn "Validation tools (glxinfo/vulkaninfo/vainfo) not found."
                # Low-level fallback for senior architect standard
                local sys_vendor=$(get_gpu_vendor_sysfs)
                if [ "$sys_vendor" != "Unknown" ]; then
                    log_ok "Fallback Verification: Found $sys_vendor GPU via sysfs."
                else
                    log_warn "To enable full validation, add 'mesa-utils' or 'vulkan-tools' to apt.txt."
                fi
            fi
        fi
    fi

    if [ "$detected" = false ]; then
        setup_software
        log_warn "Auto-detected: No GPU device. Using software rendering."
    fi

    # Final summary for NVIDIA environments
    if has_nvidia; then
        local cuda_v=$(get_cuda_metadata cuda_ver)
        [ -n "$cuda_v" ] && log_info "Active Toolkit: CUDA $cuda_v"
    fi
    return 0
}

# =============================================================================
# OpenCV CMake Arguments (GPU-aware)
# =============================================================================
# Returns CMake flags to enable CUDA acceleration for OpenCV if NVIDIA hardware
# is detected, otherwise disables CUDA. Extracted as a function so `local` is valid.
__opencv_cmake_args() {
    if [ "${OPENCV_CUDA:-auto}" = "off" ]; then
        echo "-DWITH_CUDA=OFF"
        return
    fi

    if can_build_cuda; then
        local args="-DWITH_CUDA=ON -DWITH_CUDNN=ON -DOPENCV_DNN_CUDA=ON"
        args+=" -DENABLE_FAST_MATH=ON -DCUDA_FAST_MATH=ON -DWITH_CUBLAS=ON"
        if command -v nvidia-smi >/dev/null 2>&1; then
            local caps=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | sort -u | paste -sd ";" -)
            [ -n "$caps" ] && args+=" -DCUDA_ARCH_BIN=${caps}+PTX"
        fi
        echo "$args"
    else
        echo "-DWITH_CUDA=OFF"
    fi
}

# =============================================================================
# Status
# =============================================================================
__gpu_status_impl() {
    print_banner SETUP
    log_info "GPU_MODE env: ${GPU_MODE:-not set}"
    log_info "OPENCV_CUDA policy: ${OPENCV_CUDA:-auto}"

    if has_nvidia; then
        log_ok "NVIDIA: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"

        local cuda_v=$(get_cuda_metadata cuda_ver)
        [ -n "$cuda_v" ] && log_ok "CUDA:   $cuda_v"

        local cudnn_v=$(get_cuda_metadata cudnn_ver)
        [ -n "$cudnn_v" ] && log_ok "cuDNN:  $cudnn_v"
    fi
    if has_intel_dri; then
        log_ok "Intel GPU: $(list_glob_basenames "/dev/dri/renderD*")"
    fi
    if has_amd_dri; then
        log_ok "AMD GPU: $(list_glob_basenames "/dev/dri/renderD*")"
    fi

    local renderer
    local GLX_OUT
    if command -v glxinfo &>/dev/null; then
        GLX_OUT=$(glxinfo 2>/dev/null || true)
        # Robustly extract renderer and vendor using regex to handle different glxinfo labels
        RENDERER=$(trim_ws "$(echo "$GLX_OUT" | grep -Ei "OpenGL renderer" | sed -E 's/.*:\s*(.*)/\1/' || true)")
        VENDOR=$(trim_ws "$(echo "$GLX_OUT" | grep -Ei "OpenGL vendor" | sed -E 's/.*:\s*(.*)/\1/' || true)")

        if [ -n "$RENDERER" ]; then
            if echo "$RENDERER" | grep -qi "llvmpipe"; then
                log_warn "Renderer: $RENDERER (Software Rendering)"
            else
                log_ok "Renderer: $RENDERER"
            fi
            [ -n "$VENDOR" ] && log_info "Vendor:   $VENDOR"
        else
            # Try fallback to glxinfo -B (brief mode)
            RENDERER=$(trim_ws "$(glxinfo -B 2>/dev/null | grep -Ei "OpenGL renderer" | sed -E 's/.*:\s*(.*)/\1/' || true)")
            if [ -n "$RENDERER" ]; then
                log_ok "Renderer: $RENDERER (Detected via Brief Mode)"
            else
                log_warn "Renderer: Unable to detect via glxinfo. Acceleration state uncertain."
            fi
        fi
    else
        log_warn "Renderer: glxinfo not installed (mesa-utils)."
    fi

    log_info "=== Environment Variables ==="
    log_info "DISPLAY=${DISPLAY:-not set}"
    for var in "${GPU_ENV_VARS[@]}"; do
        log_info "$var=${!var:-not set}"
    done

    log_info "=== Library Diagnostics ==="
    if command -v ldconfig &>/dev/null; then
        local gl_libs=$(ldconfig -p | grep -Ei "libGL\.so|libEGL\.so|nvidia-tls" | head -n 5)
        if [ -n "$gl_libs" ]; then
            echo "$gl_libs" | while read -r line; do log_info "  $line"; done
        else
            log_warn "  No critical GL libraries found in ldconfig cache."
        fi
    fi

    log_info "=== Build Capability ==="
    if can_build_cuda; then
        log_ok "CUDA build: available (nvcc: $(command -v nvcc))"
    else
        log_info "CUDA build: unavailable (NVIDIA runtime and nvcc are both required)"
    fi
    log_info "OpenCV CMake args: $(__opencv_cmake_args)"
}

# =============================================================================
# Integrated GPU (iGPU) Setup (Excludes NVIDIA)
# =============================================================================
setup_igpu() {
    # Auto-determine Intel/AMD based on DRI device (Excluding NVIDIA)
    if has_intel_dri; then
        apply_gpu_setup setup_intel
    elif has_amd_dri; then
        apply_gpu_setup setup_amd
    elif has_any_dri; then
        setup_mesa_driver "" "Generic DRI GPU configured"
    else
        setup_software
        log_warn "igpu mode requested but no DRI device found. Falling back to software."
    fi
}

# =============================================================================
# Main Entry
# =============================================================================
case "${1:-auto}" in
    intel)              apply_gpu_setup setup_intel ;;
    amd)                apply_gpu_setup setup_amd ;;
    nvidia)             apply_gpu_setup setup_nvidia ;;
    igpu)               apply_gpu_setup setup_igpu ;;
    cpu|software)       setup_software ;;
    status)             __gpu_status_impl ;;
    opencv_args)        __opencv_cmake_args ;;
    auto|"")            setup_auto ;;
    -h|--help)          setup_gpu_usage; setup_gpu_finish 0 ;;
    *)
        setup_gpu_usage >&2
        setup_gpu_finish 2
        ;;
esac
