# =============================================================================
# ros2_docker_template/docker/Dockerfile
# 멀티스테이지 기반 통합 Dockerfile (Dev & Prod)
# =============================================================================

# ── 전역 빌드 인자 (Global ARGs) ─────────────────────────────────────────────
ARG BASE_IMAGE=ubuntu:22.04
ARG ROS_DISTRO=humble
ARG APT_SNAPSHOT_DATE=latest
ARG UV_VERSION=0.10.10
ARG UV_PYTHON=3.10
ARG CMAKE_CXX_STANDARD=17

# ── Stage 1: base (Shared OS Context) ───────────────────────────────────────
FROM ${BASE_IMAGE} AS base

ARG DEBIAN_FRONTEND=noninteractive
ARG LANG=ko_KR.UTF-8
ARG APT_SNAPSHOT_DATE

# 공통 빌드 헬퍼 복사 및 초기화
COPY scripts/internal_apt_helper.sh /tmp/internal_apt_helper.sh
RUN chmod +x /tmp/internal_apt_helper.sh && \
    /tmp/internal_apt_helper.sh init-apt && \
    /tmp/internal_apt_helper.sh configure-snapshot ${APT_SNAPSHOT_DATE}

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends locales \
    && locale-gen ${LANG} \
    && update-locale LANG=${LANG}

ENV LANG=${LANG} \
    LC_ALL=${LANG}

# ── Stage 2: base-tools (Shared Utilities) ───────────────────────────────
FROM base AS base-tools

ARG DEBIAN_FRONTEND=noninteractive

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    bash-completion ca-certificates curl gnupg2 htop iproute2 jq lsb-release net-tools nvtop software-properties-common tree unzip wget

# ── Stage 3: build-tools (Compilers & Libraries) ───────────────────────────
FROM base-tools AS build-tools

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential ccache cmake g++ gcc gdb git libasio-dev libboost-all-dev libeigen3-dev libtbb-dev libyaml-cpp-dev make ninja-build python3-dev python3-pip python3-venv

# ── Stage 4: gui-tools (Graphics & Display) ───────────────────────────────
FROM build-tools AS gui-tools

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    clinfo fontconfig libegl1-mesa-dev libgl1-mesa-dri libgl1-mesa-glx libglfw3-dev libglx-mesa0 libqt5waylandclient5 libvulkan-dev libwayland-client0 libxkbcommon0 mesa-utils mesa-vulkan-drivers qtwayland5 terminator vulkan-tools vulkan-validationlayers x11-apps x11-utils

# Intel GPU 기본 지원 패키지
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    intel-gpu-tools intel-opencl-icd || true

# D2Coding 폰트 (한국어 환경)
RUN wget -q https://github.com/naver/d2codingfont/releases/download/VER1.3.2/D2Coding-Ver1.3.2-20180524.zip -O /tmp/d2coding.zip \
    && unzip -q /tmp/d2coding.zip -d /usr/share/fonts/truetype/d2coding \
    && rm /tmp/d2coding.zip \
    && fc-cache -f || true

# ── Stage 5: python-runtime ────────────────────────────────────────────────
FROM gui-tools AS python-runtime

ARG UV_VERSION
ARG UV_PYTHON
ARG TARGETARCH

RUN case "${TARGETARCH}" in \
    amd64) UV_ARCH="x86_64-unknown-linux-musl" ;; \
    arm64) UV_ARCH="aarch64-unknown-linux-musl" ;; \
    *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && curl -LsSf "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin --strip-components=1 "uv-${UV_ARCH}/uv" \
    && chmod +x /usr/local/bin/uv

RUN uv python install ${UV_PYTHON}

# ── Stage 6: common (Dev Core Configuration) ───────────────────────────────
FROM python-runtime AS common

ARG CMAKE_CXX_STANDARD
ARG UV_PYTHON

RUN mkdir -p /cache/ccache /cache/uv /workspace/install

