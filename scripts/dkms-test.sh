#!/usr/bin/env bash
# dkms-test: build the patched NVIDIA driver with DKMS against freshly built
# kernel RPMs, without installing anything.
#
#   dkms-test.sh <dir with kernel RPMs> [nvidia DKMS source dir] [work dir]
#
# Unpacks the kernel and kernel-devel RPMs into <work dir>, then runs DKMS
# with private --dkmstree / --sourcetree under <work dir>: nothing is
# registered with the system's DKMS, installed or loaded. Checks that the
# NPU API (pnv_npu2_init_context() and friends, provided by the in-kernel
# nvlink2-npu module) is in the kernel's Module.symvers and that the NVIDIA
# modules import it.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
RPMS=$(realpath "${1:?usage: $0 <rpm dir> [nvidia src dir] [work dir]}")
NVSRC=${2:-/usr/src/nvidia-550.54.15}
WORK=$(realpath -m "${3:-./dkms-test}")

rm -rf "$WORK"
mkdir -p "$WORK"/{root,src,tree}
for r in "$RPMS"/kernel-[0-9]*.rpm "$RPMS"/kernel-devel-[0-9]*.rpm; do
	(cd "$WORK/root" && rpm2cpio "$r" | cpio -idm --quiet)
done
KVER=$(ls "$WORK/root/lib/modules")
KDIR=$WORK/root/usr/src/kernels/$KVER
echo "kernel $KVER"

# The NPU API and its CRCs must be in the kernel's Module.symvers (the
# nvlink2-npu module is built by the kernel build itself).
grep -q "	pnv_npu2_init_context" "$KDIR/Module.symvers" ||
	{ echo "NPU API not in $KDIR/Module.symvers"; exit 1; }

cp -a "$NVSRC" "$WORK/src/nvidia-550.54.15"
"$HERE/nvidia-patches/550.54.15/apply.sh" "$WORK/src/nvidia-550.54.15" >/dev/null

d=(--sourcetree "$WORK/src" --dkmstree "$WORK/tree")
k=(-k "$KVER" --kernelsourcedir "$KDIR")
dkms add -m nvidia -v 550.54.15 "${d[@]}"
dkms build -m nvidia -v 550.54.15 "${k[@]}" "${d[@]}"

fail=0
m=$WORK/tree/nvidia/550.54.15/$KVER/ppc64le/module
echo
echo "== modules"
for ko in "$m"/nvidia.ko* "$m"/nvidia-uvm.ko*; do
	echo "  $(basename "$ko"): depends=$(modinfo -F depends "$ko")"
done
modinfo -F vermagic "$m"/nvidia.ko* | sed 's/^/  vermagic: /'

# DKMS removes the build tree (and conftest results) after the build; what
# the modules import shows what conftest enabled: nvidia.ko the NPU lookup
# (NV_PNV_PCI_GET_NPU_DEV_PRESENT), nvidia-uvm.ko the kernel ATS path
# (NV_PNV_NPU2_INIT_CONTEXT_CALLBACK_RETURNS_VOID).
echo "== NPU API imports"
imports() { modprobe --dump-modversions "$1" | awk '{print $2}'; }
for want in "nvidia.ko pnv_pci_get_npu_dev" \
	    "nvidia-uvm.ko pnv_pci_get_npu_dev" \
	    "nvidia-uvm.ko pnv_npu2_init_context" \
	    "nvidia-uvm.ko pnv_npu2_destroy_context"; do
	set -- $want
	if imports "$(ls "$m/$1"*)" | grep -qx "$2"; then
		echo "  $1 imports $2"
	else
		echo "  MISSING: $1 does not import $2"; fail=1
	fi
done

(( fail )) && echo FAIL || echo PASS
exit $fail
