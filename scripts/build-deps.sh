#!/bin/bash

ARCH="$(dpkg --print-architecture)"

# Base packages (architecture-independent)
PACKAGES="
git
zip
autoconf
automake
binfmt-support
cmake
cpp
debian-archive-keyring
debootstrap
mmdebstrap
device-tree-compiler
fdisk
gcc-arm-none-eabi
libtool
make
pkg-config
python3-cryptography
python3-pyasn1-modules
python3-pycryptodome
ca-certificates
gnupg
unzip
wget
"

# Kernel build deps (modules_prepare for out-of-tree modules against 6.12.1-msm8916)
PACKAGES="$PACKAGES bc flex bison libelf-dev libssl-dev"

if [ "$ARCH" = "amd64" ]; then
    # Cross-compilers and QEMU for amd64 host targeting aarch64
    PACKAGES="$PACKAGES g++-aarch64-linux-gnu gcc-aarch64-linux-gnu"
else
    # Native compilers on arm64 — no cross-compile needed
    PACKAGES="$PACKAGES gcc g++"
fi

apt update
apt install -y --no-install-recommends $PACKAGES

if [ "$ARCH" = "amd64" ]; then
    # qemu-user-static is only a virtual package on newer Ubuntu releases
    # (e.g. the current GitHub ubuntu-latest) and apt refuses to pick a
    # provider automatically. The fallback packages register binfmt but
    # do NOT ship the qemu-aarch64-static binary build-rootfs.sh needs,
    # so fetch the official static build from multiarch/qemu-user-static
    # whenever the binary is still missing afterwards.
    apt install -y --no-install-recommends qemu-user-static \
        || apt install -y --no-install-recommends qemu-user qemu-user-binfmt || true
    if ! command -v qemu-aarch64-static >/dev/null 2>&1; then
        wget -qO /usr/local/bin/qemu-aarch64-static \
            https://github.com/multiarch/qemu-user-static/releases/download/v7.2.0-1/qemu-aarch64-static
        chmod +x /usr/local/bin/qemu-aarch64-static
    fi
fi
rm -rf /var/lib/apt/lists/*
