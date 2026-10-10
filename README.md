# power9-nvidia-nvlink2

NVLink2 for NVIDIA V100 GPUs on IBM POWER9 (AC922 "witherspoon" class)
on kernels that no longer carry the NPU code: CPU <-> GPU NVLink, ATS
(GPU kernels using plain `malloc()` memory through the CPU's page tables),
GPU memory onlined as coherent NUMA nodes, and unified memory, with
NVIDIA's last ppc64le driver, 550.54.15.

Linux removed this support in v5.3 and v5.13. This project brings it back
as:

- **a kernel patch series** (`kernel-patches/<target>`): NPU PHB probing
  at boot, two OPAL calls, header declarations, a missing secondary-TLB
  invalidation, and the **`nvlink2-npu` module** itself
  (`CONFIG_PPC_POWERNV_NVLINK2`, built into the kernel), which provides
  the NPU2 API the GPU driver expects (`pnv_pci_get_npu_dev()`,
  `pnv_npu2_init_context()`, ...) with the original names and signatures;
- **one small patch to NVIDIA 550.54.15** (a removed kernel API);
- **tests** for bandwidth, ATS and missed-invalidation corruption.

See [docs/DESIGN.md](docs/DESIGN.md) for what lives where and why, and
[docs/INVENTORY.md](docs/INVENTORY.md) for every piece of the removed code
and where it went.

Hardware testing is in progress: the first `npu1` boot failed in NPU EEH
recovery. Patch 0006 addresses the identified registration-order defect;
runtime validation is still required. See [docs/VALIDATION.md](docs/VALIDATION.md).

## Supported

| | |
|---|---|
| Hardware | POWER9 bare metal (OPAL/skiboot), NPU2, V100-SXM2 |
| Kernel | RHEL 9.9 `5.14.0-741.*.el9_9` + `kernel-patches/rhel-9.9`, built with gcc-toolset-13; the nvlink2-npu module ships in the kernel RPM |
| Userspace | RHEL 8 (NVIDIA's ppc64le userspace is RHEL 8 only); RHEL 9 for the kernel side |
| Driver | NVIDIA 550.54.15 (ppc64le) + `nvidia-patches/550.54.15` |

## Layout

```
src/                         nvlink2-npu module sources (built by the kernel
                             build as CONFIG_PPC_POWERNV_NVLINK2=m)
scripts/kmake                run a build with the kernel's own compiler
kernel-patches/make-patches.py   regenerates the patch series (per target)
kernel-patches/<target>      kernel patch series, e.g. rhel-9.9
kernel-patches/build-kernel.sh   kernel RPMs from the RHEL SRPM (EL8 container)
nvidia-patches/550.54.15     NVIDIA driver patch + apply.sh (DKMS PATCH[])
build/Containerfile.el8      build environment (UBI 8 + gcc-toolset-13)
tests/                       bw, ats_read, ats_stress (CUDA), verify.sh
docs/                        DESIGN, INVENTORY, INSTALL, BOOT
```

## Quick start

See [docs/INSTALL.md](docs/INSTALL.md). In short:

```sh
podman build -t p9-nvlink2-el8 -f build/Containerfile.el8 build
kernel-patches/build-kernel.sh kernel-5.14.0-741.9.1.el9_9.src.rpm \
    kernel-patches/rhel-9.9 out
# with UPDATEDEFAULT=no in /etc/sysconfig/kernel:
rpm -ivh out/RPMS/kernel-5.14.0_*.rpm out/RPMS/kernel-devel-5.14.0_*.rpm
nvidia-patches/550.54.15/apply.sh && dkms install nvidia/550.54.15 -k <kernel> --force
```

## Credits

The NPU code is the work of Alistair Popple, Alexey Kardashevskiy, Mark
Hairgrove, Reza Arbab, Frederic Barrat, Oliver O'Halloran and others at
IBM, NVIDIA and in the Linux community; see [CREDITS](CREDITS).

## License

GPL-2.0-only (see [LICENSE](LICENSE)), as the kernel code it derives from.
The NVIDIA patches modify MIT-licensed files of NVIDIA's open kernel
interface layer and are under the same terms as those files.
