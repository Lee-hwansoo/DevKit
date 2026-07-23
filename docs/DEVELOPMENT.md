# 📘 DevKit 개발자 워크플로우 & 툴체인 가이드

본 문서는 **DevKit** 생태계의 핵심 개발 워크플로우, 의존성 관리 방식, 빌드 툴체인 및 SIF 빌드 옵션을 상세히 다룹니다.

---

## 🏛️ 아키텍처: 단일 진실 공급원 (SSOT)

DevKit은 모든 워크스페이스 경로 및 환경 설정에 **Single Source of Truth (SSOT)** 원칙을 강제합니다. 전체 환경은 `${WORKSPACE_PATH}` (기본값: `/workspace`)를 기준으로 결합됩니다.

### 📍 표준화된 경로 전략
- **쉐도우 디렉토리 부재**: 모든 스크립트, 패키지 및 환경 설정은 워크스페이스 내에 엄격히 위치합니다.
- **상대 경로 견고성**: 스크립트 소싱 시 다음 오버레이 패턴을 통해 실행됩니다:
  1. `${WORKSPACE_PATH}/scripts/...` (공식 SSOT 경로)
  2. `$(dirname "${BASH_SOURCE[0]}")/...` (로컬 fallback)

---

## 🏁 통합 개발 워크플로우

컨테이너 진입 후 즉시 개발을 시작할 수 있는 통합 명령어 체계입니다.

### 1. 원클릭 가상환경 & 빌드 동기화 (`mksync`)

아래 단 하나의 명령어로 가상환경 생성, 의존성 동기화, 초기 빌드를 자동 수행합니다:

```bash
mksync
```

> [!TIP]
> **`mksync` 동작 시퀀스**: `mkenv` (venv 생성) ➔ `uvs` (파이썬 패키지 동기화) ➔ `sync_deps --rosdep` (시스템/ROS 의존성 수신) ➔ `cbuild`/`mbuild` (빌드 수행).
> `ROS_DISTRO=noetic` (ROS 1) 환경에서는 시스템 파이썬 패키지를 공유하기 위해 공유 venv 모드가 자동 적용됩니다.

### 2. 의존성 관리 체계 (Dependency Management)

* **Python 패키지 (`uv`)**: `src/pyproject.toml`을 통해 관리됩니다. `uvs` 명령어로 초고속 파이썬 동기화를 수행합니다.
* **시스템 및 ROS 패키지**: `dependencies/` 디렉토리를 통해 관리되며, `sync_deps --rosdep` 명령어로 외부 레포지토리 수신 및 시스템 패키지를 설치합니다.
* `sync_deps` 및 `rosdep` 실패 시 즉시 프로세스가 중단됩니다. 의도적으로 일부 패키지만 설치하고 진행하려면 `DEVKIT_VCS_ALLOW_FAILURE=1` 또는 `DEVKIT_ROSDEP_ALLOW_FAILURE=1`을 지정하세요.

---

## ⚙️ 고급 의존성 제어 및 커스텀 (Advanced Dependency Management)

### 1. Python 레이어 (`src/pyproject.toml` & `uv`)
`pyproject.toml`을 통해 CPU/GPU 환경에 따른 파이썬 패키지(예: PyTorch 등) 분기 및 인덱스 설정을 관리합니다.

```toml
[project.optional-dependencies]
cpu = [ "torch==2.11.0", "torchvision" ]
gpu = [ "torch==2.11.0", "torchvision" ]

[[tool.uv.index]]
name = "pytorch-cpu"
url = "https://download.pytorch.org/whl/cpu"
explicit = true

[[tool.uv.index]]
name = "pytorch-cu128"
url = "https://download.pytorch.org/whl/cu128"
explicit = true
```
> GPU 패키지 설치 시 `.env`에 `UV_SYNC_FLAGS="--extra gpu"`를 지정하거나 `mksync --extra gpu`를 실행합니다.

### 2. C++ & ROS 레이어 (`CMake` + `dependencies.repos`)
- **`FetchDependencies.cmake`**: `CMakeLists.txt` 빌드 시점에 GitHub 라이브러리(예: `spdlog`, `nlohmann_json`)를 동적으로 다운로드 및 링크.
- **`dependencies.repos` & `overlay/`**: 외부 레포지토리 소스를 `src/thirdparty`로 자동 복사하며, `overlay/` 폴더 내 파일로 커스텀 덮어쓰기 보장.
- **`colcon.meta` & `CMAKE_EXTRA_ARGS`**: 대용량 외부 빌드 시간 단축(`BUILD_TESTING=OFF`) 및 GTSAM/Eigen 메모리 충돌(ODR Violation) 방지 옵션 주입.

