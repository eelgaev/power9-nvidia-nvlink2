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
```

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
(`pnv_npu2_init_context()`), and inside the driver. The in-driver one is
compiled out on kernels >= 5.9 (`UVM_CAN_USE_MMU_NOTIFIERS()`), so on 9.9
the kernel-API path is the only option — the same one RHEL 8 uses today.

## Not restored

VFIO pass-through of NVLink GPUs (`vfio_pci_nvlink2`, NPU IOMMU groups and
DMA windows), POWER8 NVLink1, pseries guest support.
