#!/bin/bash
# Fast repository validation for DevKit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT_DIR"

[ ! -f "${SOURCE_LOG:-}" ] && SOURCE_LOG="${SCRIPT_DIR}/util_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"

if ! declare -F log_info >/dev/null 2>&1; then
    log_info() { echo "[INFO] $*"; }
    log_ok() { echo "[OK] $*"; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

truthy() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

has_word() {
    local needle="$1"
    local haystack="$2"
    grep -Fxq "$needle" <<< "$haystack"
}

assert_words_present() {
    local haystack="$1"
    local label="$2"
    shift 2

    local word
    for word in "$@"; do
        if ! has_word "$word" "$haystack"; then
            log_error "$label is missing required package '$word': $haystack"
            return 1
        fi
    done
}

require_files() {
    local missing=()
    local file

    for file in "$@"; do
        [ -e "$file" ] || missing+=( "$file" )
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        log_error "Required repository file(s) missing: ${missing[*]}"
        return 1
    fi
}

require_executables() {
    local not_exec=()
    local file

    for file in "$@"; do
        [ -x "$file" ] || not_exec+=( "$file" )
    done

    if [ "${#not_exec[@]}" -gt 0 ]; then
        log_error "Required executable file(s) are not executable: ${not_exec[*]}"
        return 1
    fi
}

verify_make_help() (
    local phony_targets help_targets missing_help extra_help
    phony_targets="$(mktemp /tmp/devkit_phony_targets.XXXXXX)"
    help_targets="$(mktemp /tmp/devkit_help_targets.XXXXXX)"
    trap 'rm -f "$phony_targets" "$help_targets"' EXIT

    awk '/^\.PHONY:/ { in_phony=1; sub(/^\.PHONY:[[:space:]]*/, "") } in_phony { continued=($0 ~ /\\[[:space:]]*$/); gsub(/\\/, ""); for (i = 1; i <= NF; i++) print $i; if (!continued) in_phony=0 }' Makefile | sort -u > "$phony_targets"
    awk '/^## @target / { content=$0; sub(/^.*## @target /, "", content); sub(/[[:space:]]*:.*/, "", content); split(content, parts, /[[:space:]]+/); print parts[1] }' Makefile | sort -u > "$help_targets"

    missing_help="$(comm -23 "$phony_targets" "$help_targets")"
    extra_help="$(comm -13 "$phony_targets" "$help_targets")"

    if [ -n "$missing_help" ] || [ -n "$extra_help" ]; then
        [ -z "$missing_help" ] || log_error "Missing ## @target help for:
$missing_help"
        [ -z "$extra_help" ] || log_error "## @target entries without .PHONY target:
$extra_help"
        return 1
    fi
)

verify_vscode_json_defaults() (
    local matches
    matches="$(mktemp /tmp/devkit_vscode_default_patterns.XXXXXX)"
    trap 'rm -f "$matches"' EXIT

    if grep -R -n -E '\$\{[A-Za-z_][A-Za-z0-9_]*:-' .vscode .devcontainer > "$matches" 2>/dev/null; then
        log_error 'VS Code JSON files must not use shell default expansion like ${VAR:-default}; VS Code treats it as variable substitution.'
        sed 's/^/  /' "$matches"
        return 1
    fi
)

verify_make_completion_ssot() {
    local completion_targets phony_targets

    if grep -nE 'targets="[^"]*(completion|build|start|run-sif|docker-clean)' config/devkit_make_completion.bash >/dev/null; then
        log_error "Make completion must read targets from Makefile .PHONY instead of keeping a duplicated hard-coded target list."
        return 1
    fi
    if grep -nE 'slurm-status\|slurm-cancel\|completion\|completion-install' config/devkit_make_completion.bash >/dev/null; then
        log_error "Make completion must not duplicate no-option target lists; the default empty-key branch already covers them."
        return 1
    fi
    if ! grep -q '_devkit_targets' config/devkit_make_completion.bash; then
        log_error "Make completion must derive target candidates from Makefile .PHONY."
        return 1
    fi

    phony_targets="$(awk '/^\.PHONY:/ { in_phony=1; sub(/^\.PHONY:[[:space:]]*/, "") } in_phony { continued=($0 ~ /\\[[:space:]]*$/); gsub(/\\/, ""); for (i = 1; i <= NF; i++) print $i; if (!continued) in_phony=0 }' Makefile | sort -u)"
    completion_targets="$(
        bash -c '
            source config/devkit_make_completion.bash
            COMP_WORDS=(make "")
            COMP_CWORD=1
            COMP_LINE="make "
            COMP_POINT=${#COMP_LINE}
            _devkit_make_completion
            printf "%s\n" "${COMPREPLY[@]}" | sort -u
        '
    )"
    if [ "$completion_targets" != "$phony_targets" ]; then
        log_error "Make completion target candidates differ from Makefile .PHONY."
        diff -u <(printf '%s\n' "$phony_targets") <(printf '%s\n' "$completion_targets") >&2 || true
        return 1
    fi

    local start_keys vcs_values
    start_keys="$(
        bash -c '
            source config/devkit_make_completion.bash
            COMP_WORDS=(make start "")
            COMP_CWORD=2
            COMP_LINE="make start "
            COMP_POINT=${#COMP_LINE}
            _devkit_make_completion
            printf "%s\n" "${COMPREPLY[@]}" | sort -u
        '
    )"
    assert_words_present "$start_keys" "make start completion keys" \
        DEVKIT_VCS_ALLOW_FAILURE= DEVKIT_ROSDEP_ALLOW_FAILURE= || return 1

    vcs_values="$(
        bash -c '
            source config/devkit_make_completion.bash
            COMP_WORDS=(make start DEVKIT_VCS_ALLOW_FAILURE=)
            COMP_CWORD=2
            COMP_LINE="make start DEVKIT_VCS_ALLOW_FAILURE="
            COMP_POINT=${#COMP_LINE}
            _devkit_make_completion
            printf "%s\n" "${COMPREPLY[@]}" | sort -u
        '
    )"
    assert_words_present "$vcs_values" "DEVKIT_VCS_ALLOW_FAILURE completion values" \
        DEVKIT_VCS_ALLOW_FAILURE=0 DEVKIT_VCS_ALLOW_FAILURE=1 || return 1
}

verify_docs_cache_safety() {
    if ! grep -q "absolute, non-root path" .env.example; then
        log_error ".env.example must document that DOCKER_DEV_CACHE_DIR requires an absolute, non-root path."
        return 1
    fi
    if ! grep -q "workspace root" .env.example; then
        log_error ".env.example must document that clean-cache refuses the workspace root."
        return 1
    fi
    if ! grep -q "workspace-root" README.md; then
        log_error "README.md clean-cache documentation must mention workspace-root refusal."
        return 1
    fi
    if ! grep -q "워크스페이스 루트" README.ko.md; then
        log_error "README.ko.md clean-cache documentation must mention workspace-root refusal."
        return 1
    fi
    local vcs_doc_file
    for vcs_doc_file in .env.example README.md README.ko.md docs/DEVELOPMENT.md; do
        if ! grep -q "DEVKIT_VCS_ALLOW_FAILURE" "$vcs_doc_file"; then
            log_error "Dependency sync fail-open switch DEVKIT_VCS_ALLOW_FAILURE must be documented in $vcs_doc_file."
            return 1
        fi
    done
    if ! grep -q "DEVKIT_ROSDEP_ALLOW_FAILURE" .env.example; then
        log_error ".env.example must document DEVKIT_ROSDEP_ALLOW_FAILURE next to dependency sync settings."
        return 1
    fi
}

verify_env_example_unique_active_keys() {
    local duplicates
    duplicates="$(
        awk -F= '
            /^[[:space:]]*[A-Z][A-Z0-9_]*=/ {
                key = $1
                sub(/^[[:space:]]+/, "", key)
                sub(/[[:space:]]+$/, "", key)
                seen[key]++
            }
            END {
                for (key in seen) {
                    if (seen[key] > 1) print key
                }
            }
        ' .env.example | sort
    )"
    if [ -n "$duplicates" ]; then
        log_error ".env.example must not define active keys more than once: ${duplicates//$'\n'/, }"
        return 1
    fi
}

verify_compose_dependency_sync_env() {
    local key
    for key in DEVKIT_VCS_ALLOW_FAILURE DEVKIT_ROSDEP_ALLOW_FAILURE; do
        if ! grep -q "^[[:space:]]*${key}:" docker-compose.common.yml; then
            log_error "docker-compose.common.yml must pass ${key} into dev containers for sync_deps."
            return 1
        fi
    done
}

