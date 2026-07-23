#!/bin/bash
# =============================================================================
# scripts/apptainer_bake.sh
# Bake development snapshots or production runtime artifacts into SIF files.
# =============================================================================

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || source "/tmp/util_paths.sh"
devkit_require "util_sif_runtime.sh"
init_sif_context "$(dirname "${BASH_SOURCE[0]}")"
devkit_require "util_logging.sh"
LOG_PREFIX="[Bake]"
devkit_enable_error_trap

MODE="dev"
SIF_ENV="${ENV:-ros}"
SHARE_MODE="false"
CLEANUP_IMAGES=()
TEMP_ARCHIVES=()

cleanup_images() {
    if [ "${#TEMP_ARCHIVES[@]}" -gt 0 ]; then
        rm -f "${TEMP_ARCHIVES[@]}" 2>/dev/null || true
    fi
    if sif_dry_run; then
        return 0
    fi
    if sif_truthy "${DEVKIT_KEEP_IMAGES:-false}"; then
        return 0
    fi
    [ "${#CLEANUP_IMAGES[@]}" -gt 0 ] || return 0
    if ! docker rmi "${CLEANUP_IMAGES[@]}" >/dev/null 2>&1; then
        log_warn "Could not remove temporary Docker image(s): ${CLEANUP_IMAGES[*]}"
    fi
    return 0
}
trap cleanup_images EXIT

build_sif_from_docker_image() {
    local runtime="$1"
    local sif_file="$2"
    local docker_image="$3"
    local archive_dir="${SINGULARITY_CACHEDIR:-${APPTAINER_CACHEDIR:-/tmp}}"
    local archive

    mkdir -p "$archive_dir"
    archive="$(mktemp "${archive_dir%/}/devkit-image.XXXXXX.tar")"
    TEMP_ARCHIVES+=( "$archive" )

    docker save -o "$archive" "$docker_image"
    "$runtime" build --force "$sif_file" "docker-archive://${archive}"
}

usage() {
    cat <<'EOF'
Usage: apptainer_bake.sh [--mode dev|prod] [--env ros|dev] [--share]

Bake a development snapshot or production runtime into a SIF file.

Options:
  --mode   SIF type to bake. Default: dev.
  --env    Image family to bake. Default: ENV or ros.
  --share  Development mode only: share system site packages.
  DEVKIT_DRY_RUN=1 validates and prints the planned bake without building.
  -h, --help Show this help.
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --mode) require_sif_option_value "$1" "${2:-}" || { usage; exit 2; }; MODE="$2"; shift 2 ;;
        --env) require_sif_option_value "$1" "${2:-}" || { usage; exit 2; }; SIF_ENV="$2"; shift 2 ;;
        --share) SHARE_MODE="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 2 ;;
    esac
done

validate_sif_mode "$MODE" "dev prod" || exit 1
validate_sif_env "$SIF_ENV" || exit 1

if [ "$MODE" = "prod" ] && [ "$SHARE_MODE" = "true" ]; then
    log_error "--share is only valid with --mode dev."
    exit 2
fi

source_detected_env "${WS_SCRIPTS}/check_env.sh"
apply_sif_detected_env_defaults
configure_sif_cache_dirs

