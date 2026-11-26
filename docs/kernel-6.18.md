# Custom kernel 6.18 (replaces the postmarketOS kernel)

Since the 6.18 rollout, all four branches (`main`, `debian`,
`alpine-armv7`, `debian-armv7`) build their own kernel instead of
installing `linux-postmarketos-qcom-msm8916` from the pmOS
repository. Everything lives in `configs/kernel/`; the build is
`scripts/build-kernel.sh`, wired into `scripts/build-rootfs.sh`.

## Why

- The pmOS kernel is 6.12.1 and its config is fixed; the custom kernel is
  **Linux 6.18.65** (longterm) with the aipmy patchset ported (modem
  bam-dmux stability, rpmsg/SSR fixes, reboot-to-EDL, 800 MHz CPU cap,
  wcn36xx overlay patches 450–453: multicast-list fix, MFP/WPA3-SAE,
  interface combinations, thermal mitigation as a cooling device)
  and a config that guarantees the symbols the images need
  (`QCOM_BAM_DMUX`, `CGROUPS`, `ZRAM`, `WIREGUARD`, FunctionFS for ADB)
  plus the full tunnel/proxy set for mihomo / Clash.Meta (TUN, GRE,
  L2TP, PPP/PPTP, XFRM, VXLAN/GENEVE, nftables + iptables targets,
  TPROXY, policy routing — see `configs/kernel/README.md`).
- The kernel is now versioned with the builder: a config/patch change is
  a normal commit, and every build publishes it through the rolling
  `latest-<branch>` releases.

## What changed vs the pmOS kernel

| | pmOS kernel | Custom kernel |
|---|---|---|
| Version | 6.12.1-msm8916 | **6.18.65-msm8916** (`uname -r`) |
| Source | pmOS `.apk` | kernel.org tarball, SHA256-verified |
| DTBs | torvalds master via `build-dtb.sh` | built from the 6.18 tree with the ported DTS patches |
| Modules | `/lib/modules/6.12.1-msm8916/`, `.ko.zst` | `/lib/modules/6.18.65-msm8916/`, `.ko` (uncompressed) |
| `usb_f_fs` | module | **built-in** (`USB_CONFIGFS_F_FS=y`) — ADB gadget needs no module load |
| Reboot to EDL | not supported by the kernel | `reboot-mode edl` via the ported patch 813 (**never executed on hardware yet**) |
| Tunnel/proxy | aipmy's six prebuilt `.ko` (vermagic-locked to 6.12.94, will not load) | in-tree modules: `tun`, `gre`, `l2tp_*`, `ppp_*`, `vxlan`, `geneve`, nftables + iptables targets, TPROXY |
| wcn36xx | upstream driver | + multicast-list fix, MFP/WPA3-SAE, iface combinations (max 2 AP, no STA+AP), thermal mitigation cooling device (`/sys/class/thermal/cooling_deviceN/`) |

## Switching back

```sh
KERNEL_SOURCE=pmos bash scripts/build-rootfs.sh ./files
```

(or set `KERNEL_SOURCE=pmos` in `variables.env`). The pmOS path is kept
as a fallback, not deleted. `KERNEL_SOURCE=custom` is the default.

## Building standalone

```sh
# Build only (no install): produces Image.gz, modules, DTBs in the tree
bash scripts/build-kernel.sh

# Build + install into an existing rootfs dir
CHROOT=/path/to/rootfs OUT_DIR=./files bash scripts/build-kernel.sh
```

Build time is roughly 30–60 minutes depending on the machine (a full
`defconfig` arm64 build, `-j$(nproc)`; ~50 min at `-j2` on this VM).
The tarball is cached in `.kernel-build/` (gitignored) and re-verified
by SHA256 on every run.

## Acceptance tests (not yet run — no hardware validation)

After flashing an image built with this kernel, verify on the device:

1. `uname -r` prints `6.18.65-msm8916`.
2. `adb devices` shows the device; `adb shell` works (FunctionFS).
3. WiFi associates (`wcn36xx` module loads) and the modem comes up
   (`qcom_bam_dmux`, `rmtfs`, ModemManager).
4. `zram` swap is active (`swapon -s`) and `ssh user@192.168.42.1` works.
5. `reboot-mode edl` drops the device into EDL 9008 (then re-flash or
   power-cycle to recover) — **do this only when you are ready to
   re-flash**, since it is the least-tested path.
6. `dmesg` shows no oops from the bam-dmux/rpmsg patchset.
7. Tunnel/proxy: `modprobe tun wireguard vxlan l2tp_ppp pptp` all load,
   `nft list ruleset` works, and mihomo's TPROXY mode starts without
   missing-module errors.
8. WiFi thermal: `/sys/class/thermal/cooling_device*/type` shows a
   `wcn36xx` entry, and `cur_state` can be set 0–4.

## Notes / known gaps

- `docs/adb.md` still says the pmOS package ships `usb_f_fs.ko` — true
  for old images; on this kernel it is built-in.
- `docs/octoprint.md` / `docs/usb-modules.md` describe out-of-tree
  module builds against the pmOS 6.12.1 source tree
  (`scripts/setup-kernel-build.sh`); they are stale for the custom
  kernel — the equivalent is `make -C .kernel-build/linux-6.18.65
  M=<module dir>`, not yet documented as a workflow.
- armv7 (both families) builds with `scripts/build-kernel.sh`
  (`ARCH=arm`): `multi_v7_defconfig` + `msm8916.fragment` + the
  `msm8916-arm.fragment` supplement, the feryw-style DTS wrappers in
  `configs/kernel/dts-arm32/`, and `zImage` instead of `Image.gz`.
  All four branches' CI builds are green with this kernel.
