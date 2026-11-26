# Ported aipmy userspace tools

These images ship a curated set of MSM8916 userspace tools ported
from the OpenWrt port [aipmy/msm8916-openwrt](https://github.com/aipmy/msm8916-openwrt)
(commit `178f15b`, vendored under `configs/aipmy/` — see the NOTICE
file there for licenses). They are compiled from source during the
image build, the same way adbd is. The OpenWrt-only parts of that
repository (LuCI apps, procd/UCI glue, kernel patches) are not
included.

## Installed tools

| Tool | Path | What it does |
|---|---|---|
| `qcom-time-daemon` | `/usr/sbin/` | Syncs the system clock from the modem's QMI TIME (ATS) service |
| `ats-probe` | `/usr/sbin/` | Read-only probe of the modem ATS_RTC uptime counter |
| `diag_efs` | `/usr/bin/` | Reads the modem EFS over the SMD DIAG channel |
| `diag_logtool` | `/usr/bin/` | DIAG log capture/listener over SMD DIAG |
| `diag-bind` + `diag-bind-watch` | `/usr/sbin/` | Keeps the DIAG <-> rpmsg_chrdev bridge (`/dev/rpmsg0/1`) bound across modem SSRs |
| `reboot-mode` (+ `reboot-edl`, `reboot-dload`) | `/sbin/` | Safe reboot into EDL 9008 / DLOAD 9006 / bootloader / recovery |
| `bt-spp` | `/usr/sbin/` | Bluetooth Serial Port Profile server/client (shell pty or TCP bridge) |
| `bt-ssp-guard` | `/usr/sbin/` | Keeps the WCNSS Bluetooth SSP feature bit set |
| `diag_nv` | `/usr/sbin/` | Read/write modem NV items by ID over DIAG (`diag_nv read 550`) — clean-room implementation of the interface of upstream's prebuilt `diag_nv.bin` |
| `button-watch` | `/usr/sbin/` | Failsafe button monitor — see docs/failsafe.md |
| `carrier-autocfg` | `/usr/local/sbin/` | SIM carrier APN auto-provisioning — see docs/carrier-autocfg.md |
| `change-imei` | `/usr/local/sbin/` | Show/change the modem IMEI (NV item 550) — see docs/modem-care.md |
| `modem-care` | `/usr/local/sbin/` | Control the modem-care services below — see docs/modem-care.md |
| `modem-bandlock` | `/usr/local/sbin/` | Persistent modem band lock CLI — see docs/modem-care.md |
| `lan-speed` | `/usr/local/sbin/` | Local link throughput readout (CLI adaptation of upstream's LuCI CGI) |
| modem-care daemons | `/usr/sbin/` | `modem-led-monitor`, `wifi-led-monitor`, `sim-hotplug`, `modem-bearer-watchdog`, `himi-ok-guard` — see docs/modem-care.md |

## Services

Enabled by default: **diag-bind** (keeps the DIAG bridge alive) and
**bt-ssp-guard** (boot one-shot).

Installed but **not** enabled:

- **qcom-time-daemon** — upstream only runs it on one board, and
  chrony already disciplines the clock whenever the device is
  online. Enable it if you want the modem's clock as a source:
  `rc-update add qcom-time-daemon default` (Alpine) or
  `systemctl enable --now qcom-time-daemon` (Debian).
- **bt-spp** — needs `bluetoothd` running with `--compat` (for the
  SDP socket at `/var/run/sdp`). The images now ship that setting:
  a systemd drop-in
  (`/etc/systemd/system/bluetooth.service.d/compat.conf`) on
  Debian, `command_args="--compat"` in `/etc/conf.d/bluetooth` on
  Alpine. Note bluez itself is **not** in the default package set —
  add `bluez` via `PACKAGES`/`PROFILE_PACKAGES` (see below), then
  enable bt-spp the same way as above.

Also installed but not enabled (round 2, see docs/modem-care.md):
**modem-bearer-watchdog** and **himi-ok** — both default OFF in
`/etc/modem-care.conf` as well. Enabled by default: the
modem-care LED monitors, **sim-hotplug**, the **modem-bandlock**
boot one-shot (inert without a persisted lock), the
**failsafe-button** monitor (docs/failsafe.md), and the
**carrier-autocfg** boot pass — which is itself inert until
`ENABLED=yes` in `/etc/carrier-autocfg.conf`
(docs/carrier-autocfg.md).

## Caveats

- `reboot-edl`'s low-level half (`reboot-mode-raw`) issues the
  reboot syscall with the mode magic; full effect also depends on
  kernel reboot-mode support (aipmy carries an extra kernel patch
  for this; the postmarketOS kernel's behaviour is unverified on
  hardware).
- `diag-bind` was written against a kernel with an rpmsg-char NULL
  guard patch (part of aipmy's kernel patchset, not in the
  postmarketOS kernel). The binding mechanism itself is mainline;
  if DIAG captures misbehave after a modem SSR, check
  `/root/diag-bind.status` on the device.
- The DIAG tools talk to the modem's DIAG channel — treat them as
  low-level debugging tools, not everyday utilities.
- **CUPS** (upstream ships it as an OpenWrt package) is not in the
  default package set of either distro here. It is available as a
  plain distro package on both: add `cups` to `PACKAGES` (or a
  profile's `PROFILE_PACKAGES`) in variables.env to include it.
- **libqmi PDC patches**: aipmy's overlay carries two qmicli PDC
  patches (a segfault fix in `--pdc-load-config` and a smaller
  load chunk size). Evaluation (2026-11-26): Debian trixie and
  Alpine ship libqmi 1.36.x; the segfault fix could not be
  confirmed present in 1.36, so the patches are stored under
  `configs/libqmi-patches/` with a status README — but **not**
  applied, and no replacement libqmi is built: nothing shipped
  exercises PDC (carrier MCFG activation is disabled by design).
