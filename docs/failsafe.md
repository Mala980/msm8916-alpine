# Failsafe button monitor

These dongles are headless: no Ethernet, no usable serial console.
If networking is misconfigured after boot, the device is a brick
until reflash. The `button-watch` daemon (`/usr/sbin/button-watch`,
source `configs/failsafe/button-watch.c`, service `failsafe-button`,
**enabled by default**) turns the board's one input — the Restart
button (DT `button_restart`, gpio 23, a gpio-keys input device,
found by name at runtime, never by hardcoded event number) — into
two recovery gestures:

| Gesture | Effect |
|---|---|
| **Short press within the first 15 s** after the service starts | **Rescue mode** (below) |
| **Hold ≥ 5 s** at any time | **Factory reset** (below) |
| Short press after the first 15 s | Nothing (deliberate — see below) |

This is our adaptation, **not** OpenWrt preinit failsafe: upstream
enters failsafe before init via a preinit hook + button hotplug
daemon and brings up a dedicated gadget at 192.168.10.1. Ours runs
as a normal early service (started before NetworkManager) inside
the regular system, which is what systemd/OpenRC can offer here.

## Rescue mode

- Touches `/run/failsafe-mode` (check it from scripts/shell).
- Makes sure the USB gadget is up (`usb-gadget start` — NCM + ACM
  functions), so the host sees the USB network and `/dev/ttyACM0`.
- Prints a banner on the console and on `/dev/ttyGS0`.
- Spawns a root **login shell on `/dev/ttyGS0`** (the gadget ACM
  function), respawned when it exits. Together with the normal SSH
  server on the USB network this gives two independent ways back
  in.

## Factory reset

Deletes everything listed in **`/etc/failsafe-reset.list`** (one
path, glob, or token per line — edit it to define what "factory"
means for your deployment), then syncs and reboots. The shipped
list is:

- `nm-connections` — all NetworkManager system connections
  (`/etc/NetworkManager/system-connections/*`)
- `ssh-host-keys` — `/etc/ssh/ssh_host_*` (fresh, unique host keys
  are generated on the next boot)
- `/etc/modem-bandlock.conf` — a persisted band lock
- `/var/lib/carrier-autocfg` — carrier provisioning state
- `/root/.customized` — first-boot customisation marker, if any

A short press outside the boot window is a no-op on purpose: the
stock OpenWrt handler reboots on a short press, which makes the
only button on a network-only device dangerous to touch. Here a
reset requires an unmistakable 5-second hold.
