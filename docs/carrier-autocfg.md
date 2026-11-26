# Carrier auto-provisioning (`carrier-autocfg`)

Ported from aipmy/msm8916-openwrt's `qcom-carrier-autocfg` and
adapted to this builder's stack: upstream writes UCI network config
and is driven by procd/LuCI; here everything is the shell —
`/etc/carrier-autocfg.conf` plus the `carrier-autocfg` CLI
(`/usr/local/sbin/carrier-autocfg`). There is no web UI.

## What it does

When enabled, one provisioning pass:

1. Reads the inserted SIM's operator code (MCC-MNC) and name from
   ModemManager.
2. Looks the carrier up in `/etc/carrier-autocfg/custom-apns.tsv`
   first, then the shipped `/usr/share/carrier-autocfg/apns.tsv`
   (tab-separated: MCC-MNC, name, APN, IP type, mode, MBN path).
   Unknown carriers fall back to a Generic profile
   (APN `internet`, IPv4) without touching anything else.
3. Writes the profile into the NetworkManager connection named by
   `NM_CONN` (default `lte`): `gsm.apn`, and the IPv4/IPv6 methods
   for the profile's IP type (`ipv4` → IPv6 disabled, `ipv4v6` →
   both auto, `ipv6` → IPv4 disabled).
4. Brings the connection up and records the result in
   `/var/lib/carrier-autocfg/last-applied`. In auto mode a SIM whose
   operator was already provisioned is skipped.

## CLI

```
carrier-autocfg            # one provisioning pass (what the boot service runs)
carrier-autocfg status     # config, SIM, applied APN, MBN state
carrier-autocfg list       # known carriers
carrier-autocfg set 51010  # pin a carrier (MCC-MNC or name):
                           # MODE=manual, ENABLED=yes, apply now
carrier-autocfg auto       # MODE=auto, ENABLED=yes, apply now
carrier-autocfg off        # ENABLED=no
```

## Config (`/etc/carrier-autocfg.conf`)

| Key | Default | Meaning |
|---|---|---|
| `ENABLED` | `no` | Master switch. **Default OFF** — the boot service is installed and enabled but exits immediately while this is `no`. |
| `MODE` | `auto` | `auto` = follow the inserted SIM; `manual` = always apply `CARRIER`. |
| `CARRIER` | *(empty)* | MCC-MNC or operator name for manual mode. |
| `NM_CONN` | `lte` | NetworkManager connection to provision. |
| `MBN_DIR` | `/usr/share/carrier-autocfg/mcfg` | Where per-carrier MCFG payloads would live. |

The `carrier-autocfg` systemd unit / OpenRC init runs one pass
after ModemManager at boot. Auto mode therefore re-provisions at
boot (e.g. after a powered-off SIM swap); a running system picks up
a hot swap when ModemManager re-reads the SIM (see the sim-hotplug
service in docs/modem-care.md) and you re-run `carrier-autocfg`, or
at the next boot.

## What it does NOT do: carrier MCFG (MBN) activation

Each carrier profile names an MCFG payload
(`.../mcfg_sw.mbn`) — Qualcomm's per-carrier modem configuration.
Writing one to the modem means loading it through the QMI PDC
service and **activating it, which resets the modem** and swaps its
entire carrier configuration (VoLTE IMS settings, band policy,
feature flags). Upstream originally did this dynamically and then
**deliberately removed it**: for some carriers activation never
commits, the AP retried on every boot, and each attempt was a modem
reset → SSR → A2-handshake desync crash loop — while the modem was
already serving the carrier fine on its already-active MCFG.

This port mirrors that decision: the MBN path is reported by
`carrier-autocfg status`/`list` for reference, nothing is loaded or
activated, and the MBN blobs are not vendored into the image
(`MBN_DIR` is created empty). If you keep local blob copies, drop
them under `MBN_DIR` in the upstream layout
(`<region>/<carrier>/<variant>/mcfg_sw.mbn`); they remain inert.