verify_logging_env_contract() {
    local key
    for key in LOG_SHOW_TIME DEBUG_MODE LOG_FILE; do
        if ! grep -q "^[#[:space:]]*${key}=" .env.example; then
            log_error ".env.example must document ${key} for DevKit logging."
            return 1
        fi
        if ! grep -q "^[[:space:]]*${key}:" docker-compose.common.yml; then
            log_error "docker-compose.common.yml must pass ${key} into dev containers for DevKit logging."
            return 1
        fi
    done
    if grep -q "PROD_LOG_VOL" .env.example; then
        log_error ".env.example must not include unused PROD_LOG_VOL."
        return 1
    fi
}

verify_compose_runtime_defaults() {
    local key expected pattern ulimit_expected
    for key in NETWORK_MODE IPC_MODE PRIVILEGED; do
        expected="$(awk -F= -v key="$key" '$1 == key { print $2; exit }' .env.example)"
        if [ -z "$expected" ]; then
            log_error ".env.example must define ${key}."
            return 1
        fi
        pattern='${'"${key}"':-'"${expected}"'}'
        if ! grep -Fq "$pattern" docker-compose.common.yml; then
            log_error "docker-compose.common.yml fallback for ${key} must match .env.example (${expected})."
            return 1
        fi
    done
    ulimit_expected="$(awk -F= '$1 == "ULIMIT_NOFILE" { print $2; exit }' .env.example)"
    if [ -z "$ulimit_expected" ]; then
        log_error ".env.example must define ULIMIT_NOFILE."
        return 1
    fi
    if ! grep -Fq "soft: \${ULIMIT_NOFILE:-${ulimit_expected}}" docker-compose.common.yml || \
       ! grep -Fq "hard: \${ULIMIT_NOFILE:-${ulimit_expected}}" docker-compose.common.yml; then
        log_error "docker-compose.common.yml nofile ulimit fallback must match .env.example (${ulimit_expected})."
        return 1
    fi
    if ! grep -q "VALIDATE_COMPOSE_RUNTIME" Makefile; then
        log_error "Makefile must validate compose runtime settings before invoking Docker Compose."
        return 1
    fi
    if ! grep -Fq '${HOST_SSH_AUTH_SOCK:-/dev/null}:/tmp/ssh-auth.sock:ro' docker-compose.dev.yml; then
        log_error "docker-compose.dev.yml must mount SSH agent sockets to a stable in-container path."
        return 1
    fi
    if ! grep -Fq 'SSH_AUTH_SOCK: ${HOST_SSH_AUTH_SOCK:+/tmp/ssh-auth.sock}' docker-compose.dev.yml; then
        log_error "docker-compose.dev.yml must expose SSH_AUTH_SOCK only when a host agent socket exists."
        return 1
    fi
}

verify_compose_gpu_build_args() {
    if ! grep -q "INSTALL_INTEL_GPU_TOOLS" .env.example; then
        log_error ".env.example must document INSTALL_INTEL_GPU_TOOLS."
        return 1
    fi
    if ! grep -q "INSTALL_INTEL_GPU_TOOLS" docker-compose.common.yml; then
        log_error "docker-compose.common.yml must pass INSTALL_INTEL_GPU_TOOLS as a Docker build arg."
        return 1
    fi
    if ! grep -q -- '--build-arg "INSTALL_INTEL_GPU_TOOLS=' scripts/apptainer_bake.sh; then
        log_error "scripts/apptainer_bake.sh must pass INSTALL_INTEL_GPU_TOOLS for direct SIF Docker builds."
        return 1
    fi
    if ! awk '
        /^  base-igpu:/ { in_service = 1; found = 0; next }
        /^  base-/ && in_service { exit found ? 0 : 1 }
        in_service && /INSTALL_INTEL_GPU_TOOLS:[[:space:]]*"true"/ { found = 1 }
        END { if (in_service) exit found ? 0 : 1 }
    ' docker-compose.common.yml; then
        log_error "base-igpu must enable INSTALL_INTEL_GPU_TOOLS so Intel diagnostics stay scoped to iGPU images."
        return 1
    fi
    if ! awk '
        /^  base-ros-igpu:/ { in_service = 1; found = 0; next }
        /^  base-/ && in_service { exit found ? 0 : 1 }
        in_service && /INSTALL_INTEL_GPU_TOOLS:[[:space:]]*"true"/ { found = 1 }
        END { if (in_service) exit found ? 0 : 1 }
    ' docker-compose.common.yml; then
        log_error "base-ros-igpu must enable INSTALL_INTEL_GPU_TOOLS so Intel diagnostics stay scoped to iGPU ROS images."
        return 1
    fi
}

verify_cmake_standard_contract() {
    local file
    for file in docker-compose.common.yml docker/Dockerfile config/init_bash.sh config/util_aliases.sh scripts/apptainer_bake.sh; do
        if ! grep -q "CMAKE_C_STANDARD" "$file"; then
            log_error "CMAKE_C_STANDARD is documented in .env.example but is not wired through $file."
            return 1
        fi
    done
    if ! grep -q "VALIDATE_C_STANDARDS" Makefile; then
        log_error "Makefile must validate CMAKE_C_STANDARD and CMAKE_CXX_STANDARD values."
        return 1
    fi
}

verify_strict_gpg_build_arg_contract() {
    if ! grep -q "STRICT_GPG_CHECK" .env.example; then
        log_error ".env.example must document STRICT_GPG_CHECK."
        return 1
    fi
    if ! grep -q "^[[:space:]]*STRICT_GPG_CHECK:" docker-compose.common.yml; then
        log_error "docker-compose.common.yml must pass STRICT_GPG_CHECK as a Docker build arg."
        return 1
    fi
    if ! grep -q -- '--build-arg "STRICT_GPG_CHECK=' scripts/apptainer_bake.sh; then
        log_error "scripts/apptainer_bake.sh must pass STRICT_GPG_CHECK to Docker builds."
        return 1
    fi
    if ! awk '
        function check_stage() {
            if (stage_has_setup && !stage_has_arg) {
                print stage > "/dev/stderr"
                bad = 1
            }
        }
        /^FROM / {
            check_stage()
            stage = ($4 != "" ? $4 : $2)
            stage_has_setup = 0
            stage_has_arg = 0
            next
        }
        /^ARG[[:space:]]+STRICT_GPG_CHECK([=[:space:]]|$)/ { stage_has_arg = 1 }
        /setup-ros-repo/ { stage_has_setup = 1 }
        END { check_stage(); exit bad ? 1 : 0 }
    ' docker/Dockerfile; then
        log_error "Every Dockerfile stage that runs setup-ros-repo must declare ARG STRICT_GPG_CHECK."
        return 1
    fi
}

expect_make_failure() {
    local label="$1"
    local expected="$2"
    local output
    shift 2

    if output="$(make --no-print-directory "$@" 2>&1)"; then
        log_error "$label unexpectedly passed Makefile validation."
        return 1
    fi
    if [[ "$output" != *"$expected"* ]]; then
        log_error "$label failed for the wrong reason:"
        printf '%s\n' "$output" | sed 's/^/  /' >&2
        return 1
    fi
}

