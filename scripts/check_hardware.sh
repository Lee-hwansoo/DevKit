#!/bin/bash
# =============================================================================
# scripts/check_hardware.sh
# In-container hardware acceleration and environment diagnostic tool
#
# Usage: check_hardware.sh [--brief]
#   --brief   Compact output (warnings/errors only) for CI/CD pipelines.
#             Exit code: 0 = all pass, 1 = warnings, 2 = errors
#
# Output Strategy:
#   This script intentionally uses direct echo/printf for output rather than
#   the log_* API from util_logging.sh. Diagnostic output requires section
#   headers, indented sub-items, and mixed inline coloring that don't conform
#   to the structured [TYPE] message format of log_*(). Only ANSI color
#   variables (RED, GREEN, YELLOW, BLUE, CYAN, NC) are imported.
#
# Sections:
#   [1/5] System & Storage    — OS, CPU, SIMD, RAM, Disk thresholds
#   [2/5] Network & Time Sync — IP, MTU, Clock sync, ROS context
#   [3/5] GPU Acceleration    — Hardware nodes, OpenGL, Vulkan
#   [4/5] Development Toolchain — uv, Python, ccache, CMake env
#   [5/5] I/O & Peripherals   — Video, Serial, CAN, Input
# =============================================================================

export LC_ALL=C
export LANG=C

BRIEF_MODE=false
usage() {
    cat <<'EOF'
Usage: check_hardware.sh [--brief]

Diagnose system, GPU, development toolchain, and peripheral readiness.

Options:
  --brief    Compact output with warnings/errors only.
  -h, --help Show this help.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --brief) BRIEF_MODE=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || source "/tmp/util_paths.sh"
devkit_require "util_logging.sh"

# Load GPU environment variables if available (crucial for non-interactive shells)
GPU_ENV_FILES=(
    "/etc/profile.d/devkit-gpu.sh"
    "${HOME}/.gpu_env.sh"
)
for env_file in "${GPU_ENV_FILES[@]}"; do
    [ -f "$env_file" ] && source "$env_file"
done

# Load shared GPU detection helpers
devkit_require "util_gpu_detect.sh"

# --- Brief-mode output helpers & diagnostic counters -------------------
DIAG_WARNINGS=0
DIAG_ERRORS=0
_hw_detail()   { $BRIEF_MODE || echo "$@"; }
_hw_detail_e() { $BRIEF_MODE || echo -e "$@"; }
_hw_printf()   { $BRIEF_MODE || printf "$@"; }
_hw_ok()       { $BRIEF_MODE || echo -e "  ${GREEN}✓${NC} $1"; }
_hw_warn()     { DIAG_WARNINGS=$((DIAG_WARNINGS + 1)); echo -e "  ${YELLOW}⚠${NC} $1"; }
_hw_err()      { DIAG_ERRORS=$((DIAG_ERRORS + 1)); echo -e "  ${RED}✗${NC} $1"; }
_hw_skip()     { $BRIEF_MODE || echo "  ○ $1"; }
_hw_section()  { $BRIEF_MODE || print_section "$1"; }
# -----------------------------------------------------------------------------

