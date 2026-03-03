#!/data/data/com.termux/files/usr/bin/bash
# DevBox Second Stage Bootstrap
# Downloads Debian image + UML kernel, writes devbox-{start,shell,forward}.
#
# Uses Linux UML (User Mode Linux) — runs as a normal Termux process.
# No /dev/kvm, no root. Works on Android 11+.

set -e

DEVBOX_HOME="$HOME/.devbox"
DEBIAN_IMG="$DEVBOX_HOME/debian.img"
UML_BIN="$DEVBOX_HOME/linux-uml"
SSH_KEY="$HOME/.ssh/devbox_id_ed25519"

DEVBOX_SHARE="$PREFIX/share/devbox"
DEVBOX_RELEASES="https://github.com/mixos-go/devbox-packages/releases/download/debian-latest"

ARCH="$(uname -m)"
case "$ARCH" in
    aarch64) ;;
    x86_64)  ;;
    *) echo "[!] Unsupported arch: $ARCH"; exit 1 ;;
esac

log()  { echo "[DevBox]" "$@"; }
fail() { echo "[DevBox][ERROR]" "$@" 1>&2; exit 1; }

mkdir -p "$DEVBOX_HOME" "$DEVBOX_SHARE"

# ── 1. Download Debian rootfs ──────────────────────────────────────────────────
if [ ! -f "$DEBIAN_IMG" ]; then
    log "Downloading Debian rootfs ($ARCH)..."
    curl --fail --location --progress-bar \
        -o "$DEBIAN_IMG.tmp" \
        "$DEVBOX_RELEASES/debian-rootfs-$ARCH.img.gz" \
        || fail "Failed to download Debian rootfs."
    log "Decompressing..."
    gunzip -c "$DEBIAN_IMG.tmp" > "$DEBIAN_IMG"
    rm -f "$DEBIAN_IMG.tmp"
    log "Rootfs ready."
else
    log "Rootfs already present."
fi

# ── 2. Download UML kernel ─────────────────────────────────────────────────────
if [ ! -f "$UML_BIN" ]; then
    log "Downloading UML kernel ($ARCH)..."
    curl --fail --location --progress-bar \
        -o "$UML_BIN" "$DEVBOX_RELEASES/linux-uml-$ARCH" \
        || fail "Failed to download UML kernel."
    chmod +x "$UML_BIN"
    log "UML kernel ready."
else
    log "UML kernel already present."
fi

# ── 3. SSH key (passwordless login to VM via localhost:2222) ───────────────────
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
if [ ! -f "$SSH_KEY" ]; then
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "devbox@android" 2>/dev/null
    log "SSH key generated: $SSH_KEY"
fi

# ── 4. Write devbox-start ──────────────────────────────────────────────────────
cat > "$PREFIX/bin/devbox-start" << 'SCRIPT'
#!/data/data/com.termux/files/usr/bin/bash
# Start DevBox Debian VM via Linux UML
# UML runs as a normal Termux process — no KVM, no root, Android 11+ compatible.
# slirp: userspace NAT, forwards host:2222 -> guest:22 (sshd).

DEVBOX_HOME="$HOME/.devbox"
DEVBOX_SHARE="$PREFIX/share/devbox"
UML_BIN="$DEVBOX_HOME/linux-uml"
SSH_KEY="$HOME/.ssh/devbox_id_ed25519"
LOG="$DEVBOX_HOME/vm.log"
PID_FILE="$DEVBOX_HOME/vm.pid"

mkdir -p "$DEVBOX_HOME"

# Kill stale instance if running
if [ -f "$PID_FILE" ]; then
    OLD="$(cat "$PID_FILE" 2>/dev/null)"
    if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
        log "Stopping stale VM (PID $OLD)..."
        kill "$OLD" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$PID_FILE"
fi

export LD_LIBRARY_PATH="$PREFIX/lib:$LD_LIBRARY_PATH"
export TMPDIR="$PREFIX/tmp"

log() { echo "[devbox-start]" "$@"; }

log "Starting UML VM..."
nohup "$UML_BIN" \
    mem=1024M \
    ubd0="$DEVBOX_HOME/debian.img" \
    eth0=slirp,,tcp:2222:22 \
    root=/dev/ubda rw quiet \
    con0=fd:0,fd:1 con=pts \
    >> "$LOG" 2>&1 &

VM_PID=$!
echo "$VM_PID" > "$PID_FILE"
log "UML started (PID $VM_PID), waiting for sshd on port 2222..."

# Wait up to 60s for sshd (UML boots in ~5-15s on modern Android)
for i in $(seq 1 30); do
    sleep 2
    if bash -c "echo >/dev/tcp/127.0.0.1/2222" 2>/dev/null; then
        log "VM ready! (${i}x2s elapsed)"
        # Mount devbox share via UML hostfs (built-in filesystem bridge)
        ssh -i "$SSH_KEY" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -o ConnectTimeout=3 -p 2222 root@localhost \
            "mount -t hostfs none /mnt/devbox -o '$DEVBOX_SHARE' 2>/dev/null || true" \
            2>/dev/null || true
        exit 0
    fi
    if ! kill -0 "$VM_PID" 2>/dev/null; then
        log "ERROR: VM process died. Check: $LOG"
        exit 1
    fi
done

log "WARNING: sshd not responding after 60s. Check: $LOG"
exit 0
SCRIPT
chmod 755 "$PREFIX/bin/devbox-start"

# ── 5. Write devbox-shell ──────────────────────────────────────────────────────
cat > "$PREFIX/bin/devbox-shell" << 'SCRIPT'
#!/data/data/com.termux/files/usr/bin/bash
# Open shell into DevBox VM (SSH over localhost:2222)
exec ssh \
    -i "$HOME/.ssh/devbox_id_ed25519" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=5 \
    -p 2222 root@localhost "$@"
SCRIPT
chmod 755 "$PREFIX/bin/devbox-shell"

# ── 6. Write devbox-forward ────────────────────────────────────────────────────
cat > "$PREFIX/bin/devbox-forward" << 'SCRIPT'
#!/data/data/com.termux/files/usr/bin/bash
# Forward localhost:PORT to VM:PORT via SSH tunnel
# Usage: devbox-forward [port]   (default: 4201 for MobileAgent)
PORT="${1:-4201}"
exec ssh \
    -i "$HOME/.ssh/devbox_id_ed25519" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -N \
    -L "127.0.0.1:${PORT}:127.0.0.1:${PORT}" \
    -p 2222 root@localhost
SCRIPT
chmod 755 "$PREFIX/bin/devbox-forward"

# ── Done ────────────────────────────────────────────────────────────────────────
log ""
log "DevBox setup complete!"
log "  devbox-start          — launch VM"
log "  devbox-shell          — open shell in VM"
log "  devbox-forward [port] — forward port from VM (default: 4201)"
log "  SSH key: $SSH_KEY"
log "  VM log:  $DEVBOX_HOME/vm.log"