verify_make_validations() {
    local check_host_output make_plan

    expect_make_failure "Invalid GPU_MODE" \
        "GPU_MODE must be auto, cpu, igpu, intel, amd, or nvidia" \
        stop ENV=ros GPU_MODE=bogus

    make_plan="$(GPU_MODE=cpu make --no-print-directory build ENV=ros COMPOSE=echo 2>/dev/null)"
    [[ "$make_plan" == *"build ros-cpu"* ]]
    make_plan="$(GPU_MODE=intel make --no-print-directory build ENV=dev COMPOSE=echo 2>/dev/null)"
    [[ "$make_plan" == *"build basic-igpu"* ]]
    check_host_output="$(make --no-print-directory check-host GPU_MODE=cpu HAS_NVIDIA=true HAS_TOOLKIT_BIN=true HAS_TOOLKIT=false 2>&1)"
    [[ "$check_host_output" != *"NVIDIA Container Toolkit"* ]]
    check_host_output="$(make --no-print-directory check-host GPU_MODE=nvidia HAS_NVIDIA=true HAS_TOOLKIT_BIN=true HAS_TOOLKIT=false 2>&1)"
    [[ "$check_host_output" == *"NVIDIA Container Toolkit is installed but NOT configured for Docker"* ]]

    expect_make_failure "Invalid ROS_DISTRO" \
        "ROS_DISTRO must be 'humble' or 'noetic'" \
        env-check ROS_DISTRO=typo
    expect_make_failure "Mismatched ROS_DISTRO/BASE_IMAGE" \
        "BASE_IMAGE=ubuntu:22.04 must be paired with ROS_DISTRO=humble" \
        env-check ROS_DISTRO=noetic BASE_IMAGE=ubuntu:22.04
    expect_make_failure "Mismatched ROS_DISTRO/BASE_IMAGE" \
        "BASE_IMAGE=ubuntu:20.04 must be paired with ROS_DISTRO=noetic" \
        env-check ROS_DISTRO=humble BASE_IMAGE=ubuntu:20.04
    expect_make_failure "Unsupported official Ubuntu BASE_IMAGE" \
        "Official Ubuntu BASE_IMAGE must be ubuntu:22.04 for ROS_DISTRO=humble or ubuntu:20.04 for ROS_DISTRO=noetic" \
        env-check ROS_DISTRO=humble BASE_IMAGE=ubuntu:24.04
    expect_make_failure "Empty BASE_IMAGE" \
        "BASE_IMAGE must not be empty" \
        env-check BASE_IMAGE=
    expect_make_failure "Relative HOST_WORKSPACE_PATH" \
        "HOST_WORKSPACE_PATH must be an absolute non-root path" \
        env-check HOST_WORKSPACE_PATH=.
    expect_make_failure "Relative WORKSPACE_PATH" \
        "WORKSPACE_PATH must be an absolute non-root path inside the container" \
        env-check WORKSPACE_PATH=workspace
    expect_make_failure "Invalid COMPOSE_PROJECT_NAME override" \
        "COMPOSE_PROJECT_NAME must start and end with a lowercase letter or digit" \
        env-check COMPOSE_PROJECT_NAME=Bad
    expect_make_failure "Invalid IMAGE_TAG override" \
        "IMAGE_TAG must be a valid Docker tag" \
        env-check IMAGE_TAG=bad/tag
    expect_make_failure "Invalid OPENCV_CUDA" \
        "OPENCV_CUDA must be 'auto' or 'off'" \
        env-check OPENCV_CUDA=on
    expect_make_failure "Invalid TARGETARCH" \
        "TARGETARCH must be 'amd64' or 'arm64'" \
        env-check TARGETARCH=ppc64le
    expect_make_failure "Invalid C standard" \
        "CMAKE_C_STANDARD must be '11' or '17'" \
        env-check CMAKE_C_STANDARD=90
    expect_make_failure "Invalid C++ standard" \
        "CMAKE_CXX_STANDARD must be '17' or '20'" \
        env-check CMAKE_CXX_STANDARD=14
    expect_make_failure "Invalid NETWORK_MODE" \
        "NETWORK_MODE must be 'host', 'bridge', or 'none'" \
        env-check NETWORK_MODE=overlay
    expect_make_failure "Invalid IPC_MODE" \
        "IPC_MODE must be 'host', 'private', 'shareable', or 'none'" \
        env-check IPC_MODE=shared
    expect_make_failure "Invalid PRIVILEGED" \
        "PRIVILEGED must be 'true' or 'false'" \
        env-check PRIVILEGED=yes
    expect_make_failure "Invalid ULIMIT_NOFILE" \
        "ULIMIT_NOFILE must be a positive integer" \
        env-check ULIMIT_NOFILE=0
    expect_make_failure "Invalid GIT_CONFIG_PATH" \
        "GIT_CONFIG_PATH must point to an existing git config file" \
        env-check GIT_CONFIG_PATH=/tmp/devkit-not-gitconfig
    expect_make_failure "Invalid HOST_XAUTHORITY" \
        "HOST_XAUTHORITY must point to an existing Xauthority file" \
        env-check HOST_XAUTHORITY=/tmp/devkit-not-xauthority
    expect_make_failure "Invalid HOST_XDG_RUNTIME_DIR" \
        "HOST_XDG_RUNTIME_DIR must point to an existing runtime directory" \
        env-check HOST_XDG_RUNTIME_DIR=/tmp/devkit-not-xdg-runtime
    expect_make_failure "Invalid HOST_X11_DIR" \
        "HOST_X11_DIR must point to an existing X11 socket directory" \
        env-check HOST_X11_DIR=/tmp/devkit-not-x11
    expect_make_failure "Invalid HOST_SSH_AUTH_SOCK" \
        "HOST_SSH_AUTH_SOCK must point to an existing SSH agent UNIX socket" \
        env-check HOST_SSH_AUTH_SOCK=/tmp/devkit-not-a-socket
    expect_make_failure "Relative HOST_CACHE_DIR" \
        "Cache directory must be an absolute non-root path" \
        clean-cache HOST_CACHE_DIR=relative FORCE=1
    expect_make_failure "Workspace root HOST_CACHE_DIR" \
        "Refusing to clean the workspace root as a cache directory" \
        clean-cache HOST_CACHE_DIR="$ROOT_DIR" FORCE=1
}

verify_env_detector_cache_safety() {
    ! DOCKER_DEV_CACHE_DIR=relative scripts/check_env.sh >/dev/null 2>&1 || {
        log_error "check_env.sh must reject relative DOCKER_DEV_CACHE_DIR values."
        return 1
    }
    ! DOCKER_DEV_CACHE_DIR=/ scripts/check_env.sh >/dev/null 2>&1 || {
        log_error "check_env.sh must reject DOCKER_DEV_CACHE_DIR=/."
        return 1
    }
    ! DOCKER_DEV_CACHE_DIR="$ROOT_DIR" scripts/check_env.sh >/dev/null 2>&1 || {
        log_error "check_env.sh must reject DOCKER_DEV_CACHE_DIR when it points at the workspace root."
        return 1
    }
    ! DOCKER_DEV_CACHE_DIR=/proc/devkit-cache scripts/check_env.sh >/dev/null 2>&1 || {
        log_error "check_env.sh must fail when it cannot create DOCKER_DEV_CACHE_DIR."
        return 1
    }
}

verify_make_detector_failure_is_fatal() (
    local tmp_detect
    tmp_detect="$(mktemp -d /tmp/devkit_detector.XXXXXX)"
    trap 'rm -rf "$tmp_detect"' EXIT

    expect_make_failure "Environment detector failure" \
        "Environment detection failed" \
        status DOCKER_DEV_CACHE_DIR=relative DETECTED_ENV_FILE="$tmp_detect/detected-env.mk"
)

verify_make_detector_cache_atomic() {
    if grep -nF '$(DETECTED_ENV_FILE).tmp' Makefile >/dev/null; then
        log_error "Makefile environment detector cache must use a unique temporary file; fixed .tmp names race under parallel make invocations."
        return 1
    fi
    if ! grep -nF 'mktemp "$(DETECTED_ENV_FILE).' Makefile >/dev/null; then
        log_error "Makefile environment detector cache must be written through mktemp before atomic mv."
        return 1
    fi
}

verify_make_xauth_feedback() {
    if awk '
        /^xauth:/ { in_target = 1; next }
        in_target && /^[^[:space:]].*:/ { in_target = 0 }
        in_target && /(xauth|xhost).* *\|\| true/ { bad = 1 }
        END { exit bad ? 0 : 1 }
    ' Makefile; then
        log_error "Makefile xauth target must warn on xauth/xhost failures instead of silently swallowing them with '|| true'."
        return 1
    fi
    if ! awk '
        /^xauth:/ { in_target = 1; next }
        in_target && /^[^[:space:]].*:/ { in_target = 0 }
        in_target && /Unable to read X11 authentication/ { read_warn = 1 }
        in_target && /Unable to merge X11 authentication/ { merge_warn = 1 }
        in_target && /Unable to grant X11/ { xhost_warn = 1 }
        END { exit (read_warn && merge_warn && xhost_warn) ? 0 : 1 }
    ' Makefile; then
        log_error "Makefile xauth target must provide actionable warnings for X11 auth and xhost failures."
        return 1
    fi
    if ! awk '
        /^run-sif:/ { in_target = 1; next }
        in_target && /^[^[:space:]].*:/ { in_target = 0 }
        in_target && /DEVKIT_DRY_RUN/ && /xauth/ { found = 1 }
        END { exit found ? 0 : 1 }
    ' Makefile; then
        log_error "Makefile run-sif target must skip xauth side effects during DEVKIT_DRY_RUN."
        return 1
    fi
}

verify_docker_static() {
    if truthy "${VERIFY_DOCKER:-1}"; then
        if ! docker info >/dev/null 2>&1; then
            log_error "Docker daemon is not reachable. Start Docker or check access to /var/run/docker.sock."
            log_info "For script-only checks, run: make verify VERIFY_DOCKER=0"
            log_info "In sandboxed runners, execute Docker checks directly: docker compose -f docker-compose.dev.yml config --quiet && docker build --check -f docker/Dockerfile ."
            return 1
        fi
        docker compose -f docker-compose.dev.yml config --quiet
        local tmp_ctx
        tmp_ctx=$(mktemp -d)
        docker build --check -f docker/Dockerfile "$tmp_ctx"
        local rc=$?
        rm -rf "$tmp_ctx"
        return $rc
    else
        log_warn "Skipping Docker checks (VERIFY_DOCKER=0)."
    fi
}

