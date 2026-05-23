#!/bin/bash
# =============================================================================
# scripts/util_apptainer_binds.sh
# Centralized Bind Option Generator for Apptainer & SLURM (SSOT)
# =============================================================================

# Function to get the bind options as a space-separated string of --bind arguments.
# Usage: get_apptainer_binds <host_workspace> <container_workspace>
get_apptainer_binds() {
    local host_ws="$1"
    local container_ws="$2"
    local excludes="^(build|install|devel|log|.docker_cache|colcon.meta|.venv|compile_commands.json|.*\.sif)$"
    local binds=()

    # Enable nullglob (so unmatched globs return empty)
    # and dotglob (to match hidden files, excluding . and ..)
    shopt -s nullglob dotglob
    for item in "${host_ws}"/*; do
        [ -e "$item" ] || continue
        local name=$(basename "$item")
        [[ "$name" =~ $excludes ]] && continue
        binds+=( "--bind" "${item}:${container_ws}/${name}" )
    done
    shopt -u nullglob dotglob

    # Print the bind flags
    echo "${binds[@]}"
}
