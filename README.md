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
- **six small patches to NVIDIA 550.54.15** (a removed kernel API, an
  ATS enablement gate for the restored NPU API, three ATS servicing
  fixes: skipping migrations into GPU memory that is already full, and two
  backports from later NVIDIA drivers; and a bounded wait so a GPU that
  stops responding cannot hang every CUDA process until a reboot);
- **tests** for bandwidth, ATS and missed-invalidation corruption.

See [docs/DESIGN.md](docs/DESIGN.md) for what lives where and why, and
[docs/INVENTORY.md](docs/INVENTORY.md) for every piece of the removed code
and where it went.

ATS requires more than the restored NPU API: NVIDIA UVM also needs usable
MM lifecycle exports. When `mmput` and `__mmdrop` are GPL-only exports, UVM
cannot use them after inheriting proprietary taint from NVIDIA's core module.
Kernel patch 0007 provides compatible MM export types for the POWER9 NVLink2
configuration, and NVIDIA patch 0002 checks that both the NPU and MM APIs are
usable before enabling ATS. See [docs/VALIDATION.md](docs/VALIDATION.md) for
build checks and the hardware validation procedure.

## Supported

| | |
|---|---|
| Hardware | POWER9 bare metal (OPAL/skiboot), NPU2, V100-SXM2 |
| Kernel | RHEL 9.9 `5.14.0-741.*.el9_9` + `kernel-patches/rhel-9.9`; or mainline 6.12 LTS (`kernel-patches/mainline-6.12`); both built with gcc-toolset-13, the nvlink2-npu module ships in the kernel RPM |
| Userspace | RHEL 8 (NVIDIA's ppc64le userspace is RHEL 8 only); RHEL 9 for the kernel side |
| Driver | NVIDIA 550.54.15 (ppc64le) + `nvidia-patches/550.54.15` |

## Layout

```
src/                         nvlink2-npu module sources (built by the kernel
                             build as CONFIG_PPC_POWERNV_NVLINK2=m)
scripts/kmake                run a build with the kernel's own compiler
kernel-patches/make-patches.py   regenerates the patch series (per target)
kernel-patches/<target>      kernel patch series, e.g. rhel-9.9, mainline-6.12
kernel-patches/build-kernel.sh   kernel RPMs from the RHEL SRPM (EL8 container)
kernel-patches/build-mainline.sh kernel RPMs from a kernel.org tarball
kernel-patches/rebuild-kernel.sh incremental rebuild from a saved compiled tree
nvidia-patches/550.54.15     NVIDIA driver patches + apply.sh (DKMS PATCH[])
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
KVER='<kernel-release>'
nvidia-patches/550.54.15/apply.sh &&
dkms build nvidia/550.54.15 -k "$KVER" --force &&
dkms install nvidia/550.54.15 -k "$KVER" --force
```

For the mainline 6.12 LTS series the same flow starts from a kernel.org
tarball and the configuration shipped in the patch directory:

```sh
kernel-patches/build-mainline.sh linux-6.12.<x>.tar.xz \
    kernel-patches/mainline-6.12/kernel-ppc64le-rhel.config \
    kernel-patches/mainline-6.12 out [jobs]
```

## Driver parameters

NVIDIA patch 0006 adds one `nvidia-uvm` parameter:

| Parameter | Default | |
|---|---|---|
| `uvm_channel_init_timeout_sec` | `60` | Seconds UVM waits for a GPU to complete the init push of each new internal channel when a process first uses the GPU. `0` waits forever, as NVIDIA's driver does. |

Without the bound, a GPU that has stopped processing work (no Xid, no channel
error) leaves the first process that opens it spinning in the kernel, unkillable,
with UVM's locks held. Every later CUDA program and `nvidia-smi` then hangs in D
state, `nvidia-uvm` cannot be unloaded, and only a reboot recovers. With it, the
driver logs

```
nvidia-uvm: GPU <uuid> did not complete the init push of channel <name> in 60 s; setting the global fatal error ...
```

and sets UVM's global fatal error (as for an unrecoverable ECC error): every
waiting process gets an error and exits, and UVM refuses work until it is
reloaded. Then recover without a reboot:

```sh
# stop the CUDA programs (they now exit), then
rmmod nvidia_uvm && modprobe nvidia_uvm
nvidia-smi -r -i <bus id of the GPU from the log>   # if it still does not respond
```

Set it at load time with `options nvidia-uvm uvm_channel_init_timeout_sec=120`
in `/etc/modprobe.d/nvidia-uvm.conf`, or at run time through
`/sys/module/nvidia_uvm/parameters/uvm_channel_init_timeout_sec`. Raise it rather
than disabling it if a heavily loaded system ever trips it while healthy.

For diagnosis, NVIDIA's own `uvm_debug_prints` (also writable at run time) makes
a stuck wait log the channel, the GPU and the pending push every few seconds:

```sh
echo 1 > /sys/module/nvidia_uvm/parameters/uvm_debug_prints   # 0 to stop
```

## Credits

The NPU code is the work of Alistair Popple, Alexey Kardashevskiy, Mark
Hairgrove, Reza Arbab, Frederic Barrat, Oliver O'Halloran and others at
IBM, NVIDIA and in the Linux community; see [CREDITS](CREDITS).

## License

GPL-2.0-only (see [LICENSE](LICENSE)), as the kernel code it derives from.
The NVIDIA patches modify MIT-licensed files of NVIDIA's open kernel
interface layer and are under the same terms as those files.
