#!/bin/bash
# =============================================================================
# scripts/util_apptainer_binds.sh
# Centralized Bind Option Generator for Apptainer & SLURM (SSOT)
# =============================================================================

# Usage: get_apptainer_binds_into <array_name> <host_workspace> <container_workspace>
get_apptainer_binds_into() {
    local bind_out_name="${1:-}"
    local host_ws="${2:-}"
    local container_ws="${3:-}"
    local excludes="^(\.agents|\.codex|\.devcontainer|\.docker_cache|\.git|\.idea|\.mypy_cache|\.pytest_cache|\.ruff_cache|\.venv|\.vscode|__pycache__|build|devel|dist|env|install|log|logs|-logs|venv|colcon\.meta|compile_commands\.json|.*\.sif)$"

    if [ -z "$bind_out_name" ]; then
        echo "Output array name is required for Apptainer bind generation." >&2
        return 1
    fi

    local -n bind_out="$bind_out_name"
    bind_out=()

    if [ ! -d "$host_ws" ]; then
        echo "Host workspace for Apptainer bind does not exist: ${host_ws}" >&2
        return 1
    fi
    if [ -z "$container_ws" ] || [[ "$container_ws" != /* ]]; then
        echo "Container workspace for Apptainer bind must be an absolute path: ${container_ws:-<empty>}" >&2
        return 1
    fi

    local had_nullglob=false
    local had_dotglob=false
    shopt -q nullglob && had_nullglob=true
    shopt -q dotglob && had_dotglob=true

    # Enable nullglob (so unmatched globs return empty)
    # and dotglob (to match hidden files, excluding . and ..)
    shopt -s nullglob dotglob
    for item in "${host_ws}"/*; do
        [ -e "$item" ] || continue
        local name
        name="$(basename "$item")"
        [[ "$name" =~ $excludes ]] && continue
        bind_out+=( "--bind" "${item}:${container_ws}/${name}" )
    done

    [ "$had_nullglob" = true ] || shopt -u nullglob
    [ "$had_dotglob" = true ] || shopt -u dotglob
}
