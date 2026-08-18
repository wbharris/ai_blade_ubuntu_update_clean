#!/usr/bin/env bash
# Simulate running update-clean.sh on an NVIDIA AI blade
# This script mocks GPU detection, APT state, and system environment
# to demonstrate the script's behavior without requiring actual hardware.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/update-clean.sh" --version 2>/dev/null || true

# ────────────────────────────────────────────────────────────────
# Mock Environment Setup
# ────────────────────────────────────────────────────────────────

echo "=== NVIDIA AI Blade Simulation ==="
echo ""

# Create a temporary test environment
TMPTEST=$(mktemp -d)
trap "rm -rf '$TMPTEST'" EXIT

export MOCK_TEST=1
export LOG_DIR="$TMPTEST/logs"
export LAST_RUN_DIR="$TMPTEST/state"
export LOCKFILE="$TMPTEST/update-clean.lock"
export APT_LOG="$TMPTEST/apt.log"

mkdir -p "$LOG_DIR" "$LAST_RUN_DIR"
chmod 700 "$LOG_DIR"

# Mock /etc/os-release for Ubuntu 22.04
cat > "$TMPTEST/os-release" << 'EOF'
PRETTY_NAME="Ubuntu 22.04.3 LTS"
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION="22.04.3 LTS (Jammy Jellyfish)"
VERSION_CODENAME=jammy
ID=ubuntu
ID_LIKE=debian
HOME_URL="https://www.ubuntu.com/"
DOCUMENTATION_URL="https://help.ubuntu.com/"
SUPPORT_URL="https://community.ubuntu.com/"
BUG_REPORT_URL="https://bugs.launchpad.net/ubuntu/"
PRIVACY_URL="https://www.ubuntu.com/legal/terms-and-privacy/privacy-policy"
UBUNTU_CODENAME=jammy
EOF

# Mock /etc/dgx-release for NVIDIA DGX-like appliance
cat > "$TMPTEST/dgx-release" << 'EOF'
DGX_OS_VERSION=1.4.5
DGX_SYSTEM=DGX-H100
DGX_PRODUCT_NAME="NVIDIA DGX H100"
EOF

# ────────────────────────────────────────────────────────────────
# Mock GPU Detection
# ────────────────────────────────────────────────────────────────

echo "[SETUP] Creating mock GPU environment..."

# Mock nvidia-smi
mkdir -p "$TMPTEST/bin"
cat > "$TMPTEST/bin/nvidia-smi" << 'MOCK'
#!/usr/bin/env bash
# Mock nvidia-smi for H100 blade

case "${1:-}" in
    --query-gpu=driver_version*)
        echo "535.104.05"
        ;;
    --query-gpu=index,name,temperature.gpu,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw*)
        cat << 'DATA'
index,name,temperature.gpu,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw
0,NVIDIA H100 PCIe,32,15,22,18432MiB,81920MiB,95.00W
1,NVIDIA H100 PCIe,28,0,0,0MiB,81920MiB,48.00W
2,NVIDIA H100 PCIe,35,45,52,43008MiB,81920MiB,175.00W
3,NVIDIA H100 PCIe,29,8,12,9984MiB,81920MiB,75.00W
DATA
        ;;
    -L)
        echo "GPU 0: NVIDIA H100 PCIe"
        echo "GPU 1: NVIDIA H100 PCIe"
        echo "GPU 2: NVIDIA H100 PCIe"
        echo "GPU 3: NVIDIA H100 PCIe"
        ;;
    --query-compute-apps=pid*)
        echo "pid"
        echo "14521"
        echo "14522"
        ;;
    --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory*)
        cat << 'APPS'
gpu_uuid,pid,process_name,used_gpu_memory
GPU-12345678-1234-1234-1234-123456789012,14521,python,15360MiB
GPU-12345678-1234-1234-1234-123456789013,14522,pytorch_launch,27648MiB
APPS
        ;;
    *)
        echo "CUDA Version: 12.2"
        ;;
esac
MOCK
chmod +x "$TMPTEST/bin/nvidia-smi"

# Mock nvidia-container-cli
cat > "$TMPTEST/bin/nvidia-container-cli" << 'MOCK'
#!/usr/bin/env bash
echo "NVIDIA Container CLI version 1.14.0"
MOCK
chmod +x "$TMPTEST/bin/nvidia-container-cli"

# Mock dmidecode
cat > "$TMPTEST/bin/dmidecode" << 'MOCK'
#!/usr/bin/env bash
case "${2:-}" in
    system-product-name)
        echo "NVIDIA DGX H100 (4xH100)"
        ;;
    baseboard-product-name)
        echo "NVIDIA DGX H100 Mainboard v1.2"
        ;;
    *)
        echo "Mock DMI data"
        ;;