first_colon_value() {
    awk -v key="${1,,}" '
        idx = index(tolower($0), key) {
            colon = index($0, ":")
            if (colon > 0) {
                val = substr($0, colon + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                print val
                found = 1
                exit
            }
        }
        END { if (!found) exit 1 }
    '
}

first_kv_value() {
    awk -v key="$1" '
        idx = index($0, key) {
            eq = index($0, "=")
            if (eq > 0) {
                val = substr($0, eq + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                print val
                found = 1
                exit
            }
        }
        END { if (!found) exit 1 }
    '
}

json_number_value() {
    awk -v key="\"$1\"" '
        idx = index($0, key) {
            colon = index($0, ":")
            if (colon > 0) {
                val = substr($0, colon + 1)
                gsub(/[^0-9]/, "", val)
                print val
                found = 1
                exit
            }
        }
        END { if (!found) exit 1 }
    '
}

if ! $BRIEF_MODE; then
    print_banner DIAG
fi

# =============================================================================
# [1/5] System & Storage
# =============================================================================
_hw_section "1/5 System & Storage"

# Host/Virtualization Detection
PROC_VERSION="$(cat /proc/version 2>/dev/null || true)"
if [[ "${PROC_VERSION,,}" == *microsoft* ]]; then
    HOST_TYPE="WSL2"
elif [ -f /.dockerenv ]; then
    HOST_TYPE="Docker"
    PRIVILEGED=""
    if [ -f /proc/self/status ]; then
        while read -r key val; do
            if [ "$key" = "CapEff:" ]; then
                PRIVILEGED="$val"
                break
            fi
        done < /proc/self/status
    fi
    [ "$PRIVILEGED" = "0000003fffffffff" ] && HOST_TYPE="Docker (privileged)"
else
    HOST_TYPE="Native/BareMetal"
fi

_hw_detail "    Kernel: $(uname -r)"
PRETTY_NAME="Ubuntu"
if [ -f /etc/os-release ]; then
    while IFS= read -r line; do
        if [[ "$line" =~ ^PRETTY_NAME= ]]; then
            PRETTY_NAME="${line#*=}"
            PRETTY_NAME="${PRETTY_NAME%\"}"
            PRETTY_NAME="${PRETTY_NAME#\"}"
            break
        fi
    done < /etc/os-release
fi
_hw_detail "    OS:     ${PRETTY_NAME:-Unknown}"
_hw_detail "    Arch:   $(uname -m)"
_hw_detail "    Host:   $HOST_TYPE"

# CPU Info
CPU_MODEL=$(trim_ws "$(lscpu 2>/dev/null | first_colon_value "model name")")
[ -z "$CPU_MODEL" ] && CPU_MODEL=$(trim_ws "$(first_colon_value "model name" < /proc/cpuinfo 2>/dev/null)")
[ -z "$CPU_MODEL" ] && CPU_MODEL="Unknown CPU"
CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
_hw_detail "    CPU:    $CPU_MODEL ($CPU_CORES cores)"

# SIMD Features (architecture-aware detection)
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "armv8l" ]; then
    # ARM: Features field with NEON/SVE/crypto extensions
    SIMD_FLAGS=$(grep -m1 "Features" /proc/cpuinfo \
        | grep -woiE "neon|asimd|sve|sve2|fp16|bf16|i8mm|dotprod|aes|sha1|sha2|crc32|atomics" \
        | sort -u | tr '\n' ' ' 2>/dev/null || true)
    SIMD_FLAGS=$(trim_ws "$SIMD_FLAGS")
else
    # x86: flags field with AVX/SSE extensions
    SIMD_FLAGS=$(grep -m1 "flags" /proc/cpuinfo \
        | grep -woiE "sse4_1|sse4_2|avx|avx2|avx512f|avx512bw|avx512cd|avx512dq|avx512er|avx512ifma|avx512pf|avx512vbmi|avx512vl|avx_vnni|fma" \
        | sort -u | tr '\n' ' ' 2>/dev/null || true)
    SIMD_FLAGS=$(trim_ws "$SIMD_FLAGS")
fi
[ -n "$SIMD_FLAGS" ] && _hw_detail "    SIMD:   ${SIMD_FLAGS^^}"

# RAM — Total and Available with threshold warning
MEM_TOTAL_KB=""
MEM_AVAIL_KB=""
if [ -f /proc/meminfo ]; then
    while read -r key val _; do
        case "$key" in
            MemTotal:) MEM_TOTAL_KB="$val" ;;
            MemAvailable:) MEM_AVAIL_KB="$val" ;;
        esac
    done < /proc/meminfo
fi