verify_dockerfile_bind_cleanup() {
    if awk '
        /^RUN / {
            block = $0
            in_run = ($0 ~ /\\[[:space:]]*$/)
            if (!in_run) {
                if (block ~ /target=\/tmp\// && block ~ /rm[[:space:]]+-rf[[:space:]]+\/tmp\/\*/) bad = 1
                block = ""
            }
            next
        }
        in_run {
            block = block "\n" $0
            if ($0 !~ /\\[[:space:]]*$/) {
                if (block ~ /target=\/tmp\// && block ~ /rm[[:space:]]+-rf[[:space:]]+\/tmp\/\*/) bad = 1
                block = ""
                in_run = 0
            }
        }
        END { exit bad ? 0 : 1 }
    ' docker/Dockerfile; then
        log_error "Dockerfile RUN blocks with BuildKit bind mounts under /tmp must not delete /tmp/*; mounted helper files become busy."
        return 1
    fi
}

verify_dockerfile_package_policy() {
    if ! awk '
        /^FROM / && $4 == "prod-dev-builder" && $2 != "build-core" { bad = bad "\nprod-dev-builder must inherit from build-core, got " $2 }
        /^FROM / && $4 == "ros-builder-base" && $2 != "build-core" { bad = bad "\nros-builder-base must inherit from build-core, got " $2 }
        END {
            if (bad != "") {
                print bad > "/dev/stderr"
                exit 1
            }
        }
    ' docker/Dockerfile; then
        log_error "Production builders must bypass interactive dev stages to keep build paths lean and cacheable."
        return 1
    fi
    if grep -nE '(^|[[:space:]])libboost-all-dev([[:space:]\\]|$)' docker/Dockerfile >/dev/null; then
        log_error "Dockerfile must not install libboost-all-dev in the base development image; use explicit Boost components to avoid MPI/Python/Wave/Log bloat."
        return 1
    fi
    if grep -nE '(^|[[:space:]])software-properties-common([[:space:]\\]|$)' docker/Dockerfile >/dev/null; then
        log_error "Dockerfile must not install software-properties-common in the base development image; it pulls PackageKit/systemd stacks and add-apt-repository is not used."
        return 1
    fi
    if grep -nF 'rosdep init || true' docker/Dockerfile >/dev/null; then
        log_error "Dockerfile must not hide rosdep init failures with '|| true'; guard the initialized state explicitly."
        return 1
    fi
    if grep -nF 'rosdep update --rosdistro' docker/Dockerfile >/dev/null; then
        log_error "Dockerfile must use util_apt_helper.sh update-rosdep so rosdep update can retry and fall back to cache."
        return 1
    fi
    if ! grep -q 'update-rosdep' scripts/util_apt_helper.sh || ! grep -q 'update-rosdep' docker/Dockerfile; then
        log_error "ROS Docker stages must route rosdep cache updates through util_apt_helper.sh update-rosdep."
        return 1
    fi
    if awk '
        /^FROM / { stage = ($4 != "" ? $4 : "") }
        stage == "prod-base" && /(libegl1-mesa|libgl1-mesa-dri|libglx-mesa0|mesa-utils)/ { bad = 1 }
        END { exit bad ? 0 : 1 }
    ' docker/Dockerfile; then
        log_error "prod-base must stay headless; add Mesa/OpenGL packages to dependencies/apt.txt with # runtime only when a deployed app needs them."
        return 1
    fi
    if ! awk '
        function check_block() {
            if (stage == "prod-ros-runtime" && block ~ /setup-ros-repo/) {
                if (block !~ /install-packages runtime/ || block !~ /apt-get purge -y --auto-remove curl gnupg2 dirmngr/) bad = 1
            }
            block = ""
        }
        /^FROM / { check_block(); stage = ($4 != "" ? $4 : ""); next }
        /^RUN / { check_block(); block = $0; in_run = ($0 ~ /\\[[:space:]]*$/); if (!in_run) check_block(); next }
        in_run { block = block "\n" $0; if ($0 !~ /\\[[:space:]]*$/) { in_run = 0; check_block() } }
        END { check_block(); exit bad ? 1 : 0 }
    ' docker/Dockerfile; then
        log_error "prod-ros-runtime must setup the ROS repo, install runtime packages, and purge repo bootstrap tools in the same RUN layer."
        return 1
    fi
    if ! awk '
        /^FROM / { stage = ($4 != "" ? $4 : "") }
        stage == "prod-ros-builder" && /mksync --share/ { found = 1 }
        END { exit found ? 0 : 1 }
    ' docker/Dockerfile; then
        log_error "prod-ros-builder must run mksync --share so ROS Python bindings can see apt-provided modules such as numpy in production venvs."
        return 1
    fi
    if grep -nE '^[[:space:]]*ros-\$\{ROS_DISTRO\}-gazebo-ros-pkgs([[:space:]]|$)' dependencies/apt_ros.txt >/dev/null; then
        log_error "Gazebo must not be part of the default ROS dependency set; it pulls large simulation, OpenCV dev, Boost all, and MPI chains. Keep it as an explicit project dependency."
        return 1
    fi
    if grep -nE '^[[:space:]]*ros-\$\{ROS_DISTRO\}-ros-base[[:space:]]*#.*(^|[[:space:],])runtime([[:space:],]|$)' dependencies/apt_ros.txt >/dev/null; then
        log_error "ROS runtime defaults must use ros-core, not ros-base; ros-base pulls rosbag2 and extra robot tooling. Keep ros-base dev-only unless a project opts in."
        return 1
    fi
}

verify_dependency_file_syntax() {
    awk '
        /^[[:space:]]*($|#)/ { next }
        {
            raw = $0
            line = raw
            comment = ""
            if (match(line, /#/)) {
                comment = substr(line, RSTART + 1)
                line = substr(line, 1, RSTART - 1)
            }
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line == "") {
                next
            }
            if (line ~ /[[:space:]]/) {
                printf "%s:%d: dependency lines must contain one package token before the comment: %s\n", FILENAME, FNR, raw > "/dev/stderr"
                bad = 1
            }
            if (comment != "") {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", comment)
                split(comment, parts, /[[:space:]]+/)
                split(parts[1], tags, /,/)
                for (i in tags) {
                    if (tags[i] != "" && tags[i] != "runtime" && tags[i] != "dev" && tags[i] != "gui" && tags[i] != "ros1" && tags[i] != "ros2") {
                        printf "%s:%d: unknown dependency tag '%s' in: %s\n", FILENAME, FNR, tags[i], raw > "/dev/stderr"
                        bad = 1
                    }
                }
            }
        }
        END { exit bad ? 1 : 0 }
    ' dependencies/apt.txt dependencies/apt_ros.txt || {
        log_error "Dependency file syntax validation failed."
        return 1
    }
}

verify_apt_cuda_helpers() {
    local humble_all_pkgs humble_builder_pkgs humble_runtime_pkgs noetic_builder_pkgs noetic_runtime_pkgs forbidden_runtime_re forbidden_builder_re
    local cuda_dev_pkgs cuda_runtime_pkgs cuda_full_pkgs forbidden_cuda_dev_re

    humble_all_pkgs="$(DEVKIT_DRY_RUN=1 scripts/util_apt_helper.sh install-packages all humble dependencies)"
    humble_builder_pkgs="$(DEVKIT_DRY_RUN=1 scripts/util_apt_helper.sh install-packages builder humble dependencies)"
    humble_runtime_pkgs="$(DEVKIT_DRY_RUN=1 scripts/util_apt_helper.sh install-packages runtime humble dependencies)"
    noetic_builder_pkgs="$(DEVKIT_DRY_RUN=1 scripts/util_apt_helper.sh install-packages builder noetic dependencies)"
    noetic_runtime_pkgs="$(DEVKIT_DRY_RUN=1 scripts/util_apt_helper.sh install-packages runtime noetic dependencies)"

    assert_words_present "$humble_all_pkgs" "ROS2 dev dependency set" \
        ros-humble-ros-core ros-humble-std-msgs ros-humble-tf2-ros ros-humble-ros-base ros-humble-xacro \
        python3-colcon-common-extensions python3-rosdep python3-vcstool ros-humble-rviz2 ros-humble-rqt \
        || return 1
    assert_words_present "$humble_runtime_pkgs" "ROS2 runtime dependency set" \
        ros-humble-ros-core ros-humble-std-msgs ros-humble-tf2-ros ros-humble-tf2-ros-py ros-humble-rmw-cyclonedds-cpp \
        || return 1
    assert_words_present "$humble_builder_pkgs" "ROS2 builder dependency set" \
        ros-humble-ros-core ros-humble-std-msgs ros-humble-tf2-ros ros-humble-xacro \
        python3-colcon-common-extensions python3-rosdep python3-vcstool \
        || return 1
    assert_words_present "$noetic_builder_pkgs" "ROS1 builder dependency set" \
        ros-noetic-roslaunch ros-noetic-rospy ros-noetic-roscpp ros-noetic-std-msgs ros-noetic-tf2-ros ros-noetic-xacro \
        python3-colcon-common-extensions python3-rosdep python3-vcstool python3-catkin-tools \
        || return 1
    assert_words_present "$noetic_runtime_pkgs" "ROS1 runtime dependency set" \
        ros-noetic-roslaunch ros-noetic-rospy ros-noetic-roscpp ros-noetic-std-msgs ros-noetic-tf2-ros \
        || return 1

    forbidden_builder_re='(^|[[:space:]])(ros-[^-]+-ros-base|ros-[^-]+-cv-bridge|ros-[^-]+-rviz2?|ros-[^-]+-rqt|ros-[^-]+-gazebo-ros-pkgs)([[:space:]]|$)'
    if printf '%s\n' "$humble_builder_pkgs" "$noetic_builder_pkgs" | grep -E "$forbidden_builder_re" >/dev/null; then
        log_error "ROS builder dependency set contains GUI/desktop packages: $humble_builder_pkgs $noetic_builder_pkgs"
        return 1
    fi

    forbidden_runtime_re='(^|[[:space:]])(python3-colcon-common-extensions|python3-rosdep|python3-vcstool|python3-argcomplete|ros-[^-]+-ros-base|ros-[^-]+-cv-bridge|ros-[^-]+-xacro|ros-[^-]+-rviz2?|ros-[^-]+-rqt|ros-[^-]+-gazebo-ros-pkgs|ros-noetic-ros-core|ros-noetic-tf)([[:space:]]|$)'
    if printf '%s\n' "$humble_runtime_pkgs" "$noetic_runtime_pkgs" | grep -E "$forbidden_runtime_re" >/dev/null; then
        log_error "ROS runtime dependency set contains dev, GUI, or project-specific packages: $humble_runtime_pkgs $noetic_runtime_pkgs"
        return 1
    fi

    ! DEVKIT_DRY_RUN=1 scripts/util_apt_helper.sh install-packages runtime typo dependencies >/dev/null 2>&1
    ! scripts/util_apt_helper.sh configure-snapshot >/dev/null 2>&1
    ! scripts/util_apt_helper.sh setup-ros-repo >/dev/null 2>&1
    ! scripts/util_apt_helper.sh setup-cuda-repo >/dev/null 2>&1

    HAS_NVIDIA=true CUDA_VERSION=12.8.0 CUDNN_VERSION=9 FULL_CUDA=false DEVKIT_DRY_RUN=1 scripts/util_cuda_apt.sh runtime >/dev/null
    HAS_NVIDIA=True CUDA_VERSION=12.8.0 CUDNN_VERSION=9 FULL_CUDA=off DEVKIT_DRY_RUN=1 scripts/util_cuda_apt.sh runtime >/dev/null
    cuda_dev_pkgs="$(HAS_NVIDIA=true CUDA_VERSION=12.8.0 CUDNN_VERSION=9 FULL_CUDA=false DEVKIT_DRY_RUN=1 scripts/util_cuda_apt.sh dev)"
    cuda_runtime_pkgs="$(HAS_NVIDIA=true CUDA_VERSION=12.8.0 CUDNN_VERSION=9 FULL_CUDA=false DEVKIT_DRY_RUN=1 scripts/util_cuda_apt.sh runtime)"
    cuda_full_pkgs="$(HAS_NVIDIA=true CUDA_VERSION=12.8.0 CUDNN_VERSION=9 FULL_CUDA=true DEVKIT_DRY_RUN=1 scripts/util_cuda_apt.sh dev)"
    assert_words_present "$cuda_dev_pkgs" "Minimal CUDA dev package set" \
        cuda-nvcc-12-8 cuda-cudart-dev-12-8 cuda-nvtx-12-8 libcublas-dev-12-8 cuda-nvml-dev-12-8 libcudnn9-cuda-12 libcudnn9-dev-cuda-12 \
        || return 1
    assert_words_present "$cuda_runtime_pkgs" "CUDA runtime package set" \
        cuda-cudart-12-8 cuda-nvtx-12-8 libcublas-12-8 libcudnn9-cuda-12 \
        || return 1
    assert_words_present "$cuda_full_pkgs" "Full CUDA package set" cuda-12-8 libcudnn9-cuda-12 libcudnn9-dev-cuda-12 || return 1
    forbidden_cuda_dev_re='(^|[[:space:]])(cuda-[0-9]+-[0-9]+|cuda-visual-tools-[0-9]+-[0-9]+|cuda-command-line-tools-[0-9]+-[0-9]+|cuda-libraries-dev-[0-9]+-[0-9]+|cuda-compiler-[0-9]+-[0-9]+|nsight-[^[:space:]]+)([[:space:]]|$)'
    if printf '%s\n' "$cuda_dev_pkgs" | grep -E "$forbidden_cuda_dev_re" >/dev/null; then
        log_error "Minimal CUDA dev package set must not include full/visual/profiler metapackages: $cuda_dev_pkgs"
        return 1
    fi
    ! HAS_NVIDIA=maybe CUDA_VERSION=12.8.0 CUDNN_VERSION=9 FULL_CUDA=false DEVKIT_DRY_RUN=1 scripts/util_cuda_apt.sh runtime >/dev/null 2>&1
    ! HAS_NVIDIA=true CUDA_VERSION=12.8.0 CUDNN_VERSION=9 FULL_CUDA=maybe DEVKIT_DRY_RUN=1 scripts/util_cuda_apt.sh runtime >/dev/null 2>&1
    ! HAS_NVIDIA=true CUDA_VERSION=12.8.0 CUDNN_VERSION=9.1 FULL_CUDA=false DEVKIT_DRY_RUN=1 scripts/util_cuda_apt.sh runtime >/dev/null 2>&1
}

verify_cuda_apt_installed_marking() (
    local tmp_cuda fake_bin marked
    tmp_cuda="$(mktemp -d /tmp/devkit_cuda_apt.XXXXXX)"
    fake_bin="$tmp_cuda/bin"
    marked="$tmp_cuda/marked.txt"
    trap 'rm -rf "$tmp_cuda"' EXIT

    mkdir -p "$fake_bin"
    cat > "$fake_bin/apt-get" <<'EOF'
#!/bin/sh
exit 0
EOF
    cat > "$fake_bin/dpkg-query" <<'EOF'
#!/bin/sh
cat <<'PKGS'
ii  cuda-cudart-12-8
un  cuda-nvcc-12-8
rc  libcublas-12-8
ii  libnvidia-compute-999
ii  nsight-systems-12-8
PKGS
EOF
    cat > "$fake_bin/apt-mark" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > "$marked"
EOF
    cat > "$fake_bin/ldconfig" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$fake_bin/apt-get" "$fake_bin/dpkg-query" "$fake_bin/apt-mark" "$fake_bin/ldconfig"

    HAS_NVIDIA=true CUDA_VERSION=12.8.0 CUDNN_VERSION=9 FULL_CUDA=false PATH="$fake_bin:$PATH" \
        scripts/util_cuda_apt.sh runtime

    grep -q '^manual$' "$marked"
    grep -q '^cuda-cudart-12-8$' "$marked"
    grep -q '^nsight-systems-12-8$' "$marked"
    ! grep -q '^cuda-nvcc-12-8$' "$marked"
    ! grep -q '^libcublas-12-8$' "$marked"
    ! grep -q '^libnvidia-compute-999$' "$marked"
)

verify_gpu_setup_contract() {
    scripts/setup_gpu.sh --help >/dev/null
    ! scripts/setup_gpu.sh bogus >/dev/null 2>&1
    if grep -n "GPU setup encountered errors, continuing" docker/entrypoint.sh >/dev/null; then
        log_error "docker/entrypoint.sh must fail fast on GPU setup script errors instead of hiding them."
        return 1
    fi
}

verify_entrypoint_runtime_env_contract() {
    local required_env block
    block="$(awk '/runtime_env=\(/ { in_block = 1 } in_block { print } in_block && /exec sudo -E -u/ { exit }' docker/entrypoint.sh)"

    if ! grep -q 'exec setpriv --reuid "$user_uid" --regid "$user_gid" --init-groups env "${runtime_env\[@\]}" "$@"' docker/entrypoint.sh; then
        log_error "docker/entrypoint.sh privilege drop must use setpriv so the final user command, not sudo, becomes PID 1."
        return 1
    fi
    if ! grep -q 'exec sudo -E -u "${CONTAINER_USER}" env "${runtime_env\[@\]}" "$@"' docker/entrypoint.sh; then
        log_error "docker/entrypoint.sh must keep a sudo+env fallback that forwards the same runtime environment."
        return 1
    fi

    for required_env in \
        USER LOGNAME WORKSPACE_PATH LANG LC_ALL LANGUAGE VIRTUAL_ENV \
        DISPLAY WAYLAND_DISPLAY XAUTHORITY XDG_RUNTIME_DIR QT_X11_NO_MITSHM QT_QPA_PLATFORM GDK_BACKEND \
        SSH_AUTH_SOCK \
        ROS_DISTRO ROS_DOMAIN_ID RMW_IMPLEMENTATION ROS_MASTER_URI ROS_HOSTNAME ROS_IP \
        GPU_MODE NVIDIA_VISIBLE_DEVICES NVIDIA_DRIVER_CAPABILITIES \
        LD_LIBRARY_PATH PYTHONPATH
    do
        if ! grep -q "\"${required_env}=" <<< "$block"; then
            log_error "docker/entrypoint.sh privilege drop must explicitly forward ${required_env}."
            return 1
        fi
    done
}

verify_sif_helpers() (
    # shellcheck source=/dev/null
    source scripts/util_sif_runtime.sh

    [ "$(default_sif_file dev ros myproject latest)" = "myproject_ros_dev_latest.sif" ]
    [ "$(default_sif_file dev dev myproject latest true)" = "myproject_dev_dev-share_latest.sif" ]
    [ "$(default_sif_file prod ros myproject latest)" = "myproject_ros_prod_latest.sif" ]
    validate_sif_mode slurm
    ! validate_sif_mode test >/dev/null 2>&1
    sif_set_container_env DEVKIT_TEST_KEY value
    [ "$APPTAINERENV_DEVKIT_TEST_KEY" = "value" ]
    [ "$SINGULARITYENV_DEVKIT_TEST_KEY" = "value" ]
    DEVKIT_FORWARD_TEST=forwarded sif_forward_env_vars DEVKIT_FORWARD_TEST
    [ "$APPTAINERENV_DEVKIT_FORWARD_TEST" = "forwarded" ]
    [ "$SINGULARITYENV_DEVKIT_FORWARD_TEST" = "forwarded" ]
    ! sif_set_container_env "BAD-KEY" value >/dev/null 2>&1
    ! default_sif_file dev ros MyProject latest >/dev/null 2>&1
    ! default_sif_file dev ros _project latest >/dev/null 2>&1
    ! default_sif_file dev ros project- latest >/dev/null 2>&1
    ! default_sif_file dev ros myproject bad/tag >/dev/null 2>&1
    [ "$(normalize_sif_project_name __MyProject__)" = "myproject" ]

    (
        unset HOST_WORKSPACE_PATH CONTAINER_WORKSPACE_PATH HOST_SSH_AUTH_SOCK HAS_NVIDIA HAS_DRI IS_WSL APPTAINER_CACHEDIR SINGULARITY_CACHEDIR
        HOST_ROOT="$ROOT_DIR" WORKSPACE_PATH=/workspace apply_sif_detected_env_defaults
        [ "$HOST_WORKSPACE_PATH" = "$ROOT_DIR" ]
        [ "$CONTAINER_WORKSPACE_PATH" = "/workspace" ]
        [ "$HOST_SSH_AUTH_SOCK" = "" ]
        [ "$HAS_NVIDIA" = "false" ]
        [ "$HAS_DRI" = "false" ]
        [ "$IS_WSL" = "false" ]
    )
    (
        local tmp_sif_cache
        tmp_sif_cache="$(mktemp -d /tmp/devkit_sif_cache.XXXXXX)"
        trap 'rm -rf "$tmp_sif_cache"' EXIT
        HOST_ROOT="$ROOT_DIR" HOST_CACHE_DIR="$tmp_sif_cache/cache" configure_sif_cache_dirs
        [ "$APPTAINER_CACHEDIR" = "$tmp_sif_cache/cache/apptainer" ]
        [ "$SINGULARITY_CACHEDIR" = "$tmp_sif_cache/cache/singularity" ]
        [ -d "$APPTAINER_CACHEDIR" ]
        [ -d "$SINGULARITY_CACHEDIR" ]
    )

    HAS_NVIDIA=true get_sif_gpu_opts_into GPU_OPTS
    [ "${GPU_OPTS[*]}" = "--nv" ]
    HAS_NVIDIA=true get_sif_gpu_opts_into GPU_OPTS detected cpu
    [ "${GPU_OPTS[*]}" = "" ]
    ! get_sif_gpu_opts_into GPU_OPTS unknown >/dev/null 2>&1
    ! get_sif_gpu_opts_into GPU_OPTS detected bogus >/dev/null 2>&1
    HAS_NVIDIA=false get_sif_gpu_opts_into GPU_OPTS
    [ "${GPU_OPTS[*]}" = "" ]

    local err_file
    err_file="$(mktemp /tmp/devkit_sif_error.XXXXXX)"
    printf '%s\n' 'fuse: device not found' 'ERROR  : No setuid installation found' > "$err_file"
    explain_sif_runtime_failure "$err_file" 2>&1 | grep -q "DevKit hint"
    rm -f "$err_file"

    if [ ! -e /dev/fuse ]; then
        warn_sif_runtime_mount_constraints /usr/bin/singularity 2>&1 | grep -q "/dev/fuse is not available"
    fi
)

verify_sif_script_dry_runs() (
    local tmp_run_root bake_out prod_bake_out dev_run_out run_out slurm_submit_out slurm_job_out
    tmp_run_root="$(mktemp -d /tmp/devkit_sif_dryrun.XXXXXX)"
    trap 'rm -rf "$tmp_run_root"' EXIT

    bake_out="$tmp_run_root/bake.out"
    prod_bake_out="$tmp_run_root/prod-bake.out"
    dev_run_out="$tmp_run_root/dev-run.out"
    run_out="$tmp_run_root/run.out"
    slurm_submit_out="$tmp_run_root/slurm-submit.out"
    slurm_job_out="$tmp_run_root/slurm-job.out"

    DEVKIT_DRY_RUN=1 scripts/apptainer_bake.sh --mode dev --env ros --share > "$bake_out"
    grep -q "SIF image.*_ros_dev-share_" "$bake_out"
    grep -q "Docker build args" "$bake_out"
    grep -q "Dry-run completed; Docker and SIF build were not executed" "$bake_out"
    grep -q "docker-archive://" scripts/apptainer_bake.sh
    grep -q "docker save -o" scripts/apptainer_bake.sh
    ! DEVKIT_DRY_RUN=1 scripts/apptainer_bake.sh --mode prod --env ros --share >/dev/null 2>&1
    ! scripts/apptainer_bake.sh --mode >/dev/null 2>&1

    DEVKIT_DRY_RUN=1 INSTALL_INTEL_GPU_TOOLS=true scripts/apptainer_bake.sh --mode prod --env ros > "$prod_bake_out"
    grep -q "Target image.*prod-ros-runtime" "$prod_bake_out"
    grep -q "Docker image.*_ros_prod:" "$prod_bake_out"
    grep -q "INSTALL_INTEL_GPU_TOOLS=true" "$prod_bake_out"

    DEVKIT_DRY_RUN=1 scripts/apptainer_run.sh --mode dev --env ros > "$dev_run_out"
    grep -q "SIF Run Request" "$dev_run_out"
    grep -q "Container Env.*WORKSPACE_PATH=/workspace" "$dev_run_out"
    grep -q "Bind Options" "$dev_run_out"
    grep -q "/tmp/.container_xauth" "$dev_run_out"
    grep -q "/tmp/.container_xdg" "$dev_run_out"
    grep -q "WORKSPACE_PATH ENV COMPOSE_PROJECT_NAME" scripts/apptainer_run.sh
    grep -q "sif_forward_env_vars" scripts/slurm_run.sh
    grep -q "sif_set_container_env SSH_AUTH_SOCK" scripts/apptainer_run.sh
    GPU_MODE=cpu DEVKIT_DRY_RUN=1 scripts/apptainer_run.sh --mode dev --env ros > "$dev_run_out"
    ! grep -q -- "--nv" "$dev_run_out"

    DEVKIT_DRY_RUN=1 scripts/apptainer_run.sh --mode prod --env ros -- python3 -V > "$run_out"
    grep -q "SIF Run Request" "$run_out"
    grep -q "Project Root.*$ROOT_DIR" "$run_out"
    grep -q "Image Workspace.*embedded in production SIF" "$run_out"
    grep -q "Command.*python3 -V" "$run_out"
    grep -q "Dry-run completed; SIF runtime was not executed" "$run_out"
    ! DEVKIT_DRY_RUN=1 scripts/apptainer_run.sh --mode prod --env ros >/dev/null 2>&1
    ! scripts/apptainer_run.sh --env >/dev/null 2>&1

    (
        cd "$tmp_run_root"
        DEVKIT_DRY_RUN=1 APP_COMMAND="python3 -V" DEVKIT_SLURM_OUTPUT="-logs/%x_%j.out" DEVKIT_SLURM_ERROR="-logs/%x_%j.err" \
            HOST_WORKSPACE_PATH="$ROOT_DIR" \
            "$ROOT_DIR/scripts/apptainer_run.sh" --mode slurm --env ros > "$slurm_submit_out"
    )
    grep -q "SLURM Submission Request" "$slurm_submit_out"
    grep -q "Container Env.*WORKSPACE_PATH=/workspace" "$slurm_submit_out"
    grep -q -- "--chdir=$ROOT_DIR" "$slurm_submit_out"
    grep -q -- "--export=ALL" "$slurm_submit_out"
    grep -q "Project Root.*$ROOT_DIR" "$slurm_submit_out"
    grep -q "Image Workspace.*embedded in production SIF" "$slurm_submit_out"
    grep -q "Dry-run completed; sbatch was not executed" "$slurm_submit_out"
    [ -d "$tmp_run_root/-logs" ]
    ! DEVKIT_DRY_RUN=1 scripts/apptainer_run.sh --mode slurm --env ros >/dev/null 2>&1

    (
        cd "$tmp_run_root"
        DEVKIT_DRY_RUN=1 SIF_FILE=fake.sif HOST_WORKSPACE="$ROOT_DIR" WORKSPACE_PATH=/workspace "$ROOT_DIR/scripts/slurm_run.sh" python3 -V > "$slurm_job_out"
    )
    grep -q "SLURM Job Execution Summary" "$slurm_job_out"
    grep -q "Project Root.*$ROOT_DIR" "$slurm_job_out"
    grep -q "Image Workspace.*embedded in production SIF" "$slurm_job_out"
    grep -q "Dry-run completed; SIF runtime was not executed" "$slurm_job_out"
)

verify_apptainer_binds() (
    # shellcheck source=/dev/null
    source scripts/util_apptainer_binds.sh

    local tmp_bind_root
    tmp_bind_root="$(mktemp -d /tmp/devkit_binds.XXXXXX)"
    trap 'rm -rf "$tmp_bind_root"' EXIT

    touch "$tmp_bind_root/keep.py" "$tmp_bind_root/image.sif"
    mkdir -p "$tmp_bind_root/build" "$tmp_bind_root/.git" "$tmp_bind_root/.codex" "$tmp_bind_root/logs" "$tmp_bind_root/venv"
    get_apptainer_binds_into BIND_OPTS "$tmp_bind_root" /workspace
    [ "${BIND_OPTS[*]}" = "--bind $tmp_bind_root/keep.py:/workspace/keep.py" ]
    [[ "${BIND_OPTS[*]}" != *".git"* ]]
    [[ "${BIND_OPTS[*]}" != *".codex"* ]]
    [[ "${BIND_OPTS[*]}" != *"/logs"* ]]
    [[ "${BIND_OPTS[*]}" != *"/venv"* ]]
    ! get_apptainer_binds_into BIND_OPTS "$tmp_bind_root" workspace >/dev/null 2>&1
)

verify_alias_helpers() {
    # shellcheck source=/dev/null
    FORCE_LOAD_ALIASES=true WORKSPACE_PATH="$ROOT_DIR" source config/util_aliases.sh

    ! __remove_workspace_path "" >/dev/null 2>&1
    ! __remove_workspace_path /tmp >/dev/null 2>&1

    mkenv() { MKSYNC_MKENV_ARGS="$*"; }
    activate() { :; }
    __uvs_impl() { MKSYNC_UVS_ARGS="$*"; }
    __sync_deps_impl() { :; }
    __detect_project_type() { echo PYTHON; }

    mksync --share --extra gpu --locked >/dev/null
    [ "$MKSYNC_MKENV_ARGS" = "--share" ]
    [ "$MKSYNC_UVS_ARGS" = "--extra gpu --locked" ]

    MKSYNC_MKENV_ARGS="stale"
    MKSYNC_UVS_ARGS="stale"
    mksync >/dev/null
    [ "$MKSYNC_MKENV_ARGS" = "" ]
    [ "$MKSYNC_UVS_ARGS" = "" ]

    MKSYNC_MKENV_ARGS="stale"
    MKSYNC_UVS_ARGS="stale"
    ROS_DISTRO=noetic mksync >/dev/null
    [ "$MKSYNC_MKENV_ARGS" = "--share" ]
    [ "$MKSYNC_UVS_ARGS" = "" ]

    COMP_WORDS=(mksync --)
    COMP_CWORD=1
    __mksync_completion
    [[ " ${COMPREPLY[*]} " == *" --share "* ]]
    [[ " ${COMPREPLY[*]} " == *" --extra "* ]]
}

verify_setup_links() (
    local tmp_link_root
    tmp_link_root="$(mktemp -d /tmp/devkit_links.XXXXXX)"
    trap 'rm -rf "$tmp_link_root"' EXIT

    mkdir -p "$tmp_link_root/config" "$tmp_link_root/scripts" "$tmp_link_root/install/.venv" "$tmp_link_root/build/pkg"
    touch "$tmp_link_root/config/colcon.meta"
    cp scripts/util_setup_links.sh "$tmp_link_root/scripts/"
    cp config/util_paths.sh "$tmp_link_root/config/"
    cp scripts/util_logging.sh "$tmp_link_root/scripts/"

    printf '[{"directory":"%s","command":"cc -c a.c","file":"a.c"}]\n' "$tmp_link_root" > "$tmp_link_root/build/pkg/compile_commands.json"
    WORKSPACE_PATH="$tmp_link_root" "$tmp_link_root/scripts/util_setup_links.sh" >/dev/null
    [ -L "$tmp_link_root/colcon.meta" ]
    [ -L "$tmp_link_root/.venv" ]
    python3 -m json.tool "$tmp_link_root/compile_commands.json" >/dev/null

    printf 'not-json\n' > "$tmp_link_root/build/pkg/compile_commands.json"
    WORKSPACE_PATH="$tmp_link_root" "$tmp_link_root/scripts/util_setup_links.sh" > "$tmp_link_root/bad.out" 2> "$tmp_link_root/bad.err"
    grep -q "Failed to aggregate compile_commands.json" "$tmp_link_root/bad.err"
)

verify_sync_deps_rosdep_contract() (
    local tmp_sync_root fake_bin
    tmp_sync_root="$(mktemp -d /tmp/devkit_sync_deps.XXXXXX)"
    fake_bin="$tmp_sync_root/bin"
    trap 'rm -rf "$tmp_sync_root"' EXIT

    mkdir -p "$fake_bin" "$tmp_sync_root/dependencies/overlay" "$tmp_sync_root/src" "$tmp_sync_root/config" "$tmp_sync_root/scripts"
    cp config/util_paths.sh "$tmp_sync_root/config/"
    cp scripts/util_logging.sh "$tmp_sync_root/scripts/"

    cat > "$fake_bin/apt-get" <<'EOF'
#!/bin/sh
exit 0
EOF
    cat > "$fake_bin/sudo" <<'EOF'
#!/bin/sh
if [ "$1" = "-n" ]; then shift; fi
exec "$@"
EOF
    cat > "$fake_bin/rosdep" <<'EOF'
#!/bin/sh
case "$1" in
    install) exit 42 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$fake_bin/apt-get" "$fake_bin/sudo" "$fake_bin/rosdep"

    if WORKSPACE_PATH="$tmp_sync_root" PATH="$fake_bin:$PATH" ROS_DISTRO=humble scripts/setup_sync_deps.sh --rosdep > "$tmp_sync_root/fail.out" 2>&1; then
        log_error "setup_sync_deps.sh must fail when rosdep install fails."
        return 1
    fi
    grep -q "rosdep install failed" "$tmp_sync_root/fail.out"

    DEVKIT_ROSDEP_ALLOW_FAILURE=1 WORKSPACE_PATH="$tmp_sync_root" PATH="$fake_bin:$PATH" ROS_DISTRO=humble \
        scripts/setup_sync_deps.sh --rosdep > "$tmp_sync_root/allow.out" 2>&1
    grep -q "DEVKIT_ROSDEP_ALLOW_FAILURE=1" "$tmp_sync_root/allow.out"
)

verify_sync_deps_vcs_failure_contract() (
    local tmp_sync_root fake_bin
    tmp_sync_root="$(mktemp -d /tmp/devkit_sync_vcs.XXXXXX)"
    fake_bin="$tmp_sync_root/bin"
    trap 'rm -rf "$tmp_sync_root"' EXIT

    mkdir -p "$fake_bin" "$tmp_sync_root/dependencies/overlay" "$tmp_sync_root/src" "$tmp_sync_root/config" "$tmp_sync_root/scripts"
    cp config/util_paths.sh "$tmp_sync_root/config/"
    cp scripts/util_logging.sh "$tmp_sync_root/scripts/"
    touch "$tmp_sync_root/dependencies/dependencies.repos"

    cat > "$fake_bin/vcs" <<'EOF'
#!/bin/sh
case "$1" in
    import) exit 42 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$fake_bin/vcs"

    if WORKSPACE_PATH="$tmp_sync_root" PATH="$fake_bin:$PATH" scripts/setup_sync_deps.sh > "$tmp_sync_root/fail.out" 2>&1; then
        log_error "setup_sync_deps.sh must fail when vcs import fails."
        return 1
    fi
    grep -q "vcs import failed" "$tmp_sync_root/fail.out"

    DEVKIT_VCS_ALLOW_FAILURE=1 WORKSPACE_PATH="$tmp_sync_root" PATH="$fake_bin:$PATH" \
        scripts/setup_sync_deps.sh > "$tmp_sync_root/allow.out" 2>&1
    grep -q "DEVKIT_VCS_ALLOW_FAILURE=1" "$tmp_sync_root/allow.out"
)

