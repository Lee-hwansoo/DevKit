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
-include .env

# Workspace Path Architecture (Separation of Host and Container)
# HOST_WORKSPACE_PATH: Physical path on the host machine (Source)
# WORKSPACE_PATH: Logical path inside the container (Target/SSOT)
HOST_WORKSPACE_PATH ?= $(CURDIR)
WORKSPACE_PATH      ?= /workspace

# Auto-match TARGETARCH
TARGETARCH ?= $(HOST_ARCH)

export

# Environment Detection Engine (Auto-detection — triggered by relevant targets)
# Applied to Docker-related operations to ensure hardware and display compatibility
NEEDS_DETECTOR := $(filter-out help setup env-check%,$(MAKECMDGOALS))
ifneq ($(NEEDS_DETECTOR),)
$(foreach line,$(shell bash scripts/check_env.sh),$(eval $(line)))
endif

COMPOSE := docker compose
COMPOSE_DEV := -f docker-compose.dev.yml
COMPOSE_PROD := -f docker-compose.prod.yml
TERMINAL ?= terminator

# Macros (Deduplication & SSOT)
# Integrated GPU Mode Detection Logic
DETECT_MODE := \
	CHOSEN_MODE=$(GPU_MODE); \
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

# $1: ENV_VAR_NAME
define CHECK_ENV
	@if [ -z "$($1)" ]; then \
		echo -e "  $(ERROR) Variable $1 is not set in .env. It is strictly required for production."; \
		exit 1; \
	fi
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
	@if echo "$(COMPOSE_PROJECT_NAME)" | grep -q '[^a-z0-9_-]'; then \
		echo -e "  $(ERROR) COMPOSE_PROJECT_NAME must contain only lowercase letters, dashes (-), or underscores (_)."; \
		exit 1; \
	fi
endef

# $1: FILTER, $2: COMMAND, $3: MSG (For error display)
define EXEC_CONTAINER
	@CONTAINER=$$(docker ps --filter "name=$1" --format "{{.Names}}" | head -n 1); \
	if [ -n "$$CONTAINER" ]; then \
		docker exec -it $$CONTAINER $2 || [ $$? -eq 130 ]; \
	else \
		echo -e "  $(ERROR) No running container found for $3."; \
		exit 1; \
	fi
endef

# $1: FILTER, $2: COMMAND, $3: MSG (For error display)
define EXEC_DETACHED
	@CONTAINER=$$(docker ps --filter "name=$1" --format "{{.Names}}" | head -n 1); \
	if [ -n "$$CONTAINER" ]; then \
		docker exec -d $$CONTAINER $2; \
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
	@if [ -f docker-compose.prod.yml ]; then \
		$(COMPOSE) $(COMPOSE_PROD) --profile "*" down $1 --remove-orphans 2>/dev/null || true; \
	fi
endef

# $1: MOUNT_DIR (Absolute Path), $2: Targets to delete
define SUDO_FREE_RM
	if [ "$1" = "/" ] || [ -z "$1" ]; then \
		echo -e "  $(ERROR) Critical Safety: Refusing to delete from root directory!"; \
		exit 1; \
	fi; \
	echo -e "  $(INFO) Performing sudo-free deletion: $2 in $1"; \
	docker run --rm -v "$1:/mnt" alpine sh -c "cd /mnt && rm -rf $2" 2>/dev/null || true; \
	if [ "$(SKIP_ALPINE_RM)" != "1" ]; then \
		echo -e "  $(INFO) Cleaning up the temporary alpine image used for sudo-free deletion..."; \
		docker rmi alpine:latest 2>/dev/null || true; \
	fi
endef

