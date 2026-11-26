# Custom Linux 6.18 kernel for MSM8916

This directory holds everything the builder needs to compile its own
kernel instead of installing the postmarketOS `.apk` kernel
(`linux-postmarketos-qcom-msm8916`, 6.12.1). The custom kernel ships
on all four branches (`main`, `debian`, `alpine-armv7`,
`debian-armv7`) as the default (`KERNEL_SOURCE=custom`); the pmOS
kernel remains available as a fallback, and all four branches' CI
builds are green with this kernel.

## Source

- **Linux 6.18.65** (longterm, 2026-11-23) from kernel.org:
  `https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.65.tar.xz`
- SHA256 (from `https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc`):
  `c92606f956f09dc50b5a0e2af9e86763fce27ada1647de97f8d1ac8cfc95801d`
- `scripts/build-kernel.sh` downloads and verifies it; the tarball is
  cached under the kernel build dir (`.kernel-build/` by default) so
  re-runs don't re-download.

## Patches (`patches/`, 42 files, applied in filename order)

Ported from aipmy/msm8916-openwrt. Two sources:

- **`msm89xx/patches/` (39 patches for kernel 6.12.94)**: audit against
  6.18.65 (see the research file `.kernel618-research.md` in the repo
  root):

- **Skipped: `819-rpmsg-char-guard-null-eptdev`** — already upstream in
  6.18 (the `if (!eptdev)` guard is in `rpmsg_char.c`). This also closes
  the caveat in `docs/aipmy-packages.md` about diag-bind's kernel guard.
- **Reworked for 6.18: `813`, `834`, `838`** (the files in this directory
  are the reworked versions, not the aipmy originals):
  - `813-msm8916-reboot-to-edl-support` — `qcom_scm.c`: the following
    function is now `devm_qcom_scm_pas_context_alloc()` (was
    `qcom_scm_pas_init_image()`), so the insertion context was updated;
    `qcom-pon.c`: upstream restructured the driver (`struct pm8916_pon`
    became `struct qcom_pon` with the same `regmap`/`baseaddr` fields),
    so the warm-reset helper was rewritten on the new struct. The other
    four hunks (dtsi imem node, msm-poweroff, header, qcom_scm.h) apply
    unchanged. **Unverified on hardware**: the EDL sequence reproduces
    lk2nd's register writes but has never been executed on a dongle.
  - `834-arm64-dts-qcom-msm8916-cpu-interconnect` — upstream renamed the
    power-domain labels (`CPU_PD0` → `cpu_pd0`) and the 6.18 OPP table
    has no `opp-peak-kBps` rows; the patch was rewritten with the new
    context. Adds `interconnects` to the four CPU nodes and
    `opp-peak-kBps` to the four OPP entries.
  - `838-arm64-dts-qcom-msm8916-cpu-opp-max-800mhz` — its context
    contained the `opp-peak-kBps` lines added by 834, so it is now the
    diff against the post-834 tree: deletes the `opp-998400000` node
    (CPU capped at 800 MHz).
- The other 35 patches apply to 6.18.65 unchanged (verified from a
  pristine tree, in order). They stack on each other — keep the numeric
  order. Board-generic patches (801/804–807/847/849/852) are for boards
  we don't ship, but are part of the aipmy stack and cost nothing.

