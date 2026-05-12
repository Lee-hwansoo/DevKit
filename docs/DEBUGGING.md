# 🐛 Debugging & Development Guide

This document provides a comprehensive guide to the professional debugging ecosystem integrated into **DevKit**. By leveraging VS Code's multi-layered configurations, you can seamlessly debug **C++, Python, and ROS 1/2** applications running within high-performance Docker containers.

> [!TIP]
> **Dynamic Environment Detection**: All configurations automatically adapt to your environment via the `ROS_DISTRO` and `WORKSPACE_PATH` variables. Whether you are running **ROS 1 Noetic** or **ROS 2 Humble**, the tools "just work."

---

## 📑 Table of Contents

1.  [🛠️ Prerequisites & Setup](#-prerequisites--setup)
2.  [🔌 Connection Strategies](#-connection-strategies)
3.  [🎯 C++ Debugging (GDB)](#-c-debugging-gdb)
4.  [🐍 Python Debugging (debugpy)](#-python-debugging-debugpy)
5.  [🤖 ROS Launch Debugging](#-ros-launch-debugging)
6.  [🚀 Turnaround Optimization](#-turnaround-optimization)
7.  [⚙️ Automated Task System](#-automated-task-system)
8.  [🔍 Expert Troubleshooting](#-expert-troubleshooting)

---

## 🛠️ Prerequisites & Setup

### 1. Essential Extensions
DevKit relies on a curated set of extensions for the ultimate developer experience. When you open the workspace, VS Code will prompt you to install them (defined in `.vscode/extensions.json`).

*   **C/C++ & CMake Tools**: Full IntelliSense and GDB integration.
*   **Python & Debugpy**: Robust Python debugging and environment management.
*   **Dev Containers**: The bridge between your host and the high-performance container.
*   **ROS Extension**: Smart ROS 1/2 integration (discovery, launch, and message viewing).

### 2. Building for Debugging
To enable source-level debugging (breakpoints, variable inspection), you must build with **Debug** symbols.

| Build Mode         | CLI Command (ROS 2)                          | VS Code Task (Ctrl+Shift+B)        |
| :----------------- | :------------------------------------------- | :--------------------------------- |
| **Debug**          | `cb --cmake-args -DCMAKE_BUILD_TYPE=Debug`   | `🔨 colcon: Build (Debug)`          |
| **RelWithDebInfo** | `cb` (Default)                               | `🔨 colcon: Build (RelWithDebInfo)` |
| **Release**        | `cb --cmake-args -DCMAKE_BUILD_TYPE=Release` | `🔨 colcon: Build (Release)`        |

> [!IMPORTANT]
> Use **Debug** mode for the most reliable experience. `RelWithDebInfo` provides optimizations that might cause the debugger to skip lines or show incorrect variable values.

---

## 🔌 Connection Strategies

DevKit supports two primary workflows, depending on your needs for isolation and performance.

### Method A: Dev Containers (Recommended)
This workflow runs VS Code *inside* the container.
1.  Launch the container: `make ros`
2.  Command Palette (**Ctrl+Shift+P**) → `Dev Containers: Attach to Running Container...`
3.  Select the DevKit container.
4.  **Benefits**: Native performance, automatic IntelliSense, and integrated terminal access.

### Method B: Host-Side Development
Work from your host OS while interacting with the container.
1.  Open the workspace normally in VS Code.
2.  Use the `Host (Bind Mount)` IntelliSense profile in `c_cpp_properties.json`.
3.  **Benefits**: Access to host-side tools and simpler multi-monitor window management.

---

## 🎯 C++ Debugging (GDB)

The C++ debugging suite is built on top of GDB, providing a consistent experience across pure C++ and ROS nodes.

### 1. Launching Executables
*   **`🐛 C++: Launch Executable (GDB)`**: Automatically triggers a **Debug build** and sources the workspace before launching your chosen binary.
*   **`🐛 C++: Launch (GDB, skip build)`**: The fastest way to restart a debug session if you haven't changed the code.

### 2. Attaching to Processes
Use **`🐛 C++: Attach to Process (GDB)`** to debug a node that is already running. VS Code will provide a searchable list of active processes — simply type the name of your ROS node.

### 3. Direct Node Launch (ROS-Aware)
For complex nodes that require specific ROS arguments:
*   **ROS 2**: `🤖 ROS2: C++ Node (GDB Direct)` — Handles `--ros-args` and remapping.
*   **ROS 1**: `🐢 ROS1: C++ Node (GDB Direct)` — Handles `__name` and master URI.

---

## 🐍 Python Debugging (debugpy)

Python debugging is powered by `debugpy`, offering both local and remote capabilities.

### 1. Zero-Config Debugging
Open any `.py` file and press **F5** → select **`🐍 Python: Debug Current File`**. This works for standalone scripts, ROS nodes, and even launch files.

### 2. Remote Attach (Advanced)
Use this for nodes running in the background or within a complex launch system.
1.  **Inject Listener**: Add the following to your Python code:
    ```python
    import debugpy
    debugpy.listen(("0.0.0.0", 5678))
    debugpy.wait_for_client() # Optional: wait for you to hit F5
    ```
2.  **Attach**: F5 → select **`🐍 Python: Attach to debugpy (Remote)`**.

> [!TIP]
> **Dependency Management**: DevKit uses `uv` for lightning-fast Python dependency management. Use the `🐍 Python: uv sync` task to keep your environment up to date.

---

## 🤖 ROS Launch Debugging

Launch whole systems while maintaining debug hooks into specific nodes.

*   **ROS 2 Launch**: Select **`🤖 ROS2: Launch File`**. It handles `PYTHONPATH`, `AMENT_PREFIX_PATH`, and `LD_LIBRARY_PATH` automatically.
*   **ROS 1 Launch**: Select **`🐢 ROS1: roslaunch`**. Ensure `roscore` is running in a terminal first.

### Compound Launches (Multi-Process)
The "Holy Grail" of ROS debugging. These configurations launch your system and simultaneously attach debuggers to key nodes:
*   `🚀 Full Debug: ROS2 Launch + C++ Attach`
*   `🚀 Full Debug: ROS1 roslaunch + Python Attach`

---

## 🚀 Turnaround Optimization

Large ROS workspaces can be slow to build. DevKit includes several optimizations to keep you in the "flow":

1.  **Single Package Build**: Use the `⚡ Source & Build Package` task to rebuild only the package you are currently editing.
2.  **Skip Build Variants**: Every launch configuration has a `(skip build)` variant. Use it when iterating on logic that doesn't require a re-compile (e.g., Python code or config changes).
3.  **CCache Integration**: The build system is pre-configured with `ccache`. Check your hit rate with the `📊 Build Cache Statistics` task.

---

## ⚙️ Automated Task System

Beyond debugging, `tasks.json` provides a rich set of utilities accessible via **Ctrl+Shift+B** or the Task Runner.

| Task Category   | Featured Tasks                                                    |
| :-------------- | :---------------------------------------------------------------- |
| **Diagnostics** | `🏥 Hardware Check`, `⚡ GPU Status`, `🔍 Check Dependencies`        |
| **Maintenance** | `🧹 Clean Workspace`, `🔄 Sync Dependencies`, `🐍 Python: uv sync`   |
| **ROS Core**    | `🔨 colcon: Build (Debug)`, `🧪 colcon: Test`, `📋 Source Workspace` |

---

## 🔍 Expert Troubleshooting

### 🛑 Breakpoints Not Hit?
*   **Verify Build Mode**: Ensure you see `-DCMAKE_BUILD_TYPE=Debug` in your build logs.
*   **Source Mapping**: In `launch.json`, the `sourceFileMap` should map `/workspace/src` to `${workspaceFolder}/src`. This is already configured, but verify if you've moved directories.

### 🛑 IntelliSense "Red Squiggles"?
*   **Compile Commands**: Run a build task to generate `build/compile_commands.json`. This is the "brain" of C++ IntelliSense.
*   **Reset DB**: Command Palette → `C/C++: Reset IntelliSense Database`.

### 🛑 GDB "Operation Not Permitted"?
*   DevKit containers are privileged by default. If you encounter permission issues, run this inside the container:
    `echo 0 > /proc/sys/kernel/yama/ptrace_scope
