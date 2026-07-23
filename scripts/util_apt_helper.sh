#!/bin/bash
# =============================================================================
# scripts/util_apt_helper.sh
# Build-time APT management utility for automated package installation
#
# Handles APT initialization, snapshot configuration, ROS repository setup,
# and filtered package installation during the Docker build
# process.
# =============================================================================

set -eo pipefail
COMMAND="${1:-}"

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || source "/tmp/util_paths.sh"
devkit_require "util_logging.sh"
LOG_PREFIX="[APT Helper]"
devkit_enable_error_trap

usage() {
    cat <<'EOF'
Usage: util_apt_helper.sh <command> [args...]

Build-time APT helper commands:
  init-apt
  configure-snapshot <latest|YYYYMMDDTHHMMSSZ>
  setup-ros-repo <ros_distro>
  setup-cuda-repo <cuda_version>
  update-rosdep <ros_distro>
  install-packages <all|builder|runtime> [ros_distro] [dependency_dir]
    Set DEVKIT_DRY_RUN=1 to print selected packages without installing.
  -h, --help
EOF
}

require_command() {
    local missing=0
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command not found: $cmd"
            missing=1
        fi
    done
    return "$missing"
}

require_arg() {
    local name="$1"
    local value="${2:-}"
    if [ -z "$value" ]; then
        log_error "$name is required."
        return 2
    fi
}

# =============================================================================
# Supported ROS distributions — Single Source of Truth (SSOT)
# -----------------------------------------------------------------------------
# To add or remove a supported distro, edit ONLY `devkit_distro_row` below; the
# validate / tag / GPG-key / repo logic all derive from it. (When a second
# build-time consumer appears, promote this block to scripts/util_distros.sh and
# bind-mount it alongside this file in the Dockerfile.)
#
# Row fields (pipe-delimited): ros_ver | ubuntu_version | ubuntu_codename | gpg_key_file | repo_path
#   ros_ver      : 1 (ROS 1) | 2 (ROS 2)
#   gpg_key_file : ros.asc (ROS 1) | ros.key (ROS 2)   — file under ros/rosdistro
#   repo_path    : ros (ROS 1) | ros2 (ROS 2)          — path under packages.ros.org
# =============================================================================
DEVKIT_SUPPORTED_DISTROS="noetic humble"

devkit_distro_row() {
    case "${1:-}" in
        noetic) printf '1|20.04|focal|ros.asc|ros\n' ;;
        humble) printf '2|22.04|jammy|ros.key|ros2\n' ;;
        *) return 1 ;;
    esac
}

# devkit_distro_field <distro> <ros_ver|ubuntu_version|ubuntu_codename|gpg_key_file|repo_path|ros_major_tag>
devkit_distro_field() {
    local row ros_ver ubuntu_version ubuntu_codename gpg_key_file repo_path
    row="$(devkit_distro_row "${1:-}")" || return 1
    IFS='|' read -r ros_ver ubuntu_version ubuntu_codename gpg_key_file repo_path <<< "$row"
    case "${2:-}" in
        ros_ver)         printf '%s\n' "$ros_ver" ;;
        ubuntu_version)  printf '%s\n' "$ubuntu_version" ;;
        ubuntu_codename) printf '%s\n' "$ubuntu_codename" ;;
        gpg_key_file)    printf '%s\n' "$gpg_key_file" ;;
        repo_path)       printf '%s\n' "$repo_path" ;;
        ros_major_tag)   [ "$ros_ver" = "1" ] && printf 'ros1\n' || printf 'ros2\n' ;;
        *) return 1 ;;
    esac
}

validate_ros_distro() {
    local distro="${1:-}"
    if [ -z "$distro" ]; then
        log_error "ROS_DISTRO is required for this command."
        return 2
    fi
    if ! devkit_distro_row "$distro" >/dev/null 2>&1; then
        log_error "Unsupported ROS_DISTRO: $distro. Supported values: ${DEVKIT_SUPPORTED_DISTROS}."
        return 2
    fi
    return 0
}

