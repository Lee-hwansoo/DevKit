# 🐛 VSCode Debugging Guide for DevKit

This guide covers how to effectively debug **C++, Python, and ROS 1/2** code running inside DevKit's Docker containers using VSCode.

> **ROS Version Support:** All configurations automatically adapt to your ROS version via the `ROS_DISTRO` environment variable set in `.env` (`humble` for ROS 2, `noetic` for ROS 1).

---

## Table of Contents

1. [Prerequisites](#-prerequisites)
2. [Connection Methods](#-connection-methods)
3. [C++ Debugging (GDB)](#-c-debugging-gdb)
4. [Python Debugging (debugpy)](#-python-debugging-debugpy)
5. [ROS 2 Launch Debugging](#-ros-2-launch-debugging)
6. [ROS 1 Launch Debugging](#-ros-1-launch-debugging)
7. [Compound Debugging](#-compound-multi-process-debugging)
8. [Build Tasks Quick Reference](#-build-tasks-quick-reference)
9. [Troubleshooting](#-troubleshooting)

---

## 📋 Prerequisites

### 1. Install Recommended Extensions

When opening this project for the first time, VSCode will prompt you to install the recommended extensions defined in `.vscode/extensions.json`. **Accept all** — they are essential for debugging.

Key extensions:

- **C/C++** (`ms-vscode.cpptools`) — GDB debugger integration
- **Python** (`ms-python.python`) + **Debugpy** (`ms-python.debugpy`) — Python debugger
- **Dev Containers** (`ms-vscode-remote.remote-containers`) — Container access
- **ROS** (`ms-iot.vscode-ros`) — ROS 1/2 integration

### 2. Build with Debug Symbols

Before debugging, you **must** build with debug symbols:

```bash
# Inside the container (via `make ros-shell` or Dev Container terminal)

# ROS 2 (colcon)
colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

# ROS 1 (catkin)
catkin build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

# Pure C++
mkdir -p build && cd build
cmake ../src -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
make -j$(nproc) install

# Or use the VSCode Task: Ctrl+Shift+B → "🔨 colcon: Build (Debug)" or "🐢 catkin: Build (Debug)"
```

> **⚠️ Important:** `RelWithDebInfo` (the default `cb` alias) includes some debug info but may optimize away local variables. Use **`Debug`** mode for full debugging capabilities.

### 3. IntelliSense Setup (compile_commands.json)

For C++ IntelliSense to work on the host, `compile_commands.json` must be accessible:

**Option A: Bind Mount (Recommended for debugging)**

```ini
# In your .env file
ROS_BUILD_VOL=./build
ROS_INSTALL_VOL=./install
```

**Option B: Dev Container (Automatic)**
When using Dev Containers, IntelliSense works automatically since VSCode runs inside the container.

### 4. Python debugpy (for Remote Attach)

Install debugpy inside the container if you plan to use remote attach:

```bash
# Inside the container
uv pip install debugpy
```

---

## 🔌 Connection Methods

There are **two ways** to connect VSCode to the DevKit container:

### Method 1: Dev Containers (Recommended)

1. Start the container: `make ros` (from the host terminal)
2. In VSCode: **Ctrl+Shift+P** → `Dev Containers: Attach to Running Container...`
3. Select the DevKit container (e.g., `myproject-ros-cpu-1`)
4. VSCode reopens inside the container — all tools and tasks work natively

### Method 2: Host + docker exec

1. Start the container: `make ros`
2. Open the project folder normally in VSCode (host-side)
3. Use the integrated terminal with `make ros-shell` for manual commands
4. Debug configurations still work for `attach` mode via GDB/debugpy

> **💡 Tip:** Method 1 provides the best experience — IntelliSense, debugging, and tasks all work seamlessly inside the container.

---

## 🔧 C++ Debugging (GDB)

> Works identically with both ROS 1 and ROS 2 C++ nodes.

### Launch a C++ Executable

1. Build with Debug symbols (see Prerequisites)
2. Press **F5** or go to **Run > Start Debugging**
3. Select **`🐛 C++: Launch Executable (GDB)`** — builds before launch
4. Or select **`🐛 C++: Launch (GDB, skip build)`** — skips build for fast iteration
5. Enter the executable path (e.g., `/workspace/install/lib/my_pkg/my_node`)
6. Set breakpoints in your source files — GDB will stop at them

> **💡 Turnaround Tip:** For large workspaces (30+ packages), use the **"skip build"** variant after your initial build. This eliminates the 10+ second dependency-tree scan on every F5 press.

### Attach to a Running C++ Process

Use this when a ROS node is already running:

```bash
# ROS 2
ros2 launch my_pkg bringup.launch.py

# ROS 1
roslaunch my_pkg bringup.launch
```

1. Press **F5** → Select **`🐛 C++: Attach to Process (GDB)`**
2. Pick the process from the list (search by node name)
3. Set breakpoints — debugger attaches immediately

### Debug a C++ Node Directly with GDB

For maximum control — launch a single C++ node with GDB:

- **ROS 2:** **`🤖 ROS2: C++ Node (GDB Direct)`** — uses `--ros-args`
- **ROS 1:** **`🐢 ROS1: C++ Node (GDB Direct)`** — uses `__name:=`

---

## 🐍 Python Debugging (debugpy)

> Works identically with both ROS 1 and ROS 2 Python nodes.

### Debug the Current Python File

1. Open any `.py` file
2. Set breakpoints
3. Press **F5** → Select **`🐍 Python: Debug Current File`**
4. Debugger launches in the integrated terminal

> Works for ROS Python nodes, launch files, and standalone scripts.

### Remote Attach (for running Python nodes)

When a Python node is already running or you need to debug it from a separate process:

**Step 1:** Add debugpy listener to your Python code:

```python
import debugpy
debugpy.listen(("0.0.0.0", 5678))
print("⏳ Waiting for debugger to attach...")
debugpy.wait_for_client()
print("✅ Debugger attached!")
```

**Step 2:** Run the Python node as usual:

```bash
# ROS 2
ros2 run my_pkg my_node

# ROS 1
rosrun my_pkg my_node.py
```

**Step 3:** In VSCode, press **F5** → Select **`🐍 Python: Attach to debugpy (Remote)`**

---

## 🤖 ROS 2 Launch Debugging

### Launch a ROS 2 Launch File

1. Press **F5** → Select **`🤖 ROS2: Launch File`** (builds first) or **`🤖 ROS2: Launch File (skip build)`** (fast)
2. Enter the launch file path (e.g., `src/my_pkg/launch/bringup.launch.py`)
3. The ROS 2 system starts with debug capabilities

### Run a Single ROS 2 Node

1. Press **F5** → Select **`🤖 ROS2: Run Node`**
2. Enter the package name and executable name
3. The node runs with Python debugging enabled

---

## 🐢 ROS 1 Launch Debugging

### Launch with roslaunch

1. Press **F5** → Select **`🐢 ROS1: roslaunch`**
2. Enter the package name and launch file name (e.g., `bringup.launch`)
3. The ROS 1 system starts with roslaunch — ensure `roscore` is running

> **Note:** `roscore` must be running separately. Start it in a terminal: `roscore &`

### Run a Single ROS 1 Node

1. Press **F5** → Select **`🐢 ROS1: rosrun`**
2. Enter the package name and node executable name
3. The node runs with Python debugging enabled

---

## 🚀 Compound (Multi-Process) Debugging

Compound configurations launch multiple debug sessions simultaneously.

### ROS 2 Compounds

| Configuration | Description |
|---|---|
| **`🚀 Full Debug: ROS2 Launch + C++ Attach`** | Launch the system, then attach GDB to a C++ node |
| **`🚀 Full Debug: ROS2 Launch + Python Attach`** | Launch the system, then attach debugpy to a Python node |

### ROS 1 Compounds

| Configuration | Description |
|---|---|
| **`🚀 Full Debug: ROS1 roslaunch + C++ Attach`** | roslaunch the system, then attach GDB to a C++ node |
| **`🚀 Full Debug: ROS1 roslaunch + Python Attach`** | roslaunch the system, then attach debugpy to a Python node |

### Usage (same for all compounds)

1. Press **F5** → Select the compound configuration
2. The launch/roslaunch starts first
3. Then you're prompted to pick a process to attach to (GDB) or debugpy connects automatically
4. Both sessions run side-by-side in the Debug panel

---

## 📋 Build Tasks Quick Reference

Access all tasks via **Ctrl+Shift+B** (build) or **Terminal → Run Task**:

### ROS 2 (colcon)

| Task | Description |
|---|---|
| `🔨 colcon: Build (Debug)` | Debug build with full symbols |
| `🔨 colcon: Build (RelWithDebInfo)` | Default development build (Ctrl+Shift+B) |
| `🔨 colcon: Build Package` | Build a single package |
| `🔨 colcon: Build (Release)` | Optimized production build |
| `🧪 colcon: Test` | Run all ROS 2 tests |
| `🧪 colcon: Test Results` | View test results summary |

### ROS 1 (catkin)

| Task | Description |
|---|---|
| `🐢 catkin: Build (Debug)` | Debug build with full symbols |
| `🐢 catkin: Build (Release)` | Optimized production build |
| `🐢 catkin: Build Package` | Build a single package |

### Common

| Task | Description |
|---|---|
| `🔨 cmake: Build (Debug)` | Pure C++ debug build |
| `🐍 Python: uv sync` | Sync Python dependencies |
| `🐍 Python: Create venv` | Create virtual environment |
| `🔄 Sync Dependencies` | Clone external repos |
| `🔍 Check Dependencies` | Verify shared libraries |
| `🧹 Clean Workspace` | Remove build artifacts |
| `🏥 Hardware Check` | GPU/Display diagnostics |
| `⚡ Source & Build Package` | Build single package (pre-debug, fast) |

---

## 🔍 Troubleshooting

### compile_commands.json not found

**Symptom:** C++ IntelliSense shows red squiggles/cannot find headers

**Solution:**

1. Ensure you built with `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON` (all VSCode tasks include this)
2. If using Named Volumes (default), switch to bind mounts in `.env`:

   ```ini
   ROS_BUILD_VOL=./build
   ROS_INSTALL_VOL=./install
   ```

3. Restart the container: `make ros-restart`

### Cannot attach GDB to process

**Symptom:** "Operation not permitted" when attaching to a process

**Solution:** DevKit containers run with `privileged: true` by default, which grants `SYS_PTRACE` capability and disables seccomp restrictions. No additional configuration is needed. If issues persist:

```bash
# Inside the container
echo 0 > /proc/sys/kernel/yama/ptrace_scope
```

### debugpy connection refused

**Symptom:** Python remote attach fails with connection refused

**Solution:**

1. Ensure debugpy is installed: `uv pip install debugpy`
2. Ensure the target node has `debugpy.listen(("0.0.0.0", 5678))` before the code you want to debug
3. Since DevKit uses `network_mode: host`, port 5678 is directly accessible

### Breakpoints not hit (C++)

**Symptom:** Breakpoints show as unverified (hollow circles)

**Solution:**

1. Verify you built with `Debug` mode, not `Release`
2. Check the `sourceFileMap` in `launch.json` — it should map `/workspace/src` to `${workspaceFolder}/src`
3. Rebuild: **Ctrl+Shift+B** → `🔨 colcon: Build (Debug)` or `🐢 catkin: Build (Debug)`

### No container found for attachment

**Symptom:** Dev Containers can't find any running container

**Solution:**

1. Start the container first: `make ros` (from the host terminal)
2. Verify it's running: `docker ps`
3. The container name follows the pattern: `{COMPOSE_PROJECT_NAME}-ros-{gpu_mode}-1`

### IntelliSense slow or incorrect

**Symptom:** Autocomplete suggestions are wrong or delayed

**Solution:**

1. Allow the indexer time to complete — large ROS workspaces may take several minutes
2. Force re-index: **Ctrl+Shift+P** → `C/C++: Reset IntelliSense Database`
3. Ensure `c_cpp_properties.json` is using the correct configuration (status bar, bottom-right)

### ROS 1: roscore not running

**Symptom:** `roslaunch` or `rosrun` fails with "Unable to communicate with master"

**Solution:**

1. Start roscore in a separate terminal: `roscore &`
2. Ensure `ROS_MASTER_URI` is set correctly in `.env` (default: `http://localhost:11311`)