- **`openwrt-overlay/package/kernel/mac80211/patches/ath/` (4 patches,
  450–453, wcn36xx/mac80211)**: written against OpenWrt's mac80211
  backport, but 6.18.65 does not have any of the four behaviours, and
  the wcn36xx driver is stable enough that three apply unchanged:
  - `450-wcn36xx-only-send-mc-list-when-sta-associated` — applies
    clean. `wcn36xx_configure_filter` now only pushes the multicast
    list to the firmware when an STA interface is associated; before,
    the firmware got an empty/stale list on AP-only or unassociated
    setups.
  - `451-wcn36xx-mfp-wpa3` — applies clean. MFP/WPA3-SAE: AES-CMAC key
    is handled in software, `SW_MGMT_TX` for CCMP pairwise, `AES_CMAC`
    cipher added, `IEEE80211_HW_MFP_CAPABLE` set. 6.18 has no
    `MFP_CAPABLE` / `AES_CMAC` handling in wcn36xx at all.
  - `452-wcn36xx-iface-combinations` — applies clean. Interface
    combinations: max 2 AP interfaces on a single channel; STA+AP is
    explicitly excluded — the firmware crashes on it. This matches the
    AP-mode note in `docs/wifi-ap.md` (STA+AP unsupported by wcn36xx).
  - `453-wcn36xx-thermal-mitigation` — **reworked** (the file here is
    the reworked version). Exposes the firmware's thermal mitigation
    (HAL req 178 / rsp 179, levels 0–4) as a thermal cooling device
    (`wcn36xx`, 5 states, via `/sys/class/thermal/cooling_deviceN/`).
    The main.c / smd.h / wcn36xx.h hunks apply unchanged; the smd.c
    hunk was rewritten because 6.18 added a `len > WCN36XX_HAL_BUF_SIZE`
    guard between the response-type whitelist and the `memcpy` — the
    new `WCN36XX_HAL_SET_THERMAL_MITIGATION_RSP` case is inserted
    before that guard. All HAL constants, `set_thermal_mitigation_req_msg`,
    `thermal_of_cooling_device_register`, and the `first_boot` /
    `smd_channel` fields it uses exist in 6.18.65.
  - All four verified to apply cleanly from a pristine 6.18.65 tree,
    in order, on top of the 38-patch set (42 patches total, 0 failures).

## Config (`msm8916.fragment`)

Base is `arch/arm64/configs/defconfig` (6.18) on the arm64 branches;
the armv7 branches use `multi_v7_defconfig` plus the arm supplement
`msm8916-arm.fragment`. Either way this fragment is appended and
the result finalised with `make olddefconfig` (same
append-then-olddefconfig pattern as
`scripts/setup-kernel-build.sh`). The fragment is the
aipmy `config-6.12` delta translated to explicit values — see the
research file §3 for the symbol-by-symbol mapping. Hard requirements
verified in the merged `.config`: `CGROUPS=y`, `CGROUP_SCHED=y`,
`QCOM_BAM_DMUX=m` (modem data — defconfig lacks it entirely),
`ZRAM=m`, `WIREGUARD=m`, `USB_CONFIGFS=y` + `USB_CONFIGFS_F_FS=y`
(ADB FunctionFS, built-in so the gadget works without module load),
`QRTR=y`, `QCOM_RPM_MASTER_STATS=m`. `uname -r` is `6.18.65-msm8916`
via `CONFIG_LOCALVERSION="-msm8916"`.

### Tunnel / proxy support (mihomo / Clash.Meta and tunnel apps)

The fragment also enables the full tunnel/proxy set: `TUN`, `TAP`,
`MACVLAN`/`MACVTAP`, `IPVLAN`, GRE (`NET_IPGRE`/`IPV6_GRE`),
`NET_IPIP`, `IPV6_SIT`/`IPV6_TUNNEL`, L2TP (`L2TP`/`L2TP_V3=y`/`L2TP_IP`/
`L2TP_ETH`), PPP (`PPP`/`PPPOE`/`PPTP`/`PPP_MPPE`/`PPP_ASYNC`/
`PPP_SYNC_TTY`), XFRM (`XFRM_USER`/`XFRM_INTERFACE`/`NET_KEY`/
`INET_ESP`/`INET_IPCOMP`), `VXLAN`/`GENEVE`/`NET_FOU`/`NET_UDP_TUNNEL`,
the nftables set (`NF_TABLES`, `NFT_CT`/`NAT`/`MASQ`/`REDIR`/`COMPAT`/
`QUEUE`/`LOG`/`LIMIT`/`REJECT`/`FIB_INET`), conntrack/NAT, the legacy
iptables targets (`IP_NF_TARGET_MASQUERADE`/`REDIRECT`/`NETMAP`/`REJECT`,
`IP_NF_MANGLE`), TPROXY (`NETFILTER_XT_TARGET_TPROXY`, `NF_TPROXY_IPV4`/
`IPV6`, `NETFILTER_XT_MATCH_SOCKET`), the xt matches (`MARK`/
`CONNTRACK`/`STATE`/`OWNER`/`ADDRTYPE`/`COMMENT`), `IP_SET` +
`NETFILTER_XT_SET`, policy routing (`IP_MULTIPLE_TABLES=y`,
`IPV6_MULTIPLE_TABLES=y`, `IP_ADVANCED_ROUTER=y`), `NET_CLS_CGROUP` +
`CGROUP_NET_PRIO=y`, `VETH`, `BRIDGE`. This replaces the six
vermagic-locked prebuilt `.ko` aipmy shipped (`gre`, `l2tp_core`,
`l2tp_netlink`, `l2tp_ppp`, `ppp_mppe`, `pptp`) with in-tree modules
built against this exact kernel — **the aipmy prebuilt modules were
not ported and must not be used** (they target aipmy's 6.12.94 build
and will refuse to load).