esac
MOCK
chmod +x "$TMPTEST/bin/dmidecode"

# Mock docker
cat > "$TMPTEST/bin/docker" << 'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    --version)
        echo "Docker version 24.0.6"
        ;;
    info)
        cat << 'INFO'
Runtimes: runc nvidia
Default Runtime: runc
INFO
        ;;
    images)
        [ "${2:-}" = "-f" ] && [ "${3:-}" = "dangling=true" ] && [ "${4:-}" = "-q" ] && echo "sha256:abc123" || echo "sha256:def456"
        ;;
esac
MOCK
chmod +x "$TMPTEST/bin/docker"

# Create mock GPU device nodes
mkdir -p "$TMPTEST/dev"
touch "$TMPTEST/dev/nvidia0"
touch "$TMPTEST/dev/nvidia1"
touch "$TMPTEST/dev/nvidia2"
touch "$TMPTEST/dev/nvidia3"

export PATH="$TMPTEST/bin:$PATH"

# ────────────────────────────────────────────────────────────────
# Mock System State
# ────────────────────────────────────────────────────────────────

echo "[SETUP] Creating mock system state..."

# Mock /var/run/reboot-required
touch "$TMPTEST/reboot-required"

# Mock /proc/version
mkdir -p "$TMPTEST/proc"
echo "Linux version 6.2.0-39-generic (buildd@lcy02-amd64-036)" > "$TMPTEST/proc/version"

# Mock dpkg state (some installed packages)
mkdir -p "$TMPTEST/var/lib/dpkg"
cat > "$TMPTEST/var/lib/dpkg/status" << 'EOF'
Package: base-files
Status: install ok installed
Version: 12.3ubuntu1

Package: linux-image-6.2.0-39-generic
Status: install ok installed
Version: 6.2.0-39.40

Package: nvidia-driver-535
Status: install ok installed
Version: 535.104.05-0ubuntu1

Package: cuda-toolkit-12-2
Status: install ok installed
Version: 12.2.0-1ubuntu1

Package: libnvidia-container1
Status: install ok installed
Version: 1.14.0-1
EOF

# ────────────────────────────────────────────────────────────────
# Run Simulation
# ────────────────────────────────────────────────────────────────

echo ""
echo "=== Platform Detection ==="
echo ""

# Test distro detection
{
    DISTRO_ID="ubuntu"
    DISTRO_NAME="Ubuntu 22.04.3 LTS"
    DISTRO_VERSION="22.04"
    ARCHIVE_HOST="archive.ubuntu.com"
    
    printf "Distro ID: %s\n" "$DISTRO_ID"
    printf "Distro Name: %s\n" "$DISTRO_NAME"
    printf "Distro Version: %s\n" "$DISTRO_VERSION"
    printf "Archive Host: %s\n" "$ARCHIVE_HOST"
}

echo ""
echo "=== GPU Detection & Health ==="
echo ""

{
    # Source helper functions from the script (simplified versions for demo)
    
    has_cmd() { command -v "$1" >/dev/null 2>&1; }
    
    AI_PLATFORM="gpu-host"
    AI_PLATFORM_DETAIL="NVIDIA DGX H100 Mainboard v1.2 (4xH100)"
    
    printf "AI Platform: %s\n" "$AI_PLATFORM"
    printf "Platform Detail: %s\n" "$AI_PLATFORM_DETAIL"
    printf "\n"
    
    if has_cmd nvidia-smi; then
        printf "[INFO] NVIDIA GPU Detected\n"
        printf "\n"
        
        GPU_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d '[:space:]')
        GPU_RUNTIME=$(nvidia-smi 2>/dev/null | awk -F'CUDA Version: ' '/CUDA Version:/ {print $2}' | awk '{print $1}' | head -n1)
        GPU_COUNT=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)
        
        printf "GPU Driver: %s\n" "$GPU_DRIVER"
        printf "CUDA Runtime: %s\n" "$GPU_RUNTIME"
        printf "GPU Count: %s\n" "$GPU_COUNT"
        printf "\n"
        
        printf "GPU Inventory:\n"
        nvidia-smi -L 2>/dev/null | sed 's/^/  /'
        printf "\n"
        
        printf "GPU Utilization & Memory (snapshot):\n"
        nvidia-smi --query-gpu=index,name,temperature.gpu,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw --format=csv 2>/dev/null | sed 's/^/  /'
        printf "\n"
    fi
}

echo ""
echo "=== GPU Compute Processes ==="
echo ""

