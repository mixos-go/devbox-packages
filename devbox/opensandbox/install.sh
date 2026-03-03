#!/bin/bash
# DevBox OpenSandbox Setup Script
# Runs inside the Debian VM (via devbox-shell).
#
# Source lives on the TERMUX side at $PREFIX/share/devbox/opensandbox/
# and is mounted into the VM at /mnt/devbox/opensandbox/ via virtio-fs.
# No symlink needed — it's a real mount.

set -e

# virtio-fs mount point (set up by build-debian-image.sh fstab entry)
DEVBOX_MOUNT="/mnt/devbox"
SOURCE_DIR="$DEVBOX_MOUNT/opensandbox"
SANDBOX_DIR="$HOME/opensandbox"
CONFIG_PATH="$HOME/.sandbox.toml"
LOG="/tmp/devbox_opensandbox_install.log"

echo "=== DevBox OpenSandbox Setup ===" | tee "$LOG"

# ── 0. Check virtio-fs mount ──────────────────────────────────────────────────
if [ ! -d "$SOURCE_DIR" ]; then
    # Try mounting manually if automount failed
    echo "[0/5] Mounting virtio-fs devbox share..." | tee -a "$LOG"
    mkdir -p "$DEVBOX_MOUNT"
    mount -t virtiofs devbox "$DEVBOX_MOUNT" 2>> "$LOG" || {
        echo "ERROR: Could not mount virtio-fs share." | tee -a "$LOG"
        echo "Make sure DevBox was started with: devbox-start" | tee -a "$LOG"
        exit 1
    }
fi
echo "[0/5] Source dir: $SOURCE_DIR" | tee -a "$LOG"

# ── 1. System deps ────────────────────────────────────────────────────────────
echo "[1/5] Installing system deps..." | tee -a "$LOG"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >> "$LOG" 2>&1
apt-get install -y python3 python3-pip python3-venv curl golang-go >> "$LOG" 2>&1
echo "✓ System deps installed" | tee -a "$LOG"

# ── 2. Copy source + setup Python venv ───────────────────────────────────────
echo "[2/5] Setting up workspace at $SANDBOX_DIR..." | tee -a "$LOG"
mkdir -p "$SANDBOX_DIR"
# Copy from virtio-fs mount (read-only) to writable home dir
cp -r "$SOURCE_DIR/." "$SANDBOX_DIR/"

python3 -m venv "$SANDBOX_DIR/.venv" >> "$LOG" 2>&1
source "$SANDBOX_DIR/.venv/bin/activate"
pip install --quiet \
    fastapi "uvicorn[standard]" pydantic pydantic-settings \
    httpx pyyaml tomli >> "$LOG" 2>&1
echo "✓ Python env ready" | tee -a "$LOG"

# ── 3. Register runtime in factory.py ────────────────────────────────────────
echo "[3/5] Patching factory.py..." | tee -a "$LOG"
FACTORY="$SANDBOX_DIR/server/src/services/factory.py"
if ! grep -q "crosvm_service" "$FACTORY"; then
    sed -i '/from src.services.k8s import KubernetesSandboxService/a from src.services.crosvm_service import CrosvmSandboxService' "$FACTORY"
    sed -i 's/"kubernetes": KubernetesSandboxService,/"kubernetes": KubernetesSandboxService,\n        "crosvm":     CrosvmSandboxService,/' "$FACTORY"
    echo "✓ factory.py patched" | tee -a "$LOG"
else
    echo "✓ factory.py already patched" | tee -a "$LOG"
fi

# ── 4. Install config ─────────────────────────────────────────────────────────
echo "[4/5] Installing config..." | tee -a "$LOG"
cp "$SANDBOX_DIR/config.toml" "$CONFIG_PATH"
echo "✓ Config at $CONFIG_PATH" | tee -a "$LOG"

# ── 5. Build Go components ────────────────────────────────────────────────────
echo "[5/5] Building Go components (execd + egress)..." | tee -a "$LOG"
bash "$SANDBOX_DIR/build_go_components.sh" >> "$LOG" 2>&1 \
    && echo "✓ Go components built" | tee -a "$LOG" \
    || echo "⚠ Go build failed (non-fatal, check $LOG)" | tee -a "$LOG"

echo ""
echo "✅ OpenSandbox setup complete!"
echo "   Start:    bash $SANDBOX_DIR/start.sh"
echo "   API docs: http://localhost:8080/docs"
