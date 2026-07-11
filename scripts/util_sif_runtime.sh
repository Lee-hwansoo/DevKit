#!/bin/bash
# Resolve the SIF runtime binary used by Apptainer/Singularity workflows.
# NOTE: This file is a library meant to be sourced, not executed directly.
# The lack of an execute bit (mode 644) is intentional.

init_sif_context() {
    local script_dir="${1:?script_dir is required}"

    if [ -f "/.dockerenv" ] && [ -f "/workspace/config/util_paths.sh" ]; then
        source "/workspace/config/util_paths.sh"
        HOST_ROOT="${WS_ROOT}"
    else
        local container_workspace_path="${WORKSPACE_PATH:-}"
        unset WORKSPACE_PATH
        source "${script_dir}/../config/util_paths.sh"
        HOST_ROOT="${WS_ROOT}"
        [ -n "$container_workspace_path" ] && export WORKSPACE_PATH="$container_workspace_path"
        unset container_workspace_path
    fi

    CONTAINER_WORKSPACE_PATH="${WORKSPACE_PATH:-/workspace}"
    export HOST_ROOT CONTAINER_WORKSPACE_PATH
}

sif_truthy() {
    local value="${1:-}"
    value="${value,,}"
    case "$value" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

sif_dry_run() {
    sif_truthy "${DEVKIT_DRY_RUN:-false}"
}

sif_set_container_env() {
    local key="${1:-}"
    local value="${2-}"

    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Invalid SIF container environment key: ${key:-<empty>}" >&2
        return 1
    fi

    export "APPTAINERENV_${key}=${value}"
    export "SINGULARITYENV_${key}=${value}"
}

sif_forward_env_vars() {
    local key
    for key in "$@"; do
        if [ -n "${!key+x}" ]; then
            sif_set_container_env "$key" "${!key}"
        fi
    done
}

require_sif_option_value() {
    local option="$1"
    local value="${2:-}"

    if [ -z "$value" ] || [[ "$value" == --* ]]; then
        echo "${option} requires a value." >&2
        return 2
    fi
}

validate_sif_env() {
    case "${1:-}" in
        ros|dev) return 0 ;;
        *) echo "ENV must be ros or dev (current: ${1:-<empty>})" >&2; return 1 ;;
    esac
}

validate_sif_mode() {
    local mode="${1:-}"
    local allowed="${2:-dev prod slurm}"
    local candidate

    for candidate in $allowed; do
        [ "$mode" = "$candidate" ] && return 0
    done

    echo "SIF mode must be ${allowed// /, } (current: ${mode:-<empty>})" >&2
    return 1
}

validate_sif_project() {
    local project="${1:-}"
    if [[ ! "$project" =~ ^[a-z0-9]([a-z0-9_-]*[a-z0-9])?$ ]]; then
        echo "Project name must start and end with a lowercase letter or digit, using only lowercase letters, digits, dashes, or underscores: ${project:-<empty>}" >&2
        return 1
    fi
}

validate_image_tag() {
    local image_tag="${1:-}"
    if [[ ! "$image_tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
        echo "IMAGE_TAG must be a valid Docker tag (start with alnum/_; use alnum, _, ., -; max 128 chars): ${image_tag:-<empty>}" >&2
        return 1
    fi
}

default_sif_file() {
    local mode="${1:?mode is required}"
    local env_name="${2:?env is required}"
    local project="${3:?project is required}"
    local image_tag="${4:?image_tag is required}"
    local share="${5:-}"

    validate_sif_project "$project" || return 1
    validate_image_tag "$image_tag" || return 1

    case "$mode" in
        dev)
            validate_sif_env "$env_name" || return 1
            if sif_truthy "$share"; then
                printf '%s\n' "${project}_${env_name}_dev-share_${image_tag}.sif"
            else
                printf '%s\n' "${project}_${env_name}_dev_${image_tag}.sif"
            fi
            ;;
        prod|slurm)
            validate_sif_env "$env_name" || return 1
            printf '%s\n' "${project}_${env_name}_prod_${image_tag}.sif"
            ;;
        *)
            validate_sif_mode "$mode"
            return 1
            ;;
    esac
}

has_sif_entry_command() {
    local argc="${1:-0}"
    [ "$argc" -gt 0 ] || [ -n "${ROS_LAUNCH_COMMAND:-}" ] || [ -n "${APP_COMMAND:-}" ]
}