COPY config/  /docker_dev/config/
COPY scripts/ /docker_dev/scripts/
RUN chmod +x /docker_dev/scripts/*.sh

ENV PATH="/usr/lib/ccache:/workspace/install/.venv/bin:$PATH" \
    CCACHE_DIR=/cache/ccache \
    UV_CACHE_DIR=/cache/uv \
    UV_TOOL_DIR=/cache/uv/tools \
    UV_PYTHON=${UV_PYTHON} \
    VIRTUAL_ENV=/workspace/install/.venv \
    CMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD}

RUN cat /docker_dev/config/bashrc_common.sh >> /root/.bashrc
RUN mkdir -p /root/.config/terminator && cp /docker_dev/config/terminator_config /root/.config/terminator/config 2>/dev/null || true

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]

# ── Stage 7a: dev (Pure Dev Target) ─────────────────────────────────────────
FROM common AS dev
ARG ROS_DISTRO
RUN mkdir -p /workspace/src
ENV COLCON_HOME=/workspace
COPY dependencies/apt.txt /tmp/apt.txt
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/internal_apt_helper.sh install-packages all ${ROS_DISTRO}
WORKDIR /workspace

# ── Stage 7b: ros (ROS Dev Target) ──────────────────────────────────────────
FROM common AS ros-base
ARG DEBIAN_FRONTEND=noninteractive
ARG ROS_DISTRO

RUN /tmp/internal_apt_helper.sh setup-ros-repo ${ROS_DISTRO} && \
    apt-get update && \
    if [ "${ROS_DISTRO}" = "noetic" ]; then \
    apt-get install -y \
    ros-${ROS_DISTRO}-ros-base \
    ros-${ROS_DISTRO}-rviz \
    ros-${ROS_DISTRO}-rqt \
    ros-${ROS_DISTRO}-xacro \
    ros-${ROS_DISTRO}-cv-bridge \
    ros-${ROS_DISTRO}-tf \
    python3-catkin-tools \
    python3-colcon-common-extensions \
    python3-rosdep \
    python3-argcomplete \
    python3-vcstool \
    build-essential; \
    else \
    apt-get install -y \
    ros-${ROS_DISTRO}-ros-base \
    ros-${ROS_DISTRO}-rviz2 \
    ros-${ROS_DISTRO}-rqt \
    ros-${ROS_DISTRO}-rmw-cyclonedds-cpp \
    ros-${ROS_DISTRO}-gazebo-ros-pkgs \
    ros-${ROS_DISTRO}-xacro \
    ros-${ROS_DISTRO}-cv-bridge \
    ros-${ROS_DISTRO}-tf2-ros \
    python3-colcon-common-extensions \
    python3-rosdep \
    python3-argcomplete \
    python3-vcstool; \
    fi
RUN rosdep init && rosdep update --rosdistro ${ROS_DISTRO}

FROM ros-base AS ros
ARG ROS_DISTRO
ARG CMAKE_CXX_STANDARD
RUN mkdir -p /workspace/src
RUN cat /docker_dev/config/bashrc_ros.sh >> /root/.bashrc
RUN ln -sf /docker_dev/config/colcon.meta /workspace/colcon.meta

COPY dependencies/apt.txt /tmp/apt.txt
COPY dependencies/apt_ros.txt* /tmp/apt_ros.txt
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/internal_apt_helper.sh install-packages all ${ROS_DISTRO}

COPY dependencies/ /tmp/dependencies/
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    mkdir -p /tmp/staging && \
    if [ -f /tmp/dependencies/dependencies.repos ]; then vcs import /tmp/staging < /tmp/dependencies/dependencies.repos 2>/dev/null || true; fi && \
    if [ -d /tmp/dependencies/overlay ]; then cp -a /tmp/dependencies/overlay/. /tmp/staging/ 2>/dev/null || true; fi && \
    apt-get update && \
    (rosdep install --from-paths /tmp/staging --ignore-src -r -y --rosdistro ${ROS_DISTRO} || true) && \
    rm -rf /tmp/staging /tmp/dependencies

ENV ROS_DISTRO=${ROS_DISTRO} COLCON_HOME=/workspace
WORKDIR /workspace

# ── Stage 8: Production Builds (Bake) ───────────────────────────────────────

# --- 8A: Pure Dev Production Build ---
FROM python-runtime AS builder-dev
ARG CMAKE_CXX_STANDARD
ARG ROS_DISTRO
WORKDIR /workspace
COPY src/ src/
COPY dependencies/ dependencies/
COPY pyproject.toml* uv.lock* ./

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    cp dependencies/apt.txt /tmp/apt.txt && \
    /tmp/internal_apt_helper.sh install-packages all ${ROS_DISTRO}

ENV UV_PROJECT_ENVIRONMENT="/workspace/install/.venv"
RUN . /workspace/install/.venv/bin/activate && \
    if [ -f uv.lock ]; then uv sync --frozen; \
    elif [ -f dependencies/requirements.txt ]; then uv pip install -r dependencies/requirements.txt; fi

RUN mkdir -p build && cd build && \
    cmake ../src -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD} && \
    make -j$(nproc) && \
    make install DESTDIR=/workspace/install

# --- 8B: ROS Production Build ---
FROM ros-base AS builder-ros
ARG ROS_DISTRO
ARG CMAKE_CXX_STANDARD
WORKDIR /workspace
COPY src/ src/
COPY dependencies/ dependencies/

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    cp dependencies/apt.txt /tmp/apt.txt && \
    cp dependencies/apt_ros.txt* /tmp/apt_ros.txt 2>/dev/null || true && \
    /tmp/internal_apt_helper.sh install-packages all ${ROS_DISTRO}

RUN if [ -f dependencies/dependencies.repos ]; then \
        mkdir -p src/thirdparty && \
        vcs import src/thirdparty < dependencies/dependencies.repos && \
        (cp -a dependencies/overlay/. src/thirdparty/ 2>/dev/null || true); \
    fi

RUN rosdep update --rosdistro ${ROS_DISTRO} && \
    apt-get update && \
    rosdep install --from-paths src --ignore-src -r -y --rosdistro ${ROS_DISTRO}

RUN . /opt/ros/${ROS_DISTRO}/setup.sh && \
    colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD} --install-base /workspace/install

# ── Stage 9: Final Runtime Images (Switch) ──────────────────────────────────

# --- 9A: Pure Dev Runtime ---
FROM base AS dev-runtime
ARG ROS_DISTRO
ARG LANG=ko_KR.UTF-8
COPY dependencies/apt.txt /tmp/apt.txt
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/internal_apt_helper.sh install-packages runtime ${ROS_DISTRO} && \
    apt-get install -y --no-install-recommends locales libegl1-mesa libgl1-mesa-dri libglx-mesa0 mesa-utils \
    && locale-gen ${LANG} && update-locale LANG=${LANG} && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY --from=builder-dev /workspace/install /workspace/install
COPY docker/entrypoint.sh /entrypoint.sh
COPY scripts/gpu_setup.sh /opt/scripts/gpu_setup.sh
RUN chmod +x /entrypoint.sh /opt/scripts/gpu_setup.sh
ENV PATH="/workspace/install/.venv/bin:/workspace/install/bin:$PATH" VIRTUAL_ENV="/workspace/install/.venv"
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]

# --- 9B: ROS Runtime ---
FROM ros:${ROS_DISTRO}-ros-core AS ros-runtime
ARG ROS_DISTRO
ARG APT_SNAPSHOT_DATE
ARG LANG=ko_KR.UTF-8

COPY scripts/internal_apt_helper.sh /tmp/internal_apt_helper.sh
RUN chmod +x /tmp/internal_apt_helper.sh && /tmp/internal_apt_helper.sh configure-snapshot ${APT_SNAPSHOT_DATE}

COPY dependencies/apt.txt /tmp/apt.txt
COPY dependencies/apt_ros.txt* /tmp/apt_ros.txt
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/internal_apt_helper.sh install-packages runtime ${ROS_DISTRO} && \
    apt-get install -y --no-install-recommends locales libegl1-mesa libgl1-mesa-dri libglx-mesa0 mesa-utils \
    && locale-gen ${LANG} && update-locale LANG=${LANG} && rm -rf /var/lib/apt/lists/*

ENV LANG=${LANG} LC_ALL=${LANG} ROS_DISTRO=${ROS_DISTRO}
WORKDIR /workspace
COPY --from=builder-ros /workspace/install /workspace/install
COPY docker/entrypoint.sh /entrypoint.sh
COPY scripts/gpu_setup.sh /opt/scripts/gpu_setup.sh
RUN chmod +x /entrypoint.sh /opt/scripts/gpu_setup.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
