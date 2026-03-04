#!/bin/bash
# scripts/patches/uml-arm64/apply.sh
# Dipanggil dari build-debian-image.sh setelah tar extract

set -e
KERNEL_SRC="$1"
PATCH_DIR="$(dirname "$0")"

if [[ -z "$KERNEL_SRC" ]]; then
    echo "Usage: apply.sh <kernel-src-dir>"
    exit 1
fi

echo "[UML-arm64] Applying arm64 UML port patches to $KERNEL_SRC..."

for patch in "$PATCH_DIR"/0*.patch; do
    echo "[UML-arm64] Applying $(basename "$patch")..."
    patch -d "$KERNEL_SRC" -p1 --forward --reject-file=/tmp/uml-arm64.rej < "$patch"
done

echo "[UML-arm64] All patches applied successfully."