if [ -n "$MEM_TOTAL_KB" ] && [ -n "$MEM_AVAIL_KB" ]; then
    tot_scaled=$(( (MEM_TOTAL_KB * 10 + 524288) / 1048576 ))
    av_scaled=$(( (MEM_AVAIL_KB * 10 + 524288) / 1048576 ))
    MEM_TOTAL="$((tot_scaled/10)).$((tot_scaled%10)) GB"
    MEM_AVAIL="$((av_scaled/10)).$((av_scaled%10)) GB"
    MEM_USED_PCT=$(( (MEM_TOTAL_KB - MEM_AVAIL_KB) * 100 / MEM_TOTAL_KB ))
    if [ "$MEM_USED_PCT" -ge 90 ]; then
        _hw_warn "RAM: $MEM_TOTAL total, $MEM_AVAIL free (${MEM_USED_PCT}% used — OOM risk)"
    elif [ "$MEM_USED_PCT" -ge 75 ]; then
        _hw_warn "RAM: $MEM_TOTAL total, $MEM_AVAIL free (${MEM_USED_PCT}% used)"
    else
        _hw_detail "    RAM:    $MEM_TOTAL total, $MEM_AVAIL free"
    fi
else
    MEM_TOTAL=""
    while read -r label val _; do
        case "$label" in
            Mem:|메모리:) MEM_TOTAL="$val"; break ;;
        esac
    done < <(free -h 2>/dev/null)
    _hw_detail "    RAM:    ${MEM_TOTAL:-N/A}"
fi

# Disk Usage — with threshold-based coloring
$BRIEF_MODE || echo "    Disk:"
while read -r fs size used free_space used_pct mount; do
    # Skip header if it leaks through
    [[ "$used_pct" == *%* ]] || continue
    used_pct_num="${used_pct%\%}"
    if [ "$used_pct_num" -ge 95 ] 2>/dev/null; then
        _hw_err "Disk ${mount}: ${used_pct} used (${free_space} free) — CRITICAL"
    elif [ "$used_pct_num" -ge 80 ] 2>/dev/null; then
        _hw_warn "Disk ${mount}: ${used_pct} used (${free_space} free)"
    else
        _hw_printf "      %-10s %s used (%s free)\n" "$mount:" "$used_pct" "$free_space"
    fi
done < <(df -h / "${WS_ROOT}" 2>/dev/null | awk 'NR>1' | sort -u)

# =============================================================================
# [2/5] Network & Time Sync
# =============================================================================
_hw_section "2/5 Network & Time Sync"

# IP Address
read -r IP_ADDR _ < <(hostname -I 2>/dev/null)
if [ -n "$IP_ADDR" ]; then
    _hw_detail "    IP:         $IP_ADDR"
else
    _hw_detail_e "    IP:         ${YELLOW}Not detected${NC}"
fi

# MTU per interface — warn if low (< 1500 common default; Jumbo Frame = 9000)
_hw_detail "    Interfaces:"
while read -r iface rest; do
    [ -z "$iface" ] && continue
    mtu=""
    prev=""
    for word in $rest; do
        if [ "$prev" = "mtu" ]; then
            mtu="$word"
            break
        fi
        prev="$word"
    done
    iface_clean="${iface%:}"
    if [ -n "$mtu" ]; then
        if [ "$mtu" -lt 1500 ] 2>/dev/null; then
            _hw_warn "MTU: ${iface_clean} MTU ${mtu} (below standard 1500 — may affect sensor streams)"
            log_detail "Packet loss may occur in high-bandwidth sensor data (Lidar/Camera)."
        else
            _hw_detail "      ${iface_clean}: MTU ${mtu}"
        fi
    fi
done < <(ip addr show 2>/dev/null | awk '/^[0-9]+:/{iface=$2} /mtu/{print iface, $0}' | grep -v "^lo")

