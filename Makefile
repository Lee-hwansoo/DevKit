# =============================================================================
# ros2_docker_template/Makefile
# 원 커맨드 워크플로우 (KISS 기반 명령어 통합)
#
# 주요 명령어:
#   make setup       — 초기 설정 (최초 1회)
#   make ros         — ROS 개발 환경 시작 (NVIDIA 자동 감지)
#   make dev         — 순수 개발 환경 시작 (NVIDIA 자동 감지)
#   make ros-prod    — ROS 배포 환경 시작
#   make dev-prod    — 순수 배포 환경 시작
#   make status      — 프로젝트 및 GPU 상태 확인
# =============================================================================

-include .env
export

COMPOSE := docker compose

# 진단 엔진 연동
DETECTOR := bash scripts/env_detector.sh
$(foreach line,$(shell $(DETECTOR)),$(eval $(line)))

.PHONY: help setup check xauth status \
        build-ros build-dev rebuild-ros rebuild-dev \
        ros dev ros-shell dev-shell \
        ros-prod dev-prod \
        clean clean-cache clean-all clean-builder

# =============================================================================
# Default & Help
# =============================================================================
help:
	@echo ""
	@echo "  Docker 개발환경 템플릿"
	@echo ""
	@echo "  [설정]"
	@echo "    make setup          .env 초기화 및 X11 권한 설정"
	@echo "    make status         컨테이너 상태 및 GPU 정보 출력"
	@echo ""
	@echo "  [개발 환경 (Dev)]"
	@echo "    make ros            ROS 컨테이너 시작 (NVIDIA 자동 감지)"
	@echo "    make dev            순수 환경 컨테이너 시작 (NVIDIA 자동 감지)"
	@echo "    make ros-shell      ROS 컨테이너 셸 진입"
	@echo "    make dev-shell      순수 환경 셸 진입"
	@echo "    make build-ros      ROS 이미지 빌드"
	@echo "    make build-dev      순수 환경 이미지 빌드"
	@echo ""
	@echo "  [배포 환경 (Prod)]"
	@echo "    make ros-prod       ROS 릴리즈 서비스 시작 (NVIDIA 자동 감지)"
	@echo "    make dev-prod       순수 릴리즈 서비스 시작 (NVIDIA 자동 감지)"
	@echo ""
	@echo "  [유지보수]"
	@echo "    make clean          임시 볼륨 및 빌드 아티팩트 삭제"
	@echo "    make clean-all      모든 볼륨 및 캐시 완전 초기화"
	@echo ""

# =============================================================================
# 초기 설정 및 상태 확인
# =============================================================================
setup:
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "  .env 파일이 생성되었습니다. 설정을 수정하세요."; \
	else \
		echo "  .env 파일이 이미 존재합니다."; \
	fi
	@$(MAKE) xauth

status: check
	@echo ""
	@echo "  [프로젝트 상태 정보]"
	@echo "  ---------------------------------------------------"
	@echo "  프로젝트 이름: $(COMPOSE_PROJECT_NAME)"
	@echo "  ROS 버전:      $(ROS_DISTRO)"
	@echo "  아키텍처:      $(HOST_ARCH)"
	@echo "  디스플레이:    $(DISPLAY) ($(DISPLAY_TYPE))"
	@echo "  ---------------------------------------------------"
	@echo "  [GPU 가속 상태]"
	@if [ "$(HAS_NVIDIA)" = "true" ]; then \
		echo "  NVIDIA GPU:     검출됨"; \
		if [ "$(HAS_TOOLKIT)" = "true" ]; then \
			echo "  Docker 런타임:  NVIDIA Container Toolkit 활성"; \
		else \
			echo "  Docker 런타임:  [경고] NVIDIA Container Toolkit 미검출 (CPU 모드로 동작)"; \
		fi \
	else \
		echo "  GPU 가속:       기본 모드 (Intel/AMD/CPU)"; \
	fi
	@echo "  ---------------------------------------------------"
	@echo "  [실행 중인 컨테이너]"
	@docker ps --filter "name=$(COMPOSE_PROJECT_NAME)" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
	@echo "  ---------------------------------------------------"
	@echo "  [생성된 도커 볼륨]"
	@docker volume ls --filter "name=$(COMPOSE_PROJECT_NAME)" --format "table {{.Name}}\t{{.Driver}}"
	@echo "  ---------------------------------------------------"
	@if [ "$(HAS_NVIDIA)" = "true" ]; then \
		echo "  [NVIDIA GPU 상세]"; \
		nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits | sed 's/^/  /'; \
	fi
	@echo ""

