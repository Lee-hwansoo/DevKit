#!/bin/bash
# =============================================================================
# scripts/wsl_auditor.sh
# Diagnostic tool to verify WSL 2 host configurations (.wslconfig)
# =============================================================================

set -e

# Load logging utilities
source "$(dirname "${BASH_SOURCE[0]}")/utils_logging.sh" 2>/dev/null || true

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

# Guard: IS_WSL is the authoritative source (set by env_detector.sh → Makefile export).
# This script is only invoked from `make check` after IS_WSL=true is confirmed.
# When run standalone without IS_WSL set, exits cleanly (safe fallback).
if [ "${IS_WSL}" != "true" ]; then
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
# _ini_has() validates section context, rejecting commented lines and other-section keys.
# Check local distro config first ([boot] section)
if _ini_has "${LOCAL_WSL_CONF}" "boot" "systemd" "true"; then
    HAS_SYSTEMD="true"
fi

# Check global .wslconfig if not found locally
if [ "${HAS_SYSTEMD}" = "false" ] && _ini_has "${WSL_CONFIG_PATH}" "boot" "systemd" "true"; then
    HAS_SYSTEMD="true"
fi

# 3. Audit Mirrored Networking ([wsl2] section)
if _ini_has "${WSL_CONFIG_PATH}" "wsl2" "networkingMode" "mirrored"; then
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