# Clock Sync
if [[ "$HOST_TYPE" == *"Docker"* ]]; then
    if command -v chronyc >/dev/null 2>&1; then
        TRACKING=""
        while read -r line; do
            if [[ "$line" == *"System time"* ]]; then
                read -r -a parts <<< "$line"
                TRACKING="${parts[3]} ${parts[4]}"
                break
            fi
        done < <(chronyc tracking 2>/dev/null)
        if [ -n "$TRACKING" ]; then
            _hw_ok "Clock Sync: chrony active (offset: $TRACKING)"
        else
            _hw_skip "Clock Sync: chrony present but no data"
        fi
    elif command -v ntpq >/dev/null 2>&1; then
        NTP_SYNC=""
        while read -r line; do
            if [[ "$line" == \** ]]; then
                NTP_SYNC="$line"
                break
            fi
        done < <(ntpq -pn 2>/dev/null)
        if [ -n "$NTP_SYNC" ]; then
            _hw_ok "Clock Sync: ntpq active"
        else
            _hw_skip "Clock Sync: Cannot determine (container env — check host NTP)"
        fi
    else
        _hw_skip "Clock Sync: Not verifiable inside container (host NTP assumed)"
    fi
elif command -v timedatectl >/dev/null 2>&1; then
    TD_OUT=$(timedatectl status 2>/dev/null)
    SYNC_STATUS=$(trim_ws "$(first_colon_value "system clock synchronized" <<< "$TD_OUT")")
    NTP_SERVICE=$(trim_ws "$(first_colon_value "ntp service" <<< "$TD_OUT")")
    if [ "$SYNC_STATUS" = "yes" ]; then
        _hw_ok "Clock Sync: synchronized"
    else
        _hw_err "Clock Sync: NOT synchronized"
        log_detail "TF timestamp errors may occur (Drift detected)."
        _hw_detail_e "    ${CYAN}  Fix (Manual): sudo hwclock -s${NC}"
        _hw_detail_e "    ${CYAN}  Fix (Service): sudo systemctl restart systemd-timesyncd${NC}"
    fi
    [ -n "$NTP_SERVICE" ] && _hw_detail "    NTP:        $NTP_SERVICE"
else
    _hw_skip "Clock Sync: Cannot determine (no timedatectl/chronyc/ntpq)"
fi

# --- ROS Context ---
if [ -n "$ROS_DISTRO" ]; then
    if [[ "$ROS_DISTRO" =~ ^(noetic|melodic|kinetic|lunar|indigo|jade|groovy|hydro|fuerte)$ ]]; then
        ROS_VER="ROS 1"
    else
        ROS_VER="ROS 2"
    fi
    _hw_detail "    $ROS_VER:       $ROS_DISTRO"

    if [ "$ROS_VER" = "ROS 1" ]; then
        if [ -z "${ROS_MASTER_URI}" ]; then
            _hw_err "Master: not set — roscore will not start"
        else
            _hw_detail "    Master:     $ROS_MASTER_URI"
        fi
        [ -n "$ROS_HOSTNAME" ] && _hw_detail "    Hostname:   $ROS_HOSTNAME"
        [ -n "$ROS_IP" ]       && _hw_detail "    ROS_IP:     $ROS_IP"
    else
        if [ -z "${RMW_IMPLEMENTATION}" ]; then
            _hw_detail_e "    RMW:        ${YELLOW}not set (defaulting to rmw_fastrtps_cpp)${NC}"
        else
            _hw_detail "    RMW:        $RMW_IMPLEMENTATION"
        fi
        _hw_detail "    Domain ID:  ${ROS_DOMAIN_ID:-0}"
        if [ "${ROS_LOCALHOST_ONLY:-0}" = "1" ]; then
            _hw_warn "ROS: ROS_LOCALHOST_ONLY=1 (multi-machine discovery disabled)"
        fi
    fi
else
    _hw_detail_e "    ROS:        ${YELLOW}not set${NC}"
fi

# =============================================================================
# [3/5] GPU Acceleration
# =============================================================================
_hw_section "3/5 GPU Acceleration"

GPU_FOUND=false

# NVIDIA — kernel device node (prefer shared helper)
if type has_nvidia &>/dev/null && has_nvidia; then
    GPU_FOUND=true
    _hw_ok "/dev/nvidiactl (NVIDIA)"
elif [ -e "/dev/nvidiactl" ]; then
    GPU_FOUND=true
    _hw_ok "/dev/nvidiactl (NVIDIA)"
fi