ros_major_tag() {
    devkit_distro_field "${1:-}" ros_major_tag
}

download_file() {
    local url=$1
    local output=$2
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 "$url" -o "$output"
}

read_gpg_fingerprint() {
    local key_file=$1
    gpg --with-colons --import-options show-only --import "$key_file" 2>/dev/null \
        | awk -F: '/^fpr/{print $10; exit}'
}

install_repo_prereqs() {
    apt-get update
    apt-get install -y --no-install-recommends curl gnupg2 ca-certificates
}

# 0. Initialize APT for Docker Container (Enable caching for BuildKit mount compatibility)
init_apt() {
    rm -f /etc/apt/apt.conf.d/docker-clean
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
    log_info "Docker APT cache preservation enabled."

    # Pre-install ca-certificates to enable HTTPS snapshot support
    if ! dpkg -s ca-certificates >/dev/null 2>&1; then
        log_info "Installing ca-certificates from default archive..."
        apt-get update
        apt-get install -y --no-install-recommends ca-certificates
    fi
}

apt_truthy() {
    case "${1:-}" in
        1|true|yes|on|TRUE|True|Yes|On) return 0 ;;
        *) return 1 ;;
    esac
}

# Probe snapshot mirror reachability. Returns 0 (assume reachable) when curl is
# unavailable so early build stages without curl keep their previous behavior.
snapshot_server_reachable() {
    local host="${1:-snapshot.ubuntu.com}"
    command -v curl >/dev/null 2>&1 || return 0
    curl -fsS --connect-timeout 5 --max-time 10 -I "https://${host}/" >/dev/null 2>&1
}