# Core Infrastructure Variables Export
export IS_WSL HOST_DXG_MOUNT HOST_ARCH HAS_NVIDIA HAS_TOOLKIT HAS_DRI HOST_DRI_MOUNT TARGETARCH DISPLAY_TYPE HOST_XDG_RUNTIME_DIR HOST_WAYLAND_DISPLAY HOST_XAUTHORITY HOST_HOME NVIDIA_VISIBLE_DEVICES NVIDIA_DRIVER_CAPABILITIES NVIDIA_GPU_COUNT HOST_CACHE_DIR HOST_X11_DIR HOST_GITCONFIG HOST_SSH_AUTH_SOCK WSL_LIB_DIR_MOUNT CUDA_VERSION CUDNN_VERSION PYTHON_EXECUTABLE

# Centralized UI Sub-Header Macro
define PRINT_SECTION
	@bash -c "source scripts/util_logging.sh && print_section \"$1\""
endef

.PHONY: h help setup check check-host xauth status \
        build-ros build-dev rebuild-ros rebuild-dev \
        ros ros-stop ros-restart dev dev-stop dev-restart ros-shell dev-shell ros-term dev-term \
		build-ros-prod build-dev-prod rebuild-ros-prod rebuild-dev-prod \
        ros-prod ros-prod-stop dev-prod dev-prod-stop \
		save-ros save-dev load-ros load-dev \
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
		bash -c ' \
			source scripts/util_logging.sh && \
			print_banner WELCOME && \
			while IFS= read -r line; do \
				if [[ $$line =~ ^[[:space:]]*"## @section" ]]; then \
					section_data="$${line#*## @section }"; \
					emoji=$$(echo "$$section_data" | cut -d"|" -f1 | xargs); \
					title=$$(echo "$$section_data" | cut -d"|" -f2 | xargs); \
					color_name=$$(echo "$$section_data" | cut -d"|" -f3 | xargs); \
					color=$${!color_name:-$$BLUE}; \
					printf "\n  $${color}%s  %s:$${NC}\n" "$$emoji" "$$title"; \
				elif [[ $$line =~ ^[[:space:]]*"## @target" ]]; then \
					content="$${line#*## @target }"; \
					cmd=$$(echo "$${content%%:*}" | xargs); \
					desc=$$(echo "$${content#*:}" | xargs); \
					printf "    $${GREEN}make %-22s$${NC} : %s\n" "$$cmd" "$$desc"; \
				fi; \
			done < Makefile; \
			echo -e "\n  ${CYAN}Notice:${NC} All commands auto-detect GPU.\n" \
		'; \
	fi

# =============================================================================
# Initial Setup and Status Check
# =============================================================================

## @section 🛠️ | Setup & Infrastructure | BLUE
## @target setup : Initialize .env and host prerequisites
## @target status : Diagnose overall project & GPU state
## @target check-host : Deep audit of WSL2/Host permissions
## @target env-check : Verify .env synchronization with example
## @target xauth : Refresh X11/GUI authentication
setup:
	$(call GUARD_HOST_ONLY)
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo -e "  $(OK) Created .env file. Please edit settings to your needs."; \
	else \
		echo -e "  $(INFO) .env file already exists."; \
	fi
	@$(MAKE) xauth

status: check
	$(call GUARD_HOST_ONLY)
	$(call PRINT_SECTION,Project Configuration Summary)
	@echo "  Project Name:      $(COMPOSE_PROJECT_NAME)"
	@echo "  Workspace(Host):   $(HOST_WORKSPACE_PATH)"
	@echo "  Workspace(Docker): $(WORKSPACE_PATH)"
	@echo "  OS Environment:    $(if $(filter true,$(IS_WSL)),WSL 2 (Windows Subsystem for Linux),Linux Native)"
	@echo "  Architecture:      $(HOST_ARCH) (Target: $(TARGETARCH))"
	@echo "  Display:           $(DISPLAY) ($(DISPLAY_TYPE))"
	@echo "  GPU Mode (Set):    $(GPU_MODE)"
	@echo "  ROS Version:       $(ROS_DISTRO)"
	@echo "  Python Interpreter: $(PYTHON_EXECUTABLE)"
	$(call PRINT_SECTION,Running Containers)
	@docker ps --filter "name=$(COMPOSE_PROJECT_NAME)" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | sed 's/^/  /'
	$(call PRINT_SECTION,Created Docker Volumes)
	@docker volume ls --filter "name=$(COMPOSE_PROJECT_NAME)" --format "table {{.Name}}\t{{.Driver}}" | sed 's/^/  /'
	@if [ "$(HAS_NVIDIA)" = "true" ]; then \
		bash -c "source scripts/util_logging.sh && print_section 'NVIDIA GPU Details'"; \
		nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits | sed 's/^/  /'; \
	fi