# DRI — Intel / AMD / Mesa
if [ -d "/dev/dri" ]; then
    DRI_LIST=$(list_glob_basenames "/dev/dri/renderD*")
    if [ -n "$DRI_LIST" ]; then
        GPU_FOUND=true
        _hw_ok "/dev/dri ($DRI_LIST)"
    fi
fi

# Jetson / Tegra
if type has_tegra &>/dev/null && has_tegra; then
    GPU_FOUND=true
    TEGRA_DEVS=$(list_glob_basenames "/dev/nvhost-*")
    _hw_ok "Tegra GPU nodes: $TEGRA_DEVS"
elif compgen -G "/dev/nvhost-*" >/dev/null; then
    GPU_FOUND=true
    TEGRA_DEVS=$(list_glob_basenames "/dev/nvhost-*")
    _hw_ok "Tegra GPU nodes: $TEGRA_DEVS"
fi

# WSL2 Paravirtualized Graphics
if type has_dxg &>/dev/null && has_dxg; then
    GPU_FOUND=true
    _hw_ok "/dev/dxg (WSL2 D3D12 Paravirtualized Graphics)"
elif [ -e "/dev/dxg" ]; then
    GPU_FOUND=true
    _hw_ok "/dev/dxg (WSL2 D3D12 Paravirtualized Graphics)"
fi

if ! $GPU_FOUND; then
    _hw_err "No GPU device nodes found (/dev/nvidiactl, /dev/dri, /dev/nvhost-*, /dev/dxg)"
fi

# NVIDIA nvidia-smi
if command -v nvidia-smi &>/dev/null; then
    # Combine query to avoid invoking the slow nvidia-smi binary twice
    IFS=, read -r GPU_NAME GPU_MEM < <(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | head -n 1)
    GPU_NAME=$(trim_ws "$GPU_NAME")
    GPU_MEM=$(trim_ws "$GPU_MEM")
    if [ -n "$GPU_NAME" ]; then
        if [[ "${GPU_MEM}" =~ ^[0-9]+$ ]]; then
            MEM_GB="$(( (GPU_MEM + 512) / 1024 )) GB"
        else
            MEM_GB="${GPU_MEM:-0} MiB"
        fi
        _hw_ok "NVIDIA: $GPU_NAME ($MEM_GB)"
    fi
fi

# NVIDIA CUDA & cuDNN (Diagnostic Extension via SSOT)
CUDA_VER=$(get_cuda_metadata cuda_ver)
[ -n "$CUDA_VER" ] && _hw_ok "CUDA:    $CUDA_VER"

CUDNN_VER=$(get_cuda_metadata cudnn_ver)
[ -n "$CUDNN_VER" ] && _hw_ok "cuDNN:   $CUDNN_VER"

# AMD ROCm
if type has_rocm &>/dev/null && has_rocm; then
    if command -v rocm-smi &>/dev/null; then
        AMD_GPU=""
        while read -r line; do
            line_lc="${line,,}"
            if [[ "$line_lc" == *card* || "$line_lc" == *gpu* ]]; then
                AMD_GPU=$(trim_ws "$line")
                break
            fi
        done < <(rocm-smi --showproductname 2>/dev/null)
        [ -n "$AMD_GPU" ] \
            && _hw_ok "AMD:    $AMD_GPU" \
            || _hw_ok "AMD:    ROCm detected (rocm-smi present)"
    elif [ -d "/opt/rocm" ]; then
        ROCM_VER=$(cat /opt/rocm/.info/version 2>/dev/null || echo "unknown")
        _hw_ok "AMD:    ROCm $ROCM_VER (/opt/rocm)"
    fi
elif command -v rocm-smi &>/dev/null; then
    _hw_ok "AMD:    ROCm detected (rocm-smi present)"
elif [ -d "/opt/rocm" ]; then
    ROCM_VER=$(cat /opt/rocm/.info/version 2>/dev/null || echo "unknown")
    _hw_ok "AMD:    ROCm $ROCM_VER (/opt/rocm)"
fi

