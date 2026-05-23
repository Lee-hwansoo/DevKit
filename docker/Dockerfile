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
ARG SYS_PYTHON_EXE=""
ARG UV_SYNC_FLAGS=""
ARG CMAKE_EXTRA_ARGS=""
ARG COLCON_EXTRA_FLAGS=""
ARG HAS_NVIDIA=false
ARG FULL_CUDA=false
ARG CUDA_VERSION=""
ARG CUDNN_VERSION=""

# ── Stage: uv-binaries (Dependency Management Engine) ────────────────────────
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-binaries

# ── Stage: base (Canonical OS Foundation) ────────────────────────────────────
FROM ${BASE_IMAGE} AS base
ARG LANG
ARG TZ
ARG DEBIAN_FRONTEND
ARG WORKSPACE_PATH
ARG ROS_DISTRO
ARG APT_SNAPSHOT_DATE
ARG HAS_NVIDIA
ARG CUDA_VERSION
ENV LANG=${LANG} \
    LC_ALL=${LANG} \
    TZ=${TZ} \
    DEBIAN_FRONTEND=${DEBIAN_FRONTEND} \
    ROS_DISTRO=${ROS_DISTRO}

RUN --mount=type=bind,source=scripts/util_apt_helper.sh,target=/tmp/util_apt_helper.sh \
    --mount=type=bind,source=scripts/util_logging.sh,target=/tmp/util_logging.sh \
    --mount=type=bind,source=dependencies/,target=${WORKSPACE_PATH}/dependencies/ \
    chmod +x /tmp/util_apt_helper.sh /tmp/util_logging.sh && \
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
    if [ "$FULL_CUDA" = "true" ]; then \
    PACKAGES="cuda-${major_minor}"; \
    else \
    PACKAGES="cuda-cudart-${major_minor} cuda-nvtx-${major_minor} libcublas-${major_minor}"; \
    fi; \
    apt-get update && apt-get install -y --no-install-recommends $PACKAGES; \
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
RUN chmod +x /entrypoint.sh

# ── Stage: dev-base-tools (Compilers, GUI & Diagnostics) ─────────────────────
FROM base AS dev-base-tools
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=dependencies/,target=${WORKSPACE_PATH}/dependencies/ \
    apt-get update && apt-get install -y --no-install-recommends \
    # base-tools
    sudo bash-completion ca-certificates curl file gnupg2 htop iproute2 jq lsb-release net-tools nvtop software-properties-common tree unzip wget \
    fonts-noto-color-emoji fonts-font-awesome \
    # build-tools
    build-essential ccache cmake g++ gcc gdb git libasio-dev libboost-all-dev libeigen3-dev libtbb-dev libyaml-cpp-dev make ninja-build python3-dev \
    # gui-tools
    dbus-x11 clinfo fontconfig libegl1-mesa-dev libgl1-mesa-dri libgl1-mesa-glx libglfw3-dev libglx-mesa0 libqt5waylandclient5 libvulkan-dev libwayland-client0 libxkbcommon0 mesa-utils mesa-vulkan-drivers qtwayland5 terminator vulkan-tools vulkan-validationlayers x11-apps x11-utils && \
    # Install D2Coding Font
    if [ -f ${WORKSPACE_PATH}/dependencies/D2Coding.zip ]; then \
    unzip -q ${WORKSPACE_PATH}/dependencies/D2Coding.zip -d /usr/share/fonts/truetype/d2coding; \
    else \
    curl -sfL --retry 3 --retry-delay 2 https://github.com/naver/d2codingfont/releases/download/VER1.3.2/D2Coding-Ver1.3.2-20180524.zip -o /tmp/d2coding.zip && \
    unzip -q /tmp/d2coding.zip -d /usr/share/fonts/truetype/d2coding && rm -f /tmp/d2coding.zip; \
    fi; \
    fc-cache -f && \
    apt-get autoremove -y && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create a non-root user with UID/GID and passwordless sudo
