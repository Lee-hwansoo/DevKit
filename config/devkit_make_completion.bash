#!/usr/bin/env bash
# Bash completion for DevKit Makefile workflows.

_devkit_make_completion() {
    local cur prev words cword
    if declare -F _get_comp_words_by_ref >/dev/null 2>&1; then
        _get_comp_words_by_ref -n = cur prev words cword
    else
        words=("${COMP_WORDS[@]}")
        cword=$COMP_CWORD
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
    fi
    cur="${COMP_WORDS[COMP_CWORD]:-$cur}"
    prev="${COMP_WORDS[COMP_CWORD-1]:-$prev}"
    local current_token="${COMP_LINE:0:${COMP_POINT:-${#COMP_LINE}}}"
    current_token="${current_token##*[[:space:]]}"

    if ! { [ -f Makefile ] && grep -q "Unified Workflow Orchestration" Makefile 2>/dev/null; }; then
        if declare -F _make >/dev/null 2>&1; then
            _make
        fi
        return 0
    fi

    _devkit_key_used() {
        local key="$1"
        local word
        local index
        for ((index = 1; index < COMP_CWORD; index++)); do
            word="${COMP_WORDS[index]}"
            [ "${word%%=*}" = "$key" ] && [[ "$word" == *=* ]] && return 0
        done
        return 1
    }

    _devkit_values_for_key() {
        case "$1" in
            ENV) printf '%s\n' ros dev ;;
            SIF_MODE) printf '%s\n' dev prod slurm ;;
            SHARE|NO_CACHE|PROD_FULL_CUDA|VERIFY_DOCKER|FORCE|DEVKIT_KEEP_IMAGES|DEVKIT_VCS_ALLOW_FAILURE|DEVKIT_ROSDEP_ALLOW_FAILURE) printf '%s\n' 1 0 ;;
            CI) printf '%s\n' true false ;;
            DEVKIT_SLURM_NODES|DEVKIT_SLURM_NTASKS) printf '%s\n' 1 2 4 8 ;;
            DEVKIT_SLURM_CPUS_PER_TASK) printf '%s\n' 1 2 4 8 16 ;;
            DEVKIT_SLURM_GRES) printf '%s\n' gpu:1 gpu:2 gpu:4 ;;
            DEVKIT_SLURM_TIME) printf '%s\n' 00:30:00 01:00:00 02:00:00 04:00:00 ;;
            DEVKIT_SLURM_OUTPUT) printf '%s\n' 'logs/%x_%j.out' ;;
            DEVKIT_SLURM_ERROR) printf '%s\n' 'logs/%x_%j.err' ;;
            DEVKIT_SLURM_COMMENT) printf '%s\n' submitter:devkit ;;
        esac
    }

    _devkit_key_candidates() {
        local key
        for key in "$@"; do
            key="${key%=}"
            _devkit_key_used "$key" && continue
            printf '%s=\n' "$key"
        done
    }

    _devkit_complete_assignment_paths() {
        local key="$1"
        local value="$2"
        local mode="$3"
        local match
        local matches=()

        if [ "$mode" = "dir" ]; then
            mapfile -t matches < <(compgen -d -- "$value")
        elif [ -n "$value" ]; then
            mapfile -t matches < <(compgen -f -- "$value")
        else
            mapfile -t matches < <(compgen -G "*.sif")
        fi

        COMPREPLY=()
        if [ "$cur" = "$current_token" ]; then
            for match in "${matches[@]}"; do
                COMPREPLY+=( "${key}=${match}" )
            done
        else
            COMPREPLY=( "${matches[@]}" )
        fi
    }

    _devkit_targets() {
        awk '
            /^\.PHONY:/ { in_phony=1; sub(/^\.PHONY:[[:space:]]*/, "") }
            in_phony {
                continued = ($0 ~ /\\[[:space:]]*$/)
                gsub(/\\/, "")
                for (i = 1; i <= NF; i++) {
                    if ($i != "") print $i
                }
                if (!continued) in_phony=0
            }
        ' Makefile 2>/dev/null
    }

    local targets
    targets="$(_devkit_targets)"
    local target=""
    local word
    local index
    for ((index = 1; index < COMP_CWORD; index++)); do
        word="${COMP_WORDS[index]}"
        case "$word" in
            *=*) ;;
            -*) ;;
            *) target="$word"; break ;;
        esac
    done

    local keys=()
    case "$target" in
        build)
            keys=(ENV NO_CACHE)
            ;;
        start|restart)
            keys=(ENV DEVKIT_VCS_ALLOW_FAILURE DEVKIT_ROSDEP_ALLOW_FAILURE)
            ;;
        stop|shell|term|top)
            keys=(ENV)
            ;;
        bake-dev)
            keys=(ENV SHARE IMAGE_TAG DEVKIT_KEEP_IMAGES)
            ;;
        bake-prod)
            keys=(ENV PROD_FULL_CUDA IMAGE_TAG SOURCE_DATE_EPOCH DEVKIT_KEEP_IMAGES)
            ;;
        run-sif)
            keys=(SIF_MODE ENV SHARE RUN_ARGS APP_COMMAND ROS_LAUNCH_COMMAND SIF_FILE IMAGE_TAG DEVKIT_SLURM_JOB_NAME DEVKIT_SLURM_PARTITION DEVKIT_SLURM_NODES DEVKIT_SLURM_NTASKS DEVKIT_SLURM_CPUS_PER_TASK DEVKIT_SLURM_GRES DEVKIT_SLURM_TIME DEVKIT_SLURM_OUTPUT DEVKIT_SLURM_ERROR DEVKIT_SLURM_COMMENT SLURM_DATA_ROOT SLURM_RUN_ROOT CONTAINER_DATA_ROOT CONTAINER_RUN_ROOT)
            ;;
        verify)
            keys=(VERIFY_DOCKER)
            ;;
        clean|clean-cache|clean-all|docker-clean)
            keys=(FORCE CI)
            ;;
        *)
            keys=()
            ;;
    esac

    if [[ "$current_token" == *=* ]]; then
        local assign_key="${current_token%%=*}"
        local assign_value="${current_token#*=}"
        local assign_values="$(_devkit_values_for_key "$assign_key")"
        local full_values=""

        case "$assign_key" in
            RUN_ARGS|APP_COMMAND|ROS_LAUNCH_COMMAND|SOURCE_DATE_EPOCH|IMAGE_TAG|DEVKIT_SLURM_JOB_NAME|DEVKIT_SLURM_PARTITION)
                compopt -o nospace 2>/dev/null || true
                COMPREPLY=()
                return 0
                ;;
            SIF_FILE)
                compopt -o nospace 2>/dev/null || true
                _devkit_complete_assignment_paths "$assign_key" "$assign_value" file
                return 0
                ;;
            SLURM_DATA_ROOT|SLURM_RUN_ROOT|CONTAINER_DATA_ROOT|CONTAINER_RUN_ROOT)
                compopt -o nospace 2>/dev/null || true
                _devkit_complete_assignment_paths "$assign_key" "$assign_value" dir
                return 0
                ;;
        esac

        if [ -n "$assign_values" ]; then
            if [ "$cur" = "$current_token" ]; then
                local value
                while IFS= read -r value; do
                    full_values="$full_values ${assign_key}=${value}"
                done <<< "$assign_values"
                COMPREPLY=( $(compgen -W "$full_values" -- "$current_token") )
            else
                COMPREPLY=( $(compgen -W "$assign_values" -- "$assign_value") )
            fi
            return 0
        fi
    fi

    if [ -n "$target" ]; then
        local key_candidates
        key_candidates="$(_devkit_key_candidates "${keys[@]}")"
        COMPREPLY=( $(compgen -W "$key_candidates" -- "$cur") )
    else
        COMPREPLY=( $(compgen -W "$targets" -- "$cur") )
    fi

    if [ "${#COMPREPLY[@]}" -eq 1 ] && [[ "${COMPREPLY[0]}" == *= ]]; then
        compopt -o nospace 2>/dev/null || true
    fi
}

complete -F _devkit_make_completion make
