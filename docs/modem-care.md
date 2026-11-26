# Modem care services

Round-2 ports of the modem housekeeping services from
aipmy/msm8916-openwrt's target base-files. Upstream they are procd
services configured through UCI and LuCI; here there is no web UI —
everything is configured in **`/etc/modem-care.conf`** and driven
with the **`modem-care`** CLI (`/usr/local/sbin/modem-care`):

```
modem-care status              # gate + live state of every service
modem-care enable  sim-hotplug # flip the gate AND enable/start it
modem-care disable himi-ok     # flip the gate AND stop/disable it
```

`enable`/`disable` also do the init-system half
(`systemctl enable/disable --now` on Debian,
`rc-update`/`rc-service` on Alpine), so the config file and the
service state never drift apart.

| Service | Default | What it does |
|---|---|---|
| `modem-led` (modem-led-monitor) | **ON** | Status LED off = modem healthy (MSS remoteproc running, wwan QMI port present, ModemManager sees modem + SIM); blinking = starting/unhealthy. |
| `wifi-led` (wifi-led-monitor) | **ON** | WLAN LED: off = no AP, on = AP up without clients, blinking = a client is associated. |
| `sim-hotplug` | **ON** | Watches the modem's UIM card status; while the card is believed absent, pulses the board's `sim_hotplug` line (if it has one) so the baseband re-reads an inserted card — the firmware never notices insertions by itself. On boards without the line it runs monitor-only: it still detects swaps and makes ModemManager re-read the SIM (disable/enable), then reconnects `lte`. Never pulses a present card, never resets the modem. |
| `bearer-watchdog` (modem-bearer-watchdog) | **OFF** | Detects genuine data stalls (TX advancing, RX frozen, verified by a retried DNS probe — the first packet after RRC dormancy is always lost, so one failed probe proves nothing) and bounces the `lte` connection, cooldown-bounded. Also nudges a post-crash "zombie" modem (no ModemManager object for minutes) with a QMI DMS online + ModemManager restart. **Off by default because it can restart your data connection; opt in deliberately.** |
| `himi-ok` (himi-ok-guard) | **OFF** | Keeps modem NV item 2500 equal to `HiMI_OK` (see below). |

LED names are auto-detected (`MODEM_LED`/`WIFI_LED` in the config
can pin a specific `/sys/class/leds/<name>`); poll intervals and the
watchdog's timeouts are config keys in the same file.

## Band locking (`modem-bandlock`)

Upstream this was a UCI value re-applied by an init script and an
iface hotplug hook. Here it is a CLI, `/usr/local/sbin/modem-bandlock`:

```
modem-bandlock list          # supported / current / persisted bands
modem-bandlock set 3,7,20    # apply now (mmcli --set-current-bands)
                             # and persist to /etc/modem-bandlock.conf
modem-bandlock clear         # all supported bands, drop persistence
modem-bandlock apply         # re-apply the persisted set (boot service)
```

Band arguments accept bare LTE band numbers (`3,7,20`) or mmcli
names (`eutran-3|eutran-7`). The `modem-bandlock` boot service runs
`apply` after ModemManager, so the CLI's choice is re-asserted at
every boot.

## HiMI_OK guard

On the HiMI-baseband boards (UZ801 family and relatives) the modem's
RF task reads NV item 2500 (`NV_FACTORY_DATA_4_I`) and compares it
against the literal string `HiMI_OK`. If it does not match, the task
takes a branch that ends in an ML1 fatal roughly 900 s after any
modem (re)start. The item is cleared at every modem boot, so the
guard polls: read item 2500 via `diag_nv` (over `/dev/rpmsg0`, the
diag-bind bridge), and write `HiMI_OK` back if — and only if — the
item is **all-zero**. A non-zero item may be real factory data on a
non-HiMI modem and is never clobbered. The guard also checks the
board against the `HIMI_OK_BOARDS` allow-list (DT compatible globs:
UZ801, UF896, UFI001C, UF02, HMUF02-V5).

Upstream enables this by default on its boards; here it is
**default OFF** — enable it if your dongle shows the ~900 s modem
fatal pattern: `modem-care enable himi-ok`.

## Changing the IMEI (`change-imei`)

`/usr/local/sbin/change-imei` (adapted from aipmy's base-files):

- With no argument it prints the IMEI stored in NVRAM and the one
  the modem currently reports.
- `change-imei <15-digit IMEI>` writes the number into **modem NV
  item 550 (`NV_UE_IMEI_I`)** via `diag_nv` (DIAG NV_WRITE_F over
  `/dev/rpmsg0`; the IMEI is stored as nibble-swapped BCD). It
  verifies by read-back, then cycles the radio so the modem picks
  the new IMEI up (qmicli DMS low-power → online on
  `/dev/wwan0qmi0` when qmicli exists, else a ModemManager
  disable/enable) and restarts ModemManager.

Changing an IMEI may be illegal in your jurisdiction and can get a
device barred by carriers; the tool does exactly what you tell it.

## LAN speed (`lan-speed`)

Upstream's `lan-speed` is a CGI endpoint behind a LuCI speedtest
page. With no web UI, the port is a CLI: `lan-speed [iface]
[seconds]` samples the interface counters and prints the achieved
throughput (run it while traffic flows; it measures, it does not
generate traffic).
