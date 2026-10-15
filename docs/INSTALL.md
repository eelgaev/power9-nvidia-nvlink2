# Installation

The patched kernel is RHEL 9.9's kernel source and configuration, built in
a RHEL 8 userspace with **gcc-toolset-13**. The same compiler exists on
RHEL 8 and RHEL 9, so DKMS can build modules that match the kernel on
either:

- **RHEL 8 userspace** — keeps NVIDIA's ppc64le userspace (`libcuda`,
  `nvidia-smi`, `nvidia-persistenced`), which NVIDIA only ships for RHEL 8.
  Primary setup; see [VALIDATION.md](VALIDATION.md) for hardware test status.
- **RHEL 9 userspace** — the kernel side is the same; NVIDIA has no RHEL 9
  ppc64le packages, so its userspace must come from elsewhere.

Nothing below changes the default boot entry. See [BOOT.md](BOOT.md) for
selecting the new kernel.

## 1. Build the kernel RPMs

Use the kernel release printed by the build in the commands below.
See [VALIDATION.md](VALIDATION.md) for compatibility checks and the hardware
validation procedure.

On a ppc64le machine with podman:

```sh
podman build -t p9-nvlink2-el8 -f build/Containerfile.el8 build
kernel-patches/build-kernel.sh kernel-5.14.0-741.9.1.el9_9.src.rpm \
    kernel-patches/rhel-9.9 out [jobs]
```

The base image is Red Hat's UBI 8; on a subscribed RHEL host it gets the
full RHEL 8 repos. Without a subscription build it from a RHEL 8 rebuild:
`--build-arg BASE=quay.io/rockylinux/rockylinux:8`. The SRPM comes from
Red Hat.

Red Hat's RHEL 9 `kernel.spec` does not parse with RHEL 8's rpm, so the
script packages the kernel with the kernel's own RPM spec
(`scripts/package/mkspec`, as `make rpm-pkg`), from the SRPM's source
tarball and `kernel-ppc64le-rhel.config`. Changes from Red Hat's build:
no `DEBUG_INFO`/BTF (the spec installs the uncompressed `vmlinux` in
`/boot`), no Red Hat trusted keys, modules signed with a key generated at
build time. Output in `out/RPMS/`:

RPM packaging disables global `/usr/lib/.build-id` links. Identical
build-helper binaries in different kernel-devel releases otherwise generate
conflicting symlinks pointing into different versioned build trees. This
does not remove the helper binaries or their embedded build IDs.

To correct packaging of an existing build without recompiling:

```sh
bash kernel-patches/repackage-kernel.sh out [jobs]
```

To apply additional patches and incrementally rebuild a saved compiled tree:

```sh
bash kernel-patches/rebuild-kernel.sh previous-out additional-patches \
    out-next '<build-suffix>' [jobs]
```

### Mainline kernels

The NVLink2 patches have a mainline 6.12 LTS variant
(`kernel-patches/mainline-6.12`), generated against
`linux-6.12.<x>.tar.xz` from kernel.org. The build starts from that
tarball instead of the SRPM; the base configuration is the RHEL 9 ppc64le
one shipped in the patch directory (`kernel-ppc64le-rhel.config`), so the
feature set of the reference hosts carries over, with KVM hosting enabled
by the config patch in the series. Its mainline-only migration patch
declines page migration while a source folio is under writeback instead of
panicking during ATS access-counter handling:

```sh
kernel-patches/build-mainline.sh linux-6.12.<x>.tar.xz \
    kernel-patches/mainline-6.12/kernel-ppc64le-rhel.config \
    kernel-patches/mainline-6.12 out [jobs]
```

Packaging uses the kernel's own rpm-pkg spec: the kernel package carries
the modules and device trees and installs `/boot` files plus a BLS boot
entry via `kernel-install` on install (the default entry stays
unchanged); `kernel-devel` is the external-module build tree
(`Module.symvers`, scripts, `.config`); `kernel-headers` must not be
installed, for the same reason as above. On PowerPC the spec packages
`vmlinux` as `vmlinuz`, like the working RHEL build; the build script
selects `CONFIG_DEBUG_INFO_NONE=y` explicitly. Disabling the hidden
`CONFIG_DEBUG_INFO` switch alone allows `olddefconfig` to select DWARF
again, dramatically enlarging the boot image and modules. The DKMS flow,
the verification checks and the tests are identical to the RHEL kernel.

