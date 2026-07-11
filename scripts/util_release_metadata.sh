#!/bin/bash
# =============================================================================
# scripts/util_release_metadata.sh
# Generate production release metadata for baked/runtime artifacts.
# =============================================================================

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: util_release_metadata.sh [output_file]

Generate release metadata JSON for baked/runtime artifacts.
Set SOURCE_DATE_EPOCH to produce a reproducible build_date.
Set DEVKIT_BUILD_DATE to override build_date with an explicit ISO-8601 value.
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --*) echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

OUTPUT_FILE="${1:-${WORKSPACE_PATH:-/workspace}/release/devkit-release.json}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "[ERROR] Python is required to generate release metadata: $PYTHON_BIN" >&2
    exit 127
fi

PYTHON_VERSION="$("$PYTHON_BIN" -c 'import platform; print(platform.python_version())' 2>/dev/null || true)"

mkdir -p -- "$(dirname "$OUTPUT_FILE")"
export OUTPUT_FILE PYTHON_VERSION
"$PYTHON_BIN" - <<'PY'
import datetime
import json
import os
import sys


def resolve_build_date():
    explicit = os.environ.get("DEVKIT_BUILD_DATE") or os.environ.get("BUILD_DATE")
    if explicit:
        return explicit

    source_epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if source_epoch:
        try:
            epoch = int(source_epoch)
        except ValueError:
            print("[ERROR] SOURCE_DATE_EPOCH must be an integer Unix timestamp.", file=sys.stderr)
            sys.exit(2)
        return (
            datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
            .replace(microsecond=0)
            .isoformat()
            .replace("+00:00", "Z")
        )

    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )

metadata = {
    "project": os.environ.get("COMPOSE_PROJECT_NAME", "unknown"),
    "image_tag": os.environ.get("IMAGE_TAG", "latest"),
    "ros_distro": os.environ.get("ROS_DISTRO", "none"),
    "python": os.environ.get("PYTHON_VERSION") or "unknown",
    "cuda_version": os.environ.get("CUDA_VERSION", ""),
    "cudnn_version": os.environ.get("CUDNN_VERSION", ""),
    "opencv_cuda": os.environ.get("OPENCV_CUDA", "auto"),
    "git_commit": os.environ.get("GIT_COMMIT", "unknown"),
    "build_date": resolve_build_date(),
}

with open(os.environ["OUTPUT_FILE"], "w", encoding="utf-8") as handle:
    json.dump(metadata, handle, ensure_ascii=False, separators=(",", ":"))
    handle.write("\n")
PY
