#!/usr/bin/env bash
# build-debian-image.sh — Build Debian rootfs + UML kernel for DevBox
#
# DevBox uses Linux UML (User Mode Linux) — runs as a normal Termux process,
# no /dev/kvm, no root, works on Android 11+ (and any Android).
#
# Output in ./output/:
#   debian-rootfs-{arch}.img      — Debian bookworm rootfs (sparse ext4, no compression)
#   linux-uml-{arch}             — UML kernel binary (ELF, runs as process)
#
# Requirements (install on whichever native runner you use):
#   sudo apt install debootstrap qemu-user-static binfmt-support \
#                    libguestfs-tools qemu-utils \
#                    build-essential flex bison libssl-dev libelf-dev bc
#
# NOTE: UML cannot be cross-compiled. Run on a native aarch64 or x86_64 host.
#
# Usage:  ./scripts/build-debian-image.sh [aarch64|x86_64|all]

set -euo pipefail

ARCH="${1:-all}"
OUTPUT_DIR="$(pwd)/output"
ROOTFS_SIZE="4G"
DEBIAN_SUITE="bookworm"
UML_KERNEL_VERSION="${UML_KERNEL_VERSION:-6.12.74}"

mkdir -p "$OUTPUT_DIR"

log()  { echo "[DevBox] $*"; }
die()  { echo "[DevBox][ERROR] $*" >&2; exit 1; }

check_deps() {
    local missing=()
    for cmd in debootstrap qemu-img guestfish; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing: ${missing[*]}. Install: sudo apt install debootstrap libguestfs-tools qemu-utils"
    fi
}

# ── Build Debian rootfs ────────────────────────────────────────────────────────
build_rootfs() {
    local arch="$1"
    local deb_arch qemu_arch

    case "$arch" in
        aarch64) deb_arch="arm64";  qemu_arch="aarch64" ;;
        x86_64)  deb_arch="amd64";  qemu_arch="" ;;
        *) die "Unknown arch: $arch" ;;
    esac

    local raw_img="$OUTPUT_DIR/debian-rootfs-${arch}.img"

    log "Building Debian ${DEBIAN_SUITE} rootfs for ${arch}..."

    qemu-img create -f raw "$raw_img" "$ROOTFS_SIZE"
    mkfs.ext4 -F -L "debian-devbox" "$raw_img"

    local mnt; mnt=$(mktemp -d)
    sudo mount -o loop "$raw_img" "$mnt"

    if [[ -n "$qemu_arch" ]]; then
        sudo cp "/usr/bin/qemu-${qemu_arch}-static" "$mnt/usr/bin/" 2>/dev/null || true
    fi

    log "Running debootstrap (${deb_arch})..."
    sudo debootstrap \
        --arch="$deb_arch" \
        --include="openssh-server,curl,socat,sudo,bash,zsh,coreutils,util-linux,net-tools,iproute2,procps,less,vim-tiny,ca-certificates,wget" \
        "$DEBIAN_SUITE" "$mnt" "https://deb.debian.org/debian"

    log "Configuring rootfs..."
    echo "devbox" | sudo tee "$mnt/etc/hostname" >/dev/null

    # UML block device is /dev/ubda — fstab must reference it
    sudo tee "$mnt/etc/fstab" >/dev/null <<'FSTAB'
/dev/ubda   /       ext4    errors=remount-ro   0   1
proc        /proc   proc    defaults            0   0
sysfs       /sys    sysfs   defaults            0   0
tmpfs       /tmp    tmpfs   size=128M           0   0
FSTAB

    # UML uses slirp for networking — eth0 via DHCP works out of the box
    sudo tee "$mnt/etc/network/interfaces" >/dev/null <<'NET'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
NET

    sudo chroot "$mnt" /bin/bash -c "echo 'root:devbox' | chpasswd"
    sudo sed -i 's/#*PermitRootLogin.*/PermitRootLogin yes/'              "$mnt/etc/ssh/sshd_config"
    sudo sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' "$mnt/etc/ssh/sshd_config"
    sudo chroot "$mnt" /bin/bash -c "systemctl enable ssh" 2>/dev/null || true

    log "Installing starship prompt..."
    sudo chroot "$mnt" /bin/bash -c "
        curl -sS https://starship.rs/install.sh -o /tmp/starship-install.sh
        chmod +x /tmp/starship-install.sh
        /tmp/starship-install.sh --yes --bin-dir /usr/local/bin
        rm -f /tmp/starship-install.sh
    " 2>/dev/null || log "WARNING: starship install failed — run manually"

    sudo chroot "$mnt" /bin/bash -c "chsh -s /bin/zsh root" 2>/dev/null || true

    sudo tee "$mnt/root/.zshrc" >/dev/null <<'ZSHRC'
export TERM="xterm-256color"
export LANG="en_US.UTF-8"
export EDITOR="vim"
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE AUTO_CD EXTENDED_GLOB NO_BEEP
autoload -Uz compinit && compinit
bindkey -e
bindkey '^[[A' history-search-backward
bindkey '^[[B' history-search-forward
alias ls='ls --color=auto'
alias ll='ls -lah'
alias la='ls -A'
alias grep='grep --color=auto'
eval "$(starship init zsh)"
ZSHRC

    # Shared dir — UML hostfs mounts host $PREFIX/share/devbox -> /mnt/devbox
    # (mounted by devbox-start after VM boots, via SSH)
    sudo mkdir -p "$mnt/mnt/devbox"

    [[ -n "$qemu_arch" ]] && sudo rm -f "$mnt/usr/bin/qemu-${qemu_arch}-static"
    sudo umount "$mnt"; rmdir "$mnt"

    # Upload raw sparse .img — no compression needed.
    # Sparse ext4: only written blocks count, zeros not stored on disk.
    # APK uses directly: ubd0=debian-rootfs.img (no decompression step)
    log "Done: $raw_img ($(du -sh "$raw_img" | cut -f1) on disk)"
}