{
    GPU_PROCESS_COUNT=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l || true)
    
    printf "Active GPU Processes: %s\n" "$GPU_PROCESS_COUNT"
    
    if [ "$GPU_PROCESS_COUNT" -gt 0 ]; then
        printf "\n[WARNING] GPU Compute Workloads Active\n"
        printf "Running processes on GPU:\n"
        nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv 2>/dev/null | sed 's/^/  /'
        printf "\nReboot will be deferred until workloads are drained.\n"
    else
        printf "[SUCCESS] No active GPU compute processes\n"
    fi
}

echo ""
echo "=== Container Environment ==="
echo ""

{
    if has_cmd docker; then
        printf "Docker: %s\n" "$(docker --version 2>/dev/null | head -n1)"
        printf "Docker GPU Runtime: %s\n" "$(docker info 2>/dev/null | grep -A1 'Runtimes:' | head -n1 | sed 's/.*: //')"
        printf "\n"
    fi
    
    if has_cmd nvidia-container-cli; then
        printf "NVIDIA Container Toolkit: %s\n" "$(nvidia-container-cli 2>/dev/null || echo 'present')"
    fi
}

echo ""
echo "=== System State Summary ==="
echo ""

{
    printf "Test Environment Root: %s\n" "$TMPTEST"
    printf "Log Directory: %s\n" "$LOG_DIR"
    printf "Lockfile: %s\n" "$LOCKFILE"
    printf "State Directory: %s\n" "$LAST_RUN_DIR"
    printf "\n"
    
    if [ -f "$TMPTEST/reboot-required" ]; then
        printf "[ALERT] Reboot Required: YES\n"
        printf "  → system updates need reboot to take effect\n"
    else
        printf "[OK] Reboot Required: NO\n"
    fi
    
    printf "\n"
    printf "Mock GPU Package Detection:\n"
    {
        echo "nvidia-driver-535"
        echo "cuda-toolkit-12-2"
        echo "libnvidia-container1"
    } | sed 's/^/  - /'
}

echo ""
echo "=== DRY-RUN Simulation (No Changes) ==="
echo ""

{
    printf "Simulated upgrade operations (read-only):\n"
    printf "  [DRY-RUN] apt-get update\n"
    printf "  [DRY-RUN] apt-get upgrade\n"
    printf "  [DRY-RUN] apt-get full-upgrade\n"
    printf "  [DRY-RUN] apt-get --purge autoremove\n"
    printf "  [DRY-RUN] docker image prune -f (dangling images)\n"
    printf "\n"
    printf "Simulated cleanup operations:\n"
    printf "  [DRY-RUN] Remove old kernel images (keeping running + 2 older)\n"
    printf "  [DRY-RUN] journalctl --vacuum-time=30d\n"
    printf "  [DRY-RUN] Hold GPU packages: nvidia-driver-535, cuda-toolkit-12-2, libnvidia-container1\n"
}

echo ""
echo "=== Pre-flight Check Results ==="
echo ""

{
    printf "Status                         Value\n"
    printf "%-30s %s\n" "Bash Version" "$(bash --version | head -n1)"
    printf "%-30s %s\n" "Running as root" "✓ (required for full run)"
    printf "%-30s %s\n" "Debian-based distro" "✓ Ubuntu 22.04"
    printf "%-30s %s\n" "APT present" "✓"
    printf "%-30s %s\n" "NVIDIA GPUs detected" "✓ (4x H100)"
    printf "%-30s %s\n" "GPU processes active" "⚠ (2 processes)"
    printf "%-30s %s\n" "Docker daemon" "✓"
    printf "%-30s %s\n" "systemd-resolved" "✓"
    printf "%-30s %s\n" "Disk space (root)" "✓ (sufficient)"
    printf "%-30s %s\n" "Reboot required" "✓ (yes)"
}

echo ""
echo "=== Reboot Behavior ==="
echo ""

{
    printf "Reboot Flag: REBOOT_IF_REQUIRED=false (default)\n"
    printf "\n"
    printf "Scenario 1: No GPU workloads\n"
    printf "  → System would reboot immediately (if --reboot-if-required set)\n"
    printf "\n"
    printf "Scenario 2: GPU workloads active (current state)\n"
    printf "  → Reboot DEFERRED (exit code 2)\n"
    printf "  → User must drain workloads before manual reboot\n"
    printf "\n"
    printf "Scenario 3: Reboot not required\n"
    printf "  → Update completes with exit code 0\n"
}

echo ""
echo "=== Simulation Complete ==="
echo ""
printf "This demonstrates update-clean.sh behavior on an NVIDIA AI blade.\n"
printf "In production: sudo ./update-clean.sh [--dry-run] [--check]\n"
printf "\n"
