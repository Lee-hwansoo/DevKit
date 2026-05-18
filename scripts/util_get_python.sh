#!/bin/bash
# =============================================================================
# scripts/util_get_python.sh
# Detects the appropriate Python interpreter for the current project context
# =============================================================================

# Load path configuration
[ -f "/workspace/config/util_paths.sh" ] && source "/workspace/config/util_paths.sh"
[ -z "$WS_ROOT" ] && source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh"

# 1. Prioritize active virtual environment (User explicit activation)
[ -n "$VIRTUAL_ENV" ] && [ -x "$VIRTUAL_ENV/bin/python" ] && echo "$VIRTUAL_ENV/bin/python" && exit 0

# 2. Case: ROS Environment (Priority: System, Exception: Shared Venv)
if [ -n "$ROS_DISTRO" ]; then
    grep -q "include-system-site-packages = true" "${WS_VENV}/pyvenv.cfg" 2>/dev/null && \
        echo "${WS_VENV}/bin/python" || echo "${SYS_PYTHON_EXE:-/usr/bin/python3}"
    exit 0
fi

# 3. Case: Non-ROS Environment (Priority: Local Venv)
if [ -d "${WS_VENV}" ] && [ -x "${WS_VENV}/bin/python" ]; then
    echo "${WS_VENV}/bin/python"
    exit 0
fi

# 4. Final Fallback
echo "${SYS_PYTHON_EXE:-/usr/bin/python3}"
