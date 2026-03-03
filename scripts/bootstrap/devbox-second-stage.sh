#!/data/data/com.termux/files/usr/bin/bash
# DevBox Second Stage Bootstrap
# Runs after Termux bootstrap extraction.
# Downloads Debian OS image, sets up crosvm VM + virtio-fs shared mount.

set -e

DEVBOX_HOME="$HOME/.devbox"
DEBIAN_IMG="$DEVBOX_HOME/debian.img"
DEBIAN_KERNEL="$DEVBOX_HOME/vmlinuz"
DEBIAN_INITRD="$DEVBOX_HOME/initrd.img"

# DevBox shared dir — mounted into VM at /mnt/devbox via virtio-fs
# Contains: opensandbox/, mobile-agent/ (from bootstrap zip)
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

mkdir -p "$DEVBOX_HOME"
mkdir -p "$DEVBOX_SHARE"

# ── 1. Download Debian OS image ───────────────────────────────────────────────
if [ ! -f "$DEBIAN_IMG" ]; then
    log "Downloading Debian rootfs for $ARCH..."
    curl --fail --location --progress-bar \
        --output "$DEBIAN_IMG.tmp" \
        "$DEVBOX_RELEASES/debian-rootfs-$ARCH.img.gz" \
        || fail "Failed to download Debian rootfs."
    log "Decompressing rootfs..."
    gunzip -c "$DEBIAN_IMG.tmp" > "$DEBIAN_IMG"
    rm -f "$DEBIAN_IMG.tmp"
    log "Debian rootfs ready."
else
    log "Debian rootfs already present, skipping."
fi

# ── 2. Download kernel + initrd ───────────────────────────────────────────────
if [ ! -f "$DEBIAN_KERNEL" ]; then
    log "Downloading kernel for $ARCH..."
    curl --fail --location --progress-bar \
        --output "$DEBIAN_KERNEL" \
        "$DEVBOX_RELEASES/vmlinuz-$ARCH" \
        || fail "Failed to download kernel."
fi

if [ ! -f "$DEBIAN_INITRD" ]; then
    log "Downloading initrd for $ARCH..."
    curl --fail --location --progress-bar \
        --output "$DEBIAN_INITRD" \
        "$DEVBOX_RELEASES/initrd-$ARCH.img" \
        || fail "Failed to download initrd."
fi

# ── 3. Verify crosvm ─────────────────────────────────────────────────────────
if ! command -v crosvm &>/dev/null; then
    fail "crosvm not found. Requires Android 13+ with virtualization support."
fi

# ── 4. Write devbox-start ─────────────────────────────────────────────────────
# Uses --shared-dir to mount $PREFIX/share/devbox into VM at /mnt/devbox
# via virtio-fs. This is how opensandbox + mobile-agent get into the VM
# without being baked into the OS image.
DEVBOX_START="$PREFIX/bin/devbox-start"
cat > "$DEVBOX_START" << 'SCRIPT'
#!/data/data/com.termux/files/usr/bin/bash
# Start DevBox Debian VM via crosvm

DEVBOX_HOME="$HOME/.devbox"
DEVBOX_SHARE="$PREFIX/share/devbox"
VSOCK_CID=3

exec crosvm run \
    --cpus 2 \
    --mem 1024 \
    --rwdisk "$DEVBOX_HOME/debian.img" \
    --kernel "$DEVBOX_HOME/vmlinuz" \
    --initrd "$DEVBOX_HOME/initrd.img" \
    --params "root=/dev/vda rw console=ttyS0 quiet" \
    --serial type=stdout,hardware=serial,num=1 \
    --vsock cid="$VSOCK_CID" \
    --shared-dir "$DEVBOX_SHARE:devbox:type=fs" \
    "$@"
SCRIPT
chmod 755 "$DEVBOX_START"

# ── 5. Write devbox-shell ─────────────────────────────────────────────────────
DEVBOX_SHELL="$PREFIX/bin/devbox-shell"
cat > "$DEVBOX_SHELL" << 'SCRIPT'
#!/data/data/com.termux/files/usr/bin/bash
# Open shell into running DevBox Debian VM (SSH over vsock)

VSOCK_CID=3
exec ssh \
    -o "ProxyCommand=socat - VSOCK-CONNECT:${VSOCK_CID}:22" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    root@localhost "$@"
SCRIPT
chmod 755 "$DEVBOX_SHELL"

log "DevBox setup complete!"
log "  Start VM:   devbox-start"
log "  Open shell: devbox-shell"
log "  Shared dir: $DEVBOX_SHARE → /mnt/devbox (inside VM)"

# ── 6. Write devbox-forward ───────────────────────────────────────────────────
# Forwards Debian VM ports to localhost so Android apps can reach them.
# MobileAgent server: localhost:4201 → vsock:3:4201 (inside Debian)
DEVBOX_FORWARD="$PREFIX/bin/devbox-forward"
cat > "$DEVBOX_FORWARD" << 'SCRIPT'
#!/data/data/com.termux/files/usr/bin/bash
# Port-forward: localhost:PORT → Debian VM vsock:3:PORT
# Usage: devbox-forward [port]   (default: 4201 for MobileAgent)

VSOCK_CID=3
PORT="${1:-4201}"

log() { echo "[devbox-forward]" "$@"; }
log "Forwarding localhost:${PORT} → vsock:${VSOCK_CID}:${PORT}"

# socat listens on TCP localhost:PORT and connects to vsock
exec socat \
    TCP-LISTEN:${PORT},bind=127.0.0.1,reuseaddr,fork \
    VSOCK-CONNECT:${VSOCK_CID}:${PORT}
SCRIPT
chmod 755 "$DEVBOX_FORWARD"

log "  Port-forward: devbox-forward [port]  (default 4201 for MobileAgent)"