verify_sync_deps_force_contract() (
    local tmp_sync_root fake_bin repo_dir
    tmp_sync_root="$(mktemp -d /tmp/devkit_sync_force.XXXXXX)"
    fake_bin="$tmp_sync_root/bin"
    repo_dir="$tmp_sync_root/src/thirdparty/pkg"
    trap 'rm -rf "$tmp_sync_root"' EXIT

    mkdir -p "$fake_bin" "$tmp_sync_root/dependencies/overlay" "$tmp_sync_root/src/thirdparty" "$tmp_sync_root/config" "$tmp_sync_root/scripts"
    cp config/util_paths.sh "$tmp_sync_root/config/"
    cp scripts/util_logging.sh "$tmp_sync_root/scripts/"
    touch "$tmp_sync_root/dependencies/dependencies.repos"
    printf '%s\n' overlay > "$tmp_sync_root/dependencies/overlay/-overlay-file"

    cat > "$fake_bin/vcs" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$fake_bin/vcs"

    git init -q "$repo_dir"
    (
        cd "$repo_dir"
        git config user.email devkit@example.invalid
        git config user.name DevKit
        printf '%s\n' tracked > tracked.txt
        printf '%s\n' '*.cache' > .gitignore
        git add tracked.txt .gitignore
        git commit -q -m init
        printf '%s\n' modified > tracked.txt
        printf '%s\n' ignored > build.cache
        printf '%s\n' untracked > scratch.txt
    )

    WORKSPACE_PATH="$tmp_sync_root" PATH="$fake_bin:$PATH" scripts/setup_sync_deps.sh --force > "$tmp_sync_root/force.out" 2>&1

    [ "$(cat "$repo_dir/tracked.txt")" = "tracked" ]
    [ ! -e "$repo_dir/build.cache" ]
    [ ! -e "$repo_dir/scratch.txt" ]
    [ "$(cat "$tmp_sync_root/src/thirdparty/-overlay-file")" = "overlay" ]
)