IMAGE_TAG="${IMAGE_TAG:-latest}"
validate_image_tag "$IMAGE_TAG"
COMPOSE_PROJECT_NAME="$(resolve_sif_project_name "${HOST_ROOT}")"
GIT_COMMIT="$(git -C "${HOST_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_FULL_CUDA="${FULL_CUDA:-false}"
if [ "$MODE" = "prod" ]; then
    BUILD_FULL_CUDA="${PROD_FULL_CUDA:-false}"
fi
# GPG policy (hybrid): production artifacts default to fail-closed (strict) ROS key
# verification; dev iteration defaults to fail-open (availability). An explicit
# STRICT_GPG_CHECK always wins. apt verifies package signatures either way.
if [ "$MODE" = "prod" ]; then
    STRICT_GPG_CHECK_DEFAULT="${STRICT_GPG_CHECK:-true}"
else
    STRICT_GPG_CHECK_DEFAULT="${STRICT_GPG_CHECK:-false}"
fi

BUILD_ARGS=(
    --build-arg "BASE_IMAGE=${BASE_IMAGE:-ubuntu:22.04}"
    --build-arg "WORKSPACE_PATH=${CONTAINER_WORKSPACE_PATH}"
    --build-arg "CONTAINER_USER=${CONTAINER_USER:-user}"
    --build-arg "USER_UID=${HOST_UID:-1000}"
    --build-arg "USER_GID=${HOST_GID:-1000}"
    --build-arg "DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive}"
    --build-arg "LANG=${LANG:-C.UTF-8}"
    --build-arg "TZ=${TZ:-UTC}"
    --build-arg "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-}"
    --build-arg "ROS_DISTRO=${ROS_DISTRO:-humble}"
    --build-arg "APT_SNAPSHOT_DATE=${APT_SNAPSHOT_DATE:-latest}"
    --build-arg "STRICT_GPG_CHECK=${STRICT_GPG_CHECK_DEFAULT}"
    --build-arg "UV_VERSION=${UV_VERSION:-0.10.10}"
    --build-arg "UV_PYTHON=${UV_PYTHON:-3.10}"
    --build-arg "CMAKE_C_STANDARD=${CMAKE_C_STANDARD:-11}"
    --build-arg "CMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17}"
    --build-arg "TARGETARCH=${TARGETARCH:-amd64}"
    --build-arg "SYS_PYTHON_EXE=${SYS_PYTHON_EXE:-/usr/bin/python3}"
    --build-arg "UV_SYNC_FLAGS=${UV_SYNC_FLAGS:-}"
    --build-arg "CMAKE_EXTRA_ARGS=${CMAKE_EXTRA_ARGS:-}"
    --build-arg "COLCON_EXTRA_FLAGS=${COLCON_EXTRA_FLAGS:-}"
    --build-arg "HAS_NVIDIA=${HAS_NVIDIA:-false}"
    --build-arg "INSTALL_INTEL_GPU_TOOLS=${INSTALL_INTEL_GPU_TOOLS:-false}"
    --build-arg "CUDA_VERSION=${CUDA_VERSION:-}"
    --build-arg "CUDNN_VERSION=${CUDNN_VERSION:-}"
    --build-arg "FULL_CUDA=${BUILD_FULL_CUDA}"
    --build-arg "OPENCV_CUDA=${OPENCV_CUDA:-auto}"
    --build-arg "IMAGE_TAG=${IMAGE_TAG}"
    --build-arg "GIT_COMMIT=${GIT_COMMIT}"
    --build-arg "COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-devkit}"
)

if [ "$MODE" = "dev" ]; then
    BASE_TARGET="$SIF_ENV"
    BASE_IMAGE="${COMPOSE_PROJECT_NAME}_${SIF_ENV}_base:${IMAGE_TAG}"
    FROZEN_IMAGE="${COMPOSE_PROJECT_NAME}_${SIF_ENV}_snapshot:${IMAGE_TAG}"
    CLEANUP_IMAGES=( "$FROZEN_IMAGE" "$BASE_IMAGE" )
    SIF_FILE="${SIF_FILE:-$(default_sif_file dev "$SIF_ENV" "$COMPOSE_PROJECT_NAME" "$IMAGE_TAG" "$SHARE_MODE")}"
    if [ "$SHARE_MODE" = "true" ]; then
        SYNC_MODE="--share"
    else
        SYNC_MODE=""
    fi

    log_info "Baking development SIF: ${SIF_FILE} (ENV=${SIF_ENV}, SHARE=${SHARE_MODE})"
    if sif_dry_run; then
        echo "Target image       : ${BASE_TARGET}"
        echo "Base image         : ${BASE_IMAGE}"
        echo "Frozen image       : ${FROZEN_IMAGE}"
        echo "SIF image          : ${SIF_FILE}"
        echo "Sync mode          : ${SYNC_MODE:-default}"
        printf 'Docker build args  :'
        printf ' %q' "${BUILD_ARGS[@]}"
        echo
        log_ok "Dry-run completed; Docker and SIF build were not executed."
        exit 0
    fi
    SIF_RUNTIME="$(resolve_sif_runtime)"
    docker build \
        -f "${HOST_ROOT}/docker/Dockerfile" \
        --target "$BASE_TARGET" \
        "${BUILD_ARGS[@]}" \
        -t "$BASE_IMAGE" "${HOST_ROOT}"

    docker build -t "$FROZEN_IMAGE" -f - "${HOST_ROOT}" <<EOF
FROM ${BASE_IMAGE}
COPY . ${CONTAINER_WORKSPACE_PATH}
RUN FORCE_LOAD_ALIASES=true bash -lc "source ${CONTAINER_WORKSPACE_PATH}/config/util_aliases.sh && mksync ${SYNC_MODE}"
WORKDIR ${CONTAINER_WORKSPACE_PATH}
EOF

    build_sif_from_docker_image "$SIF_RUNTIME" "$SIF_FILE" "$FROZEN_IMAGE"
else
    PROD_TARGET="prod-${SIF_ENV}-runtime"
    PROD_IMAGE="${COMPOSE_PROJECT_NAME}_${SIF_ENV}_prod:${IMAGE_TAG}"
    CLEANUP_IMAGES=( "$PROD_IMAGE" )
    SIF_FILE="${SIF_FILE:-$(default_sif_file prod "$SIF_ENV" "$COMPOSE_PROJECT_NAME" "$IMAGE_TAG")}"

    log_info "Baking production SIF: ${SIF_FILE} (target=${PROD_TARGET})"
    if sif_dry_run; then
        echo "Target image       : ${PROD_TARGET}"
        echo "Docker image       : ${PROD_IMAGE}"
        echo "SIF image          : ${SIF_FILE}"
        printf 'Docker build args  :'
        printf ' %q' "${BUILD_ARGS[@]}"
        echo
        log_ok "Dry-run completed; Docker and SIF build were not executed."
        exit 0
    fi
    SIF_RUNTIME="$(resolve_sif_runtime)"
    docker build \
        -f "${HOST_ROOT}/docker/Dockerfile" \
        --target "$PROD_TARGET" \
        "${BUILD_ARGS[@]}" \
        -t "$PROD_IMAGE" "${HOST_ROOT}"

    build_sif_from_docker_image "$SIF_RUNTIME" "$SIF_FILE" "$PROD_IMAGE"
fi

log_ok "Baking completed: ${SIF_FILE}"
