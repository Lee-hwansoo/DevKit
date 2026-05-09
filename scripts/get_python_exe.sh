#!/bin/bash
# =============================================================================
# scripts/get_python_exe.sh
# Centralized Python Interpreter Detector (Enterprise Grade)
# Features: Dynamic path resolution, execution bit safety, and SSOT integration.
# =============================================================================

WS_ROOT="${WORKSPACE_PATH:-/workspace}"
VENV_PATH="${VENV_PATH:-${WS_ROOT}/install/.venv}"
VENV_CFG="${VENV_PATH}/pyvenv.cfg"
DEFAULT_SYS_PYTHON="/usr/bin/python3"
SYS_EXE="${SYS_PYTHON_EXE:-$DEFAULT_SYS_PYTHON}"

# Logic:
# 1. If venv exists AND has 'include-system-site-packages = true' AND the binary is executable
#    -> Use venv python (Hybrid mode: system + venv)
# 2. Otherwise, use system python (Stable/Isolated mode)
if [[ -f "$VENV_CFG" ]]; then
    # Robustly extract include-system-site-packages value using awk
    INCLUDE_SYS=$(awk -F'=' '/include-system-site-packages/ {gsub(/ /, "", $2); print tolower($2)}' "$VENV_CFG")

    if [[ "$INCLUDE_SYS" == "true" ]]; then
        TARGET_PY="${VENV_PATH}/bin/python3"
        if [[ -x "$TARGET_PY" ]]; then
            echo "$TARGET_PY"
            exit 0
        else
            # Fallback log (stderr) if venv is corrupted but config says 'true'
            echo "[Warn] Venv interpreter not executable: $TARGET_PY" >&2
        fi
    fi
fi

# Fallback with System Integrity Check
if [[ -x "$SYS_EXE" ]]; then
    echo "$SYS_EXE"
else
    # Ultimate fail-safe using PATH search
    AUTO_DETECTED_PY=$(command -v python3 || command -v python)
    if [[ -n "$AUTO_DETECTED_PY" ]]; then
        echo "$AUTO_DETECTED_PY"
    else
        # Last resort: returning a string is better than empty for build systems
        echo "$DEFAULT_SYS_PYTHON"
    fi
fi
