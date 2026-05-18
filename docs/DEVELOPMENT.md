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
> `mksync` is an orchestrator that runs `mkenv` → `uvs` → `sync_deps --rosdep` → `cb`/`mbuild` in sequence.

### 2. Dependency Management

- **Python (`uv`)**: Managed via `src/pyproject.toml`. Use `uvs` for lightning-fast synchronization.
- **System & ROS**: Managed via `dependencies/`. Use `sync_deps --rosdep` to pull external repos and install system packages.

---

## 📦 Production & Portability (Apptainer)

DevKit has transitioned from a multi-stage Docker deployment to a unified **Apptainer (Singularity)** workflow for maximum portability in HPC and cluster environments.

### 🧊 The "Bake to SIF" Strategy

Instead of maintaining complex production Docker images, we "bake" the entire validated workspace into a single **SIF (Singularity Image File)**.

| Action | Command | Result |
| :--- | :--- | :--- |
| **Bake** | `make bake` | Generates `devkit_v1.0.sif` containing the full workspace |
| **Run** | `make run-sif` | Runs the immutable image with rootless execution |

**Benefits**:

- **Total Isolation**: All `build/`, `install/`, and `scripts/` are frozen inside the image.
- **High Performance**: Native performance on clusters without the overhead of Docker daemons.
- **Version Control**: SIF files are immutable artifacts that can be easily versioned and shared.

---

## 🏥 Diagnostics & Health Checks

Maintain a healthy environment using the standardized diagnostic suite:

- **`hw_check`**: Comprehensive hardware diagnostics (GPU, Display, Architecture).
- **`gpu_status`**: Quick check of active rendering mode and driver visibility.
- **`check_deps`**: Verifies that no shared libraries (`*.so`) are missing in `install/`.
- **`make status`**: (Host-side) Audits WSL/Linux host configuration for GPU acceleration.

---

## 📝 Best Practices

1. **Always Source**: Use the `s` alias (`source install/setup.bash`) after any build or when opening a new terminal.
2. **Venv Activation**: Use `activate` to enter the Python virtual environment.
3. **Intelligent Build**: Use `cb` for ROS packages and `mbuild` for pure C++ projects.