The additional patch directory must contain only patches not yet applied to
the saved tree. The new output directory must not exist; the previous output
is mounted read-only. The compiler and packaging settings match the full build.

| Package | Install? |
|---|---|
| `kernel-…` | yes: `/boot`, `/lib/modules` (incl. the nvlink2-npu module) |
| `kernel-devel-…` | yes: build tree for DKMS |
| `kernel-headers-…` | **no**: would replace the distribution's userspace kernel headers |

## 2. Install the kernel next to the existing ones

The package's `%post` runs `/sbin/installkernel`, which adds a boot entry.
Stop it from becoming the default first:

```sh
sed -i 's/^UPDATEDEFAULT=yes/UPDATEDEFAULT=no/' /etc/sysconfig/kernel
grubby --default-kernel            # note it

rpm -ivh out/RPMS/kernel-5.14.0_*.rpm out/RPMS/kernel-devel-5.14.0_*.rpm

grubby --default-kernel            # must be unchanged
```

To remove it later: `rpm -e kernel-5.14.0_… kernel-devel-5.14.0_…`.

## 3. Rebuild NVIDIA 550.54.15 for the new kernel

The kernel RPM ships the nvlink2-npu module; there is nothing to install
for it — NVIDIA's modules import its symbols (via the kernel's
`Module.symvers`), so the module loads automatically before they do.

Needs `gcc-toolset-13-gcc` (RHEL 8 and 9 AppStream): DKMS builds through
`kmake`, which picks the compiler the kernel was built with.

```sh
KVER='<kernel-release>'
nvidia-patches/550.54.15/apply.sh &&
dkms build nvidia/550.54.15 -k "$KVER" --force &&
dkms install nvidia/550.54.15 -k "$KVER" --force
```

`apply.sh` registers the follow_pfn and ATS enablement patches with NVIDIA's
DKMS package (DKMS applies them to its build copy;
`/usr/src/nvidia-550.54.15` stays as shipped), runs the build through `kmake`,
and leaves out `nvidia-drm`
(display/KMS glue, unused on compute systems; it does not build against
RHEL 9.9's newer DRM API). Rerunning it adds newly introduced patches to an
already configured source tree without duplicating existing entries. Builds
for other kernels get the same settings; the compatibility changes preserve
the existing RHEL 8 behavior.

The explicit build step is required when updating an existing build for the
same kernel release: installing an already-built DKMS entry alone can reuse
the old modules. Confirm patch registration and application:

```sh
grep '^PATCH\[' /usr/src/nvidia-550.54.15/dkms.conf
grep 'Applying patch' \
    "/var/lib/dkms/nvidia/550.54.15/$KVER/ppc64le/log/make.log"
```

Both checks must list patches 0001 to 0005. Activate the updated modules at
the next controlled boot before checking CUDA's ATS capabilities.

Check that the driver uses the NPU API (i.e. conftest found it):

```sh
modprobe --dump-modversions \
    /lib/modules/<kernel>/extra/nvidia-uvm.ko* | grep pnv_
```

It must list `pnv_pci_get_npu_dev`, `pnv_npu2_init_context` and
`pnv_npu2_destroy_context`. `scripts/dkms-test.sh` runs the whole DKMS
build in a scratch tree and performs these checks without installing
anything. Symbol imports alone do not establish that ATS is enabled: UVM's
VA-space/mm support must also be enabled. Patch 0002 checks that the restored
NPU API and non-GPL MM lifecycle exports are available. With GPL-only
`mmput` or `__mmdrop` exports, UVM remains loadable but ATS stays disabled.
Kernel patch 0007 provides non-GPL exports of these two functions when
`CONFIG_PPC_POWERNV_NVLINK2` is enabled, supplying this compatibility.

The isolated build check rejects GPL-only imports from NVIDIA's core and UVM
modules, which compilation alone can miss. After the updated modules are loaded,
`ats_read` must report pageable memory access and pass both malloc and managed
checks, and `ats_stress` must report host-page-table ATS and actually run its
invalidation phases.

## 4. Boot and verify

Boot the new kernel (see [BOOT.md](BOOT.md)), then:

```sh
make -C tests && tests/verify.sh
```