get_sif_gpu_opts_into() {
    local -n gpu_opts_out="$1"
    local detection_mode="${2:-detected}"
    local requested_mode="${3:-${GPU_MODE:-auto}}"
    gpu_opts_out=()
    requested_mode="${requested_mode,,}"

    case "$detection_mode" in
        detected|probe) ;;
        *) echo "SIF GPU detection mode must be detected or probe (current: ${detection_mode})" >&2; return 1 ;;
    esac

    case "$requested_mode" in
        ""|auto) ;;
        cpu|igpu|intel) return 0 ;;
        nvidia)
            if [ "${HAS_NVIDIA:-false}" = "true" ] || { [ "$detection_mode" = "probe" ] && command -v nvidia-smi >/dev/null 2>&1; }; then
                gpu_opts_out=( "--nv" )
            fi
            return 0
            ;;
        amd)
            if command -v rocm-smi >/dev/null 2>&1; then
                gpu_opts_out=( "--rocm" )
            fi
            return 0
            ;;
        *) echo "GPU_MODE must be auto, cpu, igpu, intel, amd, or nvidia (current: ${requested_mode})." >&2; return 1 ;;
    esac

    if [ "${HAS_NVIDIA:-false}" = "true" ] || { [ "$detection_mode" = "probe" ] && command -v nvidia-smi >/dev/null 2>&1; }; then
        gpu_opts_out=( "--nv" )
    elif command -v rocm-smi >/dev/null 2>&1; then
        gpu_opts_out=( "--rocm" )
    fi
}

normalize_sif_project_name() {
    local raw="$1"
    printf '%s' "$raw" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cd 'a-z0-9_-' \
        | sed -E 's/^[^a-z0-9]+//; s/[^a-z0-9]+$//'
}

resolve_sif_project_name() {
    local host_root="${1:-$(pwd)}"
    local explicit="${COMPOSE_PROJECT_NAME:-}"

    if [ -n "$explicit" ]; then
        validate_sif_project "$explicit" || {
            echo "COMPOSE_PROJECT_NAME is invalid: ${explicit}" >&2
            return 2
        }
        printf '%s\n' "$explicit"
        return 0
    fi

    local fallback
    fallback="$(normalize_sif_project_name "$(basename "$host_root")")"
    printf '%s\n' "${fallback:-devkit}"
}

resolve_sif_runtime() {
    if [ -n "${APPTAINER_BIN:-}" ]; then
        command -v "$APPTAINER_BIN" >/dev/null 2>&1 && {
            command -v "$APPTAINER_BIN"
            return 0
        }
        echo "Configured APPTAINER_BIN is not executable: ${APPTAINER_BIN}" >&2
        return 127
    fi

    command -v apptainer 2>/dev/null && return 0
    command -v singularity 2>/dev/null && return 0

    echo "Apptainer/Singularity runtime not found. Install apptainer or singularity-container, or set APPTAINER_BIN." >&2
    return 127
}

warn_sif_runtime_mount_constraints() {
    local runtime="${1:-SIF runtime}"

    [ -e /dev/fuse ] && return 0

    cat >&2 <<EOF
DevKit warning: /dev/fuse is not available on this host.
${runtime} may still run with a working setuid/extraction setup, but unprivileged
containerized hosts commonly fail to mount or extract SIF images. Prefer running
SIF artifacts on the host machine or an HPC/login node with Apptainer support.
EOF
}

source_detected_env() {
    local check_env_script=$1
    local env_file
    env_file=$(mktemp /tmp/devkit_env.XXXXXX)
    if ! bash "$check_env_script" > "$env_file"; then
        rm -f "$env_file"
        return 1
    fi
    if ! source "$env_file"; then
        rm -f "$env_file"
        return 1
    fi
    rm -f "$env_file"
}

apply_sif_detected_env_defaults() {
    : "${HOST_WORKSPACE_PATH:=${HOST_ROOT:-$(pwd)}}"
    : "${CONTAINER_WORKSPACE_PATH:=${WORKSPACE_PATH:-/workspace}}"
    : "${HOST_SSH_AUTH_SOCK:=}"
    : "${HAS_NVIDIA:=false}"
    : "${HAS_DRI:=false}"
    : "${IS_WSL:=false}"
    export HOST_WORKSPACE_PATH CONTAINER_WORKSPACE_PATH HOST_SSH_AUTH_SOCK HAS_NVIDIA HAS_DRI IS_WSL
}

configure_sif_cache_dirs() {
    local cache_root="${HOST_CACHE_DIR:-${HOST_ROOT:-$(pwd)}/.docker_cache}"
    local apptainer_cache="${APPTAINER_CACHEDIR:-${cache_root}/apptainer}"
    local singularity_cache="${SINGULARITY_CACHEDIR:-${cache_root}/singularity}"

    mkdir -p -- "$apptainer_cache" "$singularity_cache"
    export APPTAINER_CACHEDIR="$apptainer_cache"
    export SINGULARITY_CACHEDIR="$singularity_cache"
}

explain_sif_runtime_failure() {
    local err_file="${1:-}"
    [ -f "$err_file" ] || return 0

    if grep -Eqi 'fuse|setuid|squashfuse|root filesystem extraction failed' "$err_file"; then
        cat >&2 <<'EOF'
DevKit hint: the SIF runtime could not mount or extract the image on this host.
Check that /dev/fuse is available, squashfuse is installed, or Singularity/Apptainer
is installed with working setuid support. On restricted CI/containers this usually
requires running SIFs on the host/HPC login node instead.
EOF
    fi
}
