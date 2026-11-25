# ADB on MSM8916 (Debian branch)

## Is it possible? Yes — and Debian makes it easy

Neither OpenStick-Builder (kinsamanka, `main`/Debian or `alpine`) nor the
Alpine branch of this repo ships `adbd`. In this ecosystem ADB comes from
**HandsomeMod**: [HandsomeYingyan/android-tools](https://github.com/HandsomeYingyan/android-tools)
("adbd adb and fastboot for handsomemod!") is an old AOSP `system/core`
tree whose `adbd` is built with:

```
-DADB_HOST=0 -DHAVE_FORKEXEC=1 -DALLOW_ADBD_ROOT=1
-DBOARD_ALWAYS_INSECURE -DADBD_NON_ANDROID
```

That daemon talks to the kernel over **FunctionFS only** — it hardcodes
`USB_FFS_ADB_PATH "/dev/usb-ffs/adb/"` (`ep0` control, `ep1` bulk-OUT,
`ep2` bulk-IN) and writes its own descriptors to `ep0`. No Android
properties, no libusb on the device side.

For Debian we do **not** need to compile that tree: Debian trixie ships
the daemon natively as the **`adbd`** package (from
`android-platform-tools`, arm64, USB transport). The Alpine branch has
no equivalent package — there, compiling the HandsomeYingyan sources
(small deps: libc, pthread, zlib, OpenSSL, libcrypt) would be the route.

## How it is integrated here

MSM8916 has a **single UDC**, so ADB cannot get its own gadget — it is
added as a second function to the existing composite gadget in
`configs/usb-gadget/usb-gadget.sh`:

1. `USB_GADGET_ADB="yes"` at build time (or `ENABLE_ADB=1` in
   `/etc/usb-gadget.conf` on the device) makes `build-rootfs.sh`
   install the `adbd` package.
2. At gadget setup, the script creates `functions/ffs.adb` — the
   instance name **must** be exactly `adb`, because adbd hardcodes
   `/dev/usb-ffs/adb/` — and links it into `configs/c.1/` next to
   `ncm.usb0`/`rndis.usb0`.
3. FunctionFS is mounted before adbd starts:
   `mount -t functionfs adb /dev/usb-ffs/adb -o uid=2000,gid=2000`
   (Debian's adbd drops privileges to the shell user, AID_SHELL 2000;
   with `uid=0` it would get `EACCES` on `ep0`).
4. `adbd` is started so it can write its descriptors to `ep0`, and only
   then is the gadget bound to the UDC (`echo $UDC > UDC`). Binding
   first would enumerate a gadget whose ADB interface is not ready.

Kernel support is verified for the exact kernel this branch installs:
the postmarketOS `linux-postmarketos-qcom-msm8916` 6.12.1-r2 .apk ships
`usb_f_fs.ko` and `libcomposite.ko` (checked in `modules.order` /
`kernel/drivers/usb/gadget/function/` of the extracted package).

## Usage

Build with ADB:

```
# variables.env
USB_GADGET_ADB="yes"
```

Or toggle on a running device (adbd package must be in the image):

```
usb-gadget enable_adb
systemctl restart usb-gadget
adb devices        # on the host
adb shell
```

## Security — read this

- The HandsomeMod-style build is an **unauthenticated root shell**
  (`BOARD_ALWAYS_INSECURE`, auth compiled out). Debian's `adbd` is the
  modern daemon with RSA host authentication — prefer it, and provision
  host keys properly.
- Keep ADB **USB-only**. adbd builds can fall back to TCP port 5555
  when no USB transport exists; on a network that would expose a shell
  to the LAN. This integration never enables the TCP transport.