ARG CONTAINER_USER=user
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN groupadd --gid $USER_GID $CONTAINER_USER \
    && useradd --uid $USER_UID --gid $USER_GID -m $CONTAINER_USER \
    && echo $CONTAINER_USER ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$CONTAINER_USER \
    && chmod 0440 /etc/sudoers.d/$CONTAINER_USER

# CUDA Toolkit Installation (Conditional)
ARG CUDA_VERSION
ARG CUDNN_VERSION
ARG HAS_NVIDIA
ARG LD_LIBRARY_PATH

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "$HAS_NVIDIA" = "true" ] && [ -n "$CUDA_VERSION" ]; then \
    major_minor=$(echo $CUDA_VERSION | sed -E 's/^([0-9]+)\.([0-9]+).*/\1-\2/'); \
    if [ "$FULL_CUDA" = "true" ]; then \
    PACKAGES="cuda-${major_minor}"; \
    else \
    PACKAGES="cuda-nvcc-${major_minor} \
    cuda-compiler-${major_minor} \
    cuda-libraries-dev-${major_minor} \
    cuda-visual-tools-${major_minor} \
    cuda-cudart-dev-${major_minor} \
    libcublas-dev-${major_minor} \
    cuda-nvml-dev-${major_minor} \
    cuda-command-line-tools-${major_minor}"; \
    fi; \
    apt-get update && apt-get install -y --no-install-recommends $PACKAGES; \
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
    rm -rf /var/lib/apt/lists/*; \
    ldconfig; \
    fi

ENV PATH=/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}
ENV CUDA_HOME=/usr/local/cuda

# Architecture-dependent packages (may not be installed on ARM64)
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get install -y --no-install-recommends intel-gpu-tools intel-opencl-icd || true && \
    rm -rf /var/lib/apt/lists/*

# ── Stage: dev-core (Python Runtime & Environment Orchestration) ─────────────
FROM dev-base-tools AS dev-core
ARG WORKSPACE_PATH
ARG CONTAINER_USER=user
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
    BASH_ENV=/home/${CONTAINER_USER}/.bashrc

RUN mkdir -p ${CCACHE_DIR} ${UV_CACHE_DIR} ${WORKSPACE_PATH}/install

COPY docker/entrypoint.sh /entrypoint.sh
COPY config/  ${WORKSPACE_PATH}/config/
COPY scripts/ ${WORKSPACE_PATH}/scripts/
RUN chmod +x /entrypoint.sh ${WORKSPACE_PATH}/scripts/*.sh ${WORKSPACE_PATH}/config/*.sh && \
    cat ${WORKSPACE_PATH}/config/init_bash.sh >> /root/.bashrc && \
    cat ${WORKSPACE_PATH}/config/init_bash.sh >> /home/${CONTAINER_USER}/.bashrc && \
    mkdir -p /root/.config/terminator /home/${CONTAINER_USER}/.config/terminator && \
    cp ${WORKSPACE_PATH}/config/terminator_config /root/.config/terminator/config 2>/dev/null || true && \
    cp ${WORKSPACE_PATH}/config/terminator_config /home/${CONTAINER_USER}/.config/terminator/config 2>/dev/null || true && \
    chown -R ${CONTAINER_USER}:${CONTAINER_USER} /home/${CONTAINER_USER}
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
    rosdep update --rosdistro ${ROS_DISTRO} && \
    rm -rf /var/lib/apt/lists/*

FROM ros-base AS ros
ARG WORKSPACE_PATH
ENV COLCON_HOME=${WORKSPACE_PATH}
WORKDIR ${WORKSPACE_PATH}

RUN mkdir -p src && ${WORKSPACE_PATH}/scripts/util_setup_links.sh
RUN SYNC_TARGET_DIR=/tmp/staging ${WORKSPACE_PATH}/scripts/setup_sync_deps.sh --rosdep && \
    rm -rf /tmp/staging

# ── Stage: python-deps (Python Dependency Caching Layer) ────────────────────
FROM dev-core AS python-deps
ARG WORKSPACE_PATH
ARG UV_SYNC_FLAGS
WORKDIR ${WORKSPACE_PATH}
ENV UV_PROJECT_ENVIRONMENT="${WORKSPACE_PATH}/install/.venv"
RUN --mount=type=cache,target=/cache/uv,sharing=locked \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=dependencies/requirements.txt,target=${WORKSPACE_PATH}/dependencies/requirements.txt \
    uv venv ${UV_PROJECT_ENVIRONMENT} && \
    if [ -f pyproject.toml ] && [ -f uv.lock ]; then \
    uv sync --frozen --no-install-project ${UV_SYNC_FLAGS}; \
    elif [ -f ${WORKSPACE_PATH}/dependencies/requirements.txt ]; then \
    uv pip install -r ${WORKSPACE_PATH}/dependencies/requirements.txt; \
    fi

# ── Stage: builder-dev (C++ & Pure Python Build Orchestration) ──────────────
FROM python-deps AS builder-dev
ARG WORKSPACE_PATH
ARG ROS_DISTRO
ARG UV_SYNC_FLAGS
ARG CMAKE_EXTRA_ARGS
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=scripts/util_apt_helper.sh,target=/tmp/util_apt_helper.sh \
    --mount=type=bind,source=scripts/util_logging.sh,target=/tmp/util_logging.sh \
    /tmp/util_apt_helper.sh install-packages all
COPY s[r]c/ src/
RUN --mount=type=cache,target=/cache/uv,sharing=locked \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    if [ -f pyproject.toml ] && [ -f uv.lock ]; then uv sync --frozen ${UV_SYNC_FLAGS}; fi
RUN ${WORKSPACE_PATH}/scripts/util_setup_links.sh && \
    SYNC_TARGET_DIR=src/thirdparty ${WORKSPACE_PATH}/scripts/setup_sync_deps.sh
RUN --mount=type=cache,target=/cache/ccache,sharing=locked \
    mkdir -p build && cd build && \
    cmake ../src -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${WORKSPACE_PATH}/install -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD} -DPYTHON_EXECUTABLE=$(bash ${WORKSPACE_PATH}/scripts/util_get_python.sh) ${CMAKE_EXTRA_ARGS} && \
    make -j$(nproc) install && \
    bash ${WORKSPACE_PATH}/scripts/check_deps.sh ${WORKSPACE_PATH}/install

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
    --mount=type=bind,source=scripts/util_apt_helper.sh,target=/tmp/util_apt_helper.sh \
    --mount=type=bind,source=scripts/util_logging.sh,target=/tmp/util_logging.sh \
    /tmp/util_apt_helper.sh install-packages all ${ROS_DISTRO} && \
    rosdep update --rosdistro ${ROS_DISTRO} && \
    ${WORKSPACE_PATH}/scripts/util_setup_links.sh && \
    SYNC_TARGET_DIR=src/thirdparty ${WORKSPACE_PATH}/scripts/setup_sync_deps.sh --rosdep && \
    rm -rf /var/lib/apt/lists/*
RUN --mount=type=cache,target=/cache/uv,sharing=locked \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    if [ -f pyproject.toml ] && [ -f uv.lock ]; then uv sync --frozen ${UV_SYNC_FLAGS}; fi
RUN --mount=type=cache,target=/cache/ccache,sharing=locked \
    . /opt/ros/${ROS_DISTRO}/setup.sh && \
    colcon build ${COLCON_EXTRA_FLAGS} --cmake-args -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD} -DPYTHON_EXECUTABLE=$(bash ${WORKSPACE_PATH}/scripts/util_get_python.sh) ${CMAKE_EXTRA_ARGS} --install-base ${WORKSPACE_PATH}/install && \
    bash ${WORKSPACE_PATH}/scripts/check_deps.sh ${WORKSPACE_PATH}/install

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
