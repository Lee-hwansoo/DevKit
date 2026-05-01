#!/bin/bash
# =============================================================================
# scripts/wsl_auditor.sh
# Diagnostic tool to verify WSL 2 host configurations (.wslconfig)
# =============================================================================

set -e

# Load logging utilities
source "$(dirname "${BASH_SOURCE[0]}")/utils_logging.sh" 2>/dev/null || true

# Check if we are actually in WSL
if ! grep -qi "Microsoft" /proc/version 2>/dev/null; then
    exit 0
fi

# 1. Locate .wslconfig on Windows Host
# Use powershell to get the Windows User Profile path reliably
WIN_USERPROFILE=$(powershell.exe -NoProfile -Command "echo \$env:USERPROFILE" 2>/dev/null | tr -d '\r')
if [ -z "${WIN_USERPROFILE}" ]; then
    # Fallback if powershell fails (rare)
    WIN_USERPROFILE=$(wslpath "$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r')")
else
    WIN_USERPROFILE=$(wslpath "${WIN_USERPROFILE}")
fi

WSL_CONFIG_PATH="${WIN_USERPROFILE}/.wslconfig"
LOCAL_WSL_CONF="/etc/wsl.conf"

# Status Flags
HAS_SYSTEMD="false"
HAS_MIRRORED="false"

# 2. Audit Systemd (Check both /etc/wsl.conf and .wslconfig)
# Check local distro config first
if [ -f "${LOCAL_WSL_CONF}" ] && grep -qi "systemd=true" "${LOCAL_WSL_CONF}"; then
    HAS_SYSTEMD="true"
fi

# Check global .wslconfig if not found locally
if [ "${HAS_SYSTEMD}" = "false" ] && [ -f "${WSL_CONFIG_PATH}" ] && grep -qi "systemd=true" "${WSL_CONFIG_PATH}"; then
    HAS_SYSTEMD="true"
fi

# 3. Audit Mirrored Networking
if [ -f "${WSL_CONFIG_PATH}" ] && grep -qi "networkingMode=mirrored" "${WSL_CONFIG_PATH}"; then
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
