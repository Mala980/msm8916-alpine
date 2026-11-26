# arm32 DTS wrappers for the three shipped dongles

Upstream 6.18 has the MSM8916 device trees only under
`arch/arm64/boot/dts/qcom/`; there are no arm32 variants. These three
files are arm32 wrappers in the style of feryw/msm8916-kernel
(branch `zhihe-6.18`): each is a two-line file that `#include`s the
corresponding arm64 DTS. The include resolves through the kernel's
`scripts/dtc/include-prefixes/arm64` symlink when the file is compiled
from `arch/arm/boot/dts/qcom/`.

`scripts/build-kernel.sh` (ARCH=arm only) copies these files into the
patched kernel tree at `arch/arm/boot/dts/qcom/` before building, so
the resulting DTBs are compiled from the *patched* arm64 DTS (aipmy
patchset included) and keep the same names as on arm64:
`msm8916-yiming-uz801v3.dtb`, `msm8916-thwc-uf896.dtb`,
`msm8916-thwc-ufi001c.dtb`.

Verified locally against the patched 6.18.65 tree: all three compile
with the same make invocation the build script uses
(`make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- qcom/<name>.dtb`),
producing ~50 KB DTBs identical in content to the arm64 ones (model
strings, `qcom,a2-pin` from patch 851, etc.).