# OpenGL
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    _hw_skip "OpenGL: No display set (DISPLAY/WAYLAND_DISPLAY)"
elif command -v glxinfo &>/dev/null; then
    GLX_OUT=$(glxinfo 2>/dev/null || true)
    if [ -n "$GLX_OUT" ]; then
        RENDERER=$(trim_ws "$(first_colon_value "opengl renderer" <<< "$GLX_OUT")")
        VENDOR=$(trim_ws "$(first_colon_value "opengl vendor" <<< "$GLX_OUT")")
        GL_VER=$(trim_ws "$(first_colon_value "opengl version string" <<< "$GLX_OUT")")
        if [[ "${RENDERER,,}" == *llvmpipe* ]]; then
            if [[ "${GPU_MODE:-auto}" =~ ^(cpu|software)$ ]]; then
                _hw_skip "OpenGL: $RENDERER (Software — GPU_MODE=${GPU_MODE}, expected)"
            else
                _hw_warn "OpenGL: $RENDERER (Software Rendering — performance impact)"
                log_detail "GPU_MODE=${GPU_MODE:-auto}. Run 'gpu auto' or check GPU drivers."
            fi
        elif [ -n "$RENDERER" ]; then
            _hw_ok "OpenGL: $RENDERER ${GREEN}(Hardware Accelerated)${NC}"
        else
            _hw_warn "OpenGL: Found but renderer name is empty. Acceleration state uncertain."
        fi
        [ -n "$VENDOR" ] && _hw_detail "    Vendor:  $VENDOR"
        [ -n "$GL_VER" ] && _hw_detail "    GL Ver:  $GL_VER"
    else
        _hw_err "OpenGL: Display connection failed"
        log_detail "On host: xhost +SI:localuser:root"
    fi
else
    sys_vendor=$(get_gpu_vendor_sysfs)
    if [ "$sys_vendor" != "Unknown" ]; then
        _hw_ok "OpenGL: $sys_vendor GPU detected via sysfs (glxinfo missing)"
    else
        _hw_skip "OpenGL: glxinfo not installed (apt: mesa-utils)"
    fi
fi

# Vulkan
if command -v vulkaninfo &>/dev/null; then
    VK_OUT=$(vulkaninfo --summary 2>/dev/null || true)
    VK_GPU=$(trim_ws "$(first_kv_value "deviceName" <<< "$VK_OUT")")
    VK_API=$(trim_ws "$(first_kv_value "apiVersion" <<< "$VK_OUT")")
    if [ -n "$VK_GPU" ]; then
        _hw_ok "Vulkan:  $VK_GPU"
        [ -n "$VK_API" ] && _hw_detail "    API:     $VK_API"
    else
        _hw_warn "Vulkan: Installed but no device found"
    fi
else
    _hw_skip "Vulkan: vulkaninfo not installed"
fi

# =============================================================================
# [4/5] Development Toolchain
# =============================================================================
_hw_section "4/5 Development Toolchain"

# Build env variables
if [ -z "${CMAKE_CXX_STANDARD:-}" ]; then
    _hw_warn "CMAKE_CXX_STANDARD: not set (may cause build failures)"
else
    _hw_detail "    CMAKE_CXX_STANDARD: ${CMAKE_CXX_STANDARD}"
fi
[ -n "${GPU_MODE:-}" ]   && _hw_detail "    GPU_MODE:           ${GPU_MODE}"

# Python
sys_py="${SYS_PYTHON_EXE:-/usr/bin/python3}"
if [[ -x "$sys_py" ]]; then
    sys_ver=$($sys_py --version 2>&1 | cut -d' ' -f2)
    _hw_ok "System Python:      $sys_ver ($sys_py)"
else
    _hw_err "System Python:     Not found at $sys_py"
fi

# uv + active venv
[ -n "${UV_PYTHON:-}" ]  && _hw_detail "    UV_PYTHON:          ${UV_PYTHON}"
if command -v uv &>/dev/null; then
    _hw_ok "uv:      $(uv --version)"
    ACTIVE_VENV="${VIRTUAL_ENV:-${WS_VENV}}"
    if [ -n "$ACTIVE_VENV" ] && [ -d "$ACTIVE_VENV" ]; then
        _hw_detail "    venv:    $ACTIVE_VENV"
    else
        _hw_detail_e "    venv:    ${YELLOW}No active virtualenv detected${NC}"
    fi
    _hw_detail "    Python versions (uv):"
    if ! $BRIEF_MODE; then
        uv python list 2>/dev/null | head -3 | sed 's/^/      /'
    fi
