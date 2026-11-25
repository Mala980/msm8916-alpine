# ADB on MSM8916 (Alpine branch)

## Is it possible? Yes — but Alpine needs a source build

Alpine ships **no `adbd` package**: its `android-tools` (community) is
client-only (`adb`, `fastboot`, image tools — see the aports APKBUILD,
there is no daemon subpackage), and postmarketOS does not publish one
either. So on this branch adbd is **compiled from source** during the
rootfs build.

The source is the same one the OpenStick ecosystem uses:
[HandsomeYingyan/android-tools](https://github.com/HandsomeYingyan/android-tools),
an old AOSP `system/core` tree whose `adbd` is built with:

```
-DADB_HOST=0 -DHAVE_FORKEXEC=1 -DALLOW_ADBD_ROOT=1
-DBOARD_ALWAYS_INSECURE -DADBD_NON_ANDROID
```

That daemon talks to the kernel over **FunctionFS only** — it hardcodes
`USB_FFS_ADB_PATH "/dev/usb-ffs/adb/"` (`ep0` control, `ep1` bulk-OUT,
`ep2` bulk-IN) and writes its own descriptors to `ep0`.

### musl compatibility

The tree targets glibc; compiling it against Alpine's musl libc needs
only a small compatibility layer, kept in `configs/adbd/`:

- `compat/sys/cdefs.h` — stub for the glibc header musl does not ship
  (the code only uses `__BEGIN_DECLS`/`__END_DECLS`).
- `compat/compat.h` — declarations musl does not provide:
  `b64_pton` (implemented by the tree's own `core/adbd/base64.c`),
  `prctl`, and `capset`.
- `compat/capset.c` — `capset(2)` implemented over the raw syscall.
- `adbd.mk` — the upstream makefile plus the compat include/flags.

The build runs inside the Alpine chroot in `scripts/build-rootfs.sh`
(pinned source commit, toolchain installed as an apk virtual package
and removed afterwards; only the runtime libs `libcrypto3`/`zlib`
stay). Verified locally against musl (gcc 15.2, Alpine 3.24) before
integration: the resulting `adbd` binary compiles cleanly and starts.

## How it is integrated here

MSM8916 has a **single UDC**, so ADB cannot get its own gadget — it is
added as a second function to the existing composite gadget in
`configs/usb-gadget/usb-gadget.sh` (the same script as the Debian
branch):

- `USB_GADGET_ADB="yes"` (default) builds adbd and writes
  `ENABLE_ADB=1` to `/etc/usb-gadget.conf`.
- At gadget setup, a `functions/ffs.adb` instance (the name **must**
  be `adb`) is linked into `configs/c.1` next to NCM/RNDIS,
  FunctionFS is mounted at `/dev/usb-ffs/adb`, and adbd is started
  **before** the gadget is bound to the UDC so it can write its
  descriptors. Runtime toggles: `usb-gadget enable_adb|disable_adb`.
- Kernel support is already there: the postmarketOS
  `linux-postmarketos-qcom-msm8916` package ships `usb_f_fs.ko`.

## Security warning

This is the HandsomeMod-style build: an **unauthenticated root shell
over USB** (`ALLOW_ADBD_ROOT` + `BOARD_ALWAYS_INSECURE`, no RSA key
confirmation like the Debian package's adbd). Anyone with physical
USB access gets root. Only enable it on devices you control, and
never expose adbd over TCP (this build is USB-only; the TCP listener
code path is not enabled for the gadget transport).
