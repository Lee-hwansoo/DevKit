# 🚀 DevKit Development & Deployment Guide

This document outlines the core architecture, development workflows, and production deployment strategies for the **DevKit** ecosystem.

---

## 🏛️ Architecture: Single Source of Truth (SSOT)

DevKit enforces a **Single Source of Truth** for all paths and configurations. The environment is anchored to the `${WORKSPACE_PATH}` (default: `/workspace`).

### 📍 Standardized Path Strategy

- **No Shadow Directories**: All scripts, configurations, and dependencies reside strictly within the workspace.
- **Relative Robustness**: Sibling scripts are sourced using a robust multi-path pattern:
  1. `${WORKSPACE_PATH}/scripts/...` (Official SSOT)
  2. `$(dirname "${BASH_SOURCE[0]}")/...` (Local Fallback/Host)

---

## 🏁 Unified Development Workflow

Experience a zero-config setup after entering the container.

### 1. One-Step Initialization

Run the following command to automate environment creation, dependency synchronization, and initial build:

```bash
mksync
```

> [!TIP]
> `mksync` is an orchestrator that runs `mkenv` → `uvs` → `sync_deps --rosdep` → `cbuild`/`mbuild` in sequence. Non-`--share` options are forwarded to `uvs`, for example `mksync --extra gpu --locked`.
> `ROS_DISTRO=noetic` automatically enables the shared venv mode because ROS 1 Python packages are provided by the system Python environment.

### 2. Dependency Management

- **Python (`uv`)**: Managed via `src/pyproject.toml`. Use `uvs` for lightning-fast synchronization.
- **System & ROS**: Managed via `dependencies/`. Use `sync_deps --rosdep` to pull external repos and install system packages.
- `sync_deps` fails fast when `vcs import`/`vcs pull` fails, and `sync_deps --rosdep` fails fast when `rosdep install` cannot resolve packages. Set `DEVKIT_VCS_ALLOW_FAILURE=1` or `DEVKIT_ROSDEP_ALLOW_FAILURE=1` only when you intentionally want to continue with a partial dependency state.

---

## 📦 Production & Portability (Apptainer)

DevKit uses **Apptainer (Singularity)** as its production deployment path for maximum portability in HPC and cluster environments.

### 🧊 The "Bake to SIF" Strategy

The validated workspace is baked into a single **SIF (Singularity Image File)**.

| Action | Command | Result |
| :--- | :--- | :--- |
| **Bake Dev Snapshot** | `make bake-dev ENV=ros|dev` | Generates a development SIF snapshot with isolated virtual environment |
| **Bake Dev Shared** | `make bake-dev ENV=ros|dev SHARE=1` | Generates a development SIF snapshot sharing system site-packages |
| **Bake Production** | `make bake-prod ENV=ros|dev [PROD_FULL_CUDA=1]` | Generates a production SIF from `install/` and runtime dependencies only |
| **Run Dev** | `make run-sif SIF_MODE=dev` | Runs the dev SIF with host workspace shadow bind |
| **Run Dev Shared** | `make run-sif SIF_MODE=dev SHARE=1` | Runs the shared dev SIF created with `SHARE=1` |
| **Run Production** | `make run-sif SIF_MODE=prod ENV=ros|dev [RUN_ARGS='cmd']` | Runs the selected production SIF without source bind |
| **Run SLURM** | `make run-sif SIF_MODE=slurm ENV=ros|dev [RUN_ARGS='cmd']` | Submits the selected production SIF as a SLURM batch job |
| **SLURM Control** | `make slurm-status` / `make slurm-cancel` | Monitor or cancel queued/running jobs on the cluster |

Default SIF names are environment-aware: `myproject_ros_dev_latest.sif`, `myproject_dev_dev-share_latest.sif`, and `myproject_ros_prod_latest.sif`. Override with `SIF_FILE=...` when needed. Set `SOURCE_DATE_EPOCH` before baking to make release metadata timestamps reproducible.

Use `DEVKIT_DRY_RUN=1` with `make bake-dev`, `make bake-prod`, or `make run-sif` to validate the planned Docker/SIF/SLURM operation without building, submitting, or executing the image.

Use `RUN_ARGS` for simple argv-style commands. Prefer `APP_COMMAND` or `ROS_LAUNCH_COMMAND` for complex shell expressions with pipes, redirects, or nested quoting.

SLURM runs print a submission request and exact `sbatch` options in the current terminal before submission, and an execution summary inside the job log with the actual allocated job/node/task resources, project root, and embedded image workspace. Production SIFs do not bind the source tree; optional runtime mounts are controlled with `SLURM_DATA_ROOT`, `SLURM_RUN_ROOT`, `CONTAINER_DATA_ROOT`, and `CONTAINER_RUN_ROOT`.

**Benefits**:

- **Total Isolation**: Dev SIFs freeze the workspace snapshot; production SIFs carry only the validated `install/` tree, runtime dependencies, and release metadata.
- **High Performance**: Native performance on clusters without the overhead of Docker daemons.
- **Version Control**: SIF files are immutable artifacts that can be easily versioned and shared.

---

## 🏥 Diagnostics & Health Checks

Maintain a healthy environment using the standardized diagnostic suite:

- **`hw_check`**: Comprehensive hardware diagnostics (GPU, Display, Architecture).
- **`gpu status`**: Quick check of active rendering mode and driver visibility.
- **`check_deps`**: Verifies that no shared libraries (`*.so`) are missing in `install/`.
- **`make status`**: (Host-side) Audits WSL/Linux host configuration for GPU acceleration.

---

## 📝 Best Practices

1. **Always Source**: Use the `s` alias (`source install/setup.bash`) after any build or when opening a new terminal.
2. **Venv Activation**: Use `activate` to enter the Python virtual environment.
3. **Intelligent Build**: Use `cbuild` for ROS packages and `mbuild` for pure C++ projects.