else
    _hw_err "uv: Not found"
fi

# ccache
if command -v ccache &>/dev/null; then
    read -r CCACHE_VER < <(ccache --version 2>/dev/null)
    _hw_ok "ccache: $CCACHE_VER"
    HITS=""
    MISSES=""
    if ccache --show-stats --format=json &>/dev/null 2>&1; then
        JSON_STATS=$(ccache --show-stats --format=json 2>/dev/null)
        HITS=$(json_number_value "direct_cache_hit" <<< "$JSON_STATS")
        MISSES=$(json_number_value "cache_miss" <<< "$JSON_STATS")
    fi
    if [ -z "$HITS" ] || [ -z "$MISSES" ]; then
        STATS=$(ccache -s 2>/dev/null)
        while read -r line; do
            if [[ "$line" == *"cache hit (direct)"* ]]; then
                read -r -a parts <<< "$line"
                HITS="${parts[${#parts[@]}-1]}"
                HITS="${HITS//,/}"
            elif [[ "$line" == *"cache miss"* ]]; then
                read -r -a parts <<< "$line"
                MISSES="${parts[${#parts[@]}-1]}"
                MISSES="${MISSES//,/}"
            fi
        done <<< "$STATS"
    fi
    if [ -n "$HITS" ] && [ -n "$MISSES" ]; then
        TOTAL=$((HITS + MISSES))
        if [ "$TOTAL" -gt 0 ]; then
            HIT_RATE=$(( HITS * 100 / TOTAL ))
            if [ "$HIT_RATE" -ge 70 ]; then
                _hw_detail_e "    Hit rate: ${GREEN}${HIT_RATE}%${NC} (${HITS} hits / ${TOTAL} total)"
            elif [ "$HIT_RATE" -ge 30 ]; then
                _hw_detail_e "    Hit rate: ${YELLOW}${HIT_RATE}%${NC} (${HITS} hits / ${TOTAL} total)"
            else
                _hw_warn "ccache hit rate: ${HIT_RATE}% — cache warming up or misses high"
            fi
        fi
    fi
fi

# =============================================================================
# [5/5] I/O & Peripherals
# =============================================================================
_hw_section "5/5 I/O & Peripherals"

# Video Devices
VIDEO_FOUND=false
if compgen -G "/dev/video*" > /dev/null 2>&1; then
    while IFS= read -r vdev; do
        VIDEO_FOUND=true
        if command -v v4l2-ctl &>/dev/null; then
            DEV_NAME=$(trim_ws "$(v4l2-ctl --device="$vdev" --info 2>/dev/null | first_colon_value "card type")")
            [ -n "$DEV_NAME" ] \
                && _hw_ok "Video:  $vdev — $DEV_NAME" \
                || _hw_ok "Video:  $vdev"
        else
            _hw_ok "Video:  $vdev"
        fi
    done < <(compgen -G "/dev/video*" || true)
fi
if ! $VIDEO_FOUND; then
    _hw_skip "Video:  No devices (/dev/video*)"
fi

# Serial Devices
SERIAL_DEVICES=$(printf '%s ' $(compgen -G "/dev/ttyUSB*" || true) $(compgen -G "/dev/ttyACM*" || true) $(compgen -G "/dev/ttyTHS*" || true))
if [ -n "$SERIAL_DEVICES" ]; then
    _hw_ok "Serial: $SERIAL_DEVICES"
else
    _hw_skip "Serial: No devices (/dev/ttyUSB*, /dev/ttyACM*, /dev/ttyTHS*)"
fi

# Input Devices
INPUT_DEVICES=$(printf '%s ' $(compgen -G "/dev/input/js*" || true))
[ -n "$INPUT_DEVICES" ] && _hw_ok "Input:  $INPUT_DEVICES"

