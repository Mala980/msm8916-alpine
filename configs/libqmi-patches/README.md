# libqmi PDC patches — evaluation (round 2, 2026-11-26)

aipmy/msm8916-openwrt carries two patches against libqmi's qmicli PDC
support in its OpenWrt overlay
(`openwrt-overlay/feeds/packages/libs/libqmi/patches/`):

- `001-fix-pdc-load-config-segfault.patch` — in
  `load_config_file_from_string()` (src/qmicli/qmicli-pdc.c),
  `file_contents` points into a `GMappedFile` (it is
  `g_mapped_file_get_contents()` output) but was passed to
  `g_free()`, corrupting the heap / segfaulting
  `qmicli --pdc-load-config` before anything is sent to the modem.
  The patch removes that one `g_free()` line.
- `002-qmicli-pdc-chunk-256.patch` — lowers
  `LOAD_CONFIG_CHUNK_SIZE` from 0x400 to 0x100, the chunk size the
  MSM8916 modem's PDC service tolerates when loading an MCFG.

## Are the distro libqmi builds already fixed?

Versions shipped by our two bases (checked 2026-11-26):

- **Debian trixie: libqmi 1.36.0-1** (packages.debian.org, source
  package libqmi, trixie/stable).
- **Alpine: 1.36.0-r0 in v3.22** (and 1.38.0 git snapshots in edge);
  the 3.24 branch tracks the same 1.36/1.38 line.

Fix status of 001 in those versions: **not confirmed fixed.** The
mapped-file free in `--pdc-load-config` was still being reported
against current libqmi in 2026 (independent mainline-port field
report: "qmicli --pdc-load-config frees memory owned by a GMappedFile
and crashes before sending anything. The fix is one line."), with an
upstream report filed from that work. A *different* PDC change
("qmicli-pdc-avoid-leaking-file_contents", a leak fix in another
spot) did land upstream before 1.36, which makes casual changelog
reading misleading — it is not this crash fix. We did not find a
1.36 changelog entry or commit that removes the `g_free()` in
`load_config_file_from_string()`.

## Decision

**Deferred.** The patches are stored here for reference only; this
builder does **not** patch or rebuild libqmi. Rationale:

- The only in-tree consumer of PDC would be carrier MCFG loading,
  and carrier-autocfg deliberately does not activate MCFG configs
  (see docs/carrier-autocfg.md), so no shipped tool exercises
  `qmicli --pdc-load-config` today.
- Rebuilding a core library (ModemManager links it) for an
  unexercised code path trades a hypothetical crash in a manual
  tool for real risk in the modem stack.

If PDC loading is ever wired up, revisit: verify the line against
the then-current libqmi source, apply 001 (and 002 for this modem),
and build libqmi as a local package on both branches.