check-host:
	@if [ "$(HAS_NVIDIA)" = "true" ] && [ "$(HAS_TOOLKIT)" = "false" ]; then \
		echo "  [경고] NVIDIA GPU가 감지되었으나 NVIDIA Container Toolkit이 없습니다."; \
		echo "  설치 안내: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"; \
	fi
	@if [ -n "$(DISPLAY)" ] && ! xhost > /dev/null 2>&1; then \
		echo "  [경고] X11 권한 확인 불가. xhost +local:root 실행이 필요할 수 있습니다."; \
	fi

xauth:
	@touch ~/.Xauthority
	@if command -v xauth &> /dev/null && [ -n "$$DISPLAY" ]; then \
		xauth nlist $$DISPLAY | sed -e 's/^..../ffff/' | xauth -f ~/.Xauthority nmerge - 2>/dev/null || true; \
	fi

check: check-host
	@if [ ! -f .env ]; then echo "  오류: .env가 없습니다. make setup 실행 필요"; exit 1; fi
	@mkdir -p ~/.ssh && touch ~/.gitconfig ~/.Xauthority

# =============================================================================
# 빌드 (Build)
# =============================================================================
build-ros: check
	$(COMPOSE) build ros-basic

build-dev: check
	$(COMPOSE) build basic

rebuild-ros: check
	$(COMPOSE) build --no-cache ros-basic

rebuild-dev: check
	$(COMPOSE) build --no-cache basic

# =============================================================================
# 실행 및 셸 진입 (Dev) - 자동 GPU 감지
# =============================================================================
ros: check xauth
	@if [ "$(HAS_NVIDIA)" = "true" ] && [ "$(HAS_TOOLKIT)" = "true" ]; then \
		echo "  NVIDIA 모드로 ROS 환경을 시작합니다..."; \
		GPU_MODE=nvidia $(COMPOSE) --profile ros-nvidia up -d ros-nvidia; \
	else \
		echo "  기본 모드로 ROS 환경을 시작합니다..."; \
		$(COMPOSE) up -d ros-basic; \
	fi
	@echo "  셸 진입: make ros-shell"

dev: check xauth
	@if [ "$(HAS_NVIDIA)" = "true" ] && [ "$(HAS_TOOLKIT)" = "true" ]; then \
		echo "  NVIDIA 모드로 순수 개발 환경을 시작합니다..."; \
		GPU_MODE=nvidia $(COMPOSE) --profile nvidia up -d nvidia; \
	else \
		echo "  기본 모드로 순수 개발 환경을 시작합니다..."; \
		$(COMPOSE) up -d basic; \
	fi
	@echo "  셸 진입: make dev-shell"

ros-shell: check
	@if docker ps --format '{{.Names}}' | grep -q "$(COMPOSE_PROJECT_NAME)_ros"; then \
		docker exec -it $$(docker ps --filter "name=$(COMPOSE_PROJECT_NAME)_ros" --format "{{.Names}}" | head -n 1) bash; \
	else \
		echo "  실행 중인 ROS 컨테이너가 없습니다. make ros를 먼저 실행하세요."; \
	fi

dev-shell: check
	@if docker ps --format '{{.Names}}' | grep -q "$(COMPOSE_PROJECT_NAME)_basic\|$(COMPOSE_PROJECT_NAME)_nvidia"; then \
		docker exec -it $$(docker ps --filter "name=$(COMPOSE_PROJECT_NAME)_basic\|$(COMPOSE_PROJECT_NAME)_nvidia" --format "{{.Names}}" | head -n 1) bash; \
	else \
		echo "  실행 중인 개발 컨테이너가 없습니다. make dev를 먼저 실행하세요."; \
	fi

