#!/bin/bash
# =============================================================================
# scripts/check_deps.sh
# Verifies build artifacts for missing runtime shared library dependencies
#
# This script is a development/build-time tool for validating install artifacts.
#
# Scans the target directory for ELF files and shared objects, using ldd to
# identify missing dependencies.
# =============================================================================

set -eo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || source "/tmp/util_paths.sh"
devkit_require "util_logging.sh"
LOG_PREFIX="[Sanity Check]"

usage() {
    cat <<'EOF'
Usage: check_deps.sh [target_dir]

Scan build/install artifacts for missing shared-library dependencies and verify
the active Python/ROS binding setup.

Options:
  -h, --help Show this help.
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --*) log_error "Unknown option: $1"; usage >&2; exit 2 ;;
esac

TARGET_DIR=${1:-${WS_INSTALL}}
MISSING_COUNT=0

log_info "Scanning for missing dependencies in $TARGET_DIR..."

if [ ! -d "$TARGET_DIR" ]; then
    log_error "Target directory '$TARGET_DIR' does not exist."
    log_info "Make sure you have built your project (e.g., 'cbuild' or 'make install') before checking dependencies."
    exit 1
fi

for required_tool in file ldd; do
    if ! command -v "$required_tool" >/dev/null 2>&1; then
        log_error "Required tool '$required_tool' is not available. Cannot validate runtime dependencies."
        exit 127
    fi
done


# Find executable files and shared libraries (.so) safely, including paths with ':' or spaces.
# Uses `file -N` to identify ELF binaries before invoking ldd, avoiding false positives
# on non-ELF executables (e.g. shell scripts) and correctly handling paths with colons.
while IFS= read -r ELF_FILE; do
    MISSING=$(ldd "$ELF_FILE" 2>/dev/null | grep "not found" || true)
    if [ -n "$MISSING" ]; then
        log_error "Missing dependencies for: $ELF_FILE\n$(echo "$MISSING" | sed 's/^/  /')"
        MISSING_COUNT=$((MISSING_COUNT + 1))
    fi
done < <(find "$TARGET_DIR" -type f \( -executable -o -name "*.so*" \) ! -name "*.py" ! -path "*/.venv/*" -exec file -N {} + 2>/dev/null | grep -E 'ELF.*(executable|shared object)' | cut -d: -f1)

# --- Python Integrity Check (SSOT Integration) -------------------------------
function verify_package() {
    local interpreter=$1
    local pkg=$2
    local msg=$3
    if ! "$interpreter" -c "import $pkg" &>/dev/null; then
        log_error "$msg"
        return 1
    fi
    return 0
}

function check_python_integrity() {
    local get_py_script="${WS_SCRIPTS}/util_get_python.sh"
    [ ! -f "$get_py_script" ] && get_py_script="$(dirname "${BASH_SOURCE[0]}")/util_get_python.sh"

    if [ ! -f "$get_py_script" ]; then
        log_warn "Python detector script not found. Skipping Python integrity check."
        return 0
    fi

    local active_py
    active_py="$(bash "$get_py_script")"
    if [ -z "$active_py" ]; then
        log_warn "Python detector returned an empty interpreter path. Skipping Python integrity check."
        return 0
    fi
    log_info "Verifying Python integrity for: $active_py"

    # 1. Basic Interpreter execution test
    if ! "$active_py" --version &>/dev/null; then
        log_error "Python interpreter is not executable: $active_py"
        return 1
    fi

    # 2. ROS Distro-specific binding test
    if [ -z "${ROS_DISTRO:-}" ] || [ ! -f "/opt/ros/${ROS_DISTRO}/setup.bash" ]; then
        log_info "ROS runtime not installed in this image. Skipping ROS binding check."
        return 0
    fi
    # ROS Python bindings live on PYTHONPATH from setup.bash, not plain system site-packages.
    source "/opt/ros/${ROS_DISTRO}/setup.bash"

    case "${ROS_DISTRO}" in
        noetic)
            verify_package "$active_py" "rospy" "ROS 1 (Noetic) bindings not found in $active_py." || {
                log_info "💡 Recommendation: If using venv, ensure 'include-system-site-packages = true' in pyvenv.cfg."
                log_info "   Otherwise, install missing system packages: sudo apt-get install python3-rospy"
                return 1
            }
            ;;
        humble)
            verify_package "$active_py" "rclpy" "ROS 2 (${ROS_DISTRO}) rclpy bindings not found in $active_py." || {
                log_info "💡 Recommendation: If using venv, ensure 'include-system-site-packages = true' in pyvenv.cfg."
                log_info "   Otherwise, ensure ROS 2 is correctly installed: sudo apt-get install python3-rclpy"
                return 1
            }
            verify_package "$active_py" "tf2_ros" "ROS 2 (${ROS_DISTRO}) tf2_ros bindings not usable in $active_py." || {
                log_info "💡 Recommendation: ROS 2 production venvs should use system site packages so apt-provided Python modules such as numpy remain visible."
                log_info "   Otherwise, add the missing Python package to src/pyproject.toml or dependencies/requirements.txt."
                return 1
            }
            ;;
        *)
            log_warn "Unknown ROS_DISTRO '${ROS_DISTRO}'. Skipping specific binding check."
            ;;
    esac

    log_ok "Python ROS bindings verified successfully."
}

check_python_integrity || MISSING_COUNT=$((MISSING_COUNT + 1))

if [ $MISSING_COUNT -gt 0 ]; then
    log_error "$MISSING_COUNT files have missing dependencies."
    log_info "Please add missing packages to dependencies/apt.txt or dependencies/apt_ros.txt (with # runtime if needed for deployment)."
    exit 1
else
    log_ok "All runtime dependencies are satisfied."
    exit 0
fi