# 1. Configure APT Snapshot Repository and Disable Valid-Until Checks
setup_snapshot() {
    local date="${1:-}"
    require_arg "APT_SNAPSHOT_DATE" "$date" || return $?
    if [ "$date" != "latest" ] && [ -n "$date" ]; then
        if [[ ! "$date" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
            log_error "APT_SNAPSHOT_DATE must be 'latest' or UTC format YYYYMMDDTHHMMSSZ (current: $date)"
            return 2
        fi

        # Verify the snapshot mirror is reachable before committing the build to it.
        # snapshot.ubuntu.com is a single upstream; if it is down we must NOT silently
        # fall back to rolling mirrors, because that would void the reproducibility
        # (SOURCE_DATE_EPOCH) the snapshot exists to guarantee. Fail loudly by default;
        # fall back only when APT_SNAPSHOT_FALLBACK is explicitly opted into.
        if ! snapshot_server_reachable; then
            if apt_truthy "${APT_SNAPSHOT_FALLBACK:-}"; then
                log_warn "Snapshot server snapshot.ubuntu.com is unreachable."
                log_warn "APT_SNAPSHOT_FALLBACK=1 set: falling back to standard Ubuntu mirrors."
                log_warn "WARNING: build reproducibility (SOURCE_DATE_EPOCH) is VOIDED for this build."
                return 0
            fi
            log_error "Snapshot server snapshot.ubuntu.com is unreachable (APT_SNAPSHOT_DATE=$date)."
            log_error "Fix network/mirror availability, choose a different snapshot date, or set"
            log_error "APT_SNAPSHOT_FALLBACK=1 to intentionally build against standard (non-reproducible) mirrors."
            return 1
        fi

        # Disable Valid-Until verification for historical snapshots
        echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99-disable-valid-until

        if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
            # [Ubuntu 24.04+ (DEB822 Format)]
            echo "APT::Snapshot \"$date\";" > /etc/apt/apt.conf.d/99-snapshot
        elif [ -f /etc/apt/sources.list ]; then
            # [Ubuntu 20.04 / 22.04 (Legacy Format)]
            local tmp_sources
            tmp_sources=$(mktemp /tmp/apt_sources.XXXXXX)
            sed \
                -e "s|http://archive.ubuntu.com/ubuntu/|http://snapshot.ubuntu.com/ubuntu/$date/|g" \
                -e "s|http://security.ubuntu.com/ubuntu/|http://snapshot.ubuntu.com/ubuntu/$date/|g" \
                -e "s|http://ports.ubuntu.com/ubuntu-ports/|http://snapshot.ubuntu.com/ubuntu-ports/$date/|g" \
                /etc/apt/sources.list > "$tmp_sources"
            cat "$tmp_sources" > /etc/apt/sources.list
            rm -f "$tmp_sources"
        fi
        log_info "Snapshot configured for: $date"
    fi
}

# 1-1. Configure ROS Repository (Import GPG keys and setup source lists)
setup_ros_repo() {
    local distro="${1:-}"
    validate_ros_distro "$distro" || return $?

    install_repo_prereqs
    require_command curl gpg dpkg awk grep || return 1

    # Get Ubuntu codename without lsb_release
    local codename
    codename=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2)
    if [ -z "$codename" ]; then codename=$(grep '^UBUNTU_CODENAME=' /etc/os-release | cut -d= -f2); fi

    # Known GPG fingerprint for ROS repository key
    local ROS_GPG_FINGERPRINT="C1CF6E31E6BADE8868B172B4F42ED6FBAB17C654"

    local TMP_KEY
    TMP_KEY=$(mktemp /tmp/ros_repo_key.XXXXXX)
    local key_url="https://raw.githubusercontent.com/ros/rosdistro/master/$(devkit_distro_field "$distro" gpg_key_file)"

    if ! download_file "$key_url" "$TMP_KEY"; then
        rm -f "$TMP_KEY"
        log_error "Failed to download ROS repository key: $key_url"
        return 1
    fi

    local ACTUAL_FP
    ACTUAL_FP=$(read_gpg_fingerprint "$TMP_KEY")
    if [ -z "$ACTUAL_FP" ]; then
        rm -f "$TMP_KEY"
        log_error "Downloaded ROS key has no readable GPG fingerprint: $key_url"
        return 1
    fi

    if [ "$ACTUAL_FP" != "$ROS_GPG_FINGERPRINT" ]; then
        if [ "${STRICT_GPG_CHECK:-false}" = "true" ]; then
            log_error "FATAL: GPG fingerprint mismatch! Expected: $ROS_GPG_FINGERPRINT, Got: $ACTUAL_FP"
            log_error "Aborting (STRICT_GPG_CHECK=true). To update, run 'make update-gpg' on the host."
            rm -f "$TMP_KEY"
            return 1
        else
            log_warn "GPG fingerprint mismatch! Expected: $ROS_GPG_FINGERPRINT, Got: $ACTUAL_FP"
            log_warn "Continuing (Fail-Open). To update and silence this warning, run 'make update-gpg' on the host."
        fi
    else
        log_info "GPG key fingerprint verified: $ACTUAL_FP"
    fi
    gpg --dearmor --yes -o /usr/share/keyrings/ros-archive-keyring.gpg < "$TMP_KEY"
    rm -f "$TMP_KEY"

    local repo_path list_file
    repo_path="$(devkit_distro_field "$distro" repo_path)"
    if [ "$(devkit_distro_field "$distro" ros_ver)" = "1" ]; then
        list_file="/etc/apt/sources.list.d/ros1-latest.list"
    else
        list_file="/etc/apt/sources.list.d/ros2.list"
    fi
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/${repo_path}/ubuntu $codename main" > "$list_file"
    log_info "ROS repository configured for: $distro ($codename)"
}

# 1-2. Configure NVIDIA CUDA Repository
setup_cuda_repo() {
    local cuda_version=$1
    if [ -z "$cuda_version" ]; then return; fi

    install_repo_prereqs
    require_command curl gpg dpkg grep tr || return 1

    # Get OS version ID (e.g., 22.04 -> 2204)
    local os_version
    os_version=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr -d '.')

    local arch
    arch=$(dpkg --print-architecture)
    local cuda_repo_arch="x86_64"
    [ "$arch" = "arm64" ] && cuda_repo_arch="sbsa"

    log_info "Configuring NVIDIA CUDA repository for Ubuntu ${os_version} (${arch})..."

    # 1. Download pinning (recommended by NVIDIA to prioritize their repo)
    local pin_url="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${os_version}/${cuda_repo_arch}/cuda-ubuntu${os_version}.pin"
    download_file "$pin_url" /etc/apt/preferences.d/cuda-repository-pin-600

    # 2. Setup repository URL
    local repo_url="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${os_version}/${cuda_repo_arch}"

    # 3. Add repository key
    # Try current and legacy keys as NVIDIA rotated them recently
    local cuda_key
    cuda_key=$(mktemp /tmp/cuda_repo_key.XXXXXX)
    if ! download_file "${repo_url}/3bf863cc.pub" "$cuda_key"; then
        download_file "${repo_url}/7fa2af80.pub" "$cuda_key"
    fi

    local cuda_fp
    cuda_fp=$(read_gpg_fingerprint "$cuda_key")
    if [ -z "$cuda_fp" ]; then
        rm -f "$cuda_key"
        log_error "Downloaded NVIDIA CUDA key has no readable GPG fingerprint."
        return 1
    fi
    log_info "NVIDIA CUDA repository key fingerprint: $cuda_fp"

    gpg --dearmor --yes -o /usr/share/keyrings/cuda-archive-keyring.gpg < "$cuda_key"
    rm -f "$cuda_key"

    # 4. Add to sources list
    echo "deb [arch=${arch} signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] ${repo_url}/ /" > /etc/apt/sources.list.d/cuda.list

    log_info "NVIDIA CUDA repository configured successfully."
}