# SocketCAN
CAN_FOUND=false
if CAN_LINKS=$(ip link show type can 2>/dev/null) && [ -n "$CAN_LINKS" ]; then
    while read -r line; do
        if [[ "$line" =~ ^[0-9]+:[[:space:]]*([^:]+): ]]; then
            can_iface="${BASH_REMATCH[1]}"
            [ -z "$can_iface" ] && continue
            CAN_FOUND=true
            if [[ "$(ip link show "$can_iface" 2>/dev/null)" == *UP* ]]; then
                _hw_ok "CAN:    $can_iface ${GREEN}(UP)${NC}"
            else
                _hw_warn "CAN: $can_iface (DOWN — run: ip link set $can_iface up)"
            fi
        fi
    done <<< "$CAN_LINKS"
fi
if ! $CAN_FOUND; then
    _hw_skip "CAN:    No interfaces found"
fi

# =============================================================================
# Summary
# =============================================================================
if $BRIEF_MODE; then
    echo ""
    echo "--- Diagnostics: ${DIAG_ERRORS} error(s), ${DIAG_WARNINGS} warning(s)"
    [ "$DIAG_ERRORS" -gt 0 ] && exit 2
    [ "$DIAG_WARNINGS" -gt 0 ] && exit 1
    exit 0
fi

echo ""
if [ "$DIAG_ERRORS" -gt 0 ]; then
    echo -e "${RED}Diagnostics complete: ${DIAG_ERRORS} error(s), ${DIAG_WARNINGS} warning(s)${NC}"
elif [ "$DIAG_WARNINGS" -gt 0 ]; then
    echo -e "${YELLOW}Diagnostics complete: ${DIAG_WARNINGS} warning(s)${NC}"
else
    echo -e "${GREEN}Diagnostics complete. All checks passed.${NC}"
fi
echo ""
if [ "$DIAG_ERRORS" -gt 0 ] || [ "$DIAG_WARNINGS" -gt 0 ]; then
    echo -e "${CYAN}================================================================${NC}"
    echo -e "  ${CYAN}Resolution Guide for Detected Issues${NC}"
    echo -e "${CYAN}================================================================${NC}"

    if [ "$DIAG_ERRORS" -gt 0 ]; then
        echo -e "  ${YELLOW}[Clock Sync Error]${NC}"
        echo -e "    WSL2 often drifts after PC sleep/hibernation."
        echo -e "    1. Force sync with host: ${CYAN}sudo hwclock -s${NC}"
        echo -e "    2. Restart service:    ${CYAN}sudo systemctl restart systemd-timesyncd${NC}"
        echo -e "    3. Permanent fix: Add 'sudo hwclock -s' to your ~/.bashrc"
        echo ""
    fi

    if [ "$DIAG_WARNINGS" -gt 0 ]; then
        echo -e "  ${YELLOW}[Network/MTU Warning]${NC}"
        echo -e "    Standard MTU is 1500. For high-end Lidar, you might need 9000 (Jumbo)."
        echo -e "    1. Check MTU:   ${CYAN}ip link show eth0${NC}"
        echo -e "    2. Set MTU:     ${CYAN}sudo ip link set dev eth0 mtu 9000${NC}"
        echo -e "    3. Host check:  Ensure Windows WSL Ethernet adapter also has matching MTU."
        echo ""
    fi
fi

echo -e "  ${CYAN}Next Steps:${NC}"
echo -e "    ${GREEN}gpu status${NC}      : Detailed GPU & Display diagnostics"
echo -e "    ${GREEN}mksync${NC}          : Fully initialize workspace (venv + deps + build)"
echo -e "    ${GREEN}cbuild${NC}          : colcon build (--release for Release profile)"
echo -e "    ${GREEN}sync_deps${NC}       : Sync external repos from .repos file"
echo -e "    ${GREEN}check_deps${NC}      : Verify missing runtime libraries in install/"
echo -e "    ${GREEN}h${NC} / ${GREEN}help${NC}         : Show full command guide"