# ── Build UML kernel ────────────────────────────────────────────────────────────
#
# UML = User Mode Linux. Compiled with ARCH=um, produces a regular ELF binary
# that boots Linux entirely in userspace via ptrace. No /dev/kvm, no root.
#
# Works on Android 11+ as a normal Termux process.
#
# slirp  = built-in userspace NAT networking (no tun/tap, no root needed)
# hostfs = mount host directories inside UML (for devbox shared dir)
# ubd    = UML block device driver (for .img disk files)
# ──────────────────────────────────────────────────────────────────────────────
build_uml_kernel() {
    local target_arch="$1"

    log "Building UML kernel ${UML_KERNEL_VERSION} for ${target_arch}..."

    local major="${UML_KERNEL_VERSION%%.*}"
    local tarball="/tmp/linux-${UML_KERNEL_VERSION}.tar.xz"
    local src_dir="/tmp/linux-${UML_KERNEL_VERSION}"

    # Download source once (reused between arch builds)
    if [[ ! -d "$src_dir" ]]; then
        if [[ ! -f "$tarball" ]]; then
            log "Downloading Linux ${UML_KERNEL_VERSION} source..."
            curl -L --fail --progress-bar \
                "https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-${UML_KERNEL_VERSION}.tar.xz" \
                -o "$tarball"
        fi
        log "Extracting..."
        tar -xf "$tarball" -C /tmp

        # Apply UML arm64 port patches (upstream kernel has no arm64 UML support)
        if [[ "$target_arch" == "aarch64" ]]; then
            log "Applying UML arm64 patches..."
            local patch_dir
            patch_dir="$(cd "$(dirname "$0")"; pwd)/patches/uml-arm64"
            for p in "$patch_dir"/0*.patch; do
                log "  → $(basename "$p")"
                patch -d "$src_dir" -p1 --forward < "$p"
            done
            log "UML arm64 patches applied."
        fi
    fi

    local build_dir="/tmp/linux-uml-${target_arch}"
    rm -rf "$build_dir"; mkdir -p "$build_dir"

    # UML (ARCH=um) is NOT cross-compilable.
    # The kernel build always uses the host CPU's SUBARCH for the userspace ABI,
    # so aarch64-linux-gnu-gcc would be handed x86-specific flags like -m64
    # and fail. Each arch MUST be built natively on its own runner.
    local host_arch
    host_arch="$(uname -m)"
    # Normalise uname output to our naming convention
    [[ "$host_arch" == "arm64" ]] && host_arch="aarch64"

    if [[ "$target_arch" != "$host_arch" ]]; then
        die "UML cannot be cross-compiled: target=${target_arch} but host=${host_arch}. \
Run this job on a native ${target_arch} runner (e.g. ubuntu-24.04-arm for aarch64)."
    fi

    # Native build — no CROSS_COMPILE needed
    local cross=""

    local J="-j$(nproc)"

    log "Configuring (ARCH=um)..."
    # shellcheck disable=SC2086
    make -C "$src_dir" O="$build_dir" ARCH=um $cross defconfig $J

    # Essential UML features
    cat >> "$build_dir/.config" <<'KCONFIG'
CONFIG_HOSTFS=y
CONFIG_UML_NET_SLIRP=y
CONFIG_BLK_DEV_UBD=y
KCONFIG
    # shellcheck disable=SC2086
    make -C "$src_dir" O="$build_dir" ARCH=um $cross olddefconfig

    log "Compiling UML kernel (~5 min)..."
    # shellcheck disable=SC2086
    make -C "$src_dir" O="$build_dir" ARCH=um $cross $J

    # UML build puts the binary at build_dir/linux
    local uml_bin
    uml_bin=$(find "$build_dir" -maxdepth 1 \( -name "linux" -o -name "vmlinux" \) 2>/dev/null | head -1)
    [[ -z "$uml_bin" ]] && die "UML binary not found after build for ${target_arch}"

    local dest="$OUTPUT_DIR/linux-uml-${target_arch}"
    cp "$uml_bin" "$dest"
    chmod +x "$dest"
    log "UML kernel ready: linux-uml-${target_arch} ($(du -sh "$dest" | cut -f1))"
}

# ── Main ───────────────────────────────────────────────────────────────────────
# Usage:
#   ./build-debian-image.sh [arch] [--rootfs-only | --kernel-only]
#
#   arch           aarch64 | x86_64 | all  (default: all)
#   --rootfs-only  build rootfs only  → output: debian-rootfs-{arch}.img
#   --kernel-only  build kernel only  → output: linux-uml-{arch}
#   (no flag)      build both
# ─────────────────────────────────────────────────────────────────────────────

TARGET="all"   # all | rootfs | kernel
for arg in "$@"; do
    case "$arg" in
        --rootfs-only) TARGET="rootfs" ;;
        --kernel-only) TARGET="kernel" ;;
    esac
done

check_deps

build_arch() {
    local arch="$1"
    case "$TARGET" in
        rootfs) build_rootfs "$arch" ;;
        kernel) build_uml_kernel "$arch" ;;
        all)    build_rootfs "$arch"; build_uml_kernel "$arch" ;;
    esac
}

case "$ARCH" in
    aarch64) build_arch aarch64 ;;
    x86_64)  build_arch x86_64  ;;
    all)
        build_arch aarch64
        build_arch x86_64
        ;;
    *)
        die "Usage: $0 [aarch64|x86_64|all] [--rootfs-only|--kernel-only]"
        ;;
esac

log ""
log "=== Output files ==="
ls -lh "$OUTPUT_DIR"/ 
