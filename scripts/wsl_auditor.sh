#!/bin/bash
# =============================================================================
# scripts/wsl_auditor.sh
# Diagnostic tool to verify WSL 2 host configurations (.wslconfig)
# =============================================================================

set -e

# Load logging utilities
source "$(dirname "${BASH_SOURCE[0]}")/utils_logging.sh" 2>/dev/null || true

# Check if we are actually in WSL 2.
# Uses composite check: WSL2-specific kernel signature OR WSLg directory presence.
# This avoids false positives from Azure VMs and Hyper-V guests that also expose
# "Microsoft" in /proc/version but lack WSL2-specific artifacts.
_is_wsl2() {
    grep -qi "microsoft" /proc/version 2>/dev/null || return 1
    grep -qiE "WSL2|microsoft-standard" /proc/version 2>/dev/null && return 0
    { [ -d "/mnt/wslg" ] || [ -d "/run/WSL" ]; } && return 0
    return 1
}

if ! _is_wsl2; then
    exit 0
fi

# 1. Locate .wslconfig on Windows Host
# timeout 3: prevents hanging if Windows process bridge is unresponsive.
# || true: prevents set -e from aborting if powershell.exe is unavailable.
WIN_USERPROFILE=""
if command -v powershell.exe >/dev/null 2>&1; then
    WIN_USERPROFILE=$(timeout 3 powershell.exe -NoProfile -Command \
        'Write-Host $env:USERPROFILE -NoNewline' 2>/dev/null | tr -d '\r') || true
fi

if [ -z "${WIN_USERPROFILE}" ]; then
    # Zero-cost fallback: infer path from /mnt/c/Users using the Windows username.
    _win_user=$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r') || true
    if [ -n "${_win_user}" ] && [ -d "/mnt/c/Users/${_win_user}" ]; then
        WIN_USERPROFILE="/mnt/c/Users/${_win_user}"
    fi
else
    WIN_USERPROFILE=$(wslpath "${WIN_USERPROFILE}" 2>/dev/null) || true
fi

WSL_CONFIG_PATH="${WIN_USERPROFILE}/.wslconfig"
LOCAL_WSL_CONF="/etc/wsl.conf"

# Status Flags
HAS_SYSTEMD="false"
HAS_MIRRORED="false"

# 2. Audit Systemd (Check both /etc/wsl.conf and .wslconfig)
# Anchored extended regex rejects commented lines and tolerates surrounding whitespace.
# Check local distro config first
if [ -f "${LOCAL_WSL_CONF}" ] && grep -qiE '^\s*systemd\s*=\s*true' "${LOCAL_WSL_CONF}"; then
    HAS_SYSTEMD="true"
fi

# Check global .wslconfig if not found locally
if [ "${HAS_SYSTEMD}" = "false" ] && [ -f "${WSL_CONFIG_PATH}" ] && \
    grep -qiE '^\s*systemd\s*=\s*true' "${WSL_CONFIG_PATH}"; then
    HAS_SYSTEMD="true"
fi

# 3. Audit Mirrored Networking
if [ -f "${WSL_CONFIG_PATH}" ] && grep -qiE '^\s*networkingMode\s*=\s*mirrored' "${WSL_CONFIG_PATH}"; then
    HAS_MIRRORED="true"
fi

# 4. Reporting
# We only print warnings if something is missing
if [ "${HAS_SYSTEMD}" = "false" ] || [ "${HAS_MIRRORED}" = "false" ]; then
    print_section "WSL Environment Audit"

    if [ "${HAS_SYSTEMD}" = "false" ]; then
        echo -e "  ${WARN} Systemd is not enabled in WSL 2."
        echo -e "  ${INFO} Required for: Native Docker Engine and automated service management."
        echo -e "  ${INFO} Fix: Add 'systemd=true' to your /etc/wsl.conf inside WSL."
    fi

    if [ "${HAS_MIRRORED}" = "false" ]; then
        echo -e "  ${WARN} Mirrored Networking Mode is not enabled in .wslconfig."
        echo -e "  ${INFO} Required for: Stable ROS 2 Multicast communication and local network access."
        echo -e "  ${INFO} Path: ${WSL_CONFIG_PATH}"
        echo -e "  ${INFO} Fix: Add 'networkingMode=mirrored' under [wsl2] section."
    fi

    echo ""
    echo -e "  ${INFO} Reference: See 'Windows (WSL 2) User Guide' in README.ko.md for details."
fi

exit 0
