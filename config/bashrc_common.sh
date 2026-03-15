# =============================================================================
# Docker Dev Environment (Common)
# =============================================================================

# ccache
export PATH="/usr/lib/ccache:$PATH"
export CCACHE_DIR=/cache/ccache

# uv (Python)
export UV_CACHE_DIR=/cache/uv
export UV_TOOL_DIR=/cache/uv/tools
export UV_PYTHON=${UV_PYTHON:-3.11}

# C++ 표준
export CMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17}

# 커스텀 aliases
source /docker_dev/config/aliases.sh

# GPU 환경 변수 (entrypoint.sh 또는 gpu_setup.sh 가 동적 생성)
if [ -f /root/.gpu_env.sh ]; then
source /root/.gpu_env.sh
fi

# uv (.venv) 자동 활성화
if [ -f "/workspace/install/.venv/bin/activate" ]; then
    source "/workspace/install/.venv/bin/activate"
fi

# 프롬프트
export PS1="\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ "
