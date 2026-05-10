# =============================================================================
# docker/Dockerfile
# Multi-stage Integrated Dockerfile (Dev & Prod)
# =============================================================================

# ── Global Build Arguments (Single Source of Truth) ──────────────────────────
ARG BASE_IMAGE=ubuntu:22.04
ARG WORKSPACE_PATH=/workspace
ARG ROS_DISTRO=humble
ARG APT_SNAPSHOT_DATE=latest
ARG UV_VERSION=0.10.10
ARG UV_PYTHON=3.10
ARG CMAKE_CXX_STANDARD=17
ARG LANG=C.UTF-8
ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH=amd64
ARG UV_SYNC_FLAGS=""
ARG CMAKE_EXTRA_ARGS=""
ARG COLCON_EXTRA_FLAGS=""
ARG HAS_NVIDIA=false
ARG CUDA_VERSION=""
ARG CUDNN_VERSION=""
ARG SYS_PYTHON_EXE=""

# ── Stage: uv-binaries (Dependency Management Engine) ────────────────────────
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-binaries

# ── Stage: base (Canonical OS Foundation) ────────────────────────────────────
FROM ${BASE_IMAGE} AS base
ARG LANG
ARG TZ
ARG DEBIAN_FRONTEND
ARG ROS_DISTRO
ARG APT_SNAPSHOT_DATE
ARG HAS_NVIDIA
ARG CUDA_VERSION
ENV LANG=${LANG} \
    LC_ALL=${LANG} \
    TZ=${TZ} \
    DEBIAN_FRONTEND=${DEBIAN_FRONTEND} \
    ROS_DISTRO=${ROS_DISTRO}

# Inject build-time helpers and dependency definitions
COPY scripts/util_apt_helper.sh /tmp/util_apt_helper.sh
COPY scripts/util_logging.sh /tmp/util_logging.sh
COPY dependencies/ /opt/dependencies/

RUN chmod +x /tmp/util_apt_helper.sh && \
    /tmp/util_apt_helper.sh init-apt && \
    /tmp/util_apt_helper.sh configure-snapshot ${APT_SNAPSHOT_DATE} && \
    if [ "$HAS_NVIDIA" = "true" ] && [ -n "$CUDA_VERSION" ]; then \
    /tmp/util_apt_helper.sh setup-cuda-repo ${CUDA_VERSION}; \
    fi

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    locales tzdata && \
    (locale-gen ${LANG} || [ "${LANG}" = "C.UTF-8" ]) && \
    update-locale LANG=${LANG} && \
    ln -snf /usr/share/zoneinfo/${TZ:-UTC} /etc/localtime && echo ${TZ:-UTC} > /etc/timezone
ENV LANG=${LANG} \
    LC_ALL=${LANG} \
    TZ=${TZ} \
    DEBIAN_FRONTEND=${DEBIAN_FRONTEND} \
    ROS_DISTRO=${ROS_DISTRO}

# ── Stage: runtime-common (Optimized Execution Context) ──────────────────────
FROM base AS runtime-common
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    libegl1-mesa libgl1-mesa-dri libglx-mesa0 mesa-utils

# CUDA Runtime Libraries (Conditional - Minimal for Production)
ARG CUDA_VERSION
ARG CUDNN_VERSION
ARG HAS_NVIDIA
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "$HAS_NVIDIA" = "true" ] && [ -n "$CUDA_VERSION" ]; then \
    major_minor=$(echo $CUDA_VERSION | sed -E 's/^([0-9]+)\.([0-9]+).*/\1-\2/'); \
    # Install runtime-side CUDA userspace libraries only.
    apt-get update && apt-get install -y --no-install-recommends \
    cuda-cudart-${major_minor} \
    cuda-nvtx-${major_minor} \
    libcublas-${major_minor}; \
    if [ -n "$CUDNN_VERSION" ]; then \
    if [ "${CUDNN_VERSION%%.*}" -ge 9 ]; then \
    cuda_major=$(echo $CUDA_VERSION | cut -d. -f1); \
    apt-get install -y --no-install-recommends libcudnn${CUDNN_VERSION}-cuda-${cuda_major}; \
    else \
    apt-get install -y --no-install-recommends libcudnn${CUDNN_VERSION}; \
    fi; \
    fi; \
    # Purge container-side NVIDIA driver userspace packages if they were pulled transitively.
    # This is critical to ensure the container uses the host's driver via nvidia-container-runtime.
    apt-get purge -y "libnvidia-compute-[0-9]*" "nvidia-compute-utils-[0-9]*" "nvidia-utils-[0-9]*" "libnvidia-extra-[0-9]*" || true; \
    apt-get autoremove -y || true; \
    apt-get clean; \
    ldconfig; \
    fi

