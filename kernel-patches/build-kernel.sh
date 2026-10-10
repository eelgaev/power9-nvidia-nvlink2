#!/usr/bin/env bash
# Build kernel RPMs from a RHEL kernel SRPM with the nvlink2-npu patches.
#
#   build-kernel.sh <kernel .src.rpm> <patch dir> <output dir> [jobs]
#
# Runs in the EL8 build container (build/Containerfile.el8) and compiles with
# gcc-toolset-13, the compiler that DKMS uses on the target hosts, so that
# modules built there later match the kernel.
#
# Red Hat's RHEL 9 kernel.spec does not parse with RHEL 8's rpm, so the
# kernel is built and packaged by the kernel's own "make rpm-pkg" from the
# SRPM's source tarball and RHEL configuration, with these changes:
#   - DEBUG_INFO (and BTF) off: no debuginfo split, and the uncompressed
#     vmlinux that rpm-pkg installs in /boot stays small;
#   - WERROR off: gcc 13 warns (-Warray-bounds false positives) where the
#     gcc 11 that RHEL 9 is built with does not;
#   - LOCALVERSION / BUILD_SALT set to the release below.
# Packaging omits global build-ID links so kernel-devel releases coexist.
# Output: <output dir>/RPMS/kernel{,-devel,-headers}-<release>*.rpm
set -euo pipefail

SRPM=$(realpath "${1:?usage: $0 <src.rpm> <patch dir> <output dir> [jobs]}")
PATCHES=$(realpath "${2:?patch dir}")
OUT=$(realpath -m "${3:?output dir}")
JOBS=${4:-$(( $(nproc) / 2 ))}
IMAGE=${IMAGE:-p9-nvlink2-el8}
SUFFIX=${SUFFIX:-npu3}

mkdir -p "$OUT"

podman run --rm \
	-v "$SRPM:/in/kernel.src.rpm:ro,z" \
	-v "$PATCHES:/in/patches:ro,z" \
	-v "$OUT:/build:z" \
	"$IMAGE" bash -euo pipefail -c '
JOBS=$1 SUFFIX=$2
source /opt/rh/gcc-toolset-13/enable
gcc --version | head -1

rm -rf /build/src /build/rpmbuild && mkdir -p /build/src && cd /build/src
rpm2cpio /in/kernel.src.rpm | cpio -idm --quiet "linux-*.tar.xz" \
	"kernel-ppc64le-rhel.config" "Makefile.rhelver"
tar -xf linux-*.tar.xz
cd linux-*/
# RHEL version macros (RHEL_MAJOR, ...), as the RHEL spec does in %prep
cp ../Makefile.rhelver .
# Load the base config before the series so its KVM config patch can apply.
cp ../kernel-ppc64le-rhel.config .config
for p in /in/patches/0*.patch; do
	echo "applying $(basename "$p")"
	patch -p1 -s < "$p"
done

# RHEL release of the SRPM, e.g. 741.9.1.el9_9 -> 5.14.0-741.9.1.npu3.el9_9.ppc64le
rel=$(basename "$PWD" | sed "s/^linux-[0-9.]*-//")
krel="-${rel%%.el*}.$SUFFIX.el${rel#*.el}.ppc64le"

scripts/config --disable WERROR \
	--disable DEBUG_INFO --disable DEBUG_INFO_BTF \
	--disable DEBUG_INFO_BTF_MODULES \
	--set-str LOCALVERSION "$krel" --disable LOCALVERSION_AUTO \
	--set-str BUILD_SALT "${krel#-}" \
	--set-str CRYPTO_FIPS_NAME "Red Hat Enterprise Linux 9 - Kernel Cryptographic API"
make -s olddefconfig
echo "kernel release: $(make -s kernelrelease)"
grep -E "^CONFIG_(FTRACE_MCOUNT_USE_[A-Z_]+|CC_VERSION_TEXT)=" .config

# What "make rpm-pkg" does, minus its _smp_mflags override (which leaves
# the build inside rpmbuild serial): spec from scripts/package/mkspec and a
# source tarball. rpmbuild -ta cannot be used: the RHEL tree contains other
# .spec files.
kp=kernel-$(make -s kernelrelease | tr - _)
KERNELRELEASE=$(make -s kernelrelease) MAKE=make srctree=. \
	RCS_TAR_IGNORE=--exclude=.git sh scripts/package/mkspec > ../kernel.spec
mkdir -p /build/rpmbuild/SOURCES
tar --exclude=./.git --transform "s,^\.,$kp," \
	-czf "/build/rpmbuild/SOURCES/$kp.tar.gz" .
rpmbuild --define "_topdir /build/rpmbuild" --define "_smp_mflags -j$JOBS" \
	--define "_build_id_links none" --target ppc64le -bb ../kernel.spec
mkdir -p /build/RPMS
mv /build/rpmbuild/RPMS/*/*.rpm /build/RPMS/
' build "$JOBS" "$SUFFIX"

ls -l "$OUT/RPMS"