check-host:
	$(call GUARD_HOST_ONLY)
	@if [ "$(HAS_NVIDIA)" = "true" ]; then \
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
		if command -v xauth >/dev/null 2>&1; then \
			[ -f "$(HOST_XAUTHORITY)" ] || touch "$(HOST_XAUTHORITY)" 2>/dev/null || true; \
			xauth nlist $(DISPLAY) 2>/dev/null | sed -e 's/^..../ffff/' | xauth -f $(HOST_XAUTHORITY) nmerge - 2>/dev/null || true; \
		fi; \
	fi
	@if [ -n "$(DISPLAY)" ] && command -v xhost >/dev/null 2>&1; then \
		xhost +local:root > /dev/null 2>&1 || true; \
		xhost +si:localuser:root > /dev/null 2>&1 || true; \
		xhost +si:localuser:$(shell whoami) > /dev/null 2>&1 || true; \
	fi

check: check-host
	$(call GUARD_HOST_ONLY)
	@if [ ! -f .env ]; then echo -e "  $(ERROR) .env not found. Please run 'make setup' first."; exit 1; fi
	@if [ ! -d "$(HOST_WORKSPACE_PATH)" ]; then echo -e "  $(ERROR) HOST_WORKSPACE_PATH ($(HOST_WORKSPACE_PATH)) does not exist."; exit 1; fi
	@if [ "$(IS_WSL)" = "true" ]; then \
		bash scripts/check_wsl.sh; \
		if [[ "$(CURDIR)" == /mnt/* ]]; then \
			echo -e "  $(WARN) You are running from a Windows mount path ($(CURDIR))."; \
			echo -e "  $(INFO) IO performance will be significantly degraded in WSL 2."; \
			echo -e "  $(INFO) Recommendation: Move the project to the WSL home directory (e.g., ~/work/)."; \
		fi \
	fi
	$(call VALIDATE_COMPOSE_NAME)
	$(call VALIDATE_ROS_ENV)

# Verify environment variables synchronization
env-check:
	$(call GUARD_HOST_ONLY)
	@echo -e "  $(INFO) Comparing .env settings against .env.example..."
	@MISSING=$$(comm -23 <(grep -E "^[^#]+=" .env.example | cut -d= -f1 | sort) <(grep -E "^[^#]+=" .env | cut -d= -f1 | sort)); \
	if [ -n "$$MISSING" ]; then \
		echo -e "  $(WARN) The following environment variables are missing in your .env:\n$$MISSING"; \
	else \
		echo -e "  $(OK) All required environment variables are properly set."; \
	fi

# =============================================================================
# Build
# =============================================================================

## @section 🏗️ | Image Building | BLUE
## @target build-ros / dev : Build development images
## @target rebuild-ros / dev : Full rebuild (no cache)
## @target build-ros-prod / dev : Build optimized production images
build-ros: check
	$(call BUILD_SERVICE,$(COMPOSE_DEV),ros,ROS Development,,Build finished! Please run 'make ros' to start the container.)

build-dev: check
	$(call BUILD_SERVICE,$(COMPOSE_DEV),basic,Pure Development,,Build finished! Please run 'make dev' to start the container.)

rebuild-ros: check
	$(call BUILD_SERVICE,$(COMPOSE_DEV),ros,Rebuild ROS without cache,--no-cache,Build finished! Please run 'make ros' to start the container.)

rebuild-dev: check
	$(call BUILD_SERVICE,$(COMPOSE_DEV),basic,Rebuild Pure Dev without cache,--no-cache,Build finished! Please run 'make dev' to start the container.)

build-ros-prod: check
	@echo -e "  $(INFO) [Notice] A clean build (make clean) is recommended for production-grade artifacts."
	$(call BUILD_SERVICE,$(COMPOSE_PROD),ros,Bake Production ROS,,Production image baked! Extract with 'make save-ros' or run with 'make ros-prod'.)

build-dev-prod: check
	@echo -e "  $(INFO) [Notice] A clean build (make clean) is recommended for production-grade artifacts."
	$(call BUILD_SERVICE,$(COMPOSE_PROD),basic,Bake Production Pure Dev,,Production image baked! Extract with 'make save-dev' or run with 'make dev-prod'.)

rebuild-ros-prod: check
	@echo -e "  $(INFO) [Notice] A clean build (make clean) is recommended for production-grade artifacts."
	$(call BUILD_SERVICE,$(COMPOSE_PROD),ros,Rebuild Production ROS without cache,--no-cache,Production image baked! Extract with 'make save-ros' or run with 'make ros-prod'.)

rebuild-dev-prod: check
	@echo -e "  $(INFO) [Notice] A clean build (make clean) is recommended for production-grade artifacts."
	$(call BUILD_SERVICE,$(COMPOSE_PROD),basic,Rebuild Production Pure Dev without cache,--no-cache,Production image baked! Extract with 'make save-dev' or run with 'make dev-prod'.)

# =============================================================================
# Execution and Shell Access (Dev) - Auto GPU Detection
# =============================================================================

## @section 💻 | Development (Interactive) | BLUE
## @target ros / dev : Run ROS or Pure Dev environment
## @target ros-shell / dev-shell : Enter container shell
## @target ros-stop / dev-stop : Stop specific service
## @target ros-restart / dev-restart : Restart specific service
## @target ros-term / dev-term : Open container in new window
ros: check xauth
	$(call RUN_SERVICE,$(COMPOSE_DEV),ros,ROS Development)
	@echo -e "\n  $(INFO) [Hint] Container started! Use 'make ros-shell' or 'make ros-term' to attach to the container."

dev: check xauth
	$(call RUN_SERVICE,$(COMPOSE_DEV),basic,Pure Development)
	@echo -e "\n  $(INFO) [Hint] Container started! Use 'make dev-shell' or 'make dev-term' to attach to the container."

# Stop and Restart Services Individually
ros-stop:
	$(call STOP_SERVICE,$(COMPOSE_DEV),ros,ROS Development)

dev-stop:
	$(call STOP_SERVICE,$(COMPOSE_DEV),basic,Pure Development)

ros-restart: ros-stop ros
dev-restart: dev-stop dev

# Filter Definitions
ROS_FILTER := ^$(COMPOSE_PROJECT_NAME)[-_]ros-(cpu|igpu|nvidia)
DEV_FILTER := ^$(COMPOSE_PROJECT_NAME)[-_]basic-(cpu|igpu|nvidia)

ros-shell: check xauth
	$(call EXEC_CONTAINER,$(ROS_FILTER),bash,ROS)

ros-term: check xauth
	$(call EXEC_DETACHED,$(ROS_FILTER),$(TERMINAL),ROS)

dev-shell: check xauth
	$(call EXEC_CONTAINER,$(DEV_FILTER),bash,Development)

dev-term: check xauth
	$(call EXEC_DETACHED,$(DEV_FILTER),$(TERMINAL),Development)

# =============================================================================
# Production Execution (Prod) - Auto GPU Detection
# =============================================================================

## @section 🚀 | Production & Portability | BLUE
## @target ros-prod / dev-prod : Run production service
## @target ros-prod-stop / dev-prod-stop : Stop production service
## @target save-ros / save-dev : Export image to .tar.gz
## @target load-ros / load-dev : Restore image from .tar.gz
ros-prod: check xauth
	$(call CHECK_ENV,ROS_LAUNCH_COMMAND)
	$(call RUN_SERVICE,$(COMPOSE_PROD),ros,ROS Production)
	@$(MAKE) logs

ros-prod-stop:
	$(call STOP_SERVICE,$(COMPOSE_PROD),ros,ROS Production)

dev-prod: check xauth
	$(call CHECK_ENV,APP_COMMAND)
	$(call RUN_SERVICE,$(COMPOSE_PROD),basic,Pure Development Production)
	@$(MAKE) logs

dev-prod-stop:
	$(call STOP_SERVICE,$(COMPOSE_PROD),basic,Pure Development Production)

# Image Extraction and Restoration Strategy
IMAGE_SUFFIX := $(if $(filter humble,$(ROS_DISTRO)),humble,$(if $(filter noetic,$(ROS_DISTRO)),noetic,latest))
SAVE_NAME_ROS := $(COMPOSE_PROJECT_NAME)-ros-$(IMAGE_SUFFIX).tar.gz
SAVE_NAME_DEV := $(COMPOSE_PROJECT_NAME)-dev-$(IMAGE_SUFFIX).tar.gz

# $1: TARGET_ENV (ros-runtime or dev-runtime), $2: SAVE_FILE_NAME, $3: MSG
define SAVE_IMAGE
	@echo -e "  $(INFO) Extracting production image for $3: $2..."
	@docker save $(COMPOSE_PROJECT_NAME)/$1:latest | gzip > $2
	@echo -e "  $(OK) Image extraction completed: $$(du -h $2) (Path: ./$2)"
endef

# $1: SAVE_FILE_NAME, $2: MSG
define LOAD_IMAGE
	@if [ ! -f $1 ]; then echo -e "  $(ERROR) File not found: $1"; exit 1; fi
	@echo -e "  $(INFO) Restoring $2 image..."
	@docker load < $1
	@echo -e "  $(OK) $2 image restored successfully."
endef

save-ros:
	$(call GUARD_HOST_ONLY)
	$(call SAVE_IMAGE,ros-runtime,$(SAVE_NAME_ROS),ROS)

save-dev:
	$(call GUARD_HOST_ONLY)
	$(call SAVE_IMAGE,dev-runtime,$(SAVE_NAME_DEV),Pure Development)

load-ros:
	$(call GUARD_HOST_ONLY)
	$(call LOAD_IMAGE,$(SAVE_NAME_ROS),ROS)

load-dev:
	$(call GUARD_HOST_ONLY)
	$(call LOAD_IMAGE,$(SAVE_NAME_DEV),Pure Development)

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
	@watch -t -n 1 "bash -c ' \
		source scripts/util_logging.sh; \
		print_section \"All Containers Status (CPU/Mem/PIDs)\"; echo \"\"; \
		docker stats --no-stream --format \"table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.PIDs}}\" | sed \"s/^/  /\"; \
		if [ \"$(HAS_NVIDIA)\" = \"true\" ]; then \
			echo \"\"; print_section \"NVIDIA GPU Details\"; echo \"\"; \
			nvidia-smi --query-gpu=index,name,utilization.gpu,utilization.memory,memory.used,memory.total --format=csv,noheader,nounits | sed \"s/^/  GPU /\"; \
		fi; \
		if [ \"$(HAS_DRI)\" = \"true\" ]; then \
			echo \"\"; print_section \"Intel/AMD (DRI) Load Status\"; echo \"\"; \
			for dev in /sys/class/drm/renderD*; do \
				[ -d \"\$$dev\" ] || continue; \
				idx=\$${dev##*renderD}; \
				vendor=\$$(cat \"\$$dev/device/vendor\" 2>/dev/null); \
				if [ \"\$$vendor\" = \"0x8086\" ]; then vname=\"Intel\"; \
				elif [ \"\$$vendor\" = \"0x1002\" ] || [ \"\$$vendor\" = \"0x1022\" ]; then vname=\"AMD\"; \
				else vname=\"DRI\"; fi; \
				echo -n \"  GPU \$$idx (\$$vname) Status: \"; \
				if [ -e \"\$$dev/device/gpu_busy_percent\" ]; then \
					usage=\$$(cat \"\$$dev/device/gpu_busy_percent\"); \
					echo \"\$$usage%\"; \
				else \
					echo \"Active (Use make top for details)\"; \
				fi; \
			done; \
		fi; \
	'" || [ $$? -eq 130 ]

# Detailed Expert Monitoring (Per CPU Core + Per GPU Process)
top:
	$(call GUARD_HOST_ONLY)
	@CONTAINER=$$(docker ps --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)" --format "{{.Names}}" | head -n 1); \
	if [ -n "$$CONTAINER" ]; then \
		echo -e "  $(INFO) Initiating granular container-level monitoring ($$CONTAINER)..."; \
		docker exec -it $$CONTAINER bash -c " \
			FOUND=0; \
			if command -v nvtop >/dev/null 2>&1; then \
				if ! nvtop 2>&1 | head -n 1 | grep -q 'No GPU'; then \
					nvtop; FOUND=1; \
				fi; \
			fi; \
			if [ \"\$$FOUND\" = \"0\" ] && command -v intel_gpu_top >/dev/null 2>&1; then \
				intel_gpu_top; FOUND=1; \
			elif [ \"\$$FOUND\" = \"0\" ] && command -v radeontop >/dev/null 2>&1; then \
				radeontop; FOUND=1; \
			fi; \
			if [ \"\$$FOUND\" = \"0\" ]; then htop; fi; \
		" || [ $$? -eq 130 ]; \
	else \
		echo -e "  $(ERROR) No running project container found. Trying host tools instead..."; \
		FOUND=0; \
		if command -v nvtop >/dev/null 2>&1; then \
			if nvtop 2>&1 | head -n 1 | grep -q "No GPU"; then \
				echo -e "  $(WARN) Host nvtop failed to detect a GPU. Trying an alternative..."; \
			else \
				nvtop || [ $$? -eq 130 ]; FOUND=1; \
			fi; \
		fi; \
		if [ "$$FOUND" = "0" ] && [ "$(HAS_DRI)" = "true" ]; then \
			for dev in /sys/class/drm/renderD*; do \
				[ -e "$$dev/device/vendor" ] || continue; \
				vendor=$$(cat "$$dev/device/vendor" 2>/dev/null); \
				if [ "$$vendor" = "0x8086" ] && command -v intel_gpu_top >/dev/null 2>&1; then \
					echo -e "  $(INFO) Intel GPU detected. Running intel_gpu_top..."; \
					sudo intel_gpu_top || [ $$? -eq 130 ]; FOUND=1; break; \
				elif ([ "$$vendor" = "0x1002" ] || [ "$$vendor" = "0x1022" ]) && command -v radeontop >/dev/null 2>&1; then \
					echo -e "  $(INFO) AMD GPU detected. Running radeontop..."; \
					radeontop || [ $$? -eq 130 ]; FOUND=1; break; \
				fi; \
			done; \
		fi; \
		if [ "$$FOUND" = "0" ] && command -v htop >/dev/null 2>&1; then \
			htop || [ $$? -eq 130 ]; FOUND=1; \
		fi; \
		if [ "$$FOUND" = "0" ]; then \
			echo -e "  $(ERROR) Appropriate monitoring tools (nvtop, intel_gpu_top, htop) could not be found."; exit 1; \
		fi; \
	fi

logs:
	$(call GUARD_HOST_ONLY)
	@if [ -n "$$($(COMPOSE) $(COMPOSE_DEV) ps --status running -q 2>/dev/null)" ]; then \
		echo -e "  $(INFO) [Dev] Streaming development logs..."; \
		$(COMPOSE) $(COMPOSE_DEV) logs -f --tail 100; \
	elif [ -f docker-compose.prod.yml ] && [ -n "$$($(COMPOSE) $(COMPOSE_PROD) ps --status running -q 2>/dev/null)" ]; then \
		echo -e "  $(INFO) [Prod] Streaming production logs..."; \
		$(COMPOSE) $(COMPOSE_PROD) logs -f --tail 100; \
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
		docker volume rm $$VOLUMES 2>/dev/null || true; \
	fi
	@if [ "$(FORCE)" = "1" ] || [ "$(CI)" = "true" ]; then \
		echo -e "  $(WARN) CI/FORCE mode: Forcibly deleting host folders without prompting."; ans="y"; \
	else \
		echo -e "  $(WARN) Do you want to delete the [build, install, log, .venv, colcon.meta] host folders?"; \
		echo -en "  $(WARN) If you used bind mounts in [.env], actual data will be lost! [Y/N]: "; \
		read ans || true; \
	fi; \
	if [ "$$ans" = "y" ] || [ "$$ans" = "Y" ]; then \
		$(call SUDO_FREE_RM,$(HOST_WORKSPACE_PATH),build install log .venv colcon.meta); \
	else \
		echo -e "  $(INFO) Safely skipped deleting host folders."; \
	fi
	@echo -e "  $(OK) General project clean up completed."

clean-cache:
	$(call GUARD_HOST_ONLY)
	@CACHE_DIR=$(HOST_CACHE_DIR); \
	if [ -z "$$CACHE_DIR" ] || [ "$$CACHE_DIR" = "/" ]; then \
		echo -e "  $(ERROR) Cache directory ($$CACHE_DIR) is invalid or unsafe."; \
		exit 1; \
	fi; \
	if ! (echo "$$CACHE_DIR" | grep -q "$(COMPOSE_PROJECT_NAME)" || echo "$$CACHE_DIR" | grep -q "$(HOST_WORKSPACE_PATH)"); then \
		echo -e "  $(WARN) This cache string ($$CACHE_DIR) points to a shared global cache. Proceeding here affects all projects."; \
	fi; \
	if [ -d "$$CACHE_DIR" ]; then \
		if [ "$(FORCE)" = "1" ] || [ "$(CI)" = "true" ]; then \
			ans="y"; \
		else \
			echo -en "  $(WARN) Are you sure you want to delete the host cache directory ($$CACHE_DIR)? [Y/N]: "; \
			read ans || true; \
		fi; \
		if [ "$$ans" != "y" ] && [ "$$ans" != "Y" ]; then echo -e "  $(INFO) Deletion cancelled."; exit 1; fi; \
		$(call SUDO_FREE_RM,$$(dirname "$$CACHE_DIR"),$$(basename "$$CACHE_DIR")); \
	fi
	@echo -e "  $(OK) Docker local cache clean up (clean-cache) completed."

# Reset all project-related resources (including images)
clean-all:
	$(call GUARD_HOST_ONLY)
	@$(MAKE) clean SKIP_ALPINE_RM=1
	@$(MAKE) clean-cache SKIP_ALPINE_RM=1
	@echo -e "  $(INFO) Cleaning up the temporary alpine image used for sudo-free deletion..."
	@docker rmi alpine:latest 2>/dev/null || true
	@echo -e "  $(INFO) Cleaning up all images related to project $(COMPOSE_PROJECT_NAME)..."
	@IMAGES=$$(docker images -q --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)"); \
	if [ -n "$$IMAGES" ]; then \
		docker rmi -f $$IMAGES 2>/dev/null || true; \
		echo -e "  $(OK) Project-related images removed."; \
	else \
		echo -e "  $(INFO) No project-related images to delete."; \
	fi
	@echo -e "  $(OK) Full project reset (clean-all) completed."

# Global Docker cleanup (Warning: affects build caches across all projects on the system)
docker-clean:
	$(call GUARD_HOST_ONLY)
	@if [ "$(FORCE)" = "1" ] || [ "$(CI)" = "true" ]; then \
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
