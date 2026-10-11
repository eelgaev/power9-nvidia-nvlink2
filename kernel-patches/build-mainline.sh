#!/usr/bin/env bash
# Build mainline kernel RPMs (e.g. the 6.12 LTS series) with the nvlink2
# patches, using the kernel's own rpm-pkg packaging.
#
#   build-mainline.sh <linux tarball> <base config> <patch dir> <output dir> [jobs]
#
# Runs in the EL8 build container (build/Containerfile.el8) and compiles with
# gcc-toolset-13, the compiler that DKMS uses on the target hosts, so that
# modules built there later match the kernel.
#
# The base config is the RHEL 9 ppc64le configuration shipped in the patch
# directory: it carries the feature set of the reference hosts (filesystems,
# drivers). The patch series applies on top, including the KVM-host config
# patch; symbols new to mainline take their defaults in
# "make olddefconfig".
#
# With these changes to the defaults:
#   - DEBUG_INFO (and BTF) off: smaller vmlinux and no debuginfo split;
#   - WERROR off: gcc 13 warns where the reference gcc does not;
#   - LOCALVERSION / BUILD_SALT set to "-$SUFFIX" (default "mainline");
#   - PPC_POWERNV_NVLINK2 built as the nvlink2-npu module.
#
# Packaging generates the spec with scripts/package/mkspec and builds it in
# place (no second extraction), parallelized via _smp_mflags; upstream's
# "make rpm-pkg" would build serially. The spec packs the kernel, the
# external-module devel tree (incl. .config for kmake and DKMS) and the
# userspace headers. Output: <output dir>/RPMS/kernel{,-devel,-headers}-<release>*.rpm
set -euo pipefail

SRC_TARBALL=$(realpath "${1:?usage: $0 <linux tarball> <base config> <patch dir> <output dir> [jobs]}")
CONFIG=$(realpath "${2:?base config required}")
PATCHES=$(realpath "${3:?patch dir}")
OUT=$(realpath -m "${4:?output dir}")
JOBS=${5:-$(( $(nproc) / 2 ))}
IMAGE=${IMAGE:-p9-nvlink2-el8}
SUFFIX=${SUFFIX:-mainline}

mkdir -p "$OUT"

podman run --rm \
	-v "$SRC_TARBALL:/in/source.tar:ro,z" \
	-v "$CONFIG:/in/base-config:ro,z" \
	-v "$PATCHES:/in/patches:ro,z" \
	-v "$OUT:/build:z" \
	"$IMAGE" bash -euo pipefail -c '
JOBS=$1 SUFFIX=$2
source /opt/rh/gcc-toolset-13/enable
gcc --version | head -1
export KBUILD_BUILD_USER=p9build KBUILD_BUILD_HOST=p9build

rm -rf /build/src /build/rpmbuild && mkdir -p /build/src && cd /build/src
tar -xf /in/source.tar
cd linux-*/
cp /in/base-config .config
for p in /in/patches/0*.patch; do
	echo "applying $(basename "$p")"
	patch -p1 -s < "$p"
done

# e.g. 6.12.112 with SUFFIX=mainline -> 6.12.112-mainline
base=$(make -s kernelversion)
krel="-${SUFFIX}"

scripts/config --disable WERROR \
	--enable DEBUG_INFO_NONE --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
	--disable DEBUG_INFO --disable DEBUG_INFO_BTF \
	--disable DEBUG_INFO_BTF_MODULES \
	--set-str LOCALVERSION "$krel" --disable LOCALVERSION_AUTO \
	--set-str BUILD_SALT "${krel#-}" \
	--module PPC_POWERNV_NVLINK2
make -s olddefconfig
grep -qx "CONFIG_DEBUG_INFO_NONE=y" .config
! grep -qx "CONFIG_DEBUG_INFO=y" .config
make -s prepare
release=$(make -s kernelrelease)
[[ $release == "$base$krel" ]] || { echo "unexpected release: $release" >&2; exit 1; }
echo "kernel release: $release"
grep -E "^CONFIG_(FTRACE_MCOUNT_USE_[A-Z_]+|CC_VERSION_TEXT)=" .config

# The kernel'"'"'s own rpm-pkg spec (scripts/package/kernel.spec): kernel with
# modules and dtbs, the external-module devel tree and the userspace headers.
# On powerpc image_name is vmlinux, an ELF boot image as in the RHEL RPM;
# disabling DWARF above keeps it small. The generic zImage is a pseries
# wrapper, so do not substitute it for a PowerNV boot image.
# %post installs /boot files and a BLS entry via kernel-install, leaving the
# default boot entry unchanged. ARCH is the Kbuild arch (powerpc); the RPM
# target arch is ppc64le.
mkdir -p /build/rpmbuild/SOURCES /build/rpmbuild/SPECS
ARCH=powerpc KERNELRELEASE="$release" srctree="$PWD" \
	sh scripts/package/mkspec /build/rpmbuild/SPECS/kernel.spec
cp .config /build/rpmbuild/SOURCES/config
: > /build/rpmbuild/SOURCES/diff.patch
tar --exclude=./.git --transform "s,^\.,linux," \
	-czf /build/rpmbuild/SOURCES/linux.tar.gz .

# kmake and DKMS tooling read the kernel .config from the devel tree, which
# install-extmod-build does not copy.
python3 - <<PY
from pathlib import Path
spec = Path("/build/rpmbuild/SPECS/kernel.spec")
s = spec.read_text()
apostrophe = chr(39)
old = "install-extmod-build %{buildroot}/usr/src/kernels/%{KERNELRELEASE}" + apostrophe + "\n"
new = old + "cp .config %{buildroot}/usr/src/kernels/%{KERNELRELEASE}/.config\n"
assert s.count(old) == 1, "unexpected generated spec"
spec.write_text(s.replace(old, new))
PY

# Build in place against the configured tree; _smp_mflags parallelizes the
# %build make (upstream forces it to %{nil}). --nodeps skips BuildRequires
# resolution: the container provides the tools (gcc via gcc-toolset-13;
# dwarves is only needed for the disabled BTF).
cd "$PWD" && rpmbuild -bb --target ppc64le --build-in-place --noprep \
	--define "_topdir /build/rpmbuild" --define "_smp_mflags -j$JOBS" \
	--define "_build_id_links none" --nodeps \
	/build/rpmbuild/SPECS/kernel.spec
mkdir -p /build/RPMS
mv /build/rpmbuild/RPMS/*/*.rpm /build/RPMS/
' mainline "$JOBS" "$SUFFIX"

ls -l "$OUT/RPMS"
