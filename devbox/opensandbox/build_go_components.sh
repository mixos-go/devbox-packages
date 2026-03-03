#!/bin/bash
# DevBox — Build OpenSandbox Go Components
# Compiles execd and egress inside Debian VM via crosvm (no root needed).
# Called by install.sh after Python setup.
#
# Outputs (inside proot ubuntu):
#   ~/opensandbox/bin/execd    ← execution daemon HTTP server
#   ~/opensandbox/bin/egress   ← DNS proxy + network policy sidecar
#
# ingress intentionally NOT compiled — requires knative/K8s CRDs, not applicable on Android.

set -e

SANDBOX_DIR="$HOME/opensandbox"
BIN_DIR="$SANDBOX_DIR/bin"
COMP_DIR="$SANDBOX_DIR/components"
LOG="$SANDBOX_DIR/build_go.log"

mkdir -p "$BIN_DIR"

echo "=== DevBox Go Components Build ===" | tee "$LOG"
echo "$(date)" | tee -a "$LOG"

# ── 1. Install Go if not present ──────────────────────────────────────────────
GO_BIN=$(command -v go 2>/dev/null || echo "")

if [ -z "$GO_BIN" ]; then
    echo "[1/4] Installing Go via apt..." | tee -a "$LOG"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >> "$LOG" 2>&1
    apt-get install -y golang-go >> "$LOG" 2>&1
    GO_BIN=$(command -v go)
fi

GO_VERSION=$($GO_BIN version 2>/dev/null || echo "unknown")
echo "[1/4] Go: $GO_VERSION" | tee -a "$LOG"

# Ensure Go version is >= 1.21 (opensandbox requires 1.24 but ubuntu ships older)
# If apt golang is too old, install from official binary.
GO_MAJOR=$($GO_BIN version | grep -oP 'go\K[0-9]+\.[0-9]+' | cut -d. -f1)
GO_MINOR=$($GO_BIN version | grep -oP 'go\K[0-9]+\.[0-9]+' | cut -d. -f2)

if [ "$GO_MAJOR" -lt 1 ] || ([ "$GO_MAJOR" -eq 1 ] && [ "$GO_MINOR" -lt 21 ]); then
    echo "[1/4] Go too old (need >=1.21). Installing from official binary..." | tee -a "$LOG"

    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64) GOARCH="arm64" ;;
        armv7l|armhf)  GOARCH="armv6l" ;;
        x86_64)        GOARCH="amd64" ;;
        i686)          GOARCH="386" ;;
        *)             echo "Unsupported arch: $ARCH" | tee -a "$LOG"; exit 1 ;;
    esac

    GO_TARBALL="go1.24.5.linux-${GOARCH}.tar.gz"
    GO_URL="https://go.dev/dl/${GO_TARBALL}"

    echo "[1/4] Downloading $GO_URL ..." | tee -a "$LOG"
    curl -fsSL "$GO_URL" -o "/tmp/${GO_TARBALL}" >> "$LOG" 2>&1
    tar -C /usr/local -xzf "/tmp/${GO_TARBALL}" >> "$LOG" 2>&1
    rm -f "/tmp/${GO_TARBALL}"
    export PATH="/usr/local/go/bin:$PATH"
    GO_BIN="/usr/local/go/bin/go"
    echo "export PATH=/usr/local/go/bin:\$PATH" >> "$HOME/.bashrc"
fi

export PATH="$(dirname $GO_BIN):$PATH"
export GOPATH="$HOME/go"
export GOCACHE="$HOME/.cache/go-build"
export GOFLAGS="-trimpath"
# Disable CGO where possible for static binaries (better portability in proot)
export CGO_ENABLED=0

echo "[1/4] Using: $($GO_BIN version)" | tee -a "$LOG"

# ── 2. Fixup go.mod replace directives ───────────────────────────────────────
# The replace directives point to ../internal which is fine when run from
# the opensandbox repo root. We need absolute paths here.
echo "[2/4] Patching go.mod replace directives..." | tee -a "$LOG"

patch_replace() {
    local MOD_FILE="$1"
    if [ -f "$MOD_FILE" ]; then
        # Replace relative ../internal with absolute path
        sed -i "s|replace github.com/alibaba/opensandbox/internal => ../internal|replace github.com/alibaba/opensandbox/internal => ${COMP_DIR}/internal|g" "$MOD_FILE"
        echo "  Patched: $MOD_FILE" | tee -a "$LOG"
    fi
}

patch_replace "$COMP_DIR/execd/go.mod"
patch_replace "$COMP_DIR/egress/go.mod"

# ── 3. Build execd ────────────────────────────────────────────────────────────
# execd: HTTP execution daemon — runs commands inside a sandbox, serves REST API
# Endpoints: /exec, /filesystem, /jupyter, /metric, /ping
echo "[3/4] Building execd..." | tee -a "$LOG"

if [ -f "$BIN_DIR/execd" ] && [ "$COMP_DIR/execd" -ot "$BIN_DIR/execd" ]; then
    echo "  execd binary up-to-date, skipping." | tee -a "$LOG"
else
    cd "$COMP_DIR/execd"
    $GO_BIN mod download >> "$LOG" 2>&1
    $GO_BIN build \
        -ldflags="-s -w -X github.com/alibaba/opensandbox/internal/version.Version=devbox-proot" \
        -o "$BIN_DIR/execd" \
        ./... \
        >> "$LOG" 2>&1
    echo "  ✓ execd built: $(du -sh $BIN_DIR/execd | cut -f1)" | tee -a "$LOG"
fi

# ── 4. Build egress ───────────────────────────────────────────────────────────
# egress: FQDN-based egress control — DNS proxy + nftables network policy
# Gracefully degrades if CAP_NET_ADMIN not available (logs warning, disables enforcement)
echo "[4/4] Building egress..." | tee -a "$LOG"

if [ -f "$BIN_DIR/egress" ] && [ "$COMP_DIR/egress" -ot "$BIN_DIR/egress" ]; then
    echo "  egress binary up-to-date, skipping." | tee -a "$LOG"
else
    cd "$COMP_DIR/egress"
    # egress uses some CGO for nftables on some platforms — try CGO_ENABLED=0 first
    $GO_BIN mod download >> "$LOG" 2>&1
    $GO_BIN build \
        -ldflags="-s -w -X github.com/alibaba/opensandbox/internal/version.Version=devbox-proot" \
        -o "$BIN_DIR/egress" \
        ./... \
        >> "$LOG" 2>&1 \
    || {
        echo "  CGO_ENABLED=0 failed, retrying with CGO_ENABLED=1..." | tee -a "$LOG"
        apt-get install -y gcc libc-dev >> "$LOG" 2>&1
        CGO_ENABLED=1 $GO_BIN build \
            -ldflags="-s -w" \
            -o "$BIN_DIR/egress" \
            ./... \
            >> "$LOG" 2>&1
    }
    echo "  ✓ egress built: $(du -sh $BIN_DIR/egress | cut -f1)" | tee -a "$LOG"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo "" | tee -a "$LOG"
echo "✅ Go components built successfully!" | tee -a "$LOG"
ls -lh "$BIN_DIR/" | tee -a "$LOG"
echo ""
echo "Binaries:"
echo "  execd  → $BIN_DIR/execd   (execution daemon, run with: execd --port 44772)"
echo "  egress → $BIN_DIR/egress  (network policy, requires CAP_NET_ADMIN or gracefully degrades)"
