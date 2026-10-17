# Design

## Goal

Full NVLink2 on POWER9 (AC922 class) with NVIDIA V100 GPUs and NVIDIA's
last ppc64le driver (550.54.15) on a kernel newer than the ones that
carried the code: CPU <-> GPU links, ATS (GPUs translating through the
CPU's page tables), GPU memory onlined as coherent NUMA nodes, unified
memory. The NPU code ships as a module built into the kernel
(`CONFIG_PPC_POWERNV_NVLINK2`); the parts that cannot be a module are a
small kernel patch series.

Target: RHEL 9.9 (`5.14.0-741.*.el9_9`), which already carries the 256 MiB
memory-block fix for coherent device memory and the secondary-TLB
notifier infrastructure.

## What lives where

```
            GPU driver (nvidia.ko, nvidia-uvm.ko)       NVIDIA 550.54.15 +
                 |  pnv_pci_get_npu_dev()                nvidia-patches/
                 |  pnv_npu2_init_context() / destroy
                 v
  nvlink2-npu.ko  (src/, in-tree module, patch 0005)
    npu-dev.c   GPU <-> NPU lookup via device tree
    npu-lpar.c  OPAL map-LPAR / init-context per GPU (at load)
    npu-ats.c   per-mm context = mmu_notifier subscription
                ->arch_invalidate_secondary_tlbs -> ATSD MMIO -> GPU TLBs
                copro accounting -> global tlbie -> nest MMU
                 |
                 v
  kernel (kernel-patches/)
    0001  probe "ibm,ioda2-npu2-phb", NPU PEs, controller ops   (boot time)
    0002  opal_npu_{init,destroy}_context, export map_lpar      (OPAL)
    0003  prototypes in asm/pci.h, asm/powernv.h                (conftest)
    0004  notify secondary TLBs on single-page radix flushes    (correctness)
    0005  the nvlink2-npu module (src/)                   (CONFIG_PPC_POWERNV_NVLINK2)
    0006  defer NPU EEH registration until its PEs exist       (initialization order)
    0007  compatible MM lifetime export types for NVLink2 UVM (driver compatibility)
    0008  enable POWER KVM host modules in the base config     (configuration)
    0009  defer device migration of folios under writeback    (mainline-6.12 only)
```

The series is generated per target by `make-patches.py`
(`kernel-patches/<target>/`). It targets `rhel-9.9` (the 5.14-based RHEL
9.9 kernel) and `mainline-6.12` (the 6.12 LTS series, generated against
`linux-6.12.112`). The steps are identical except that mainline 6.12
removed IODA1 support, so 0001 uses the three-entry PHB type enum and
name list there. RHEL-only config plumbing (`Makefile.rhelver`, the
vendor config patch target) stays in the RHEL build flow;
`build-mainline.sh` applies the same series to a kernel.org tarball with
the RHEL 9 ppc64le configuration as base. Patch 0008 is the config change;
mainline-only patch 0009 handles a device migration writeback failure
observed during ATS access-counter processing. It clears the migration flag
for a folio still under writeback; the existing finalize path discards the
unused destination and restores the source mapping. A build and a DKMS check
cannot establish hardware correctness: repeat the staged ATS tests on the
new kernel before treating this correction as validated.

## Why these are kernel patches (not module code)

- **0001** — The NPU PHBs must be created by `pnv_pci_init_ioda_phb()`
  during early PCI init, and their PEs assigned at PCI fixup, using static
  and `__init` code of the powernv platform — before any module loads.
  Without it the NPU PCI devices (`[1014:04ea]`) do not exist: NVIDIA's
  `ibmnpu` glue cannot bind them or train the links, and nothing else
  works.
- **0002** — OPAL calls go through the kernel-internal `opal_call()`
  trampoline; the two context calls had their wrappers removed and
  `opal_npu_map_lpar()` is not exported.
- **0003** — NVIDIA's conftest decides whether NVLink/ATS support is
  compiled in by compiling calls against `<linux/pci.h>` and
  `<asm/powernv.h>`; the declarations have to be in those headers. (An
  alternative is forcing an extra include into the NVIDIA build.)
- **0004** — On 9.9 the radix TLB flush code notifies secondary TLBs for
  range and full-mm flushes but not for single-page flushes, which are
  what copy-on-write, page migration, reclaim and KSM use. Missing them
  leaves stale GPU translations: silent memory corruption. (A module could
  only work around this with kprobes on a hot path.)
- **0007** — UVM's VA-space/mm association imports `mmput()` and
  `__mmdrop()`. Their GPL-only export types prevent loading UVM after it
  inherits proprietary taint from NVIDIA's core module. With
  `CONFIG_PPC_POWERNV_NVLINK2` enabled, this patch provides non-GPL exports
  of these two functions. Their MM lifetime implementations remain the
  current kernel implementations; other configurations retain GPL-only exports.

The module itself (0005) is a tristate (`=m`) so a failure to load its
init does not keep the system from booting, and so the ATSD/GPU mapping
happens at an explicit point (module load) rather than at boot; NVIDIA's
modules import its symbols, so it always loads first.

## Key adaptations in the module

- **Context per mm.** RHEL 8 kept the context in `mm->context.npu_context`.
  The module uses `mmu_notifier_get_locked()` with its own ops, which
  returns the one subscription per (mm, ops) with a reference, and
  `mmu_notifier_put()` on destroy. The callers already hold `mmap_lock`
  for write, as both the old API and `mmu_notifier_get_locked()` require.
- **Invalidation hook.** `->invalidate_range` and `->change_pte` are gone;
  `->arch_invalidate_secondary_tlbs` is called by the radix flush code
  after the CPU TLB invalidation, which is the ordering ATSD needs.
- **Nest MMU.** The context marks the mm as having a coprocessor
  (`mm_context_add_copro()`), so every TLB invalidation for it is a global
  `tlbie`, which the nest MMU snoops. The firmware option of explicit
  nest-MMU flushes (`ibm,nmmu-flush`) is not supported: AC922 firmware does
  not request it, and `flush_all_mm()` now calls back into the notifier.
- **Per-NPU state** (ATSD registers, OPAL PHB id) comes from the device
  tree (`ibm,mmio-atsd`, `ibm,opal-phbid`) and is kept in the module
  instead of `pci_controller::npu`.
- **GPU <-> LPAR binding**, done by the kernel at PCI fixup before, is done
  at module load. The NVIDIA modules depend on the module's symbols, so it
  always loads first.

## NVIDIA driver path

UVM has two IBM ATS implementations: through the kernel API
(`pnv_npu2_init_context()`), and inside the driver. Detection of the production
NPU context callback API selects the kernel implementation, as on RHEL 8.

The original version gate in `UVM_CAN_USE_MMU_NOTIFIERS()` also disables
UVM's VA-space/mm association on newer kernels, preventing global ATS
enablement even when the kernel implementation is compiled. NVIDIA patch
0002 requires the production NPU API and usable non-GPL MM lifetime exports
before allowing that association. Kernel patch 0007 supplies compatible MM
export types for this platform configuration. Kernel-provided invalidation
remains the selected path.

GPU access counters make UVM migrate pageable memory that a GPU reads often
to that GPU's NUMA node. The driver's own allocations on the node (cudaMalloc,
managed memory) cannot be reclaimed by the kernel. Once they fill the node,
each migration unmaps the source pages, fails its `__GFP_THISNODE` allocation
with a page allocation failure warning and maps the pages back, several times
per second for an application that keeps reading the same host memory.
NVIDIA patch 0003 checks the destination node's free pages against its low
watermark first and leaves the pages in place when there is no room; the
notifications are still cleared. It also passes `__GFP_NOWARN` to these
allocations, whose failures are handled.

Patches 0004 and 0005 port two ATS fixes from later NVIDIA drivers. 0004
stops access counter servicing from populating ranges that migrate_vma
cannot migrate (for example file-backed mappings): the GPU just accessed
those pages, so they are already populated. ATS faults and the explicit
migration ioctl keep populating. 0005 makes a fault on a vma that cannot be
populated (for example VM_IO) cancel only those faults; before, the
replayable fault path treated it as a global error and cancelled the whole
fault batch.

Patch 0006 bounds one wait. When a process first uses a GPU, UVM creates its
internal channels and waits for the GPU to complete each one's init push. That
wait ends only on a channel error or UVM's global fatal error; it does not
check for signals (NVIDIA's own TODO in `uvm_spin_loop()`). A GPU that stops
processing work without reporting an error therefore leaves the registering
thread spinning forever with the locks every other process needs to open or
close `/dev/nvidia-uvm`, and the machine needs a reboot. On the AC922 this
happened to a V100 whose interrupt line had gone quiet after hours of ATS
traffic. After `uvm_channel_init_timeout_sec` (default 60 s) the patch sets the
global fatal error instead, which every UVM wait already checks, so all
waiters return and the module can be reloaded. It is global by design: a GPU
in that state cannot be trusted with the other GPUs' migrations either. See
the README's "Driver parameters".

## Not restored

VFIO pass-through of NVLink GPUs (`vfio_pci_nvlink2`, NPU IOMMU groups and
DMA windows), POWER8 NVLink1, pseries guest support.
