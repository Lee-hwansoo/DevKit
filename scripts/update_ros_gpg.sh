#!/bin/bash
# =============================================================================
# scripts/update_ros_gpg.sh
# Utility to verify and update ROS GPG repository fingerprints.
# =============================================================================

set -eo pipefail

# Load logging utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_LOG="${SCRIPT_DIR}/utils_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"
LOG_PREFIX="[GPG Update]"

TARGET_FILE="${SCRIPT_DIR}/internal_apt_helper.sh"
ROS_KEY_URL="https://raw.githubusercontent.com/ros/rosdistro/master/ros.key"
ROS_ASC_URL="https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc"

# Command line arguments
CHECK_ONLY=false
AUTO_UPDATE=false
for arg in "$@"; do
    case $arg in
        --check) CHECK_ONLY=true ;;
        --update) AUTO_UPDATE=true ;;
    esac
done

fetch_fingerprint() {
    local url=$1
    local tmp_key
    tmp_key=$(mktemp /tmp/ros_key_update.XXXXXX)

    # Use trap for cleanup
    trap 'rm -f "$tmp_key"' RETURN

    if ! curl -sSL "$url" -o "$tmp_key"; then
        log_error "Failed to download key from $url"
        return 1
    fi

    local fp
    fp=$(gpg --with-colons --import-options show-only --import "$tmp_key" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
    echo "$fp"
}

log_info "Fetching current ROS GPG key fingerprints..."
FP_KEY=$(fetch_fingerprint "$ROS_KEY_URL")
FP_ASC=$(fetch_fingerprint "$ROS_ASC_URL")

if [ -z "$FP_KEY" ] || [ -z "$FP_ASC" ]; then
    log_error "Could not retrieve fingerprints from official sources. Check your internet connection."
    exit 1
fi

if [ "$FP_KEY" != "$FP_ASC" ]; then
    log_warn "Fingerprints for ros.key and ros.asc do not match!"
    log_warn "  ros.key (ROS 2): $FP_KEY"
    log_warn "  ros.asc (ROS 1): $FP_ASC"
    log_warn "This is unexpected. Please verify manually at https://www.ros.org/reps/rep-2000.html"
fi

# We use the key fingerprint as primary (typically same as .asc)
LATEST_FP="$FP_KEY"

CURRENT_FP=$(grep "local ROS_GPG_FINGERPRINT=" "$TARGET_FILE" | cut -d'"' -f2 || true)

if [ -z "$CURRENT_FP" ]; then
    log_error "Could not find current fingerprint in $TARGET_FILE"
    exit 1
fi

if [ "$CURRENT_FP" == "$LATEST_FP" ]; then
    log_ok "Fingerprint is already up to date: $CURRENT_FP"
    exit 0
fi

log_warn "Fingerprint mismatch detected!"
log_warn "  Current (in code): $CURRENT_FP"
log_warn "  Latest (from web): $LATEST_FP"

if [ "$CHECK_ONLY" == "true" ]; then
    log_error "Check failed (GPG drift detected). Please run 'make update-gpg' locally."
    exit 1
fi

if [ "$AUTO_UPDATE" != "true" ]; then
    echo ""
    echo -e "  ${YELLOW}WARNING: This will modify your source code to trust the new GPG key.${NC}"
    echo -n "  Do you want to update the fingerprint in internal_apt_helper.sh? [y/N]: "
    read -r ans
    if [[ ! "$ans" =~ ^[yY]$ ]]; then
        log_info "Update cancelled by user."
        exit 0
    fi
fi

log_info "Updating $TARGET_FILE..."
# Replace the fingerprint in the file
sed -i "s/local ROS_GPG_FINGERPRINT=\"$CURRENT_FP\"/local ROS_GPG_FINGERPRINT=\"$LATEST_FP\"/" "$TARGET_FILE"

log_ok "Fingerprint successfully updated to $LATEST_FP"
