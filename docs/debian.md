# Debian branch — what differs from `main` (Alpine)

Same repository layout, same profile contract (`profiles/*.env` →
`variables.env`), same outputs (`files/rootfs.tgz`, `rootfs.img.gz`,
`boot.img.gz`, `firmware.zip`, `gpt_both0.bin`), same `flash.sh`.
Only the userland construction differs:

| Area | Alpine (`main`) | Debian (`debian`) |
| --- | --- | --- |
| Bootstrap | `apk.static` + `alpine-base` | `debootstrap --foreign` + second stage (qemu-aarch64-static) |
| Release | Alpine v3.21 | Debian trixie (`RELEASE`) |
| Packages | `apk add` | `apt-get install` (Debian names, e.g. `docker.io`, `openssh-server`, `zram-tools`) |
| Init | OpenRC (`.init` files, `rc-update`) | systemd (units in `configs/systemd/`, `systemctl enable`) |
| Kernel | `linux-postmarketos-qcom-msm8916` apk installed via apk from pmOS repo v26.06 | Same kernel (6.12.1-r5), `.apk` downloaded from the pmOS mirror and extracted into the rootfs — the method used by OpenStick-Builder's Debian build |
| Firmware blobs | `msm-firmware-loader` apk | `configs/msm-firmware-loader/msm-firmware-loader.sh` + `msm-firmware-loader.service` (from OpenStick-Builder, MIT) |
| SSH | Dropbear | OpenSSH server |
| zram | `/etc/local.d/zram.start` script | `zram-tools` (`/etc/default/zramswap`, 256MB lz4) |
| Console | inittab respawn shell on ttyMSM0 | `serial-getty@ttyMSM0` autologin override (from OpenStick-Builder) |
| USB gadget | OpenRC service | `usb-gadget.service` (same configfs script, `configs/usb-gadget/usb-gadget.sh`) |
| Expand rootfs | OpenRC oneshot | `expand-rootfs.service` oneshot (same script) |

Reference for the Debian approach:
[kinsamanka/OpenStick-Builder](https://github.com/kinsamanka/OpenStick-Builder)
branch `main` — `scripts/debootstrap.sh`, `scripts/setup.sh`,
`scripts/msm-firmware-loader.sh`, `configs/system/`.

## Known limitations of this branch

- The OctoPrint and Zoraxy stack scripts (`stacks/run-*.sh`,
  `stacks/install-*.sh`) were written for Alpine/OpenRC and are carried
  over structurally. They are **not yet validated** on Debian. The
  `docker` profile is fully ported.
- The prebuilt OctoPrint USB-serial kernel modules in `modules/` target
  the Alpine build's module tree; on Debian, use the kernel's in-tree
  drivers or rebuild via `make modules`.
- ADB (`USB_GADGET_ADB="yes"`) installs Debian's native `adbd` package
  and adds the FunctionFS `ffs.adb` function to the existing composite
  gadget — see [docs/adb.md](adb.md). Kernel support verified:
  `usb_f_fs.ko` ships in the pmOS 6.12.1-r5 kernel package.
