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
  SDP socket at `/var/run/sdp`). Debian: add `--compat` to the
  bluetooth service's `ExecStart`. Alpine: set
  `command_args="--compat"` for the bluetooth service. Then enable
  bt-spp the same way as above.

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