### 3. 시스템 패키지 태깅 규칙 (`dependencies/apt.txt`)
생성되는 프로덕션 SIF 용량을 최소화하기 위해 `apt.txt` 내에 주석 태그를 지정합니다:
- `# runtime`: 프로덕션 SIF 이미지에 반드시 포함될 실행 필수 패키지.
- `# dev`: 개발 컨테이너에만 포함되고 프로덕션 SIF에서는 제외할 빌드 도구.
- `# gui`: RViz, RQT, OpenCV 디스플레이 등 GUI 전용 패키지 (프로덕션 헤드리스 빌드 시 자동 스킵).

---

## 🛡️ 보안 및 아키텍처 제약사항 (Security & Architecture)

1. **동적 권한 매핑**: 호스트의 UID/GID를 컨테이너 내 non-root 개발자 계정으로 동적 매핑하여 권한 에러를 차단합니다.
2. **`privileged: true`**: USB 센서, 카메라, SocketCAN 통신을 위해 컨테이너가 특권 모드로 작동합니다.
3. **`network_mode: host`**: ROS DDS 통신 성능 극대화를 위해 호스트 네트워크를 공유합니다. 충돌 방지를 위해 `.env`에서 고유한 `ROS_DOMAIN_ID`를 설정하세요.

---

## 📄 라이선스 및 사용 지침 (License & Usage)

본 **DevKit** 보일러플레이트 코드 및 설정 파일은 **[MIT-0 (MIT No Attribution)](LICENSE)** 라이선스로 제공됩니다.

- **출처 표기 의무 없음**: 템플릿 사용 시 원작자나 출처를 명시할 필요가 없으며, 상용·개인·기업 내부망 등 어떤 목적이든 자유롭게 활용 가능합니다.
- **자유로운 라이선스 변경**: 새 프로젝트에 이 템플릿을 사용할 때 루트의 `LICENSE` 파일을 자유롭게 삭제하거나 본인 프로젝트의 라이선스로 덮어쓸 수 있습니다.

---

## 📦 프로덕션 & 이식성 (Apptainer SIF)

HPC 및 클러스터 환경 배포를 위해 워크스페이스를 단일 이진 파일인 **SIF (Singularity Image File)**로 추출합니다.

### 🧊 SIF 생성 및 실행 명령어 가이드

| 작업 구분 | CLI 명령어 | 결과 및 특징 |
| :--- | :--- | :--- |
| **Bake Dev Snapshot** | `make bake-dev ENV=ros\|dev` | 독립 가상환경을 포함한 개발용 SIF 스냅샷 생성 |
| **Bake Dev Shared** | `make bake-dev ENV=ros\|dev SHARE=1` | 시스템 site-packages를 공유하는 개발용 SIF 스냅샷 생성 |
| **Bake Production** | `make bake-prod ENV=ros\|dev [PROD_FULL_CUDA=1]` | `install/` 및 런타임 의존성만 포함하는 최적화 운영 SIF 생성 |
| **Run Dev** | `make run-sif SIF_MODE=dev` | 소스 바인드 상태로 개발용 SIF 실행 |
| **Run Production** | `make run-sif SIF_MODE=prod ENV=ros\|dev RUN_ARGS='cmd'` | 소스 바인드 없이 산출물 격리 실행 |
| **Run SLURM** | `make run-sif SIF_MODE=slurm ENV=ros\|dev RUN_ARGS='cmd'` | SLURM 배치 스케줄러 노드에 작업 제출 |
| **SLURM Control** | `make slurm-status` / `make slurm-cancel` | 활성/대기 중인 SLURM 배치 작업 조회 및 취소 |

---

## 🏥 진단 유틸리티 & 헬스 체크

유지보수 및 진단을 위해 제공되는 표준 툴셋입니다:

* **`hw_check`**: CPU, RAM, 네트워크, GPU, 디스플레이 통과 상태 스캔.
* **`gpu status`**: 가동 중인 GPU 드라이버 및 렌더링 모드 검사.
* **`check_deps`**: `install/` 내 누락된 `*.so` 라이브러리를 `ldd`로 탐지.
* **`make status`**: (호스트) WSL2/Linux 호스트 하드웨어 가속 설정 모니터링.

---

## 📝 모범 사례 (Best Practices)

1. **환경 소싱 (`s`)**: 빌드 후 또는 새 터미널을 열었을 때 `s` 알리애스 (`source install/setup.bash`) 실행.
2. **파이썬 가상환경 진입**: `activate` 알리애스를 통해 isolated venv 진입.
3. **스마트 빌드**: ROS 패키지는 `cbuild`, Pure C++ 프로젝트는 `mbuild` 사용.
