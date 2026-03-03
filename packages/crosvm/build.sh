TERMUX_PKG_HOMEPAGE=https://crosvm.dev
TERMUX_PKG_DESCRIPTION="A secure virtual machine monitor for KVM on Linux/Android"
TERMUX_PKG_LICENSE="BSD 3-Clause"
TERMUX_PKG_MAINTAINER="@devbox"
TERMUX_PKG_VERSION="main"
TERMUX_PKG_SRCURL=https://chromium.googlesource.com/crosvm/crosvm/+archive/refs/heads/main.tar.gz
TERMUX_PKG_SHA256=SKIP
TERMUX_PKG_DEPENDS="openssl, zlib"
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_NO_STATICSPLIT=true

# crosvm only supports aarch64 and x86_64
if [ "$TERMUX_ARCH" = "arm" ] || [ "$TERMUX_ARCH" = "i686" ]; then
	termux_error_exit "crosvm does not support $TERMUX_ARCH (32-bit). Only aarch64 and x86_64 are supported."
fi

termux_step_pre_configure() {
	termux_setup_rust

	# Map Termux arch to Rust target
	case "$TERMUX_ARCH" in
		aarch64) export CARGO_TARGET_NAME="aarch64-linux-android" ;;
		x86_64)  export CARGO_TARGET_NAME="x86_64-linux-android" ;;
	esac

	# Use pkg-config for system libs
	export OPENSSL_NO_VENDOR=1
	export OPENSSL_SYS_USE_PKG_CONFIG=1

	# No need for system linker flags clash
	unset CFLAGS
	unset CXXFLAGS
}

termux_step_make() {
	# Build crosvm with minimal features suitable for Android/Termux:
	# - kvm: core VM support via /dev/kvm
	# - balloon: memory ballooning for guest
	# - net: virtio-net networking
	# - disk: virtio-block disk support
	# No GPU, no USB, no sandbox (minijail not available in Termux)
	cargo build \
		--release \
		--no-default-features \
		--features "kvm,balloon,net,disk,audio" \
		--target "$CARGO_TARGET_NAME"
}

termux_step_make_install() {
	install -Dm755 \
		"target/$CARGO_TARGET_NAME/release/crosvm" \
		"$TERMUX_PREFIX/bin/crosvm"
}