# Note: entrypoint.sh is also copied in dev-core (inheritance tree differs so duplication is required)
COPY docker/entrypoint.sh /entrypoint.sh
COPY config/util_aliases.sh /opt/scripts/util_aliases.sh
COPY config/init_ros_env.sh /opt/scripts/init_ros_env.sh
COPY scripts/setup_gpu.sh /opt/scripts/setup_gpu.sh
COPY scripts/util_logging.sh /opt/scripts/util_logging.sh
COPY scripts/util_gpu_detect.sh /opt/scripts/util_gpu_detect.sh
COPY scripts/check_env.sh /opt/scripts/check_env.sh
COPY scripts/check_hardware.sh /opt/scripts/check_hardware.sh
COPY scripts/util_get_python.sh /opt/scripts/util_get_python.sh
COPY scripts/show_welcome.sh /opt/scripts/show_welcome.sh
RUN chmod +x /entrypoint.sh /opt/scripts/*.sh

# ── Stage: dev-base-tools (Compilers, GUI & Diagnostics) ─────────────────────
FROM base AS dev-base-tools
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    # base-tools
    bash-completion ca-certificates curl file gnupg2 htop iproute2 jq lsb-release net-tools nvtop software-properties-common tree unzip wget \
    fonts-noto-color-emoji fonts-font-awesome \
    # build-tools
    build-essential ccache cmake g++ gcc gdb git libasio-dev libboost-all-dev libeigen3-dev libtbb-dev libyaml-cpp-dev make ninja-build python3-dev \
    # gui-tools
    dbus-x11 clinfo fontconfig libegl1-mesa-dev libgl1-mesa-dri libgl1-mesa-glx libglfw3-dev libglx-mesa0 libqt5waylandclient5 libvulkan-dev libwayland-client0 libxkbcommon0 mesa-utils mesa-vulkan-drivers qtwayland5 terminator vulkan-tools vulkan-validationlayers x11-apps x11-utils

# CUDA Toolkit Installation (Conditional)
ARG CUDA_VERSION
ARG CUDNN_VERSION
ARG HAS_NVIDIA
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "$HAS_NVIDIA" = "true" ] && [ -n "$CUDA_VERSION" ]; then \
    major_minor=$(echo $CUDA_VERSION | sed -E 's/^([0-9]+)\.([0-9]+).*/\1-\2/'); \
    # Install development-side CUDA userspace libraries and toolchain.
    apt-get update && apt-get install -y --no-install-recommends \
    cuda-nvcc-${major_minor} \
    cuda-compiler-${major_minor} \
    cuda-cudart-dev-${major_minor} \
    libcublas-dev-${major_minor} \
    cuda-nvml-dev-${major_minor} \
    cuda-command-line-tools-${major_minor}; \
    if [ -n "$CUDNN_VERSION" ]; then \
    if [ "${CUDNN_VERSION%%.*}" -ge 9 ]; then \
    cuda_major=$(echo $CUDA_VERSION | cut -d. -f1); \
    apt-get install -y --no-install-recommends libcudnn${CUDNN_VERSION}-cuda-${cuda_major} libcudnn${CUDNN_VERSION}-dev-cuda-${cuda_major}; \
    else \
    apt-get install -y --no-install-recommends libcudnn${CUDNN_VERSION} libcudnn${CUDNN_VERSION}-dev; \
    fi; \
    fi; \
    # Purge container-side NVIDIA driver userspace packages if they were pulled transitively.
    # This is critical to ensure the container uses the host's driver via nvidia-container-runtime.
    apt-get purge -y "libnvidia-compute-[0-9]*" "nvidia-compute-utils-[0-9]*" "nvidia-utils-[0-9]*" "libnvidia-extra-[0-9]*" || true; \
    apt-get autoremove -y || true; \
    apt-get clean; \
    ldconfig; \
    fi