Renames vs the request (all verified in 6.18.65 Kconfig): `FOU` is
`NET_FOU`, `IP_UDP_TUNNEL` is `NET_UDP_TUNNEL`, and the xtables symbols
carry the `NETFILTER_XT_` prefix (`NETFILTER_XT_TARGET_TPROXY`,
`NETFILTER_XT_MATCH_*`, `NETFILTER_XT_SET`). `L2TP` and `IP_SET` are
`menuconfig` symbols (tristate). `L2TP_V3`, `NF_NAT_MASQUERADE`,
`IP_MULTIPLE_TABLES`, `IPV6_MULTIPLE_TABLES`, `IP_ADVANCED_ROUTER`,
`CGROUP_NET_PRIO` are bools (`=y`).

Prerequisites (in the fragment's second block — `olddefconfig` silently
drops a symbol whose dependency is unset, so these are explicit):
`NET_IPGRE_DEMUX` (GRE + PPTP), `IP_NF_NAT` + `IP_NF_IPTABLES_LEGACY`
+ `NETFILTER_XTABLES_LEGACY=y` (legacy iptables targets + mangle),
`NF_TABLES_IPV4`/`IPV6`/`INET` + `NFT_FIB_IPV4`/`IPV6` (nft NAT / fib),
`NETFILTER_NETLINK_QUEUE` (nft queue). All 150 fragment symbols were
verified to land in the merged `.config` after `olddefconfig` (the only
exception is the documented `LEDS_QCOM_LPG` case below).

## What build-kernel.sh produces

- `arch/arm64/boot/Image.gz` (armv7: `arch/arm/boot/zImage`) →
  installed as `/boot/vmlinuz` in the rootfs (extlinux loads
  `/vmlinuz`; the pmOS package shipped a gzip kernel too, so the
  format matches).
- Modules → `make modules_install INSTALL_MOD_PATH=<rootfs>`, landing
  in `/lib/modules/6.18.65-msm8916/` (same layout the pmOS package
  used, new version string).
- DTBs for the three dongles (`msm8916-yiming-uz801v3`,
  `msm8916-thwc-uf896`, `msm8916-thwc-ufi001c`; on armv7, compiled
  from the wrappers in `dts-arm32/`) → `files/dtbs/`,
  overwriting the ones `build-dtb.sh` compiled from torvalds master,
  so the patched DTS (LED function names, a2-pin, interconnect, 800 MHz
  cap) is what actually boots. `build-rootfs.sh` then copies them into
  `/boot/dtbs/qcom/` as before.

## Switching back

`build-rootfs.sh` has a `KERNEL_SOURCE` switch (default `custom`).
Set `KERNEL_SOURCE=pmos` (env or `variables.env`) to go back to the
postmarketOS `.apk` kernel. The old path is kept, not deleted.

## Not yet done

- No hardware validation yet: the kernel has been compiled locally and
  the config/patches verified, but it has never booted on a dongle.
  Flash + serial + `adb devices` + WiFi + modem are the acceptance
  tests (see `docs/kernel-6.18.md`).
