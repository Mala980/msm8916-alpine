#!/bin/bash
# Build the custom Linux 6.18 kernel for MSM8916 (see configs/kernel/README.md).
#
#   ARCH=arm64  (default) — defconfig + msm8916.fragment, aarch64-linux-gnu-
#   ARCH=arm    — multi_v7_defconfig + same fragment, arm-linux-gnueabihf-
#                 (armv7 needs the DTS wrappers in configs/kernel/dts-arm32/,
#                 not vendored yet — the script fails clearly without them)
#
# Env (all optional):
#   KERNEL_VERSION     default 6.18.65
#   KERNEL_TARBALL_URL default https://cdn.kernel.org/.../linux-6.18.65.tar.xz
#   KERNEL_SHA256      default pinned in README.md
#   KERNEL_BUILD_DIR   default $WORKDIR/.kernel-build (tarball cache + source)
#   CHROOT             rootfs dir to install into (modules + /boot/vmlinuz);
#                      if unset, only builds (Image/modules/DTBs stay in the tree)
#   OUT_DIR            where to drop the built DTBs (default $WORKDIR/files)
#   JOBS               default $(nproc)
#
# Requires: wget, xz, git (patch application), make, bc, flex, bison,
# libelf-dev, libssl-dev, and the cross gcc (all in scripts/build-deps.sh).
set -euo pipefail

WORKDIR="$(pwd)"
ARCH="${ARCH:-arm64}"
KERNEL_VERSION="${KERNEL_VERSION:-6.18.65}"
KERNEL_TARBALL_URL="${KERNEL_TARBALL_URL:-https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz}"
KERNEL_SHA256="${KERNEL_SHA256:-c92606f956f09dc50b5a0e2af9e86763fce27ada1647de97f8d1ac8cfc95801d}"
KERNEL_BUILD_DIR="${KERNEL_BUILD_DIR:-$WORKDIR/.kernel-build}"
CHROOT="${CHROOT:-}"
OUT_DIR="${OUT_DIR:-$WORKDIR/files}"
JOBS="${JOBS:-$(nproc)}"
PATCH_DIR="$WORKDIR/configs/kernel/patches"
FRAGMENT="$WORKDIR/configs/kernel/msm8916.fragment"

# --- arch setup -----------------------------------------------------------
if [ "$ARCH" = "arm64" ]; then
    if [ "$(uname -m)" = "aarch64" ]; then CROSS_COMPILE="${CROSS_COMPILE:-}"; else CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"; fi
    DEFCONFIG="defconfig"
    KERNEL_IMAGE="Image.gz"
    DTB_NAMES=(msm8916-yiming-uz801v3 msm8916-thwc-uf896 msm8916-thwc-ufi001c)
elif [ "$ARCH" = "arm" ]; then
    if [ "$(uname -m)" = "armv7l" ]; then CROSS_COMPILE="${CROSS_COMPILE:-}"; else CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabihf-}"; fi
    DEFCONFIG="multi_v7_defconfig"
    KERNEL_IMAGE="zImage"
    DTB_NAMES=(msm8916-yiming-uz801v3 msm8916-thwc-uf896 msm8916-thwc-ufi001c)
    if [ ! -d "$WORKDIR/configs/kernel/dts-arm32" ]; then
        echo "ERROR: ARCH=arm needs the arm32 DTS wrappers in configs/kernel/dts-arm32/ (not vendored yet — see configs/kernel/README.md)." >&2
        exit 1
    fi
else
    echo "ERROR: unsupported ARCH=$ARCH (arm64|arm)" >&2
    exit 1
fi

# --- preflight ------------------------------------------------------------
for tool in wget xz git make bc flex bison "${CROSS_COMPILE}gcc"; do
    command -v "$tool" >/dev/null || { echo "ERROR: $tool not found. Run build-deps.sh" >&2; exit 1; }
done
[ -d "$PATCH_DIR" ] || { echo "ERROR: patch dir not found: $PATCH_DIR" >&2; exit 1; }
[ -f "$FRAGMENT" ] || { echo "ERROR: config fragment not found: $FRAGMENT" >&2; exit 1; }

KSRC="$KERNEL_BUILD_DIR/linux-$KERNEL_VERSION"
TARBALL="$KERNEL_BUILD_DIR/linux-$KERNEL_VERSION.tar.xz"
mkdir -p "$KERNEL_BUILD_DIR"

# --- 1. fetch + verify ----------------------------------------------------
if [ -f "$TARBALL" ]; then
    if echo "$KERNEL_SHA256  $TARBALL" | sha256sum -c - >/dev/null 2>&1; then
        echo "[*] Tarball cached, SHA256 OK: $TARBALL"
    else
        echo "[!] Cached tarball failed SHA256 — re-downloading"
        rm -f "$TARBALL"
    fi