# Architecture-dependent packages (may not be installed on ARM64)
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get install -y --no-install-recommends intel-gpu-tools intel-opencl-icd || true

# D2Coding Font
RUN if [ -f /opt/dependencies/D2Coding.zip ]; then \
    unzip -q /opt/dependencies/D2Coding.zip -d /usr/share/fonts/truetype/d2coding; \
    else \
    curl -sfL https://github.com/naver/d2codingfont/releases/download/VER1.3.2/D2Coding-Ver1.3.2-20180524.zip -o /tmp/d2coding.zip && \
    unzip -q /tmp/d2coding.zip -d /usr/share/fonts/truetype/d2coding && rm -f /tmp/d2coding.zip; \
    fi; \
    fc-cache -f || true

# ── Stage: dev-core (Python Runtime & Environment Orchestration) ─────────────
FROM dev-base-tools AS dev-core
ARG WORKSPACE_PATH
ARG SYS_PYTHON_EXE
ARG UV_VERSION
ARG UV_PYTHON
ARG CMAKE_CXX_STANDARD

# Install uv and setup Python
COPY --from=uv-binaries /uv /uvx /usr/local/bin/
RUN uv python install ${UV_PYTHON}

ENV PATH="/usr/lib/ccache:${WORKSPACE_PATH}/install/.venv/bin:$PATH" \
    CCACHE_DIR=/cache/ccache \
    UV_CACHE_DIR=/cache/uv \
    UV_PYTHON=${UV_PYTHON} \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    VIRTUAL_ENV=${WORKSPACE_PATH}/install/.venv \
    CMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD} \
    SYS_PYTHON_EXE=${SYS_PYTHON_EXE} \
    BASH_ENV=/root/.bashrc

RUN mkdir -p ${CCACHE_DIR} ${UV_CACHE_DIR} ${WORKSPACE_PATH}/install

