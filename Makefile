# =============================================================================
# Makefile
# Unified Workflow Orchestration (KISS-based Command Integration)
# =============================================================================

SHELL := /bin/bash

# Colors and Logging Definitions
BLUE   := \033[0;34m
GREEN  := \033[0;32m
RED    := \033[0;31m
YELLOW := \033[1;33m
CYAN   := \033[0;36m
NC     := \033[0m
INFO   := $(CYAN)[INFO]$(NC)
OK     := $(GREEN)[OK]$(NC)
WARN   := $(YELLOW)[WARN]$(NC)
ERROR  := $(RED)[ERROR]$(NC)

# Load Environment Variables
USER_GPU_MODE := $(shell printf '%s' "$$GPU_MODE")
-include .env
ifneq ($(strip $(USER_GPU_MODE)),)
GPU_MODE := $(USER_GPU_MODE)
endif

# Workspace Path Architecture (Separation of Host and Container)
# HOST_WORKSPACE_PATH: Physical path on the host machine (Source)
# WORKSPACE_PATH: Logical path inside the container (Target/SSOT)
HOST_WORKSPACE_PATH ?= $(CURDIR)
WORKSPACE_PATH      ?= /workspace

# Fallback cache path for targets that skip the env detector (e.g. clean%),
# mirroring scripts/check_env.sh. The detector's -include overrides this when it runs.
HOST_CACHE_DIR      ?= $(if $(DOCKER_DEV_CACHE_DIR),$(DOCKER_DEV_CACHE_DIR),$(HOST_WORKSPACE_PATH)/.docker_cache)

# Auto-match TARGETARCH
TARGETARCH ?= $(HOST_ARCH)

export

# Environment Detection Engine (Auto-detection — triggered by relevant targets)
# Applied to Docker-related operations to ensure hardware and display compatibility
# Pure teardown/cleanup/log targets need only .env (COMPOSE_PROJECT_NAME) + compose,
# not host GPU/display detection — exclude them so they don't pay the docker-info/
# nvidia-smi cost. (stop/restart/status keep detection: they resolve the GPU-variant
# service via DETECT_MODE.)
# INVARIANT: targets excluded here never see detector-emitted vars (HOST_CACHE_DIR,
# HOST_XAUTHORITY, HAS_*, etc.) — those expand empty. Only reference such vars through a
# non-detector source: a parse-time `?=` default (see HOST_CACHE_DIR below), an `-include
# .env` value, a `$(MAKE)` sub-target that re-runs detection (see setup -> xauth), or a
# `[ -n ... ]` guard (see VALIDATE_HOST_INTEGRATION_PATHS). verify_repo.sh guards the
# HOST_CACHE_DIR case (verify_make_detector_excluded_cache_default).
NEEDS_DETECTOR := $(filter-out help setup env-check% verify down logs clean% docker-clean,$(MAKECMDGOALS))
ifneq ($(NEEDS_DETECTOR),)
DETECTED_ENV_FILE := .docker_cache/detected-env.mk
$(shell mkdir -p .docker_cache && tmp=$$(mktemp "$(DETECTED_ENV_FILE).XXXXXX") && { bash scripts/check_env.sh --makefile > "$$tmp" && mv "$$tmp" "$(DETECTED_ENV_FILE)" || { rm -f "$$tmp"; printf '%s\n' '$$(error Environment detection failed. Run scripts/check_env.sh for details.)' > "$(DETECTED_ENV_FILE)"; }; })
-include $(DETECTED_ENV_FILE)
endif

COMPOSE := docker compose
COMPOSE_DEV := -f docker-compose.dev.yml
TERMINAL ?= terminator
ENV ?= ros
SIF_MODE ?= dev
truthy = $(filter 1 true yes on,$(shell printf '%s' '$(strip $1)' | tr '[:upper:]' '[:lower:]'))

SERVICE_PREFIX := $(if $(filter ros,$(ENV)),ros,$(if $(filter dev,$(ENV)),basic,))
SERVICE_LABEL := $(if $(filter ros,$(ENV)),ROS Development,$(if $(filter dev,$(ENV)),Pure Development,))
SERVICE_FILTER := ^$(SERVICE_PREFIX)-(cpu|igpu|nvidia)$$
FIND_CONTAINER = docker ps --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)" --format '{{.Names}}\t{{.Label "com.docker.compose.service"}}' | awk -F '\t' '$$2 ~ /$1/ {print $$1; exit}'

# Macros (Deduplication & SSOT)
# Integrated GPU Mode Detection Logic
DETECT_MODE := \
	CHOSEN_MODE=$(GPU_MODE); \
	case "$$CHOSEN_MODE" in \
		""|auto|cpu|igpu|intel|amd|nvidia) ;; \
		*) echo -e "  $(ERROR) GPU_MODE must be auto, cpu, igpu, intel, amd, or nvidia (current: $$CHOSEN_MODE)."; exit 1 ;; \
	esac; \
	if [ -z "$$CHOSEN_MODE" ] || [ "$$CHOSEN_MODE" = "auto" ]; then \
		if [ "$(HAS_NVIDIA)" = "true" ] && [ "$(HAS_TOOLKIT)" = "true" ]; then CHOSEN_MODE=nvidia; \
		elif [ "$(HAS_DRI)" = "true" ]; then CHOSEN_MODE=igpu; \
		else CHOSEN_MODE=cpu; fi; \
	elif [ "$$CHOSEN_MODE" = "intel" ] || [ "$$CHOSEN_MODE" = "amd" ]; then \
		CHOSEN_MODE=igpu; \
	fi;

# $1: COMPOSE_FILES, $2: SERVICE_PREFIX, $3: MSG
define RUN_SERVICE
	@$(DETECT_MODE) \
	PROF=$$CHOSEN_MODE; \
	TARGET_SVC=$2-$$CHOSEN_MODE; \
	echo -e "  $(INFO) [$$CHOSEN_MODE] Starting $3 environment (Service: $$TARGET_SVC)..."; \
	$(COMPOSE) $1 --profile $$TARGET_SVC up -d $$TARGET_SVC
endef

# $1: COMPOSE_FILES, $2: SERVICE_PREFIX, $3: MSG
define STOP_SERVICE
	@$(DETECT_MODE) \
	PROF=$$CHOSEN_MODE; \
	TARGET_SVC=$2-$$CHOSEN_MODE; \
	echo -e "  $(INFO) [$$CHOSEN_MODE] Stopping $3 environment (Service: $$TARGET_SVC)..."; \
	$(COMPOSE) $1 --profile $$TARGET_SVC stop $$TARGET_SVC
endef

define VALIDATE_ROS_ENV
	@if [ -n "$(ROS_DOMAIN_ID)" ]; then \
		if ! [ "$(ROS_DOMAIN_ID)" -eq "$(ROS_DOMAIN_ID)" ] 2>/dev/null || [ "$(ROS_DOMAIN_ID)" -lt 0 ] || [ "$(ROS_DOMAIN_ID)" -gt 101 ]; then \
			echo -e "  $(ERROR) ROS_DOMAIN_ID must be a number between 0 and 101 (Current: $(ROS_DOMAIN_ID))"; \
			exit 1; \
		fi \
	fi
	@if [ -n "$(RMW_IMPLEMENTATION)" ] && [ "$(RMW_IMPLEMENTATION)" != "rmw_cyclonedds_cpp" ] && [ "$(RMW_IMPLEMENTATION)" != "rmw_fastrtps_cpp" ]; then \
		echo -e "  $(WARN) Non-standard RMW_IMPLEMENTATION detected: $(RMW_IMPLEMENTATION)"; \
	fi
endef

define VALIDATE_COMPOSE_NAME
	@if [[ ! "$(COMPOSE_PROJECT_NAME)" =~ ^[a-z0-9]([a-z0-9_-]*[a-z0-9])?$$ ]]; then \
		echo -e "  $(ERROR) COMPOSE_PROJECT_NAME must start and end with a lowercase letter or digit, using only lowercase letters, digits, dashes (-), or underscores (_)."; \
		exit 1; \
	fi
endef

define VALIDATE_IMAGE_TAG
	@if [[ ! "$(IMAGE_TAG)" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$$ ]]; then \
		echo -e "  $(ERROR) IMAGE_TAG must be a valid Docker tag (start with alnum/_; use alnum, _, ., -; max 128 chars)."; \
		exit 1; \
	fi
endef

define VALIDATE_ROS_DISTRO
	@if [ "$(ROS_DISTRO)" != "humble" ] && [ "$(ROS_DISTRO)" != "noetic" ]; then \
		echo -e "  $(ERROR) ROS_DISTRO must be 'humble' or 'noetic' (current: $(ROS_DISTRO))."; \
		exit 1; \
	fi
endef

define VALIDATE_ROS_BASE_IMAGE
	@case "$(BASE_IMAGE)" in \
		"") \
			echo -e "  $(ERROR) BASE_IMAGE must not be empty."; \
			exit 1 ;; \
		*[[:space:]]*) \
			echo -e "  $(ERROR) BASE_IMAGE must not contain whitespace (current: $(BASE_IMAGE))."; \
			exit 1 ;; \
		ubuntu:22.04|ubuntu:22.04@*) \
			if [ "$(ROS_DISTRO)" != "humble" ]; then \
				echo -e "  $(ERROR) BASE_IMAGE=ubuntu:22.04 must be paired with ROS_DISTRO=humble (current: $(ROS_DISTRO))."; \
				exit 1; \
			fi ;; \
		ubuntu:20.04|ubuntu:20.04@*) \
			if [ "$(ROS_DISTRO)" != "noetic" ]; then \
				echo -e "  $(ERROR) BASE_IMAGE=ubuntu:20.04 must be paired with ROS_DISTRO=noetic (current: $(ROS_DISTRO))."; \
				exit 1; \
			fi ;; \
		ubuntu:*) \
			echo -e "  $(ERROR) Official Ubuntu BASE_IMAGE must be ubuntu:22.04 for ROS_DISTRO=humble or ubuntu:20.04 for ROS_DISTRO=noetic (current: $(BASE_IMAGE))."; \
			exit 1 ;; \
	esac
