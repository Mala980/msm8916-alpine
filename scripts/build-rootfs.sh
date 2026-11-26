#!/bin/bash
# Debian rootfs builder for MSM8916 — Debian branch.
# Ported from the Alpine build-rootfs.sh (branch main) keeping the same
# profile contract, outputs (rootfs.tgz + rootfs/ dir) and config layout.
# Debian userland via debootstrap (reference: kinsamanka/OpenStick-Builder
# branch main, scripts/debootstrap.sh + scripts/setup.sh); the kernel is
# still the postmarketOS linux-postmarketos-qcom-msm8916 .apk, extracted
# into the rootfs the same way OpenStick-Builder's Debian build does it.
set -euo pipefail

# ponytail: load order: default profile → selected profile → local overrides
[ -f ./profiles/default.env ] && source ./profiles/default.env

if [ -n "${PROFILE:-}" ]; then
    _PROFILE_FILE="./profiles/${PROFILE}.env"
    if [ ! -f "$_PROFILE_FILE" ]; then
        _AVAILABLE=$(ls ./profiles/*.env 2>/dev/null | xargs -n1 basename | sed 's/\.env$//' | grep -v '^default$' | tr '\n' ' ')
        echo "ERROR: Unknown profile '${PROFILE}'. Available: ${_AVAILABLE:-none}"
        exit 1
    fi
    source "$_PROFILE_FILE"
fi

[ -f ./variables.env ] && source ./variables.env

# Configuration
WORKDIR="$(pwd)"
OUT_DIR="${1:-"$WORKDIR/files"}"
STAGING="$(mktemp -d)"
CHROOT="$STAGING/rootfs"

HOST_NAME="${HOST_NAME:-uz801a}"
RELEASE="${RELEASE:-trixie}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
DEBIAN_SECURITY_MIRROR="${DEBIAN_SECURITY_MIRROR:-http://deb.debian.org/debian-security}"
PMOS_RELEASE="${PMOS_RELEASE:-v26.06}"
PMOS_MIRROR="${PMOS_MIRROR:-http://mirror.postmarketos.org/postmarketos}"
KERNEL_VERSION="${KERNEL_VERSION:-6.12.1-r5}"

USERNAME="${USERNAME:-user}"
DTB_FILE="${DTB_FILE:-msm8916-yiming-uz801v3.dtb}"
USB0_IP="${USB0_IP:-192.168.42.1/24}"
USB_GADGET_INSTALL="${USB_GADGET_INSTALL:-yes}"
USB_GADGET_OTG="${USB_GADGET_OTG:-no}"
USB_GADGET_ENABLED="${USB_GADGET_ENABLED:-yes}"
USB_GADGET_ADB="${USB_GADGET_ADB:-yes}"
OCTOPRINT_PREINSTALL="${OCTOPRINT_PREINSTALL:-no}"
ZORAXY_PREINSTALL="${ZORAXY_PREINSTALL:-no}"
DOCKER_ENABLE="${DOCKER_ENABLE:-no}"
STACKS="${STACKS:-}"
# Profile-controlled additions (set in profiles/*.env, not here)
PROFILE_PACKAGES="${PROFILE_PACKAGES:-}"
PROFILE_SERVICES="${PROFILE_SERVICES:-}"

# Required: password must be set
[ -z "${PASSWORD:-}" ] && {
    echo "ERROR: PASSWORD not set. Copy variables.env.example to variables.env and set a password."
    exit 1
}

# Cleanup on exit (unmount chroot bind mounts first)
cleanup() {
    for a in proc sys dev/pts dev run; do
        mountpoint -q "$CHROOT/$a" 2>/dev/null && umount "$CHROOT/$a" || true
    done
    rm -rf "$STAGING"
}
trap cleanup EXIT INT TERM

# Validations
[ -d "$OUT_DIR" ] || mkdir -p "$OUT_DIR"
HOST_ARCH="$(uname -m)"
IS_ARM64=false
[ "$HOST_ARCH" = "aarch64" ] || [ "$HOST_ARCH" = "arm64" ] && IS_ARM64=true

if [ "$IS_ARM64" = "false" ]; then
    command -v qemu-aarch64-static >/dev/null || { echo "Falta qemu-aarch64-static"; exit 1; }
fi
command -v debootstrap >/dev/null || { echo "ERROR: debootstrap not found (run scripts/build-deps.sh)"; exit 1; }

echo "[*] Profile: ${PROFILE:-default}"
echo "[*] Output directory: $OUT_DIR"
echo "[*] Temporary staging: $STAGING"
echo "[*] Debian release: $RELEASE (kernel: postmarketOS $KERNEL_VERSION from $PMOS_RELEASE)"

# --- Bootstrap Debian (foreign + second stage, like OpenStick-Builder) ---
mkdir -p "$CHROOT"
echo "[*] Bootstrapping Debian ($RELEASE, arm64)..."
debootstrap --foreign --arch arm64 \
    --keyring /usr/share/keyrings/debian-archive-keyring.gpg \
    "$RELEASE" "$CHROOT" "$DEBIAN_MIRROR"

if [ "$IS_ARM64" = "false" ]; then
    mkdir -p "$CHROOT/usr/bin"
    cp "$(which qemu-aarch64-static)" "$CHROOT/usr/bin/"
fi

cat << EOF > "$CHROOT/etc/apt/sources.list"
deb ${DEBIAN_MIRROR} ${RELEASE} main contrib non-free-firmware
deb ${DEBIAN_SECURITY_MIRROR} ${RELEASE}-security main contrib non-free-firmware
deb ${DEBIAN_MIRROR} ${RELEASE}-updates main contrib non-free-firmware
EOF

mount -t proc proc "$CHROOT/proc/"
mount -t sysfs sys "$CHROOT/sys/"
mount -o bind /dev/ "$CHROOT/dev/"
mount -o bind /dev/pts/ "$CHROOT/dev/pts/"
mount -o bind /run "$CHROOT/run/"
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

chroot "$CHROOT" /bin/bash /debootstrap/debootstrap --second-stage

# --- Base packages (Debian equivalents of the Alpine base set + OpenStick's) ---
echo "[*] Installing packages..."
cat > "$STAGING/setup.sh" <<'SETUPEOF'
#!/bin/sh -e
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

echo 'tzdata tzdata/Areas select Etc' | debconf-set-selections
echo 'tzdata tzdata/Zones/Etc select UTC' | debconf-set-selections
echo "locales locales/default_environment_locale select en_US.UTF-8" | debconf-set-selections
echo "locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8" | debconf-set-selections
rm -f /etc/locale.gen

apt-get update -qq
# Base set: Debian equivalents of the Alpine branch base packages, merged
# with OpenStick-Builder's Debian setup.sh list. The MSM firmware loader
# itself is not a Debian package; it is installed from configs/ below.
apt-get install -qqy --no-install-recommends \
    systemd systemd-sysv udev \
    sudo passwd \
    e2fsprogs \
    locales tzdata \
    network-manager \
    modemmanager \
    rmtfs qrtr-tools \
    wpasupplicant wireless-regdb iw \
    iptables iproute2 \
    dnsmasq hostapd bridge-utils \
    openssh-server \
    chrony \
    zram-tools \
    nano bash bash-completion \
    ca-certificates
SETUPEOF
cp "$STAGING/setup.sh" "$CHROOT/setup.sh"
chmod +x "$CHROOT/setup.sh"
chroot "$CHROOT" /bin/sh -c /setup.sh
rm -f "$CHROOT/setup.sh"

# Install profile-specific packages (profile contract — separate from base and user packages)
if [ -n "${PROFILE_PACKAGES:-}" ]; then
    _PPKG_LIST="$(echo "$PROFILE_PACKAGES" | tr '\n' ' ' | tr -s ' ')"
    echo "[*] Installing profile packages (${PROFILE:-default}): ${_PPKG_LIST}"
    chroot "$CHROOT" /bin/sh -c "DEBIAN_FRONTEND=noninteractive apt-get install -qqy --no-install-recommends ${_PPKG_LIST}"
fi

# Install extra packages from variables.env (user/local overrides)
if [ -n "${PACKAGES:-}" ]; then
    _PKG_LIST="$(echo "$PACKAGES" | tr '\n' ' ' | tr -s ' ')"
    echo "[*] Installing user packages..."
    chroot "$CHROOT" /bin/sh -c "DEBIAN_FRONTEND=noninteractive apt-get install -qqy --no-install-recommends ${_PKG_LIST}"
fi

# --- Kernel from postmarketOS (.apk extracted, OpenStick-Builder method) ---
echo "[*] Installing postmarketOS kernel $KERNEL_VERSION..."
# --keep-directory-symlink: the .apk carries a top-level lib/ directory;
# extracting it over trixie's usrmerge /lib -> usr/lib symlink would
# replace the symlink with a real directory holding only lib/modules,
# breaking the dynamic loader (/lib/ld-linux-aarch64.so.1) for every
# subsequent chroot call.
wget -q -O - "${PMOS_MIRROR}/${PMOS_RELEASE}/aarch64/linux-postmarketos-qcom-msm8916-${KERNEL_VERSION}.apk" \
    | tar xzf - -C "$CHROOT" --keep-directory-symlink --exclude=.PKGINFO --exclude=.SIGN* 2>/dev/null || {
        echo "ERROR: failed to download/extract kernel apk (check KERNEL_VERSION=$KERNEL_VERSION against $PMOS_RELEASE)"
        exit 1
    }
# Safety net: if /lib still ended up as a real directory, merge its
# contents into usr/lib and restore the usrmerge symlink.
if [ -d "$CHROOT/lib" ] && [ ! -L "$CHROOT/lib" ]; then
    cp -a "$CHROOT/lib/." "$CHROOT/usr/lib/"
    rm -rf "$CHROOT/lib"
    ln -s usr/lib "$CHROOT/lib"
fi
# Module dependencies for the extracted kernel
_KERNEL_REL="$(ls "$CHROOT/lib/modules" | head -n1)"
if [ -n "$_KERNEL_REL" ]; then
    chroot "$CHROOT" /bin/sh -c "depmod ${_KERNEL_REL} || true"
fi

# --- User + base setup ---
echo "[*] Setting up Debian..."
chroot "$CHROOT" /bin/sh -c "
echo ${USERNAME}:${PASSWORD}::::/home/${USERNAME}:/bin/bash | newusers
printf 'PS1=\"\\[\\033[01;32m\\]\\u@\\h\\[\\033[00m\\]:\\[\\033[01;34m\\]\\w\\[\\033[00m\\]\$ \"\\n' > /home/${USERNAME}/.bash_profile
chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.bash_profile
passwd -d root || true
"

# Sudo config
install -d -m0750 "$CHROOT/etc/sudoers.d"
echo "${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL" > "$CHROOT/etc/sudoers.d/${USERNAME}"
chmod 0440 "$CHROOT/etc/sudoers.d/${USERNAME}"

# Hostname
echo "$HOST_NAME" > "$CHROOT/etc/hostname"
sed -i "/localhost/ s/$/ ${HOST_NAME}/" "$CHROOT/etc/hosts"

# --- systemd units (Debian branch replaces OpenRC .init files) ---
echo "[*] Installing systemd units..."
install -Dm0644 configs/systemd/msm-firmware-loader.service "$CHROOT/etc/systemd/system/msm-firmware-loader.service"
install -Dm0755 configs/msm-firmware-loader/msm-firmware-loader.sh "$CHROOT/usr/sbin/msm-firmware-loader.sh"
mkdir -p "$CHROOT/lib/firmware/msm-firmware-loader"
install -Dm0644 configs/systemd/usb-gadget.service "$CHROOT/etc/systemd/system/usb-gadget.service"
install -Dm0644 configs/systemd/expand-rootfs.service "$CHROOT/etc/systemd/system/expand-rootfs.service"
# Serial console autologin (same override as OpenStick-Builder Debian)
mkdir -p "$CHROOT/etc/systemd/system/serial-getty@ttyMSM0.service.d"
install -Dm0644 configs/systemd/serial-getty-override.conf \
    "$CHROOT/etc/systemd/system/serial-getty@ttyMSM0.service.d/override.conf"

# Docker install + configuration (profile-driven; Debian package: docker.io)
if [ "$DOCKER_ENABLE" = "yes" ]; then
    echo "[*] Installing Docker (docker.io)..."
    chroot "$CHROOT" /bin/sh -c "DEBIAN_FRONTEND=noninteractive apt-get install -qqy --no-install-recommends docker.io"
    chroot "$CHROOT" /bin/sh -c "adduser ${USERNAME} docker || true"
    echo "[*] Configuring Docker..."
    mkdir -p "$CHROOT/etc/docker"
    cat > "$CHROOT/etc/docker/daemon.json" <<'DOCKEREOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "iptables": true
}
DOCKEREOF
fi

# ADB daemon (profile/config-driven; Debian trixie ships a native arm64
# 'adbd' package — the daemon HandsomeMod builds from AOSP sources.
# See docs/adb.md. The gadget side lives in usb-gadget.sh: ffs.adb.)
if [ "$USB_GADGET_ADB" = "yes" ]; then
    echo "[*] Installing ADB daemon (adbd)..."
    chroot "$CHROOT" /bin/sh -c "DEBIAN_FRONTEND=noninteractive apt-get install -qqy --no-install-recommends adbd"
fi

# aipmy userspace tools — a curated set of MSM8916 utilities ported
# from aipmy/msm8916-openwrt (vendored in configs/aipmy, see
# docs/aipmy-packages.md): qcom-time-daemon, ats-probe, diag_efs,
# diag_logtool, diag-bind, reboot-mode (EDL), bt-spp, bt-ssp-guard.
# Compiled inside the chroot; the toolchain and libqrtr-dev are
# purged again afterwards (libqrtr1 stays as the runtime library).
echo "[*] Building aipmy userspace tools..."
mkdir -p "$CHROOT/tmp/aipmy"
cp -a configs/aipmy/. "$CHROOT/tmp/aipmy/"
chroot "$CHROOT" /bin/sh -c "
    DEBIAN_FRONTEND=noninteractive apt-get install -qqy --no-install-recommends gcc libc6-dev make libqrtr-dev
    apt-mark manual libqrtr1 >/dev/null 2>&1 || true
    cd /tmp/aipmy && make -f aipmy.mk -j\$(nproc) && make -f aipmy.mk install
    DEBIAN_FRONTEND=noninteractive apt-get purge -qqy gcc libc6-dev make libqrtr-dev
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -qqy --purge
"
rm -rf "$CHROOT/tmp/aipmy"
for svc in diag-bind qcom-time-daemon bt-spp bt-ssp-guard; do
    install -Dm0644 "configs/aipmy/systemd/$svc.service" "$CHROOT/etc/systemd/system/$svc.service"
done
chroot "$CHROOT" /bin/sh -c "systemctl enable diag-bind bt-ssp-guard" || true
echo "[+] aipmy tools installed"

# Chrony configuration (same as Alpine branch)
echo "[*] Configuring Chrony..."
mkdir -p "$CHROOT/etc/chrony"
cat > "$CHROOT/etc/chrony/chrony.conf" <<'CHRONYEOF'
# NTP servers
server 0.pool.ntp.org iburst
server 1.pool.ntp.org iburst
server 2.pool.ntp.org iburst
server 3.pool.ntp.org iburst

# Sync system clock to hardware clock
rtcsync

# Drift file
driftfile /var/lib/chrony/chrony.drift

# Make chrony quickly sync on startup
makestep 1.0 3
CHRONYEOF

# zram swap via zram-tools (Debian equivalent of the Alpine local.d script, ~256MB)
echo "[*] Configuring zram swap..."
cat > "$CHROOT/etc/default/zramswap" <<'ZRAMEOF'
ALGO=lz4
SIZE=256
PRIORITY=100
ZRAMEOF

# Udev rules
cat << EOF > "$CHROOT/etc/udev/rules.d/99-nm-usb0.rules"
SUBSYSTEM=="net", ACTION=="add|change|move", ENV{DEVTYPE}=="gadget", ENV{NM_UNMANAGED}="0"
EOF

# --- NetworkManager configs (same files as Alpine branch) ---
echo "[*] Copying configs..."
mkdir -p "$CHROOT/etc/NetworkManager/system-connections"
cp configs/network-manager/*.nmconnection "$CHROOT/etc/NetworkManager/system-connections/" 2>/dev/null || true
chmod 0600 "$CHROOT/etc/NetworkManager/system-connections/"* 2>/dev/null || true
# dns=dnsmasq (same tweak as OpenStick-Builder Debian)
if [ -f "$CHROOT/etc/NetworkManager/NetworkManager.conf" ]; then
    grep -q '^\[main\]' "$CHROOT/etc/NetworkManager/NetworkManager.conf" \
        && sed -i '/\[main\]/a dns=dnsmasq' "$CHROOT/etc/NetworkManager/NetworkManager.conf" \
        || printf '[main]\ndns=dnsmasq\n' >> "$CHROOT/etc/NetworkManager/NetworkManager.conf"
fi

# Substitute WiFi placeholders if WiFi is enabled and credentials are provided
if [ "${WIFI_ENABLED:-yes}" = "yes" ] && [ -n "${WIFI_SSID:-}" ]; then
    echo "[*] Configuring WiFi connection (SSID: ${WIFI_SSID})"
    WLAN_CONN="$CHROOT/etc/NetworkManager/system-connections/wlan.nmconnection"
    sed -i "s/__SSID__/${WIFI_SSID}/g" "$WLAN_CONN"
    sed -i "s/__PASS__/${WIFI_PASS:-}/g" "$WLAN_CONN"
    if [ -n "${WIFI_IP:-}" ]; then
        echo "[*] WiFi: static ${WIFI_IP}"
        sed -i '/^\[ipv4\]/,/^\[ipv6\]/ s|method=auto|method=manual|' "$WLAN_CONN"
        if [ -n "${WIFI_GW:-}" ]; then
            sed -i "/\[ipv4\]/a address1=${WIFI_IP},${WIFI_GW}" "$WLAN_CONN"
        else
            sed -i "/\[ipv4\]/a address1=${WIFI_IP}" "$WLAN_CONN"
        fi
        if [ -n "${WIFI_DNS:-}" ]; then
            _WIFI_DNS="$(printf '%s' "$WIFI_DNS" | tr ',' ';')"
            case "$_WIFI_DNS" in *';') ;; *) _WIFI_DNS="${_WIFI_DNS};" ;; esac
            sed -i "/\[ipv4\]/a dns=${_WIFI_DNS}" "$WLAN_CONN"
        fi
    fi
else
    echo "[*] WiFi disabled or no SSID provided — removing wlan config"
    rm -f "$CHROOT/etc/NetworkManager/system-connections/wlan.nmconnection"
fi

# Configure usb0 connection
mkdir -p "$CHROOT/etc/NetworkManager/dnsmasq-shared.d"
USB0_CONN="$CHROOT/etc/NetworkManager/system-connections/usb0.nmconnection"
if [ "${USB0_IP}" = "dhcp" ]; then
    echo "[*] USB0: DHCP client mode"
    sed -i "s|method=shared|method=auto|g; /address1=/d" "$USB0_CONN"
else
    echo "[*] USB0: static ${USB0_IP}"
    sed -i "s|__USB0_IP__|${USB0_IP}|g" "$USB0_CONN"
    if [ -n "${USB0_GW:-}" ]; then
        echo "[*] USB0: gateway ${USB0_GW}, DNS ${USB0_DNS:-8.8.8.8}"
        sed -i "s|method=shared|method=manual|g" "$USB0_CONN"
        sed -i "s|never-default=true|gateway=${USB0_GW}|g" "$USB0_CONN"
        sed -i "/\[ipv4\]/a dns=${USB0_DNS:-8.8.8.8};" "$USB0_CONN"
    else
        cat > "$CHROOT/etc/NetworkManager/dnsmasq-shared.d/usb0.conf" << 'EOF'
# Don't send default gateway (option 3) via DHCP
dhcp-option=3

# Only send IP address and DNS
interface=usb0
EOF
    fi
fi

# DTBs: compiled (files/dtbs/) take priority, then precompiled (dtbs/)
mkdir -p "$CHROOT/boot/dtbs/qcom"
cp "$OUT_DIR/dtbs/"*.dtb "$CHROOT/boot/dtbs/qcom/" 2>/dev/null || true
cp dtbs/*.dtb "$CHROOT/boot/dtbs/qcom/" 2>/dev/null || true

mkdir -p "$CHROOT/boot/extlinux"
cat > "$CHROOT/boot/extlinux/extlinux.conf" <<EOF
TIMEOUT 10
DEFAULT debian

LABEL debian
    MENU LABEL Debian Linux
    linux /vmlinuz
    fdt /dtbs/qcom/${DTB_FILE}
    append earlycon root=/dev/mmcblk0p14 console=ttyMSM0,115200 no_framebuffer=true rw rootwait
EOF

cat > "$CHROOT/etc/fstab" <<EOF
/dev/mmcblk0p13    /boot    ext2    defaults    0 2
/dev/mmcblk0p14    /        ext4    defaults    0 1
EOF

# USB gadget (same configfs script as Alpine branch; systemd unit instead of OpenRC)
if [ "$USB_GADGET_INSTALL" = "yes" ]; then
    install -Dm0755 configs/usb-gadget/usb-gadget.sh "$CHROOT/usr/sbin/usb-gadget"
    cat > "$CHROOT/etc/usb-gadget.conf" << EOF
# MSM8916 USB Gadget Configuration

USE_NCM=1           # 1 = NCM (Linux/Mac), 0 = RNDIS (Windows)
ENABLE_OTG=$([ "$USB_GADGET_OTG" = "yes" ] && echo 1 || echo 0)        # 1 = OTG Host mode, 0 = Gadget mode
ENABLE_ADB=$([ "$USB_GADGET_ADB" = "yes" ] && echo 1 || echo 0)        # 1 = add ADB FunctionFS function (ffs.adb)
EOF
fi

# Expand rootfs on first boot (same script; systemd oneshot, flag matches the script)
install -Dm0755 configs/expand-rootfs/expand-rootfs.sh "$CHROOT/usr/sbin/expand-rootfs.sh"

# --- Enable services (systemd) ---
echo "[*] Enabling services..."
_ENABLE="NetworkManager ModemManager rmtfs ssh chrony zramswap msm-firmware-loader expand-rootfs serial-getty@ttyMSM0"
[ "$USB_GADGET_ENABLED" = "yes" ] && [ "$USB_GADGET_INSTALL" = "yes" ] && _ENABLE="$_ENABLE usb-gadget"
[ "$DOCKER_ENABLE" = "yes" ] && _ENABLE="$_ENABLE docker"
for svc in ${PROFILE_SERVICES:-}; do _ENABLE="$_ENABLE $svc"; done
for svc in ${SERVICES_AUTOSTART:-}; do _ENABLE="$_ENABLE $svc"; done
chroot "$CHROOT" /bin/sh -c "systemctl enable $_ENABLE" || \
    echo "[!] WARNING: systemctl enable reported errors — check unit names: $_ENABLE"

# apt cleanup (keep the image small, same spirit as the Alpine --no-cache)
chroot "$CHROOT" /bin/sh -c "apt-get clean; rm -rf /var/lib/apt/lists/* /var/log/apt/*" || true
echo -n > "$CHROOT/root/.bash_history" || true

# Stack hooks — profile-driven via STACKS (see profiles/*.env and stacks/run-*.sh)
# NOTE (Debian branch): the OctoPrint/Zoraxy stack scripts were written for
# Alpine/OpenRC; on Debian they are carried over structurally and are NOT
# yet validated. The docker profile is fully supported via docker.io above.
for _stack in ${STACKS:-}; do
    echo "[*] Running stack: $_stack"
    CHROOT="$CHROOT" STAGING="$STAGING" WORKDIR="$WORKDIR" \
        bash "$WORKDIR/stacks/run-${_stack}.sh"
done

# Unmount bind mounts before tarring (cleanup trap would race the tarball)
for a in proc sys dev/pts dev run; do
    mountpoint -q "$CHROOT/$a" 2>/dev/null && umount "$CHROOT/$a" || true
done

# Create tarball
echo "[*] Creating tarball..."
tar cpzf "$STAGING/debian_rootfs.tgz" \
    --exclude="root/*" \
    --exclude="usr/bin/qemu-aarch64-static" \
    -C "$CHROOT" .

# Copy to output directory (same output names as the Alpine branch)
echo "[*] Copying rootfs to $OUT_DIR..."
rm -rf "$OUT_DIR/rootfs"
mkdir -p "$OUT_DIR/rootfs"
tar -C "$CHROOT" \
    --exclude="root/*" \
    --exclude="usr/bin/qemu-aarch64-static" \
    -cf - . | tar -C "$OUT_DIR/rootfs" -xf -

cp "$STAGING/debian_rootfs.tgz" "$OUT_DIR/rootfs.tgz"

echo "[+] OK: Debian rootfs ready in $OUT_DIR (profile: ${PROFILE:-default})"
echo "    - Release: Debian ${RELEASE}"
echo "    - Kernel: linux-postmarketos-qcom-msm8916 ${KERNEL_VERSION} from ${PMOS_RELEASE}"
echo "    - Docker: ${DOCKER_ENABLE}"
echo "    - Stacks: ${STACKS:-none}"
echo "    - DTB: ${DTB_FILE}"
echo "    - $OUT_DIR/rootfs/ (directory)"
echo "    - $OUT_DIR/rootfs.tgz (tarball)"
ls -lh "$OUT_DIR/rootfs.tgz"
