# Inventory of the removed NPU / NVLink2 code

Sources compared: RHEL 8 (`4.18.0-553.*.el8_10`, the last kernel known to
run NVLink2 with ATS on AC922), mainline v5.2 / v5.12 (before the two
removals) and RHEL 9.9 (`5.14.0-741.*.el9_9`, the target).

Classification:

- **a** — moves into a module as is
- **b** — moves into a module with adaptation
- **c** — needs the kernel (boot-time code, internal symbols, header contract)
- **—** — not needed for bare-metal NVLink2 with ATS

## arch/powerpc/platforms/powernv/npu-dma.c

| Code | What it does | Class | Where now |
|---|---|---|---|
| `pnv_pci_get_gpu_dev()`, `pnv_pci_get_npu_dev()`, `get_pci_dev()` | GPU <-> NPU device lookup via `ibm,gpu` / `ibm,npu` phandles | a | `src/npu-dev.c` |
| `struct npu`, `pnv_npu2_init()` | per-NPU state: ATSD registers (`ibm,mmio-atsd`), index | b | `src/npu-main.c`; state is module-owned instead of `pci_controller::npu` |
| `struct npu_context`, `pnv_npu2_init_context()`, `pnv_npu2_destroy_context()`, `pnv_npu2_release_context()` | per-mm ATS context, release callback, copro accounting | b | `src/npu-ats.c`; one `mmu_notifier_get_locked()` subscription per mm replaces `mm->context.npu_context` |
| `mmio_invalidate*()`, `acquire/release_atsd_reg()`, `get_atsd_launch_val()` | ATSD shootdowns to the GPUs | a | `src/npu-ats.c` |
| `pnv_npu2_mn_invalidate_range()`, `pnv_npu2_mn_change_pte()`, `pnv_npu2_mn_release()` | MMU notifier hooks | b | `->arch_invalidate_secondary_tlbs` (`->invalidate_range` and `->change_pte` no longer exist in 9.9) |
| nest MMU explicit flush (`ibm,nmmu-flush`, `flush_all_mm()`) | firmware-requested explicit nMMU flush | — | not used by AC922 firmware; would recurse into the notifier on 9.9 |
| `pnv_npu2_handle_fault()` | fault pages in for the GPU | b | `src/npu-ats.c` (`get_user_pages_remote()` signature, `mmap_lock`) |
| `pnv_npu2_map_lpar_dev()`, `pnv_npu2_unmap_lpar_dev()` | bind GPU to LPAR, OPAL context init | a | `src/npu-lpar.c` |
| `pnv_npu2_map_lpar()` at boot | map every GPU at PCI fixup | b | module init (`npu_map_all_gpus()`) |
| IOMMU / TCE: `pnv_npu_set_window()`, `pnv_npu_take_ownership()`, compound groups (`npu_comp`) | VFIO pass-through of NVLink GPUs | — | not restored |
| NVLink1 (POWER8) TCE kill | POWER8 only | — | not restored |

## arch/powerpc/platforms/powernv/pci-ioda.c, pci.c, pci.h

| Code | What it does | Class | Where now |
|---|---|---|---|
| `PNV_PHB_NPU_NVLINK`, `PNV_PHB_MODEL_NPU2`, `pnv_pci_init_npu_phb()`, probing `ibm,ioda2-npu2-phb` | create the NPU PHBs at boot | c | kernel patch 0001 |
| `pnv_ioda_setup_npu_PE()`, `pnv_pci_ioda_setup_nvlink()` | PE assignment for NPU links (shared per GPU, PE#0 reserved) | c | kernel patch 0001 (static, runs at PCI fixup) |
| `pnv_npu_ioda_controller_ops`, `pnv_npu_disable_device()` | NPU PHB controller ops | c | kernel patch 0001 |
| PELT-V skip for NPU PHBs | NPUs have no PELT-V | c | kernel patch 0001 |

All of these use internal, `__init` or static functions and data of the
powernv PCI code (`pnv_pci_init_ioda_phb()`, `pnv_ioda_setup_dev_PE()`,
`struct pnv_phb`) and run before any module can load.

## OPAL calls (opal-call.c, opal.h)

| Call | Status in 9.9 | Class | Where now |
|---|---|---|---|
| `opal_npu_init_context` | removed | c | patch 0002 (restored + exported) |
| `opal_npu_destroy_context` | removed | c | patch 0002 (restored + exported) |
| `opal_npu_map_lpar` | present (OpenCAPI), not exported | c | patch 0002 (exported) |

The OPAL entry trampoline (`opal_call()` / `__opal_call()`) is internal to
the kernel; a module cannot make OPAL calls without an exported wrapper.

## Headers

| Declaration | Class | Why |
|---|---|---|
| `pnv_pci_get_npu_dev()` etc. in `asm/pci.h` | c | NVIDIA's conftest compiles against `<linux/pci.h>` |
| `pnv_npu2_init_context()` etc., `NPU2_WRITE` in `asm/powernv.h` | c | NVIDIA's conftest compiles against `<asm/powernv.h>` and checks the callback type |
| `NV_MAX_NPUS` in `asm/book3s/64/mmu.h` | — | still present in 9.9 |

## Core mm / arch hooks

| Item | 9.9 status | Class |
|---|---|---|
| `mm_context_add_copro()` / `mm_context_remove_copro()` | inline in `asm/mmu_context.h` | a |
| `mm_context_t::copros` (global TLBIs reach the nest MMU) | present | a |
| `mm_context_t::npu_context` | removed | b (notifier subscription) |
| `radix__flush_*` exports | present | a |
| secondary TLB notification from radix range / mm flushes | present (`mmu_notifier_arch_invalidate_secondary_tlbs()`) | a |
| secondary TLB notification from `radix__flush_tlb_page_psize()` and `radix__flush_tlb_collapsed_pmd()` | **missing** | c — patch 0004 |
| `mmu_notifier_*`, `get_user_pages_remote()`, `of_get_ibm_chip_id()` | exported | a |
| memory hotplug for GPU memory (`/sys/devices/system/memory/probe`, `online_movable`, `offline_and_remove_memory()`) | present | — |
| 256 MiB memory blocks with coherent device memory | present (backported) | — |

## NVIDIA 550.54.15

| Item | Fix |
|---|---|
| `follow_pfn()` removed (RHEL 9.6+); `follow_pfnmap_start()` is GPL-only | nvidia patch 0001: conftest; without it, user I/O memory lookup (`cudaHostRegisterIoMemory`) fails cleanly, as in later NVIDIA drivers |
| `nvidia-drm` vs RHEL 9.9's DRM API | left out of the DKMS build (`apply.sh`); display/KMS only |
| `pnv_*` symbols live in the nvlink2-npu module | built into the kernel (`CONFIG_PPC_POWERNV_NVLINK2`); their symbol versions come from the kernel's `Module.symvers` |
| UVM's in-driver IBM ATS path | compiled out on kernels >= 5.9 (`UVM_CAN_USE_MMU_NOTIFIERS()`); the kernel-API path (`NV_PNV_NPU2_INIT_CONTEXT_CALLBACK_RETURNS_VOID`) is used, as on RHEL 8 |
