#!/bin/bash
set -euo pipefail

# Paths
WORKDIR="$(pwd)"
OUT_DIR="${1:-"$WORKDIR/files"}"
STAGING="$(mktemp -d)"
ROOTFS_TAR="$OUT_DIR/rootfs.tgz"
BOOT_RAW="$STAGING/boot.raw"
ROOT_RAW="$STAGING/rootfs.raw"
ROOTDIR="$STAGING/rootdir"
BOOTDIR="$STAGING/bootdir"

# Cleanup on exit
trap 'rm -rf "$STAGING"' EXIT INT TERM

# Sizes. The boot image stays fixed. The rootfs image is sized
# dynamically from its content plus headroom — it is expanded to
# fill the whole partition on first boot (see expand-rootfs), so a
# fixed oversized image only wastes build time and download bytes.
# ROOT_SIZE_MIB can still pin an exact size.
BOOT_SIZE_MIB="${BOOT_SIZE_MIB:=64}"
ROOT_SIZE_MIB="${ROOT_SIZE_MIB:=}"
ROOT_HEADROOM_MIB="${ROOT_HEADROOM_MIB:=512}"

# Requirements
[ -d "$OUT_DIR" ] || { echo "No existe directorio: $OUT_DIR"; exit 1; }
[ -f "$ROOTFS_TAR" ] || { echo "No existe $ROOTFS_TAR"; exit 1; }

echo "[*] Output directory: $OUT_DIR"
echo "[*] Temporary staging: $STAGING"
echo "[*] Rootfs source: $ROOTFS_TAR"

# Extract the rootfs tarball once. The images are populated straight
# from the directory with mkfs -d — no loop mounts needed.
mkdir -p "$ROOTDIR" "$BOOTDIR"
tar xpf "$ROOTFS_TAR" -C "$ROOTDIR"

# Boot image content = the tarball's /boot at the partition root
# (the layout the old --strip-components=2 extraction produced),
# minus linux.efi.
if [ -d "$ROOTDIR/boot" ]; then
    cp -a "$ROOTDIR/boot/." "$BOOTDIR/" || true
    rm -f "$BOOTDIR/linux.efi"
fi

echo "[*] Boot partition contents:"
ls -lhR "$BOOTDIR/" | head -30 || true

# The rootfs image keeps /boot, /root and /dev as empty directories
# (mountpoint/runtime dirs — the same exclusions the old per-image
# tar extraction applied: ./boot/*, ./root/*, ./dev/*).
for d in boot root dev; do
    if [ -d "$ROOTDIR/$d" ]; then
        find "$ROOTDIR/$d" -mindepth 1 -delete
    fi
done

# Create boot image (ext2)
echo "[*] Creating boot image ($BOOT_SIZE_MIB MiB)..."
truncate -s "$((BOOT_SIZE_MIB * 1024 * 1024))" "$BOOT_RAW"
mkfs.ext2 -F -d "$BOOTDIR" "$BOOT_RAW" >/dev/null 2>&1

# Create rootfs image (ext4), sized from content + headroom
if [ -z "$ROOT_SIZE_MIB" ]; then
    CONTENT_MIB="$(du -sm "$ROOTDIR" | cut -f1)"
    ROOT_SIZE_MIB=$((CONTENT_MIB + ROOT_HEADROOM_MIB))
    echo "[*] Rootfs content: $CONTENT_MIB MiB + $ROOT_HEADROOM_MIB MiB headroom"
fi
echo "[*] Creating rootfs image ($ROOT_SIZE_MIB MiB)..."
truncate -s "$((ROOT_SIZE_MIB * 1024 * 1024))" "$ROOT_RAW"
mkfs.ext4 -F -d "$ROOTDIR" "$ROOT_RAW" >/dev/null 2>&1

# Compress raw images with gzip
echo "[*] Compressing images..."
gzip -c "$BOOT_RAW" > "$OUT_DIR/boot.img.gz"
gzip -c "$ROOT_RAW" > "$OUT_DIR/rootfs.img.gz"

echo "[+] Images created successfully:"
echo "    - $OUT_DIR/boot.img.gz ($(du -h "$OUT_DIR/boot.img.gz" | cut -f1))"
echo "    - $OUT_DIR/rootfs.img.gz ($(du -h "$OUT_DIR/rootfs.img.gz" | cut -f1))"