verify_release_metadata() (
    local tmp_release_root
    tmp_release_root="$(mktemp -d /tmp/devkit_release.XXXXXX)"
    trap 'rm -rf "$tmp_release_root"' EXIT

    SOURCE_DATE_EPOCH=0 ROS_DISTRO="${ROS_DISTRO:-humble}" WORKSPACE_PATH="$tmp_release_root" scripts/util_release_metadata.sh "$tmp_release_root/release.json"
    python3 -m json.tool "$tmp_release_root/release.json" >/dev/null
    DEVKIT_RELEASE_JSON="$tmp_release_root/release.json" \
        python3 -c 'import json, os; data=json.load(open(os.environ["DEVKIT_RELEASE_JSON"], encoding="utf-8")); assert data["build_date"] == "1970-01-01T00:00:00Z"'
)

verify_pyproject_readme() {
    local pyproject_readme
    pyproject_readme="$(awk -F= '/^[[:space:]]*readme[[:space:]]*=/ { value=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); gsub(/^"|"$/, "", value); gsub(/^'\''|'\''$/, "", value); print value; exit }' src/pyproject.toml)"
    if [ -n "$pyproject_readme" ] && [ ! -e "src/$pyproject_readme" ]; then
        log_error "pyproject readme does not exist: src/$pyproject_readme"
        return 1
    fi
}

