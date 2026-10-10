#!/usr/bin/env bash
# Register the nvlink2-npu kernel patch with NVIDIA's DKMS package.
#
#   apply.sh [nvidia DKMS source dir]     (default /usr/src/nvidia-550.54.15)
#
# Uses DKMS's own patch mechanism: the patches are copied to <dir>/patches/
# and listed as PATCH[] in <dir>/dkms.conf, so DKMS applies them to its
# build copy every time it builds the driver; the sources in <dir> stay as
# shipped. Also:
#  - runs the build through kmake, which selects the compiler the target
#    kernel was built with (e.g. gcc-toolset-13 for the patched RHEL 9.9
#    kernel on a RHEL 8 host);
#  - leaves out nvidia-drm (display / KMS glue, unused on compute systems),
#    which does not build against the newer DRM API of RHEL 9.9.
#
# The NPU API (pnv_npu2_init_context() and friends) is provided by the
# nvlink2-npu module built into the kernel; its symbol versions are in the
# kernel's Module.symvers, which modpost reads.
#
# Afterwards rebuild the driver for the target kernel, e.g.:
#   dkms build nvidia/550.54.15 -k <kernel release> --force
#   dkms install nvidia/550.54.15 -k <kernel release> --force
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DIR=${1:-/usr/src/nvidia-550.54.15}
CONF=$DIR/dkms.conf

[[ -f $CONF ]] || { echo "no $CONF" >&2; exit 1; }
grep -q '^PACKAGE_VERSION="550.54.15"' "$CONF" ||
	{ echo "$CONF is not NVIDIA 550.54.15" >&2; exit 1; }

mkdir -p "$DIR/patches"
cp "$HERE"/0*.patch "$DIR/patches/"
cp "$HERE/../../scripts/kmake" "$DIR/kmake"

if grep -q 'kmake' "$CONF"; then
	echo "$CONF already set up for power9-nvlink2"
	exit 0
fi

cp -n "$CONF" "$CONF.orig"
{
	echo
	echo "# power9-nvlink2: follow_pfn conftest for kernels where follow_pfn() was removed"
	i=0
	for p in "$HERE"/0*.patch; do
		echo "PATCH[$i]=\"$(basename "$p")\""
		i=$((i + 1))
	done
} >> "$CONF"
# Build with the target kernel's compiler and leave out nvidia-drm
grep -q '^BUILT_MODULE_NAME\[2\]="nvidia-drm"' "$CONF" ||
	{ echo "unexpected module list in $CONF" >&2; exit 1; }
sed -i -e 's|^MAKE\[0\]="|MAKE[0]="./kmake ${kernel_source_dir} |' \
	-e '/^MAKE\[0\]=/s|"$| NV_EXCLUDE_KERNEL_MODULES=nvidia-drm"|' \
	-e '/^BUILT_MODULE_NAME\[2\]="nvidia-drm"/d' \
	-e '/^DEST_MODULE_LOCATION\[2\]=/d' \
	-e 's/^\(BUILT_MODULE_NAME\|DEST_MODULE_LOCATION\)\[3\]/\1[2]/' \
	-e 's/^\(BUILT_MODULE_NAME\|DEST_MODULE_LOCATION\)\[4\]/\1[3]/' "$CONF"

echo "Updated $CONF (original saved as $CONF.orig):"
grep -E '^(MAKE\[0\]|BUILT_MODULE_NAME|PATCH)' "$CONF"