fi
if [ ! -f "$TARBALL" ]; then
    echo "[*] Downloading Linux $KERNEL_VERSION ..."
    wget -q --show-progress -O "$TARBALL" "$KERNEL_TARBALL_URL"
    echo "$KERNEL_SHA256  $TARBALL" | sha256sum -c -
fi

# --- 2. extract (fresh tree every run — patches must apply to pristine) ---
echo "[*] Extracting $KERNEL_VERSION ..."
rm -rf "$KSRC"
tar -xf "$TARBALL" -C "$KERNEL_BUILD_DIR"

# --- 3. apply patches (filename order; 819 deliberately absent) ----------
echo "[*] Applying $(ls "$PATCH_DIR"/*.patch | wc -l) patches from $PATCH_DIR ..."
for patch in "$PATCH_DIR"/*.patch; do
    echo "    + $(basename "$patch")"
    (cd "$KSRC" && git apply --check "$patch") || { echo "ERROR: patch does not apply: $patch" >&2; exit 1; }
    (cd "$KSRC" && git apply "$patch")
done
echo "[+] All patches applied"

# --- 4. config: defconfig + fragment --------------------------------------
echo "[*] Configuring ($DEFCONFIG + msm8916.fragment) ..."
(cd "$KSRC" && make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" "$DEFCONFIG" >/dev/null)
cat "$FRAGMENT" >> "$KSRC/.config"
(cd "$KSRC" && make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig >/dev/null)

# Hard requirements — fail loudly instead of shipping a kernel without them.
for req in "CONFIG_CGROUPS=y" "CONFIG_CGROUP_SCHED=y" "CONFIG_QCOM_BAM_DMUX=m" \
           "CONFIG_ZRAM=m" "CONFIG_WIREGUARD=m" "CONFIG_USB_CONFIGFS_F_FS=y"; do
    grep -qx "$req" "$KSRC/.config" || { echo "ERROR: merged .config lacks $req" >&2; exit 1; }
done
echo "[+] Config verified: $(grep -c '^CONFIG_' "$KSRC/.config") symbols; release $(make -C "$KSRC" -s ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" kernelrelease)"

# --- 5. build ---------------------------------------------------------------
# gcc writes assembler temp files to $TMPDIR (default /tmp); on machines
# where /tmp is a small tmpfs that fills mid-build, point it at the
# build dir on the big disk instead.
export TMPDIR="$KERNEL_BUILD_DIR/tmp"
mkdir -p "$TMPDIR"
# Build only the DTBs this project ships (DTB_NAMES) instead of the
# generic `dtbs` target: `dtbs` compiles every board the defconfig
# enables (all vendors), which is slow, and a broken DTS for a board we
# do not ship would fail the whole kernel build.
DTB_TARGETS=()
for dtb in "${DTB_NAMES[@]}"; do
    DTB_TARGETS+=("qcom/${dtb}.dtb")
done
echo "[*] Building kernel ($KERNEL_IMAGE + modules + ${#DTB_TARGETS[@]} DTBs, -j$JOBS) ..."
(cd "$KSRC" && make -j"$JOBS" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" "$KERNEL_IMAGE" modules "${DTB_TARGETS[@]}")

# --- 6. install -------------------------------------------------------------
if [ -n "$CHROOT" ]; then
    KREL="$(make -C "$KSRC" -s ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" kernelrelease)"
    echo "[*] Installing modules to $CHROOT/lib/modules/$KREL ..."
    (cd "$KSRC" && make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
        modules_install INSTALL_MOD_PATH="$CHROOT" INSTALL_MOD_STRIP=1 >/dev/null)
    echo "[*] Installing kernel as $CHROOT/boot/vmlinuz ..."
    if [ "$ARCH" = "arm64" ]; then
        install -Dm644 "$KSRC/arch/arm64/boot/Image.gz" "$CHROOT/boot/vmlinuz"
    else
        install -Dm644 "$KSRC/arch/arm/boot/zImage" "$CHROOT/boot/vmlinuz"
    fi
    mkdir -p "$OUT_DIR/dtbs"
    for dtb in "${DTB_NAMES[@]}"; do
        cp "$KSRC/arch/$ARCH/boot/dts/qcom/${dtb}.dtb" "$OUT_DIR/dtbs/${dtb}.dtb"
    done
    echo "[+] Kernel $KREL installed:"
    echo "    - $CHROOT/boot/vmlinuz ($(du -h "$CHROOT/boot/vmlinuz" | cut -f1))"
    echo "    - $CHROOT/lib/modules/$KREL ($(find "$CHROOT/lib/modules/$KREL" -name '*.ko' | wc -l) modules)"
    echo "    - DTBs: ${DTB_NAMES[*]}"
else
    echo "[+] Built (no CHROOT set, nothing installed):"
    ls -lh "$KSRC/arch/$ARCH/boot/$KERNEL_IMAGE"
    ls "$KSRC/arch/$ARCH/boot/dts/qcom/"msm8916-{yiming-uz801v3,thwc-uf896,thwc-ufi001c}.dtb
fi
