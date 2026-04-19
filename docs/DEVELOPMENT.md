# ailab Workspace

This directory contains the core source code and dependency specifications for the **ailab** project.

## 🏁 원스톱 개발 워크플로우 (One-step Workflow)

프로젝트에 처음 진입했거나 의존성 또는 하드웨어 구성이 변경된 경우, 아래 **단 한 줄의 명령어**로 모든 환경 구축(Python, ROS, System) 및 빌드를 완료할 수 있습니다.

```bash
mksync
```

> [!NOTE]
> `mksync`는 `mkenv` → `uvs` → `sync_deps --rosdep` → `cb` (또는 `mbuild`) 과정을 순차적으로 자동 수행합니다. 작업이 완료된 후 **`activate`**로 가상환경에 진입하고 **`s`** 명령어로 환경을 소싱하세요.

---

## 🔍 상세 가이드 (Standard Guide)

### 1. Python Environment (uv)

`uv`를 통해 고성능의 격리된 환경을 제공합니다. `uvs` 명령어는 `src/pyproject.toml`을 읽어 현재 시스템에 NVIDIA GPU가 있는지 확인하고, 그에 맞는 PyTorch(cu128 또는 cpu)를 자동으로 선택하여 설치합니다.

### 2. ROS & System Dependencies

`sync_deps --rosdep` 명령어는 내 소스 코드와 외부 라이브러리의 의존성을 한 번에 관리합니다:
- `dependencies/dependencies.repos`에 명시된 외부 패키지를 `src/thirdparty`로 가져옵니다.
- **`src/`** 디렉토리 전체를 재귀적으로 검색하여 `carmaker_teleop` 같은 내 패키지와 외부 패키지의 `package.xml` 의존성을 모두 자동으로 설치합니다.

### 3. Build & Source

- **`cb`**: `colcon build`의 별칭으로 `RelWithDebInfo` 모드로 빌드합니다.
- **`s`**: 빌드가 끝난 후 `source install/setup.bash`를 실행하여 현재 셸에 빌드된 패키지들을 반영합니다.

## 📦 주요 포함 라이브러리 (Core Stack)

- **Deep Learning**: PyTorch, torchvision
- **Computer Vision**: OpenCV, Scikit-Image, Scikit-Learn
- **3D Processing**: Open3D
- **Analysis**: NumPy, Pandas, Matplotlib, SciPy
- **Utils**: Pyre-check (Static Type checking)

## 환경 체크용 명령어

```bash
python3 -c "import torch; import torchvision; print(f'PyTorch Version: {torch.__version__}'); print(f'CUDA Available: {torch.cuda.is_available()}'); print(f'GPU Name: {torch.cuda.get_device_name(0) if torch.cuda.is_available() else \"None\"}')"
```
