#!/bin/bash
# =============================================================================
# scripts/check_wsl.sh
# Diagnostic tool to verify WSL 2 host configurations (.wslconfig)
# =============================================================================

set -e

# Load logging utilities
source "$(dirname "${BASH_SOURCE[0]}")/util_logging.sh" 2>/dev/null || true

# Section-aware INI value checker (local utility).
# Usage: _ini_has <file> <section> <key> <value>
# Returns 0 if [section] contains an uncommented key=value pair, 1 otherwise.
# Handles: leading whitespace, case-insensitive matching, and comment rejection.
_ini_has() {
    local file="$1" section="$2" key="$3" value="$4"
    [ -f "$file" ] || return 1
    awk -v s="$section" -v k="$key" -v v="$value" '
        BEGIN { IGNORECASE = 1 }
        { sub(/\r$/, "", $0) }
        /^[ \t]*\[/ {
            gsub(/[\[\]]/, "", $0)
            gsub(/^[ \t]+|[ \t]+$/, "", $0)
            in_sect = ($0 == s)
            next
        }
        in_sect && /^[^#;]/ {
            split($0, kv, /[ \t]*=[ \t]*/)
            gsub(/^[ \t]+|[ \t]+$/, "", kv[1])
            gsub(/^[ \t]+|[ \t]+$/, "", kv[2])
            if (tolower(kv[1]) == tolower(k) && tolower(kv[2]) == tolower(v)) { found=1; exit }
        }
        END { exit !found }
    ' "$file" 2>/dev/null
}

if [ "${IS_WSL}" != "true" ]; then
    exit 0
fi

# 1. Locate .wslconfig on Windows Host
WIN_USERPROFILE=""

# Method A: powershell.exe (Most reliable)
if command -v powershell.exe >/dev/null 2>&1; then
    _raw_profile=$(timeout 3 powershell.exe -NoProfile -Command 'Write-Host $env:USERPROFILE -NoNewline' 2>/dev/null | tr -d '\r') || true
    if [ -n "${_raw_profile}" ]; then
        WIN_USERPROFILE=$(wslpath "${_raw_profile}" 2>/dev/null) || true
    fi
fi

# Method B: cmd.exe fallback
if [ -z "${WIN_USERPROFILE}" ] && command -v cmd.exe >/dev/null 2>&1; then
    _raw_profile=$(timeout 3 cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r') || true
    if [ -n "${_raw_profile}" ]; then
        WIN_USERPROFILE=$(wslpath "${_raw_profile}" 2>/dev/null) || true
    fi
fi

# Method C: Hardcoded inference from /mnt/c/Users (Last resort)
if [ -z "${WIN_USERPROFILE}" ]; then
    _win_user=$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r' 2>/dev/null || whoami)
    for _drive in /mnt/*; do
        if [ -d "${_drive}/Users/${_win_user}" ]; then
            WIN_USERPROFILE="${_drive}/Users/${_win_user}"
            break
        fi
    done
fi

WSL_CONFIG_PATH="${WIN_USERPROFILE}/.wslconfig"
LOCAL_WSL_CONF="/etc/wsl.conf"

# Status Flags
HAS_SYSTEMD="false"
HAS_MIRRORED="false"

# 2. Audit Systemd
if _ini_has "${LOCAL_WSL_CONF}" "boot" "systemd" "true"; then
    HAS_SYSTEMD="true"
fi

# Check global .wslconfig if not found locally
if [ "${HAS_SYSTEMD}" = "false" ] && _ini_has "${WSL_CONFIG_PATH}" "boot" "systemd" "true"; then
    HAS_SYSTEMD="true"
fi

# 3. Audit Mirrored Networking
if _ini_has "${WSL_CONFIG_PATH}" "wsl2" "networkingMode" "mirrored"; then
    HAS_MIRRORED="true"
fi

# 4. Reporting
if [ "${HAS_SYSTEMD}" = "false" ] || [ "${HAS_MIRRORED}" = "false" ]; then
    print_section "WSL Environment Audit"

    if [ "${HAS_SYSTEMD}" = "false" ]; then
        log_warn "Systemd is not enabled in WSL 2."
        log_detail "Required for: Native Docker Engine and automated service management."
        log_detail "Fix: Add 'systemd=true' to your /etc/wsl.conf inside WSL."
    fi

    if [ "${HAS_MIRRORED}" = "false" ]; then
        log_warn "Mirrored Networking Mode is not enabled in .wslconfig."
        log_detail "Required for: Stable ROS 2 Multicast communication."
        log_detail "Path: ${WSL_CONFIG_PATH}"
        log_detail "Fix: Add 'networkingMode=mirrored' under [wsl2] section."
    fi
    echo ""
fi

# 5. GPU Acceleration Audit
SOURCE_GPU="$(dirname "${BASH_SOURCE[0]}")/util_gpu_detect.sh"
if [ -f "$SOURCE_GPU" ]; then
    source "$SOURCE_GPU"
else
    exit 0
fi

if [ "${IS_WSL}" = "true" ] && command -v glxinfo &>/dev/null; then
    host_renderer=$(glxinfo -B 2>/dev/null | grep -Ei "OpenGL renderer string" | head -n 1 | sed -E 's/.*:[[:space:]]*(.*)/\1/' | xargs || true)

    if [ -n "$host_renderer" ]; then
        # Scenario A: Software Rendering Fallback (Critical performance impact)
        if [[ "$host_renderer" == *"llvmpipe"* ]]; then
            print_section "WSL GPU Acceleration Audit"
            log_warn "Host OpenGL is stuck on Software Rendering (llvmpipe)."
            if has_nvidia; then
                log_info "Fix (NVIDIA): Add the following to your HOST(WSL) ~/.bashrc:"
                get_gpu_prescription "nvidia_wsl" "    "
            elif has_dxg || has_any_dri; then
                log_info "Fix (iGPU): Add the following to your HOST(WSL) ~/.bashrc:"
                get_gpu_prescription "igpu_wsl" "    "
            fi
            echo ""

        # Scenario B: Sub-optimal GPU selection (e.g. using iGPU while NVIDIA dGPU is available)
        elif [[ "$host_renderer" == *"D3D12"* ]] && has_nvidia && [[ "$host_renderer" != *"NVIDIA"* ]]; then
            print_section "WSL GPU Acceleration Audit"
            log_info "Current Renderer: ${host_renderer} (iGPU)"
            log_detail "Optimization: High-performance NVIDIA dGPU is available but idle."
            log_info "Fix: Add the following to your HOST(WSL) ~/.bashrc:"
            get_gpu_prescription "nvidia_optimize_wsl" "    "
            echo ""
        fi
    fi
fi

exit 0