verify_prod_entrypoint_contract() (
    local missing_out output tmp_prod_root
    tmp_prod_root="$(mktemp -d /tmp/devkit_prod_entrypoint.XXXXXX)"
    trap 'rm -rf "$tmp_prod_root"' EXIT
    missing_out="$tmp_prod_root/missing.out"

    mkdir -p "$tmp_prod_root/install/.venv/bin" "$tmp_prod_root/install/bin"

    output="$(cd /tmp && WORKSPACE_PATH="$tmp_prod_root" APP_COMMAND='printf "%s|%s|%s" "$PWD" "$WORKSPACE_PATH" "$VIRTUAL_ENV"' "$ROOT_DIR/docker/prod_entrypoint.sh")"
    [ "$output" = "$tmp_prod_root|$tmp_prod_root|$tmp_prod_root/install/.venv" ]

    output="$(cd /tmp && WORKSPACE_PATH="$tmp_prod_root" "$ROOT_DIR/docker/prod_entrypoint.sh" bash -lc 'printf "%s|%s" "$PWD" "$WORKSPACE_PATH"')"
    [ "$output" = "$tmp_prod_root|$tmp_prod_root" ]

    if WORKSPACE_PATH="$tmp_prod_root/missing" "$ROOT_DIR/docker/prod_entrypoint.sh" >"$missing_out" 2>&1; then
        log_error "prod_entrypoint must fail when WORKSPACE_PATH does not exist."
        return 1
    fi
    grep -q "Workspace path does not exist" "$missing_out"
)