update_rosdep() {
    local distro="${1:-}"
    validate_ros_distro "$distro" || return $?
    require_command rosdep find sleep || return 1

    if [ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]; then
        rosdep init
    fi

    local attempt
    for attempt in 1 2 3; do
        if rosdep update --rosdistro "$distro"; then
            return 0
        fi
        log_warn "rosdep update failed (attempt ${attempt}/3)."
        [ "$attempt" = "3" ] || sleep $((attempt * 3))
    done

    if [ -d /root/.ros/rosdep/sources.cache ] && find /root/.ros/rosdep/sources.cache -type f -print -quit 2>/dev/null | grep -q .; then
        log_warn "Continuing with the existing rosdep cache after update failures."
        return 0
    fi

    log_error "rosdep update failed and no usable cache exists."
    return 1
}

# 2. Install user-defined packages with conditional tag-based filtering
install_packages() {
    local filter="${1:-}"  # "all" (dev), "builder" (prod build), or "runtime" (deployment)
    local distro="${2:-}"
    local dep_dir="${3:-${WS_DEPS:-/workspace/dependencies}}" # Default dependency directory

    case "$filter" in
        all|builder|runtime) ;;
        *)
            log_error "install-packages mode must be 'all', 'builder', or 'runtime' (current: ${filter:-<empty>})"
            return 2
            ;;
    esac

    local apt_file="/tmp/apt.txt"
    local ros_file="/tmp/apt_ros.txt"

    # Fallback to centralized dependency directory if /tmp files don't exist
    [ ! -f "$apt_file" ] && [ -f "${dep_dir}/apt.txt" ] && apt_file="${dep_dir}/apt.txt"
    [ ! -f "$ros_file" ] && [ -f "${dep_dir}/apt_ros.txt" ] && ros_file="${dep_dir}/apt_ros.txt"
    if [ ! -f "$apt_file" ] && { [ -z "$distro" ] || [ ! -f "$ros_file" ]; }; then
        log_error "No APT dependency files found. Checked /tmp and ${dep_dir}."
        return 1
    fi

    # Detect target ROS version tag
    local target_tag="none"
    local other_tag="ros1|ros2"
    if [ -n "$distro" ]; then
        validate_ros_distro "$distro" || return $?
        target_tag="$(ros_major_tag "$distro")"
        if [ "$target_tag" = "ros1" ]; then
            other_tag="ros2"
        else
            other_tag="ros1"
        fi
    fi

    local pkgs=""

    filter_pkg_list() {
        local file=$1
        local mode=$2
        if [ -f "$file" ]; then
            awk -v mode="$mode" -v distro="$distro" -v other_tag="$other_tag" '
                /^[[:space:]]*($|#)/ { next }
                {
                    comment = ""
                    line = $0
                    if (match(line, /#/)) {
                        comment = substr(line, RSTART + 1)
                        line = substr(line, 1, RSTART - 1)
                    }
                    if (mode == "runtime" && comment !~ /(^|[[:space:],])runtime([[:space:],]|$)/) {
                        next
                    }
                    if (mode == "builder" && comment ~ /(^|[[:space:],])(dev|gui)([[:space:],]|$)/) {
                        next
                    }
                    if (other_tag != "none" && comment ~ "(^|[[:space:],])" other_tag "([[:space:],]|$)") {
                        next
                    }
                    gsub(/\$\{ROS_DISTRO\}/, distro, line)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                    if (line != "") {
                        print line
                    }
                }
            ' "$file"
        fi
    }

    # Extract packages from apt.txt
    if [ -f "$apt_file" ]; then
        pkgs=$(filter_pkg_list "$apt_file" "$filter")
    fi

    # Extract packages from apt_ros.txt
    if [ -n "$distro" ] && [ -f "$ros_file" ]; then
        local ros_pkgs
        ros_pkgs=$(filter_pkg_list "$ros_file" "$filter")
        pkgs="$pkgs $ros_pkgs"
    fi

    pkgs=$(printf '%s\n' "$pkgs" | awk 'NF { for (i = 1; i <= NF; i++) { printf "%s%s", sep, $i; sep = " " } } END { print "" }')

    if [ "${DEVKIT_DRY_RUN:-}" = "1" ]; then
        [ -n "$pkgs" ] && printf '%s\n' $pkgs
        return 0
    fi

    if [ -n "$pkgs" ]; then
        if [ -n "$distro" ]; then
            log_info "Installing ($filter) packages for $distro ($target_tag): $pkgs"
        else
            log_info "Installing ($filter) packages: $pkgs"
        fi
        if ! apt-get update; then
            log_error "'apt-get update' failed."
            if [ -f /etc/apt/apt.conf.d/99-snapshot ]; then
                log_info "Recommendation: A snapshot is active. Verify the snapshot date or repository availability."
            fi
            exit 1
        fi
        read -r -a pkg_array <<< "$pkgs"
        apt-get install -y --no-install-recommends "${pkg_array[@]}"
    else
        log_info "No packages matched filter ($filter, $target_tag)"
    fi
}

case "$COMMAND" in
    "-h"|"--help")
        usage
        ;;
    "init-apt")
        init_apt
        ;;
    "configure-snapshot")
        setup_snapshot "${2:-}"
        ;;
    "setup-ros-repo")
        setup_ros_repo "${2:-}"
        ;;
    "setup-cuda-repo")
        require_arg "CUDA_VERSION" "${2:-}" && setup_cuda_repo "$2"
        ;;
    "update-rosdep")
        update_rosdep "${2:-}"
        ;;
    "install-packages")
        install_packages "${2:-}" "${3:-}" "${4:-}"
        ;;
    *)
        log_error "Unknown command: ${COMMAND:-<empty>}"
        usage >&2
        exit 2
        ;;
esac
