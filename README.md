# Debian Linux for MSM8916 Devices

> **Branch `debian`** — Debian variant of this builder. The `main` branch
> builds Alpine Linux; this branch keeps the exact same repository
> structure, profile system, and build flow, but produces a **Debian**
> rootfs instead. The Debian userland approach (debootstrap + apt +
> systemd, kernel extracted from the postmarketOS .apk) follows
> [kinsamanka/OpenStick-Builder](https://github.com/kinsamanka/OpenStick-Builder)
> (branch `main`).

Debian rootfs builder for MSM8916-based devices (dongles and MiFi routers) with USB gadget networking, Docker, and LTE modem support.

## Features

- **Debian trixie** with postmarketOS v25.06 kernel (6.12.1, `linux-postmarketos-qcom-msm8916`)
- **systemd** init (the Alpine branch uses OpenRC)
- **USB Gadget Mode**: NCM (Linux/Mac) or RNDIS (Windows) networking, optional **ADB** (FunctionFS)
- **Direct USB Networking**: Simple usb0 interface with DHCP (no bridge complexity)
- **WiFi Client**: WPA2 support via NetworkManager
- **LTE Modem**: ModemManager with QMI support (MSM8916 cellular), `rmtfs` + `qrtr-tools`, firmware blobs loaded from the device partitions by `msm-firmware-loader`
- **Docker**: Pre-installed via `docker.io` with user in docker group (docker profile)
- **NTP Sync**: Chrony for time synchronization
- **zram Swap**: Compressed in-RAM swap via `zram-tools` (~256MB)
- **Auto-expand rootfs**: First boot partition and filesystem expansion
- **OpenSSH**: SSH server (serial console has root autologin, like OpenStick)
- **WireGuard**: VPN support (optional, via `PACKAGES`)

## Requirements

### Host System

- **Vagrant** + **QEMU** (for local builds: `brew install vagrant qemu && vagrant plugin install vagrant-qemu`)
- **Python 3** with `edl` tool (for flashing via EDL mode)

## Configuration

### variables.env

Copy `variables.env.example` to `variables.env` and edit to customize your build:

```
cp variables.env.example variables.env
```

```
HOST_NAME="uz801a"
USERNAME="user"
PASSWORD="mypassword"          # Required — build fails if not set

WIFI_SSID="MyNetwork"        # Optional — WiFi SSID to connect to
WIFI_PASS="MyPassword"       # Optional — WiFi password
WIFI_IP=""                   # Optional static WiFi IPv4 CIDR; empty = DHCP
WIFI_GW=""                   # Optional gateway for WIFI_IP
WIFI_DNS=""                  # Optional DNS for WIFI_IP

DTB_FILE="msm8916-yiming-uz801v3.dtb"   # DTB to use in extlinux.conf

USB0_IP="192.168.42.1/24"   # Static IP for USB gadget (with DHCP server)
                             # Set to "dhcp" when plugged into a router (OpenWrt, etc.)
USB_GADGET_ADB="no"          # "yes" adds ADB (ffs.adb + adbd) next to NCM/RNDIS

# Optional mirror overrides
RELEASE="trixie"
PMOS_RELEASE="v25.06"
KERNEL_VERSION="6.12.1-r2"
# DEBIAN_MIRROR="http://deb.debian.org/debian"
# PMOS_MIRROR="http://mirror.postmarketos.org/postmarketos"

# Extra packages to install (Debian package names; essentials are hardcoded in the script)
PACKAGES="
wireguard-tools
htop
"

# Extra services to auto-start (systemd unit names)
SERVICES_AUTOSTART="
"
```

`variables.env` is git-ignored so your credentials are never committed.

### WiFi Configuration

Set `WIFI_SSID` and `WIFI_PASS` in `variables.env`. The build will substitute them into the NetworkManager connection automatically.

By default WiFi uses DHCP. To bake in a static WiFi address for any profile/stack, set:

```
WIFI_IP="192.168.1.50/24"
WIFI_GW="192.168.1.1"
WIFI_DNS="1.1.1.1;8.8.8.8;"
```

### DTB Selection

Set `DTB_FILE` in `variables.env` to select which compiled DTB the bootloader uses. See `dtbs/readme.md` for available options.

### USB0 IP Mode

`USB0_IP` controls how the USB gadget interface is configured:

- **Static IP** (default): `USB0_IP="192.168.42.1/24"` — acts as a DHCP server for the connected host.
- **DHCP client**: `USB0_IP="dhcp"` — useful when the device is plugged into a router (e.g. OpenWrt) that assigns IPs.

### USB Gadget Configuration

USB gadget uses a simple configuration file `/etc/usb-gadget.conf`:

```
# MSM8916 USB Gadget Configuration

USE_NCM=1           # 1 = NCM (Linux/Mac), 0 = RNDIS (Windows)
ENABLE_OTG=0        # 1 = OTG Host mode, 0 = Gadget mode
ENABLE_ADB=0        # 1 = ADB FunctionFS function (ffs.adb) alongside the network function
```

**Management commands:**

```
# Enable NCM mode (Linux/Mac compatible)
usb-gadget enable_ncm

# Enable RNDIS mode (Windows compatible)
usb-gadget disable_ncm

# Enable OTG Host mode (for USB peripherals)
usb-gadget enable_otg

# Disable OTG (back to gadget mode)
usb-gadget disable_otg

# View current config
usb-gadget status

# Apply changes
systemctl restart usb-gadget
```

## Custom Device Trees

The build system can compile DTS (Device Tree Source) files from the upstream Linux kernel and from the local `dts/` directory.

### Upstream DTS (auto-compiled)

`make build` automatically fetches the kernel DTS tree (cached in `.kernel-dts/`) and compiles these upstream files:

- `msm8916-yiming-uz801v3.dts`
- `msm8916-thwc-uf896.dts`
- `msm8916-thwc-ufi001c.dts`

### Custom DTS

Add your own `.dts` files to the `dts/` directory. They are compiled with the same flags and include paths as the upstream files, so you can reference kernel DTSI files:

```
// dts/msm8916-mydevice.dts
/dts-v1/;
#include "msm8916-ufi.dtsi"
// ... your customizations
```

Compile only DTS (without full build):

```
make dts
```

Output goes to `files/dtbs/`. See `dtbs/readme.md` for the list of precompiled fallback DTBs.

## Usage

### 1. Build everything

**Preferred — profile builds:**

Pick an appliance profile. Run these commands **inside the builder VM** (via `make builder`) or in CI; they build rootfs, boot image, `firmware.zip`, and GPT table:

```
make docker      # Docker-enabled base image
make zoraxy      # Zoraxy: native reverse proxy, no Docker (see note below)
make octoprint   # OctoPrint profile (see note below)
```

> **Debian branch note:** the `docker` profile is fully ported
> (`docker.io` + systemd). The `octoprint` and `zoraxy` stack scripts
> were written for Alpine/OpenRC and are carried over structurally —
> they are **not yet validated** on Debian.

Profile images are **minimal**: only the packages and services for the chosen appliance are installed.

USB gadget tooling (`usb-gadget`, `/etc/usb-gadget.conf`) is installed and auto-started in the **default**, **docker**, and **zoraxy** profiles. The **octoprint** profile is the exception: it sets `USB_GADGET_INSTALL="no"` because the USB port is used as host for the printer — gadget tooling is omitted and USB OTG host mode is forced at boot instead (`USB_GADGET_OTG="yes"`).

> **Vagrant artifact flow:** Profile targets run `make build-all PROFILE=...` inside the VM or CI and do **not** call `make fetch`. After the build finishes, exit the VM and run `make fetch` on the host to copy artifacts. The host targets `make build-vm` / `make build-all-vm` handle the full cycle (up → build → fetch) automatically but are generic — they do not set a profile.

See **docs/profiles.md** for a full breakdown of what each profile installs, which services it enables, and how USB mode is set.

---

**Option A — interactive shell inside the VM:**

```
# Open a shell in the builder VM (first time provisions automatically)
make builder

# Inside the VM: build rootfs + boot image
make build

# Or build everything including firmware.zip and GPT table
make build-all

# Exit the VM
exit

# Back on the host — copy artifacts from the VM to host files/
make fetch
```

> **Note:** vagrant-qemu uses SLIRP user networking; NFS and shared folders are not available. `make fetch` is the only way to copy artifacts to the host.

**Option B — one-shot from the host (recommended, no interactive shell needed):**

```
make build-vm       # build inside VM and fetch artifacts automatically
make build-all-vm   # same but includes firmware.zip and GPT table
```

`make fetch` is always safe to re-run — it overwrites artifacts with the latest build.

**Build output** in `files/`:

- `rootfs.img.gz` - Debian rootfs image
- `rootfs.tgz` - Debian rootfs tarball
- `boot.img.gz` - Kernel + initramfs boot image
- `gpt_both0.bin` - GPT partition table for 4GB eMMC (with `build-all`)
- `firmware.zip` - Complete firmware package (with `build-all`)

### 2. Flash to device via EDL

#### Enter EDL Mode

1. Power off the device completely
2. Hold **Volume Up** button
3. Connect USB cable while holding button
4. Device enters EDL mode (no screen indication)

#### Flash with EDL

```
./flash.sh
```

### 3. First Boot

After flashing and reboot:

1. Device boots Debian Linux (~30-45 seconds)
2. Rootfs automatically expands to fill eMMC
3. WiFi connects to configured network
4. USB gadget activates (NCM/RNDIS interface)
5. USB interface gets IP 192.168.42.1/24 with DHCP server
6. SSH server starts on port 22

**Access via SSH:**

```
# Via WiFi (check router for IP)
ssh user@192.168.77.XXX

# Via USB
ssh user@192.168.42.1

# Default credentials
Username: user
Password: (configured in variables.env)
```

## Optional Stacks

The `stacks/` directory contains install scripts and Docker Compose files for optional services. On this Debian branch the stack scripts are carried over from the Alpine branch and are not yet validated on Debian (see the note under Usage).

- **Portainer (Docker UI)**: `docker compose -f stacks/portainer.docker-compose.yml up -d` — Web UI: `http://<device-ip>:9000`
- **Watchtower (Auto-update containers)**: `docker compose -f stacks/watchtower.docker-compose.yml up -d`

## Profile Validation

After flashing and first boot, confirm the selected profile is active:

```
# USB gadget tooling (default, docker, zoraxy profiles — not octoprint)
usb-gadget status

# Services (systemd)
systemctl status NetworkManager ModemManager usb-gadget
```

## Credits

- [hkfuertes](https://github.com/hkfuertes/msm8916-alpine) — original Alpine builder (branch `main` of this repo's upstream)
- [kinsamanka/OpenStick-Builder](https://github.com/kinsamanka/OpenStick-Builder) — Debian rootfs approach, `msm-firmware-loader`, serial-getty autologin override
- postmarketOS — kernel packages for MSM8916