verify_verify_repo_hygiene() {
    local fixed_tmp_pattern="/tmp/devkit_prod_entrypoint""_missing.out"

    if grep -q "$fixed_tmp_pattern" scripts/verify_repo.sh; then
        log_error "verify_repo.sh must not use fixed /tmp output files; place temporary outputs under mktemp-owned directories."
        return 1
    fi
    if ! grep -q '^verify_sif_helpers() ($' scripts/verify_repo.sh; then
        log_error "verify_sif_helpers must run in a subshell so APPTAINERENV/SINGULARITYENV test exports cannot leak into later checks."
        return 1
    fi
}

main() {
    require_files \
        docker/Dockerfile \
        docker-compose.dev.yml \
        config/devkit_make_completion.bash \
        scripts/util_apt_helper.sh \
        scripts/util_cuda_apt.sh \
        scripts/util_release_metadata.sh \
        scripts/verify_repo.sh \
        docker/prod_entrypoint.sh

    require_executables \
        scripts/util_apt_helper.sh \
        scripts/util_cuda_apt.sh \
        scripts/util_release_metadata.sh \
        scripts/verify_repo.sh \
        docker/prod_entrypoint.sh

    bash -n scripts/*.sh config/*.sh config/*.bash docker/*.sh
    verify_make_help
    verify_vscode_json_defaults
    verify_make_completion_ssot
    verify_docs_cache_safety
    verify_env_example_unique_active_keys
    verify_make_validations
    verify_make_xauth_feedback
    verify_env_detector_cache_safety
    verify_make_detector_failure_is_fatal
    verify_make_detector_cache_atomic
    verify_compose_dependency_sync_env
    verify_logging_env_contract
    verify_compose_runtime_defaults
    verify_compose_gpu_build_args
    verify_cmake_standard_contract
    verify_strict_gpg_build_arg_contract
    verify_dockerfile_bind_cleanup
    verify_dockerfile_package_policy
    verify_dependency_file_syntax
    verify_docker_static

    if [ -f .env ]; then
        make --no-print-directory env-check
    else
        log_warn ".env not found; skipping env-check."
    fi

    verify_apt_cuda_helpers
    verify_cuda_apt_installed_marking
    verify_gpu_setup_contract
    verify_entrypoint_runtime_env_contract
    verify_sif_helpers
    verify_sif_script_dry_runs
    verify_apptainer_binds
    verify_alias_helpers
    verify_setup_links
    verify_sync_deps_rosdep_contract
    verify_sync_deps_vcs_failure_contract
    verify_sync_deps_force_contract
    verify_release_metadata
    verify_pyproject_readme
    verify_prod_entrypoint_contract
    verify_verify_repo_hygiene

    log_ok "Repository validation checks passed."
}

main "$@"