endef

define VALIDATE_WORKSPACE_PATHS
	@if [ -z "$(HOST_WORKSPACE_PATH)" ] || [ "$(HOST_WORKSPACE_PATH)" = "/" ] || [[ "$(HOST_WORKSPACE_PATH)" != /* ]]; then \
		echo -e "  $(ERROR) HOST_WORKSPACE_PATH must be an absolute non-root path (current: $(HOST_WORKSPACE_PATH))."; \
		exit 1; \
	fi
	@if [ -z "$(WORKSPACE_PATH)" ] || [ "$(WORKSPACE_PATH)" = "/" ] || [[ "$(WORKSPACE_PATH)" != /* ]]; then \
		echo -e "  $(ERROR) WORKSPACE_PATH must be an absolute non-root path inside the container (current: $(WORKSPACE_PATH))."; \
		exit 1; \
	fi
endef

define VALIDATE_TARGETARCH
	@if [ -n "$(TARGETARCH)" ] && [ "$(TARGETARCH)" != "amd64" ] && [ "$(TARGETARCH)" != "arm64" ]; then \
		echo -e "  $(ERROR) TARGETARCH must be 'amd64' or 'arm64' (current: $(TARGETARCH))."; \
		exit 1; \
	fi
endef

define VALIDATE_C_STANDARDS
	@if [ -n "$(CMAKE_C_STANDARD)" ] && [ "$(CMAKE_C_STANDARD)" != "11" ] && [ "$(CMAKE_C_STANDARD)" != "17" ]; then \
		echo -e "  $(ERROR) CMAKE_C_STANDARD must be '11' or '17' (current: $(CMAKE_C_STANDARD))."; \
		exit 1; \
	fi
	@if [ -n "$(CMAKE_CXX_STANDARD)" ] && [ "$(CMAKE_CXX_STANDARD)" != "17" ] && [ "$(CMAKE_CXX_STANDARD)" != "20" ]; then \
		echo -e "  $(ERROR) CMAKE_CXX_STANDARD must be '17' or '20' (current: $(CMAKE_CXX_STANDARD))."; \
		exit 1; \
	fi
endef

define VALIDATE_OPENCV_CUDA
	@if [ "$(OPENCV_CUDA)" != "auto" ] && [ "$(OPENCV_CUDA)" != "off" ]; then \
		echo -e "  $(ERROR) OPENCV_CUDA must be 'auto' or 'off' (current: $(OPENCV_CUDA))."; \
		exit 1; \
	fi
endef

define VALIDATE_COMPOSE_RUNTIME
	@if [ -n "$(NETWORK_MODE)" ] && [ "$(NETWORK_MODE)" != "host" ] && [ "$(NETWORK_MODE)" != "bridge" ] && [ "$(NETWORK_MODE)" != "none" ]; then \
		echo -e "  $(ERROR) NETWORK_MODE must be 'host', 'bridge', or 'none' (current: $(NETWORK_MODE))."; \
		exit 1; \
	fi
	@if [ -n "$(IPC_MODE)" ] && [ "$(IPC_MODE)" != "host" ] && [ "$(IPC_MODE)" != "private" ] && [ "$(IPC_MODE)" != "shareable" ] && [ "$(IPC_MODE)" != "none" ]; then \
		echo -e "  $(ERROR) IPC_MODE must be 'host', 'private', 'shareable', or 'none' (current: $(IPC_MODE))."; \
		exit 1; \
	fi
	@if [ -n "$(PRIVILEGED)" ] && [ "$(PRIVILEGED)" != "true" ] && [ "$(PRIVILEGED)" != "false" ]; then \
		echo -e "  $(ERROR) PRIVILEGED must be 'true' or 'false' (current: $(PRIVILEGED))."; \
		exit 1; \
	fi
	@if [ -n "$(ULIMIT_NOFILE)" ] && { ! [[ "$(ULIMIT_NOFILE)" =~ ^[0-9]+$$ ]] || [ "$(ULIMIT_NOFILE)" -lt 1 ]; }; then \
		echo -e "  $(ERROR) ULIMIT_NOFILE must be a positive integer (current: $(ULIMIT_NOFILE))."; \
		exit 1; \
	fi
endef

define VALIDATE_HOST_INTEGRATION_PATHS
	@if [ -n "$(GIT_CONFIG_PATH)" ] && [ "$(GIT_CONFIG_PATH)" != "/dev/null" ] && [ ! -f "$(GIT_CONFIG_PATH)" ]; then \
		echo -e "  $(ERROR) GIT_CONFIG_PATH must point to an existing git config file (current: $(GIT_CONFIG_PATH))."; \
		exit 1; \
	fi
	@if [ -n "$(HOST_XAUTHORITY)" ] && [ ! -f "$(HOST_XAUTHORITY)" ]; then \
		echo -e "  $(ERROR) HOST_XAUTHORITY must point to an existing Xauthority file (current: $(HOST_XAUTHORITY))."; \
		exit 1; \
	fi
	@if [ -n "$(HOST_XDG_RUNTIME_DIR)" ] && [ ! -d "$(HOST_XDG_RUNTIME_DIR)" ]; then \
		echo -e "  $(ERROR) HOST_XDG_RUNTIME_DIR must point to an existing runtime directory (current: $(HOST_XDG_RUNTIME_DIR))."; \
		exit 1; \
	fi
	@if [ -n "$(HOST_X11_DIR)" ] && [ ! -d "$(HOST_X11_DIR)" ]; then \
		echo -e "  $(ERROR) HOST_X11_DIR must point to an existing X11 socket directory (current: $(HOST_X11_DIR))."; \
		exit 1; \
	fi
	@if [ -n "$(HOST_SSH_AUTH_SOCK)" ] && [ "$(HOST_SSH_AUTH_SOCK)" != "/dev/null" ] && [ ! -S "$(HOST_SSH_AUTH_SOCK)" ]; then \
		echo -e "  $(ERROR) HOST_SSH_AUTH_SOCK must point to an existing SSH agent UNIX socket (current: $(HOST_SSH_AUTH_SOCK))."; \
		exit 1; \
	fi
endef

define VALIDATE_PROJECT_CONFIG
	$(call VALIDATE_WORKSPACE_PATHS)
	$(call VALIDATE_HOST_INTEGRATION_PATHS)
	$(call VALIDATE_COMPOSE_NAME)
	$(call VALIDATE_IMAGE_TAG)
	$(call VALIDATE_ROS_DISTRO)
	$(call VALIDATE_ROS_BASE_IMAGE)
	$(call VALIDATE_TARGETARCH)
	$(call VALIDATE_C_STANDARDS)
	$(call VALIDATE_OPENCV_CUDA)
	$(call VALIDATE_COMPOSE_RUNTIME)
	$(call VALIDATE_ROS_ENV)
endef

define REQUIRE_ENV_FILE
	@if [ ! -f .env ]; then echo -e "  $(ERROR) .env not found. Please run 'make setup' first."; exit 1; fi
endef

define REQUIRE_HOST_WORKSPACE_DIR
	@if [ ! -d "$(HOST_WORKSPACE_PATH)" ]; then echo -e "  $(ERROR) HOST_WORKSPACE_PATH ($(HOST_WORKSPACE_PATH)) does not exist."; exit 1; fi
endef

# Reusable helper: run a command, capture stdout/stderr to temp files, display
# the output on success or a warning with stderr on failure, then clean up.
# $1: temp file prefix, $2: command to run, $3: warning message on failure
COMMA := ,
define DOCKER_QUERY
	@OUT=$$(mktemp /tmp/devkit_$(1).out.XXXXXX); ERR=$$(mktemp /tmp/devkit_$(1).err.XXXXXX); \
	if $(2) >"$$OUT" 2>"$$ERR"; then \
		sed 's/^/  /' "$$OUT"; \
	else \
		echo -e "  $(WARN) $(3)"; \
		sed 's/^/  /' "$$ERR"; \
	fi; \
	rm -f "$$OUT" "$$ERR"
endef

define VALIDATE_ENV_FILE_VALUES
	@awk -F= '\
		$$1 == "COMPOSE_PROJECT_NAME" || $$1 == "IMAGE_TAG" { \
			key=$$1; value=$$2; \
			gsub(/^[[:space:]]+|[[:space:]]+$$/, "", value); \
			gsub(/^"|"$$/, "", value); \
			gsub(/^'\''|'\''$$/, "", value); \
			values[key]=value; \
		} \
		END { \
			if (values["COMPOSE_PROJECT_NAME"] !~ /^[a-z0-9]([a-z0-9_-]*[a-z0-9])?$$/) { \
				print "  $(ERROR) COMPOSE_PROJECT_NAME must start and end with a lowercase letter or digit, using only lowercase letters, digits, dashes (-), or underscores (_)."; \
				exit 1; \
			} \
			if (values["IMAGE_TAG"] !~ /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$$/) { \
				print "  $(ERROR) IMAGE_TAG must be a valid Docker tag (start with alnum/_; use alnum, _, ., -; max 128 chars)."; \
				exit 1; \
			} \
		}' .env
endef

define VALIDATE_ENV_MODE
	@if [ "$(ENV)" != "ros" ] && [ "$(ENV)" != "dev" ]; then \
		echo -e "  $(ERROR) ENV must be 'ros' or 'dev' (current: $(ENV))."; \
		exit 1; \
	fi
endef

define VALIDATE_SIF_MODE
	@if [ "$(SIF_MODE)" != "dev" ] && [ "$(SIF_MODE)" != "prod" ] && [ "$(SIF_MODE)" != "slurm" ]; then \
		echo -e "  $(ERROR) SIF_MODE must be 'dev', 'prod', or 'slurm' (current: $(SIF_MODE))."; \
		exit 1; \
	fi
endef

define CHECK_SIF_READY
	$(call GUARD_HOST_ONLY)
	$(call REQUIRE_ENV_FILE)
	$(call VALIDATE_PROJECT_CONFIG)
	$(call REQUIRE_HOST_WORKSPACE_DIR)
endef

# $1: FILTER, $2: COMMAND, $3: MSG (For error display)
define EXEC_CONTAINER
	@CONTAINER=$$($(call FIND_CONTAINER,$1)); \
	if [ -n "$$CONTAINER" ]; then \
		docker exec -it -u $(CONTAINER_USER) $$CONTAINER $2 || [ $$? -eq 130 ]; \
	else \
		echo -e "  $(ERROR) No running container found for $3."; \
		exit 1; \
	fi
endef

# $1: FILTER, $2: COMMAND, $3: MSG (For error display)
define EXEC_DETACHED
	@CONTAINER=$$($(call FIND_CONTAINER,$1)); \
	if [ -n "$$CONTAINER" ]; then \
		docker exec -d -u $(CONTAINER_USER) $$CONTAINER $2; \
	else \
		echo "  [ERROR] No running container found for $3."; \
		exit 1; \
	fi
endef

# $1: COMPOSE_FILES, $2: SERVICE_PREFIX, $3: MSG, $4: EXTRA_ARGS, $5: HINT_MSG
define BUILD_SERVICE
	@$(DETECT_MODE) \
	TARGET_SVC=$2-$$CHOSEN_MODE; \
	echo -e "  $(INFO) Building image for [$3] (Service: $$TARGET_SVC)..."; \
	$(COMPOSE) $1 build $4 $$TARGET_SVC
	@echo -e "\n  $(INFO) [Hint] $5"
endef

# $1: EXTRA_ARGS (e.g. -v for volumes)
define TEARDOWN_SERVICES
	$(COMPOSE) $(COMPOSE_DEV) --profile "*" down $1 --remove-orphans
endef

# $1: MOUNT_DIR (Absolute Path), $2: Targets to delete
define SUDO_FREE_RM
	if [ "$1" = "/" ] || [ -z "$1" ]; then \
		echo -e "  $(ERROR) Critical Safety: Refusing to delete from root directory!"; \
		exit 1; \
	fi; \
	if [ ! -d "$1" ]; then \
		echo -e "  $(ERROR) Refusing to clean missing directory: $1"; \
		exit 1; \
	fi; \
	echo -e "  $(INFO) Performing sudo-free deletion: $2 in $1"; \
	docker run --rm -v "$1:/mnt" alpine sh -c 'cd /mnt || exit 1; for target do rm -rf -- "$$target"; done' sh $2; \
	if [ "$(SKIP_ALPINE_RM)" != "1" ]; then \
		$(call CLEAN_ALPINE_IMAGE); \
	fi
endef

define CLEAN_ALPINE_IMAGE
	echo -e "  $(INFO) Cleaning up the temporary alpine image used for sudo-free deletion..."; \
	docker rmi alpine:latest 2>/dev/null || true
endef

# Core Infrastructure Variables Export
CONTAINER_USER ?= user
HOST_UID ?= $(shell id -u 2>/dev/null || echo 1000)
HOST_GID ?= $(shell id -g 2>/dev/null || echo 1000)
export IS_WSL HOST_DXG_MOUNT HOST_ARCH HAS_NVIDIA HAS_TOOLKIT HAS_DRI HOST_DRI_MOUNT TARGETARCH DISPLAY_TYPE HOST_XDG_RUNTIME_DIR HOST_WAYLAND_DISPLAY HOST_XAUTHORITY HOST_HOME NVIDIA_VISIBLE_DEVICES NVIDIA_DRIVER_CAPABILITIES NVIDIA_GPU_COUNT HOST_CACHE_DIR HOST_X11_DIR HOST_GITCONFIG HOST_SSH_AUTH_SOCK WSL_LIB_DIR_MOUNT CUDA_VERSION CUDNN_VERSION PYTHON_EXECUTABLE HOST_UID HOST_GID CONTAINER_USER

# Centralized UI Sub-Header Macro
define PRINT_SECTION
	@bash -c "source scripts/util_logging.sh && print_section \"$1\""
endef

.PHONY: h help completion completion-install setup check check-host xauth status verify \
        build start stop restart shell term \
		bake-dev bake-prod run-sif slurm-status slurm-cancel \
		update-gpg stats top logs down clean clean-cache clean-all docker-clean env-check

h: help

# =============================================================================
# Infrastructure Logic
# =============================================================================
IS_CONTAINER := $(shell [ -f /.dockerenv ] && echo true || echo false)

define GUARD_HOST_ONLY
	@if [ "$(IS_CONTAINER)" = "true" ]; then \
		echo -e "  ${RED}[ERROR]${NC} This command must be run on the HOST, not inside the container."; \
		echo -e "  ${CYAN}[Hint]${NC} Use container aliases. (type ${YELLOW}h${NC} or ${YELLOW}help${NC})"; \
		exit 1; \
	fi
endef

# =============================================================================
# Help
# =============================================================================

help:
	@if [ "$(IS_CONTAINER)" = "true" ]; then \
		bash -c "source scripts/util_logging.sh && print_banner GUIDE && echo -e \"\n  ${YELLOW}Notice:${NC} You are INSIDE the container.\n  Please use aliases (type ${GREEN}h${NC} or ${GREEN}help${NC}) instead of make commands.\n\""; \
	else \
		bash scripts/util_make_help.sh Makefile; \
	fi

completion:
	@cat config/devkit_make_completion.bash

completion-install:
	$(call GUARD_HOST_ONLY)
	@set -e; \
	COMPLETION_DIR="$${HOME}/.bash_completion.d"; \
	COMPLETION_FILE="$$COMPLETION_DIR/devkit_make_completion.bash"; \
	BASH_COMPLETION_FILE="$${HOME}/.bash_completion"; \
	mkdir -p "$$COMPLETION_DIR"; \
	cp config/devkit_make_completion.bash "$$COMPLETION_FILE"; \
	touch "$$BASH_COMPLETION_FILE"; \
	if ! grep -Fq "$$COMPLETION_FILE" "$$BASH_COMPLETION_FILE"; then \
		{ \
			echo ""; \
			echo "# DevKit make completion"; \
			echo "[ -f \"$$COMPLETION_FILE\" ] && source \"$$COMPLETION_FILE\""; \
		} >> "$$BASH_COMPLETION_FILE"; \
	fi; \
	echo -e "  $(OK) Installed DevKit make completion for new Bash sessions."; \
	echo -e "  $(INFO) Open a new terminal, or run: source ~/.bash_completion"

# =============================================================================
# Initial Setup and Status Check
# =============================================================================

## @arg ENV=ros|dev | Docker/SIF family selector (default: ros)
## @arg SIF_MODE=dev|prod|slurm | SIF execution target (default: dev)
## @arg SHARE=1 | Bind-mount the host workspace into the container
## @arg NO_CACHE=1 | Force an image rebuild without layer cache
## @arg PROD_FULL_CUDA=1 | Include the full CUDA toolkit in the prod image
## @arg RUN_ARGS='cmd' | Command to execute inside the SIF
## @arg IMAGE_TAG=latest | Image tag used for build/run (default: latest)

## @section 🧰 | Setup & Infrastructure | BLUE
## @target h : Alias for help
## @target help : Show this command guide
## @target completion : Print bash completion script for make commands
## @target completion-install : Install host bash completion for make commands
## @target setup : Initialize .env and host prerequisites
## @target status : Diagnose overall project & GPU state
## @target check : Validate host prerequisites before running workflows
## @target check-host : Deep audit of WSL2/Host permissions
## @target env-check : Verify .env synchronization with example
## @target verify : Run fast repository validation checks
## @target xauth : Refresh X11/GUI authentication
setup:
	$(call GUARD_HOST_ONLY)
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		SAFE_USER=$$(whoami | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-'); \
		TMP_ENV=$$(mktemp /tmp/devkit_env.XXXXXX); \
		sed "s/^COMPOSE_PROJECT_NAME=\(.*\)/COMPOSE_PROJECT_NAME=\1-$$SAFE_USER/" .env > "$$TMP_ENV"; \
		mv "$$TMP_ENV" .env; \
		PROJECT_NAME=$$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' .env); \
		echo -e "  $(OK) Created .env file and dynamically isolated project name to '$$PROJECT_NAME'."; \
	else \
		echo -e "  $(INFO) .env file already exists."; \
	fi
	@$(MAKE) --no-print-directory completion-install || echo -e "  $(WARN) Completion install skipped."
	@$(MAKE) xauth

status: check
	$(call GUARD_HOST_ONLY)
	$(call PRINT_SECTION,Project Configuration Summary)
	@printf "  %-19s %s\n" "Host User:"          "$(shell whoami) (UID: $(HOST_UID) / GID: $(HOST_GID))"
	@printf "  %-19s %s\n" "Container User:"     "$(CONTAINER_USER)"
	@printf "  %-19s %s\n" "Project Name:"       "$(COMPOSE_PROJECT_NAME)"
	@printf "  %-19s %s\n" "Workspace(Host):"    "$(HOST_WORKSPACE_PATH)"
	@printf "  %-19s %s\n" "Workspace(Docker):"  "$(WORKSPACE_PATH)"
	@printf "  %-19s %s\n" "OS Environment:"     "$(if $(filter true,$(IS_WSL)),WSL 2 (Windows Subsystem for Linux),Linux Native)"
	@printf "  %-19s %s\n" "Architecture:"       "$(HOST_ARCH) (Target: $(TARGETARCH))"
	@printf "  %-19s %s\n" "Display:"            "$(DISPLAY) ($(DISPLAY_TYPE))"
	@printf "  %-19s %s\n" "GPU Mode (Set):"     "$(GPU_MODE)"
	@printf "  %-19s %s\n" "ROS Version:"        "$(ROS_DISTRO)"
	@printf "  %-19s %s\n" "Python Interpreter:" "$(PYTHON_EXECUTABLE)"
	$(call PRINT_SECTION,Running Containers)
	$(call DOCKER_QUERY,status_docker_ps,docker ps --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}",Unable to query Docker containers. Check Docker daemon/socket permissions.)
	$(call PRINT_SECTION,Created Docker Volumes)
	$(call DOCKER_QUERY,status_docker_volume,docker volume ls --filter "name=$(COMPOSE_PROJECT_NAME)" --format "table {{.Name}}\t{{.Driver}}",Unable to query Docker volumes. Check Docker daemon/socket permissions.)
	@if [ "$(HAS_NVIDIA)" = "true" ]; then \
		bash -c "source scripts/util_logging.sh && print_section 'NVIDIA GPU Details'"; \
	fi
	$(if $(filter true,$(HAS_NVIDIA)),$(call DOCKER_QUERY,status_nvidia,nvidia-smi --query-gpu=name$(COMMA)driver_version$(COMMA)memory.total --format=csv$(COMMA)noheader$(COMMA)nounits,Unable to query NVIDIA GPU details.))

check-host:
	$(call GUARD_HOST_ONLY)
	@REQUESTED_GPU=$$(printf '%s' "$(GPU_MODE)" | tr '[:upper:]' '[:lower:]'); \
	case "$$REQUESTED_GPU" in ""|auto|nvidia) CHECK_NVIDIA=true ;; *) CHECK_NVIDIA=false ;; esac; \
	if [ "$$CHECK_NVIDIA" = "true" ] && [ "$(HAS_NVIDIA)" = "true" ]; then \
		if [ "$(HAS_TOOLKIT_BIN)" = "false" ]; then \
			echo -e "  $(WARN) NVIDIA GPU detected but NVIDIA Container Toolkit is not installed."; \
			echo -e "  $(INFO) Refer to README.md for installation instructions."; \
		elif [ "$(HAS_TOOLKIT)" = "false" ]; then \
			echo -e "  $(WARN) NVIDIA Container Toolkit is installed but NOT configured for Docker."; \
			echo -e "  $(INFO) Fix: Run 'sudo nvidia-ctk runtime configure --runtime=docker'"; \
			echo -e "  $(INFO) Then restart Docker: 'sudo systemctl restart docker' OR 'sudo service docker restart'"; \
		fi \
	fi

xauth:
	$(call GUARD_HOST_ONLY)
	@if [ -n "$(DISPLAY)" ]; then \
		if command -v xauth >/dev/null 2>&1 || command -v xhost >/dev/null 2>&1; then \
			TMP_DIR=$$(mktemp -d /tmp/devkit_xauth.XXXXXX); \
			trap 'rm -rf "$$TMP_DIR"' EXIT; \
			ERR="$$TMP_DIR/err"; \
			XAUTH_DATA="$$TMP_DIR/data"; \
			if command -v xauth >/dev/null 2>&1; then \
				if [ ! -f "$(HOST_XAUTHORITY)" ] && ! touch "$(HOST_XAUTHORITY)" 2> "$$ERR"; then \
					echo -e "  $(WARN) Unable to create Xauthority file: $(HOST_XAUTHORITY)"; \
					while read -r line; do echo "    $$line"; done < "$$ERR"; \
				elif ! xauth nlist "$(DISPLAY)" > "$$XAUTH_DATA" 2> "$$ERR"; then \
					echo -e "  $(WARN) Unable to read X11 authentication for DISPLAY=$(DISPLAY). GUI apps may not open."; \
					while read -r line; do echo "    $$line"; done < "$$ERR"; \
				elif ! (while read -r line; do echo "ffff$${line#????}"; done < "$$XAUTH_DATA") | xauth -f "$(HOST_XAUTHORITY)" nmerge - 2>> "$$ERR"; then \
					echo -e "  $(WARN) Unable to merge X11 authentication for DISPLAY=$(DISPLAY). GUI apps may not open."; \
					while read -r line; do echo "    $$line"; done < "$$ERR"; \
				fi; \
			fi; \
			if command -v xhost >/dev/null 2>&1; then \
				if ! xhost +local:root > /dev/null 2> "$$ERR"; then \
					echo -e "  $(WARN) Unable to grant X11 local root access."; \
					while read -r line; do echo "    $$line"; done < "$$ERR"; \
				fi; \
				if ! xhost +si:localuser:root > /dev/null 2> "$$ERR"; then \
					echo -e "  $(WARN) Unable to grant X11 root user access."; \
					while read -r line; do echo "    $$line"; done < "$$ERR"; \
				fi; \
				if ! xhost +si:localuser:$(shell whoami) > /dev/null 2> "$$ERR"; then \
					echo -e "  $(WARN) Unable to grant X11 access for user $(shell whoami)."; \
					while read -r line; do echo "    $$line"; done < "$$ERR"; \
				fi; \
			fi; \
		fi; \
	fi


check:
	$(call GUARD_HOST_ONLY)
	$(call REQUIRE_ENV_FILE)
	$(call VALIDATE_PROJECT_CONFIG)
	$(call REQUIRE_HOST_WORKSPACE_DIR)
	@$(MAKE) --no-print-directory check-host
	@if [ "$(IS_WSL)" = "true" ]; then \
		bash scripts/check_wsl.sh; \
		if [[ "$(CURDIR)" == /mnt/* ]]; then \
			echo -e "  $(WARN) You are running from a Windows mount path ($(CURDIR))."; \
			echo -e "  $(INFO) IO performance will be significantly degraded in WSL 2."; \
			echo -e "  $(INFO) Recommendation: Move the project to the WSL home directory (e.g., ~/work/)."; \
		fi \
	fi

# Verify environment variables synchronization
env-check:
	$(call GUARD_HOST_ONLY)
	$(call REQUIRE_ENV_FILE)
	@echo -e "  $(INFO) Comparing .env settings against .env.example..."
	@MISSING=$$(awk -F= 'FNR == NR { if ($$0 ~ /^[^#][^=]*=/) expected[$$1] = 1; next } $$0 ~ /^[^#][^=]*=/ { delete expected[$$1] } END { for (key in expected) print key }' .env.example .env | sort); \
	if [ -n "$$MISSING" ]; then \
		echo -e "  $(ERROR) The following environment variables are missing in your .env:\n$$MISSING"; \
		exit 1; \
	else \
		echo -e "  $(OK) All required environment variables are properly set."; \
	fi
	$(call VALIDATE_ENV_FILE_VALUES)
	$(call VALIDATE_PROJECT_CONFIG)
	@echo -e "  $(OK) Environment variable values are valid."

verify:
	$(call GUARD_HOST_ONLY)
	$(call PRINT_SECTION,Repository Validation)
	@VERIFY_DOCKER="$(VERIFY_DOCKER)" bash scripts/verify_repo.sh

# =============================================================================
# Build
# =============================================================================

## @section 🏭 | Image Building | BLUE
## @target build ENV=ros|dev [NO_CACHE=1] : Build development image
build: check
	@bash scripts/check_preflight.sh
	$(call VALIDATE_ENV_MODE)
	$(call BUILD_SERVICE,$(COMPOSE_DEV),$(SERVICE_PREFIX),$(SERVICE_LABEL),$(if $(call truthy,$(NO_CACHE)),--no-cache,),Build finished! Run 'make start ENV=$(ENV)' to start the container.)

# =============================================================================
# Execution and Shell Access (Dev) - Auto GPU Detection
# =============================================================================

## @section 💻 | Development (Interactive) | BLUE
## @target start ENV=ros|dev : Run ROS or Pure Dev environment
## @target stop ENV=ros|dev : Stop environment
## @target restart ENV=ros|dev : Restart environment
## @target shell ENV=ros|dev : Enter container shell
## @target term ENV=ros|dev : Open container in new window
start: check xauth
	$(call VALIDATE_ENV_MODE)
	$(call RUN_SERVICE,$(COMPOSE_DEV),$(SERVICE_PREFIX),$(SERVICE_LABEL))
	@echo -e "\n  $(INFO) [Hint] Container started! Use 'make shell ENV=$(ENV)' or 'make term ENV=$(ENV)' to attach."

stop:
	$(call GUARD_HOST_ONLY)
	$(call VALIDATE_ENV_MODE)
	$(call STOP_SERVICE,$(COMPOSE_DEV),$(SERVICE_PREFIX),$(SERVICE_LABEL))

restart: stop start

shell: check xauth
	$(call VALIDATE_ENV_MODE)
	$(call EXEC_CONTAINER,$(SERVICE_FILTER),bash,$(SERVICE_LABEL))

term: check xauth
	$(call VALIDATE_ENV_MODE)
	$(call EXEC_DETACHED,$(SERVICE_FILTER),$(TERMINAL),$(SERVICE_LABEL))

# =============================================================================
# Apptainer Baking (Portable Snapshot)
# =============================================================================

## @section 🧊 | Apptainer Workflow (Dev Snapshot & Production & Server) | BLUE
## @target bake-dev ENV=ros|dev [SHARE=1] : Bake development SIF snapshot
## @target bake-prod ENV=ros|dev [PROD_FULL_CUDA=1] : Bake user-facing production SIF
## @target run-sif SIF_MODE=dev|prod|slurm [ENV=ros|dev] [SHARE=1] [RUN_ARGS='cmd'] : Run or submit a SIF artifact
bake-dev: check
	@bash scripts/check_preflight.sh
	$(call VALIDATE_ENV_MODE)
	$(call PRINT_SECTION,Baking Development Apptainer Snapshot)
	@./scripts/apptainer_bake.sh --mode dev --env $(ENV) $(if $(call truthy,$(SHARE)),--share,)

bake-prod: check
	@bash scripts/check_preflight.sh
	$(call VALIDATE_ENV_MODE)
	$(call PRINT_SECTION,Baking Production Apptainer Image)
	@./scripts/apptainer_bake.sh --mode prod --env $(ENV)

run-sif:
	$(call CHECK_SIF_READY)
	$(call VALIDATE_SIF_MODE)
	$(call VALIDATE_ENV_MODE)
	$(call PRINT_SECTION,Running Apptainer Image)
	$(if $(and $(filter dev,$(SIF_MODE)),$(if $(call truthy,$(DEVKIT_DRY_RUN)),,1)),@$(MAKE) xauth,)
	@SHARE="$(SHARE)" ./scripts/apptainer_run.sh --mode $(SIF_MODE) --env $(ENV) -- $(RUN_ARGS)

# =============================================================================
# SLURM Scheduling (HPC)
# =============================================================================

## @section 📡 | SLURM Scheduling (Server) | BLUE
## @target slurm-status : Query active/pending SLURM jobs
## @target slurm-cancel : Cancel running/pending SLURM jobs
slurm-status:
	$(call GUARD_HOST_ONLY)
	@if command -v squeue >/dev/null 2>&1; then \
		squeue -u $$USER; \
	else \
		echo -e "  $(ERROR) SLURM binary 'squeue' not found."; \
		exit 1; \
	fi

slurm-cancel:
	$(call GUARD_HOST_ONLY)
	@if command -v scancel >/dev/null 2>&1; then \
		echo -en "  $(WARN) Enter Job ID to cancel: "; \
		read jobid; \
		if [ -z "$$jobid" ]; then \
			echo -e "  $(ERROR) Job ID is required. Operation cancelled."; \
			exit 1; \
		fi; \
		scancel $$jobid && echo -e "  $(OK) Cancelled job $$jobid."; \
	else \
		echo -e "  $(ERROR) SLURM binary 'scancel' not found."; \
		exit 1; \
	fi

# =============================================================================
# Maintenance
# =============================================================================

## @section 📊 | Monitoring & Maintenance | BLUE
## @target stats : Real-time resource monitor (CPU/Mem/GPU)
## @target top : Detailed per-process monitor
## @target logs : Stream real-time container logs
## @target update-gpg : Update ROS GPG keys in build scripts
## @target down : Stop and remove all containers
update-gpg:
	$(call GUARD_HOST_ONLY)
	@bash scripts/setup_ros_gpg.sh

# Real-time Monitoring (CPU, MEM, NVIDIA/Intel/AMD GPU)
stats:
	$(call GUARD_HOST_ONLY)
	@echo -e "  $(INFO) Initiating real-time resource monitoring (Ctrl+C to terminate)..."
	@watch -t -n 2 "bash scripts/util_make_stats.sh $(HAS_NVIDIA) $(HAS_DRI)" || [ $$? -eq 130 ]

# Detailed Expert Monitoring (Per CPU Core + Per GPU Process)
top:
	$(call GUARD_HOST_ONLY)
	$(call VALIDATE_ENV_MODE)
	@CONTAINER=$$($(call FIND_CONTAINER,$(SERVICE_FILTER))); \
	if [ -n "$$CONTAINER" ]; then \
		echo -e "  $(INFO) Initiating granular $(SERVICE_LABEL) container monitoring ($$CONTAINER)..."; \
		docker exec -it -u $(CONTAINER_USER) $$CONTAINER bash "$(WORKSPACE_PATH)/scripts/util_make_top.sh" container || [ $$? -eq 130 ]; \
	else \
		echo -e "  $(ERROR) No running $(SERVICE_LABEL) container found. Trying host tools instead..."; \
		bash scripts/util_make_top.sh host "$(HAS_DRI)" || [ $$? -eq 130 ]; \
	fi

logs:
	$(call GUARD_HOST_ONLY)
	@if [ -n "$$($(COMPOSE) $(COMPOSE_DEV) ps --status running -q 2>/dev/null)" ]; then \
		echo -e "  $(INFO) [Dev] Streaming development logs..."; \
		$(COMPOSE) $(COMPOSE_DEV) logs -f --tail 100; \
	else \
		echo -e "  $(WARN) No running development containers found."; \
	fi

down:
	$(call GUARD_HOST_ONLY)
	$(call TEARDOWN_SERVICES)
	@echo -e "  $(OK) All containers have successfully been stopped and removed."

# =============================================================================
# Cleanup
# =============================================================================

## @section 🧹 | Cleanup | BLUE
## @target clean : Delete build output (build/install/log)
## @target clean-cache : Wipe .docker_cache (ccache/uv/apt)
## @target clean-all : Reset everything (images/volumes/cache)
## @target docker-clean : Global Docker system cleanup
clean:
	$(call GUARD_HOST_ONLY)
	$(call TEARDOWN_SERVICES,-v)
	@echo -e "  $(INFO) Removing all named volumes related to $(COMPOSE_PROJECT_NAME)..."
	@VOLUMES=$$(docker volume ls -q --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)"); \
	if [ -n "$$VOLUMES" ]; then \
		docker volume rm $$VOLUMES; \
	else \
		echo -e "  $(INFO) No project-related volumes to delete."; \
	fi
	@if [ -n "$(call truthy,$(FORCE))" ] || [ -n "$(call truthy,$(CI))" ]; then \
		echo -e "  $(WARN) CI/FORCE mode: Forcibly deleting host folders without prompting."; ans="y"; \
	else \
		echo -e "  $(WARN) Do you want to delete the [build, devel, install, log, .venv, colcon.meta] host folders?"; \
		echo -en "  $(WARN) If you used bind mounts in [.env], actual data will be lost! [Y/N]: "; \
		read ans || true; \
	fi; \
	if [ "$$ans" = "y" ] || [ "$$ans" = "Y" ]; then \
		$(call SUDO_FREE_RM,$(HOST_WORKSPACE_PATH),build devel install log .venv colcon.meta); \
	else \
		echo -e "  $(INFO) Safely skipped deleting host folders."; \
	fi
	@echo -e "  $(OK) General project clean up completed."

clean-cache:
	$(call GUARD_HOST_ONLY)
	@CACHE_DIR="$(HOST_CACHE_DIR)"; \
		CACHE_DIR="$${CACHE_DIR%/}"; \
		HOST_ROOT="$(HOST_WORKSPACE_PATH)"; \
		HOST_ROOT="$${HOST_ROOT%/}"; \
		if [ -z "$$CACHE_DIR" ] || [ "$$CACHE_DIR" = "/" ] || [[ "$$CACHE_DIR" != /* ]]; then \
			echo -e "  $(ERROR) Cache directory must be an absolute non-root path (current: $$CACHE_DIR)."; \
			exit 1; \
		fi; \
		if [ "$$CACHE_DIR" = "$$HOST_ROOT" ]; then \
			echo -e "  $(ERROR) Refusing to clean the workspace root as a cache directory: $$CACHE_DIR"; \
			exit 1; \
		fi; \
		case "$$CACHE_DIR" in \
			*"$(COMPOSE_PROJECT_NAME)"*|"$$HOST_ROOT"/*) ;; \
			*) echo -e "  $(WARN) This cache string ($$CACHE_DIR) points to a shared global cache. Proceeding here affects all projects." ;; \
		esac; \
	if [ -d "$$CACHE_DIR" ]; then \
		if [ -n "$(call truthy,$(FORCE))" ] || [ -n "$(call truthy,$(CI))" ]; then \
			ans="y"; \
		else \
			echo -en "  $(WARN) Are you sure you want to delete the host cache directory ($$CACHE_DIR)? [Y/N]: "; \
			read ans || true; \
		fi; \
		if [ "$$ans" != "y" ] && [ "$$ans" != "Y" ]; then echo -e "  $(INFO) Deletion cancelled."; exit 1; fi; \
		echo -e "  $(INFO) Clearing cache directory contents: $$CACHE_DIR"; \
		docker run --rm -v "$$CACHE_DIR:/mnt" alpine sh -c 'find /mnt -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'; \
		if [ "$(SKIP_ALPINE_RM)" != "1" ]; then \
			$(call CLEAN_ALPINE_IMAGE); \
		fi; \
	fi
	@echo -e "  $(OK) Docker local cache clean up (clean-cache) completed."

# Reset all project-related resources (including images)
clean-all:
	$(call GUARD_HOST_ONLY)
	@$(MAKE) clean SKIP_ALPINE_RM=1
	@$(MAKE) clean-cache SKIP_ALPINE_RM=1
	@$(call CLEAN_ALPINE_IMAGE)
	@echo -e "  $(INFO) Cleaning up all images related to project $(COMPOSE_PROJECT_NAME)..."
	@IMAGES=$$(docker images -q --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)"); \
	if [ -n "$$IMAGES" ]; then \
		docker rmi -f $$IMAGES; \
		echo -e "  $(OK) Project-related images removed."; \
	else \
		echo -e "  $(INFO) No project-related images to delete."; \
	fi
	@echo -e "  $(OK) Full project reset (clean-all) completed."

# Global Docker cleanup (Warning: affects build caches across all projects on the system)
docker-clean:
	$(call GUARD_HOST_ONLY)
	@if [ -n "$(call truthy,$(FORCE))" ] || [ -n "$(call truthy,$(CI))" ]; then \
		ans="y"; \
	else \
		echo -en "  $(WARN) Do you want to globally clean Docker on this host? (Deletes all build cache and unused images) [Y/N]: "; \
		read ans || true; \
	fi; \
	if [ "$$ans" != "y" ] && [ "$$ans" != "Y" ]; then echo -e "  $(INFO) Operation cancelled."; exit 1; fi
	@echo -e "  $(INFO) Cleaning up Docker BuildKit caches..."
	@docker builder prune -a -f
	@echo -e "  $(INFO) Cleaning up unused images..."
	@docker image prune -f
	@echo -e "  $(OK) Global Docker cleanup completed."