COPY config/  /docker_dev/config/
COPY scripts/ /docker_dev/scripts/
RUN chmod +x /docker_dev/scripts/*.sh && \
    cat /docker_dev/config/init_bash.sh >> /root/.bashrc && \
    mkdir -p /root/.config/terminator && cp /docker_dev/config/terminator_config /root/.config/terminator/config 2>/dev/null || true

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]

# ── Stage: dev targets (Interactive Developer Environments) ─────────────────
FROM dev-core AS dev
ARG WORKSPACE_PATH
ARG ROS_DISTRO
ENV COLCON_HOME=${WORKSPACE_PATH}
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/util_apt_helper.sh install-packages all
WORKDIR ${WORKSPACE_PATH}

FROM dev-core AS ros-base
ARG ROS_DISTRO
ENV ROS_DISTRO=${ROS_DISTRO}
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/util_apt_helper.sh setup-ros-repo ${ROS_DISTRO}
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/util_apt_helper.sh install-packages all ${ROS_DISTRO} && \
    (rosdep init || true) && \
    rosdep update --rosdistro ${ROS_DISTRO}

FROM ros-base AS ros
ARG WORKSPACE_PATH
ENV COLCON_HOME=${WORKSPACE_PATH}
RUN mkdir -p ${WORKSPACE_PATH}/src && \
    ln -sf /docker_dev/config/colcon.meta ${WORKSPACE_PATH}/colcon.meta
RUN SYNC_TARGET_DIR=/tmp/staging /docker_dev/scripts/setup_sync_deps.sh --rosdep && \
    rm -rf /tmp/staging
WORKDIR ${WORKSPACE_PATH}

# ── Stage: python-deps (Python Dependency Caching Layer) ────────────────────
FROM dev-core AS python-deps
ARG WORKSPACE_PATH
ARG UV_SYNC_FLAGS
WORKDIR ${WORKSPACE_PATH}
COPY pyproject.toml* uv.lock* ./
ENV UV_PROJECT_ENVIRONMENT="${WORKSPACE_PATH}/install/.venv"
RUN --mount=type=cache,target=/cache/uv,sharing=locked \
    uv venv ${UV_PROJECT_ENVIRONMENT} && \
    if [ -f pyproject.toml ] && [ -f uv.lock ]; then \
    uv sync --frozen --no-install-project ${UV_SYNC_FLAGS}; \
    elif [ -f /opt/dependencies/requirements.txt ]; then \
    uv pip install -r /opt/dependencies/requirements.txt; \
    fi

# ── Stage: builder-dev (C++ & Pure Python Build Orchestration) ──────────────
FROM python-deps AS builder-dev
ARG WORKSPACE_PATH
ARG ROS_DISTRO
ARG UV_SYNC_FLAGS
ARG CMAKE_EXTRA_ARGS
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/util_apt_helper.sh install-packages all
COPY s[r]c/ src/
RUN --mount=type=cache,target=/cache/uv,sharing=locked \
    if [ -f pyproject.toml ] && [ -f uv.lock ]; then uv sync --frozen ${UV_SYNC_FLAGS}; fi
RUN --mount=type=cache,target=/cache/ccache,sharing=locked \
    mkdir -p build && cd build && \
    cmake ../src -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${WORKSPACE_PATH}/install -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD} -DPYTHON_EXECUTABLE=$(bash /docker_dev/scripts/util_get_python.sh) ${CMAKE_EXTRA_ARGS} && \
    make -j$(nproc) && make install && \
    bash /docker_dev/scripts/check_deps.sh ${WORKSPACE_PATH}/install

# ── Stage: builder-ros (ROS Workspace Orchestration) ─────────────────────────
FROM ros-base AS builder-ros
ARG WORKSPACE_PATH
ARG UV_SYNC_FLAGS
ARG CMAKE_EXTRA_ARGS
ARG COLCON_EXTRA_FLAGS
WORKDIR ${WORKSPACE_PATH}
COPY --from=python-deps ${WORKSPACE_PATH}/install/.venv ${WORKSPACE_PATH}/install/.venv
COPY pyproject.toml* uv.lock* ./
COPY s[r]c/ src/
ENV UV_PROJECT_ENVIRONMENT="${WORKSPACE_PATH}/install/.venv"
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/util_apt_helper.sh install-packages all ${ROS_DISTRO} && \
    rosdep update --rosdistro ${ROS_DISTRO} && \
    ln -s /opt/dependencies ${WORKSPACE_PATH}/dependencies && \
    SYNC_TARGET_DIR=src/thirdparty /docker_dev/scripts/setup_sync_deps.sh --rosdep
RUN --mount=type=cache,target=/cache/uv,sharing=locked \
    if [ -f pyproject.toml ] && [ -f uv.lock ]; then uv sync --frozen ${UV_SYNC_FLAGS}; fi
RUN --mount=type=cache,target=/cache/ccache,sharing=locked \
    . /opt/ros/${ROS_DISTRO}/setup.sh && \
    colcon build ${COLCON_EXTRA_FLAGS} --cmake-args -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD} -DPYTHON_EXECUTABLE=$(bash /docker_dev/scripts/util_get_python.sh) ${CMAKE_EXTRA_ARGS} --install-base ${WORKSPACE_PATH}/install && \
    bash /docker_dev/scripts/check_deps.sh ${WORKSPACE_PATH}/install

# ── Final Production Runtime Images (Switch Strategy) ────────────────────────
FROM runtime-common AS dev-runtime
ARG WORKSPACE_PATH
WORKDIR ${WORKSPACE_PATH}
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/util_apt_helper.sh install-packages runtime && \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder-dev ${WORKSPACE_PATH}/install ${WORKSPACE_PATH}/install
ENV PATH="${WORKSPACE_PATH}/install/.venv/bin:${WORKSPACE_PATH}/install/bin:$PATH" VIRTUAL_ENV="${WORKSPACE_PATH}/install/.venv"
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]

FROM runtime-common AS ros-runtime
ARG WORKSPACE_PATH
WORKDIR ${WORKSPACE_PATH}
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/util_apt_helper.sh setup-ros-repo ${ROS_DISTRO}
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/util_apt_helper.sh install-packages runtime ${ROS_DISTRO} && \
    apt-get update && apt-get install -y --no-install-recommends \
    ros-${ROS_DISTRO}-ros-base \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder-ros ${WORKSPACE_PATH}/install ${WORKSPACE_PATH}/install
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