# =============================================================================
# 배포 실행 (Prod) - 자동 GPU 감지
# =============================================================================
ros-prod: check
	@if [ "$(HAS_NVIDIA)" = "true" ] && [ "$(HAS_TOOLKIT)" = "true" ]; then \
		echo "  NVIDIA 모드로 ROS 배포 서비스를 시작합니다..."; \
		$(COMPOSE) -f docker-compose.prod.yml --profile ros-nv up -d; \
	else \
		echo "  기본 모드로 ROS 배포 서비스를 시작합니다..."; \
		$(COMPOSE) -f docker-compose.prod.yml --profile ros up -d; \
	fi

dev-prod: check
	@if [ "$(HAS_NVIDIA)" = "true" ] && [ "$(HAS_TOOLKIT)" = "true" ]; then \
		echo "  NVIDIA 모드로 순수 배포 서비스를 시작합니다..."; \
		$(COMPOSE) -f docker-compose.prod.yml --profile dev-nv up -d; \
	else \
		echo "  기본 모드로 순수 배포 서비스를 시작합니다..."; \
		$(COMPOSE) -f docker-compose.prod.yml --profile dev up -d; \
	fi

# =============================================================================
# 유지보수
# =============================================================================
down:
	$(COMPOSE) down

logs:
	@if [ -f docker-compose.prod.yml ] && docker compose -f docker-compose.prod.yml ps --format '{{.Names}}' | grep -q "$(COMPOSE_PROJECT_NAME)"; then \
		echo "  [Prod] 배포 환경 로그를 스트리밍합니다..."; \
		docker compose -f docker-compose.prod.yml logs -f --tail 100; \
	else \
		echo "  [Dev] 개발 환경 로그를 스트리밍합니다..."; \
		docker compose logs -f --tail 100; \
	fi

clean-builder:
	@echo "  Docker BuildKit 캐시를 정리하여 용량을 확보합니다..."
	docker builder prune -f

clean: down
	$(COMPOSE) down -v
	@docker volume rm $(COMPOSE_PROJECT_NAME)_ros_build_$(ROS_DISTRO) 2>/dev/null || true
	@docker volume rm $(COMPOSE_PROJECT_NAME)_ros_install_$(ROS_DISTRO) 2>/dev/null || true
	@docker volume rm $(COMPOSE_PROJECT_NAME)_ros_log_$(ROS_DISTRO) 2>/dev/null || true

clean-cache:
	@CACHE_DIR=$(WORKSPACE_PATH)/.docker_cache; \
	if [ -d "$$CACHE_DIR" ]; then \
		echo "  호스트 측 도커 캐시 폴더($$CACHE_DIR)를 삭제합니다..."; \
		sudo rm -rf "$$CACHE_DIR"; \
	fi

clean-all: down
	@echo "  $(COMPOSE_PROJECT_NAME) 관련 모든 리소스(컨테이너, 볼륨)를 삭제합니다..."
	$(COMPOSE) down -v --remove-orphans
	@echo "  잔여 프로젝트 볼륨 강제 삭제 중..."
	@VOLUMES=$$(docker volume ls -q --filter "name=$(COMPOSE_PROJECT_NAME)"); \
	if [ -n "$$VOLUMES" ]; then \
		docker volume rm $$VOLUMES 2>/dev/null || true; \
	fi
	@CACHE_DIR=$(WORKSPACE_PATH)/.docker_cache; \
	if [ -d "$$CACHE_DIR" ]; then \
		read -p "  $$CACHE_DIR (ccache, uv 등)도 삭제하시겠습니까? [y/N] " ans; \
		if [ "$$ans" = "y" ] || [ "$$ans" = "Y" ]; then \
			sudo rm -rf "$$CACHE_DIR"; \
		fi \
	fi

