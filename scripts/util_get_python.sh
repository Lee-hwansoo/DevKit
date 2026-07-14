#!/bin/bash
# =============================================================================
# scripts/util_get_python.sh
# Detects the appropriate Python interpreter for the current project context
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || source "/tmp/util_paths.sh"

case "${1:-}" in
    "" ) ;;
    -h|--help)
        cat <<'EOF'
Usage: util_get_python.sh

Print the Python interpreter selected for the current DevKit context.
EOF
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        exit 2
        ;;
esac

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
