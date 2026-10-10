#!/usr/bin/env python3
"""Recreate the kernel patch series for a target from a pristine kernel tree.

Usage: make-patches.py <target> [--tree DIR] [--src-dir DIR]

<target>      kernel-patches/<target>/ directory (e.g. rhel-9.9); the .patch
              files are (re)written there.
--tree DIR    git checkout of the pristine kernel source (for rhel-9.9:
              linux-5.14.0-741.*.el9_9) whose HEAD is the unmodified tree.
              Reset the tree to its pristine base commit before rerunning.
--src-dir DIR sources of the nvlink2-npu module (default: ../src), copied
              into the tree by the module step.

Each step makes exact, checked string replacements and commits; `git
format-patch` then produces the .patch files. The patches are maintained as
.patch files in kernel-patches/<target>/; this script is how they were
generated and how to regenerate them after a rebase.
"""
import argparse
import os
import shutil
import subprocess
import sys

TREE = "."
SRC = "src"
PATCH_NAME = "eelgaev"
PATCH_EMAIL = "3100771+eelgaev@users.noreply.github.com"


def edit(path, old, new, count=1):
    with open(os.path.join(TREE, path)) as f:
        s = f.read()
    n = s.count(old)
    if n != count:
        sys.exit(f"{path}: expected {count} match(es), found {n}:\n{old}")
    s = s.replace(old, new)
    with open(os.path.join(TREE, path), "w") as f:
        f.write(s)


def commit(msg):
    # Keep personal identity and local timezone out of generated patches.
    env = os.environ.copy()
    for role in ("AUTHOR", "COMMITTER"):
        env[f"GIT_{role}_NAME"] = PATCH_NAME
        env[f"GIT_{role}_EMAIL"] = PATCH_EMAIL
    env["TZ"] = "UTC"
    subprocess.run(["git", "add", "-A"], cwd=TREE, check=True)
    subprocess.run(["git", "commit", "-q", "-s", "-F", "-"], cwd=TREE,
                   input=msg.encode(), env=env, check=True)


# ---------------------------------------------------------------------------
# 0001: NPU2 NVLink PHB probing and PE setup
# ---------------------------------------------------------------------------
def step_0001_phb_probing():
    IODA = "arch/powerpc/platforms/powernv/pci-ioda.c"
    PCI_C = "arch/powerpc/platforms/powernv/pci.c"
    PCI_H = "arch/powerpc/platforms/powernv/pci.h"

    edit(PCI_H, """enum pnv_phb_type {
	PNV_PHB_IODA1,
	PNV_PHB_IODA2,
	PNV_PHB_NPU_OCAPI,
};""", """enum pnv_phb_type {
	PNV_PHB_IODA1,
	PNV_PHB_IODA2,
	PNV_PHB_NPU_NVLINK,
	PNV_PHB_NPU_OCAPI,
};""")
    edit(PCI_H, """	PNV_PHB_MODEL_PHB3,
};""", """	PNV_PHB_MODEL_PHB3,
	PNV_PHB_MODEL_NPU2,
};""")
    edit(PCI_H, """extern void pnv_pci_init_ioda2_phb(struct device_node *np);
""", """extern void pnv_pci_init_ioda2_phb(struct device_node *np);
extern void pnv_pci_init_npu_phb(struct device_node *np);
""")

    edit(PCI_C, """	/* Look for NPU2 OpenCAPI PHBs */""", """	/*
	 * Look for NPU2 NVLink PHBs. The ATS / context management API that
	 * GPU drivers use on top of them (pnv_npu2_init_context() and
	 * friends) is provided by the nvlink2-npu module
	 * (CONFIG_PPC_POWERNV_NVLINK2).
	 */
	for_each_compatible_node(np, NULL, "ibm,ioda2-npu2-phb")
		pnv_pci_init_npu_phb(np);

	/* Look for NPU2 OpenCAPI PHBs */""")

    edit(IODA, """static const char * const pnv_phb_names[] = { "IODA1", "IODA2", "NPU_OCAPI" };""",
         """static const char * const pnv_phb_names[] = { "IODA1", "IODA2", "NPU_NVLINK",
					      "NPU_OCAPI" };""")
    edit(IODA, """	if (phb->type != PNV_PHB_NPU_OCAPI)
		pnv_ioda_unset_peltv(phb, pe, parent);""",
         """	if (phb->type != PNV_PHB_NPU_NVLINK && phb->type != PNV_PHB_NPU_OCAPI)
		pnv_ioda_unset_peltv(phb, pe, parent);""")
    edit(IODA, """	if (phb->type != PNV_PHB_NPU_OCAPI)
		pnv_ioda_set_peltv(phb, pe, true);""",
         """	if (phb->type != PNV_PHB_NPU_NVLINK && phb->type != PNV_PHB_NPU_OCAPI)
		pnv_ioda_set_peltv(phb, pe, true);""")

    # NPU PE setup, restored from v5.12 (removed by commit 562d1e207d32). The
    # GPU lookup helper is a private copy; the exported pnv_pci_get_gpu_dev()
    # lives in the module.
    edit(IODA, """static void pnv_pci_ioda_dma_dev_setup(struct pci_dev *pdev)
{""", """static struct pci_dev *pnv_npu_get_gpu_dev(struct pci_dev *npdev)
{
	struct device_node *dn;
	struct pci_dn *pdn;
	struct pci_dev *gpdev;

	if (!npdev->dev.of_node)
		return NULL;

	dn = of_parse_phandle(npdev->dev.of_node, "ibm,gpu", 0);
	if (!dn)
		return NULL;

	pdn = PCI_DN(dn);
	gpdev = pdn ? pci_get_domain_bus_and_slot(pci_domain_nr(pdn->phb->bus),
						  pdn->busno, pdn->devfn) : NULL;
	of_node_put(dn);

	return gpdev;
}

static struct pnv_ioda_pe *pnv_ioda_setup_npu_PE(struct pci_dev *npu_pdev)
{
	int pe_num, found_pe = false, rc;
	long rid;
	struct pnv_ioda_pe *pe;
	struct pci_dev *gpu_pdev, *peer;
	struct pci_dn *npu_pdn;
	struct pnv_phb *phb = pci_bus_to_pnvhb(npu_pdev->bus);

	/*
	 * Intentionally leak a reference on the npu device (for
	 * nvlink only; this is not an opencapi path) to make sure it
	 * never goes away, as it's been the case all along and some
	 * work is needed otherwise.
	 */
	pci_dev_get(npu_pdev);

	/*
	 * Due to a hardware errata PE#0 on the NPU is reserved for
	 * error handling. This means we only have three PEs remaining
	 * which need to be assigned to four links, implying some
	 * links must share PEs.
	 *
	 * To achieve this we assign PEs such that NPUs linking the
	 * same GPU get assigned the same PE.
	 */
	gpu_pdev = pnv_npu_get_gpu_dev(npu_pdev);
	for (pe_num = 0; pe_num < phb->ioda.total_pe_num; pe_num++) {
		pe = &phb->ioda.pe_array[pe_num];
		if (!pe->pdev)
			continue;

		peer = pnv_npu_get_gpu_dev(pe->pdev);
		pci_dev_put(peer);
		if (peer == gpu_pdev) {
			/*
			 * This device has the same peer GPU so should
			 * be assigned the same PE as the existing
			 * peer NPU.
			 */
			dev_info(&npu_pdev->dev,
				"Associating to existing PE %x\\n", pe_num);
			npu_pdn = pci_get_pdn(npu_pdev);
			rid = npu_pdev->bus->number << 8 | npu_pdn->devfn;
			npu_pdn->pe_number = pe_num;
			phb->ioda.pe_rmap[rid] = pe->pe_number;
			pe->device_count++;

			/* Map the PE to this link */
			rc = opal_pci_set_pe(phb->opal_id, pe_num, rid,
					OpalPciBusAll,
					OPAL_COMPARE_RID_DEVICE_NUMBER,
					OPAL_COMPARE_RID_FUNCTION_NUMBER,
					OPAL_MAP_PE);
			WARN_ON(rc != OPAL_SUCCESS);
			found_pe = true;
			break;
		}
	}
	pci_dev_put(gpu_pdev);

	if (!found_pe)
		/*
		 * Could not find an existing PE so allocate a new
		 * one.
		 */
		return pnv_ioda_setup_dev_PE(npu_pdev);
	else
		return pe;
}

static void pnv_pci_ioda_setup_nvlink(void)
{
	struct pci_controller *hose;
	struct pci_dev *pdev;
	struct pnv_phb *phb;

	list_for_each_entry(hose, &hose_list, list_node) {
		phb = hose->private_data;
		if (phb->type != PNV_PHB_NPU_NVLINK)
			continue;

		/* PE#0 is needed for error reporting */
		pnv_ioda_reserve_pe(phb, 0);
		list_for_each_entry(pdev, &hose->bus->devices, bus_list)
			pnv_ioda_setup_npu_PE(pdev);
	}
}

static void pnv_pci_ioda_dma_dev_setup(struct pci_dev *pdev)
{""")

    edit(IODA, """static void pnv_pci_ioda_fixup(void)
{
""", """static void pnv_pci_ioda_fixup(void)
{
	pnv_pci_ioda_setup_nvlink();
""")
    edit(IODA, """	case PNV_PHB_NPU_OCAPI:
		break;
	default:
		WARN_ON(1);""", """	case PNV_PHB_NPU_NVLINK:
	case PNV_PHB_NPU_OCAPI:
		break;
	default:
		WARN_ON(1);""")
    edit(IODA, """static void pnv_pci_ioda_shutdown(struct pci_controller *hose)
{""", """static void pnv_npu_disable_device(struct pci_dev *pdev)
{
	struct eeh_dev *edev = pci_dev_to_eeh_dev(pdev);
	struct eeh_pe *eehpe = edev ? edev->pe : NULL;

	if (eehpe && eeh_ops && eeh_ops->reset)
		eeh_ops->reset(eehpe, EEH_RESET_HOT);
}

static void pnv_pci_ioda_shutdown(struct pci_controller *hose)
{""")
    edit(IODA, """static const struct pci_controller_ops pnv_npu_ocapi_ioda_controller_ops = {""",
         """static const struct pci_controller_ops pnv_npu_ioda_controller_ops = {
	.enable_device_hook	= pnv_pci_enable_device_hook,
	.window_alignment	= pnv_pci_window_alignment,
	.reset_secondary_bus	= pnv_pci_reset_secondary_bus,
	.shutdown		= pnv_pci_ioda_shutdown,
	.disable_device		= pnv_npu_disable_device,
};

static const struct pci_controller_ops pnv_npu_ocapi_ioda_controller_ops = {""")
    edit(IODA, """	else if (of_device_is_compatible(np, "ibm,power8-pciex"))
		phb->model = PNV_PHB_MODEL_PHB3;
""", """	else if (of_device_is_compatible(np, "ibm,power8-pciex"))
		phb->model = PNV_PHB_MODEL_PHB3;
	else if (of_device_is_compatible(np, "ibm,power9-npu-pciex"))
		phb->model = PNV_PHB_MODEL_NPU2;
""")
    edit(IODA, """	switch (phb->type) {
	case PNV_PHB_NPU_OCAPI:
		hose->controller_ops = pnv_npu_ocapi_ioda_controller_ops;""",
         """	switch (phb->type) {
	case PNV_PHB_NPU_NVLINK:
		hose->controller_ops = pnv_npu_ioda_controller_ops;
		break;
	case PNV_PHB_NPU_OCAPI:
		hose->controller_ops = pnv_npu_ocapi_ioda_controller_ops;""")
    edit(IODA, """void __init pnv_pci_init_npu2_opencapi_phb(struct device_node *np)""",
         """void __init pnv_pci_init_npu_phb(struct device_node *np)
{
	pnv_pci_init_ioda_phb(np, 0, PNV_PHB_NPU_NVLINK);
}

void __init pnv_pci_init_npu2_opencapi_phb(struct device_node *np)""")

    commit("""powerpc/powernv: restore NVLink2 NPU PHB probing and PE setup

Commit 562d1e207d32 ("powerpc/powernv: remove the nvlink support")
dropped the probing of the POWER9 NPU2 NVLink PHBs ("ibm,ioda2-npu2-phb").
Without it the NPU PCI devices (one per NVLink brick, [1014:04ea]) never
appear, so GPU drivers cannot train the links or use them, and the CPU
side of NVLink (coherent GPU memory, ATS) is unreachable.

Restore, for NPU2 only:
 - PHB type PNV_PHB_NPU_NVLINK / model PNV_PHB_MODEL_NPU2 and probing;
 - the NPU controller ops (no DMA setup: NVLink DMA is not translated by
   the NPU PE);
 - PE assignment at fixup time, sharing one PE between the links of the
   same GPU (PE#0 is reserved due to a hardware erratum).

Not restored: POWER8 NVLink1, IOMMU group / VFIO pass-through plumbing
(npu_comp) and the NPU context / ATS API, which is provided by the
nvlink2-npu module (see the next patches).

The restored code is from v5.12 and was written by Alistair Popple,
Alexey Kardashevskiy, Frederic Barrat and Reza Arbab among others.
""")


# ---------------------------------------------------------------------------
# 0002: NPU OPAL calls
# ---------------------------------------------------------------------------
def step_0002_opal_calls():
    edit("arch/powerpc/include/asm/opal.h", """int64_t opal_invalid_call(void);
int64_t opal_npu_map_lpar(""", """int64_t opal_invalid_call(void);
int64_t opal_npu_destroy_context(uint64_t phb_id, uint64_t pid, uint64_t bdf);
int64_t opal_npu_init_context(uint64_t phb_id, int pasid, uint64_t msr,
			uint64_t bdf);
int64_t opal_npu_map_lpar(""")
    edit("arch/powerpc/platforms/powernv/opal-call.c",
         """OPAL_CALL(opal_npu_map_lpar,			OPAL_NPU_MAP_LPAR);""",
         """OPAL_CALL(opal_npu_init_context,		OPAL_NPU_INIT_CONTEXT);
OPAL_CALL(opal_npu_destroy_context,		OPAL_NPU_DESTROY_CONTEXT);
OPAL_CALL(opal_npu_map_lpar,			OPAL_NPU_MAP_LPAR);""")
    edit("arch/powerpc/platforms/powernv/opal.c", """EXPORT_SYMBOL_GPL(opal_error_code);
""", """EXPORT_SYMBOL_GPL(opal_error_code);
/* NVLink2 context management, used by the nvlink2-npu module */
EXPORT_SYMBOL_GPL(opal_npu_init_context);
EXPORT_SYMBOL_GPL(opal_npu_destroy_context);
EXPORT_SYMBOL_GPL(opal_npu_map_lpar);
""")
    commit("""powerpc/powernv: restore and export the NPU2 context OPAL calls

OPAL_NPU_INIT_CONTEXT and OPAL_NPU_DESTROY_CONTEXT wrappers were removed
with the NVLink support in commit 562d1e207d32; opal_npu_map_lpar() stayed
for OpenCAPI but is not exported. The OPAL call trampoline is internal to
the kernel, so a module cannot issue these calls itself.

Restore the two wrappers and export all three (GPL) for the nvlink2-npu
module, which binds GPUs to the host LPAR and sets up their NPU
translation contexts.
""")


# ---------------------------------------------------------------------------
# 0003: prototypes of the module-provided API
# ---------------------------------------------------------------------------
def step_0003_declarations():
    edit("arch/powerpc/include/asm/pci.h", """#endif	/* __KERNEL__ */

#endif /* __ASM_POWERPC_PCI_H */""", """#endif	/* __KERNEL__ */

/*
 * NVLink2 NPU helpers. Provided by the nvlink2-npu module
 * (CONFIG_PPC_POWERNV_NVLINK2); declared here because GPU drivers look for
 * them in this header.
 */
extern struct pci_dev *pnv_pci_get_gpu_dev(struct pci_dev *npdev);
extern struct pci_dev *pnv_pci_get_npu_dev(struct pci_dev *gpdev, int index);
extern int pnv_npu2_map_lpar_dev(struct pci_dev *gpdev, unsigned int lparid,
		unsigned long msr);
extern int pnv_npu2_unmap_lpar_dev(struct pci_dev *gpdev);

#endif /* __ASM_POWERPC_PCI_H */""")
    edit("arch/powerpc/include/asm/powernv.h", """#ifdef CONFIG_PPC_POWERNV
extern void powernv_set_nmmu_ptcr(unsigned long ptcr);
""", """#ifdef CONFIG_PPC_POWERNV
extern void powernv_set_nmmu_ptcr(unsigned long ptcr);

/*
 * NVLink2 address translation services (ATS). Provided by the nvlink2-npu
 * module (CONFIG_PPC_POWERNV_NVLINK2); declared here because GPU drivers
 * look for them in this header.
 */
#define NPU2_WRITE 1
struct npu_context;
struct pci_dev;
extern struct npu_context *pnv_npu2_init_context(struct pci_dev *gpdev,
			unsigned long flags,
			void (*cb)(struct npu_context *, void *),
			void *priv);
extern void pnv_npu2_destroy_context(struct npu_context *context,
				struct pci_dev *gpdev);
extern int pnv_npu2_handle_fault(struct npu_context *context, uintptr_t *ea,
				unsigned long *flags, unsigned long *status,
				int count);
""")
    commit("""powerpc: declare the NVLink2 NPU API provided by nvlink2-npu

The NPU2 ATS / context API (pnv_npu2_init_context() etc.) and the NPU
device lookup helpers were removed in commits 7eb3cf761927 and
562d1e207d32. They are implemented by the nvlink2-npu module (see the
next patch), with the same names and signatures as before.

Declare them in the headers they used to live in. GPU drivers detect the
API by compiling against these declarations (e.g. NVIDIA's conftest
checks <linux/pci.h> and <asm/powernv.h>); the symbols themselves are
resolved against the module at load time.
""")


# ---------------------------------------------------------------------------
# 0004: secondary TLB invalidation on single-page radix flushes
# ---------------------------------------------------------------------------
def step_0004_radix_secondary_tlbs():
    RADIX = "arch/powerpc/mm/book3s64/radix_tlb.c"
    edit(RADIX, """		} else if (cputlb_use_tlbie())
			_tlbie_va(vmaddr, pid, psize, RIC_FLUSH_TLB);
		else
			_tlbiel_va_multicast(mm, vmaddr, pid, psize, RIC_FLUSH_TLB);
	}
	preempt_enable();
}""", """		} else if (cputlb_use_tlbie())
			_tlbie_va(vmaddr, pid, psize, RIC_FLUSH_TLB);
		else
			_tlbiel_va_multicast(mm, vmaddr, pid, psize, RIC_FLUSH_TLB);
	}
	preempt_enable();
	mmu_notifier_arch_invalidate_secondary_tlbs(mm, vmaddr,
				vmaddr + (1UL << mmu_psize_to_shift(psize)));
}""")
    edit(RADIX, """			_tlbiel_va_range_multicast(mm,
					addr, end, pid, PAGE_SIZE, mmu_virtual_psize, true);
	}

	preempt_enable();
}
#endif /* CONFIG_TRANSPARENT_HUGEPAGE */""", """			_tlbiel_va_range_multicast(mm,
					addr, end, pid, PAGE_SIZE, mmu_virtual_psize, true);
	}

	preempt_enable();
	mmu_notifier_arch_invalidate_secondary_tlbs(mm, addr, end);
}
#endif /* CONFIG_TRANSPARENT_HUGEPAGE */""")
    commit("""powerpc/64s/radix: notify secondary TLBs on single-page flushes

Since the backport of upstream commit 1af5a8109904 ("mmu_notifiers:
rename invalidate_range notifier") and its series, secondary TLBs (devices
doing ATS against the CPU page tables) are invalidated from the
architecture TLB flush code via mmu_notifier_arch_invalidate_secondary_tlbs()
instead of from the generic mm code. On radix this is called for mm-wide
and range flushes, but not from radix__flush_tlb_page_psize() or
radix__flush_tlb_collapsed_pmd().

Single-page flushes are what ptep_clear_flush() uses: copy-on-write after
fork, page migration, reclaim and KSM. A device caching a translation for
such a page (e.g. a GPU using NVLink2 ATS) would keep accessing the old
page after the CPU has moved on, which silently corrupts memory.

Call the notifier from both functions, as the range flushes already do.
This is a no-op unless a secondary-TLB notifier is registered on the mm.
""")


# ---------------------------------------------------------------------------
# 0005: the nvlink2-npu module
# ---------------------------------------------------------------------------
MODULE_FILES = ("npu.h", "npu-main.c", "npu-dev.c", "npu-lpar.c", "npu-ats.c")
POWERNV = "arch/powerpc/platforms/powernv"


def step_0005_module():
    # The module sources, from the repository's src/ directory.
    for f in MODULE_FILES:
        src = os.path.join(SRC, f)
        dst = os.path.join(TREE, POWERNV, f)
        if not os.path.isfile(src):
            sys.exit(f"{src}: not found")
        if os.path.exists(dst):
            sys.exit(f"{dst}: already exists (tree not pristine?)")
        shutil.copy(src, dst)

    edit(f"{POWERNV}/Kconfig", """	default y

config OPAL_PRD""", """	default y

config PPC_POWERNV_NVLINK2
	tristate "IBM POWER9 NVLink2 NPU support (NPU2)"
	depends on PPC_POWERNV && PCI
	default m
	help
	  Support for the POWER9 NVLink2 NPU (nest memory management unit,
	  address translation services): NPU context management, ATSD
	  invalidations and the NPU <-> GPU device lookup for GPU drivers
	  (e.g. NVIDIA V100 on AC922-class systems). Builds as the
	  nvlink2-npu module and is a no-op on systems without NPU2 NVLink
	  PHBs.

config OPAL_PRD""")
    edit(f"{POWERNV}/Makefile", """obj-$(CONFIG_PPC_SECURE_BOOT) += opal-secvar.o
""", """obj-$(CONFIG_PPC_SECURE_BOOT) += opal-secvar.o

nvlink2-npu-y			:= npu-main.o npu-dev.o npu-lpar.o npu-ats.o
obj-$(CONFIG_PPC_POWERNV_NVLINK2) += nvlink2-npu.o
""")
    commit("""powerpc/powernv: add the nvlink2-npu module for NPU2 GPU support

Add the NPU2 support for GPU drivers as the nvlink2-npu module
(CONFIG_PPC_POWERNV_NVLINK2, default m on PowerNV):

 - the NPU API Linux removed in v5.3 / v5.13, with the original names and
   signatures: pnv_pci_get_gpu_dev() / pnv_pci_get_npu_dev() (device-tree
   NPU <-> GPU lookup) and pnv_npu2_init_context() /
   pnv_npu2_destroy_context() / pnv_npu2_handle_fault() (per-mm ATS
   contexts and address translation shootdowns towards the GPUs);
 - binding the GPUs to the host LPAR via the OPAL context calls restored
   in the previous patches;
 - discovery of the NPU2 NVLink PHBs, their MMIO ATSD registers and the
   mapping of all GPUs at module load.

Based on arch/powerpc/platforms/powernv/npu-dma.c (Linux v5.2 / v5.12,
RHEL 8), written by Alistair Popple, Alexey Kardashevskiy, Frederic
Barrat and Reza Arbab among others, with the per-mm context carried by
the mm's mmu_notifier subscription (mmu_notifier_get_locked()) and
invalidations arriving through ->arch_invalidate_secondary_tlbs(), which
the radix TLB flush code calls.
""")


def step_0006_npu_eeh_ordering():
    edit(f"{POWERNV}/pci-ioda.c", "#include <asm/sections.h>\n",
         "#include <asm/eeh.h>\n#include <asm/sections.h>\n")
    edit(f"{POWERNV}/eeh-powernv.c", """	/* already configured? */
	if (edev->pdev) {""", """	/* NPU PEs are assigned in the final PCI fixup, after device addition. */
	if (phb->type == PNV_PHB_NPU_NVLINK &&
	    pdn->pe_number == IODA_INVALID_PE)
		return NULL;

	/* already configured? */
	if (edev->pdev) {""")
    edit(f"{POWERNV}/pci-ioda.c", """		list_for_each_entry(pdev, &hose->bus->devices, bus_list)
			pnv_ioda_setup_npu_PE(pdev);
	}
}""", """		list_for_each_entry(pdev, &hose->bus->devices, bus_list)
			pnv_ioda_setup_npu_PE(pdev);

#ifdef CONFIG_EEH
		/* Complete deferred EEH registration with valid PE mappings. */
		list_for_each_entry(pdev, &hose->bus->devices, bus_list)
			if (!pci_dev_to_eeh_dev(pdev))
				eeh_probe_device(pdev);
#endif
	}
}""")
    commit("""powerpc/powernv: defer NPU EEH probing until PEs are assigned

pcibios_init() adds PCI devices before calling the final platform fixup.
The restored NPU controller has no DMA device setup hook, and assigns
its PEs only in pnv_pci_ioda_setup_nvlink(). The earlier EEH probe thus
records IODA_INVALID_PE (-1) in pe_config_addr, even though the final
fixup subsequently fills in the PCI reverse map.

An all-ones config read then queries the invalid EEH PE. The IODA state
helper returns permanently unavailable without consulting firmware.
Unlike the RHEL 8 kernel, RHEL 9.9 can treat EEH_STATE_NOT_SUPPORT as
a failure, triggering recovery and removal of live NPU devices.

Defer probing of NVLink NPU devices with unassigned PEs, then complete
their EEH registration immediately after NPU PE setup. Do not change
the generic EEH failure policy or any other PHB type.
""")


TARGETS = {
    "rhel-9.9": (step_0001_phb_probing, step_0002_opal_calls,
                 step_0003_declarations, step_0004_radix_secondary_tlbs,
                 step_0005_module, step_0006_npu_eeh_ordering),
}


def main():
    global TREE, SRC
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("target", choices=sorted(TARGETS))
    ap.add_argument("--tree", default=".", help="pristine kernel git tree")
    ap.add_argument("--src-dir", default=os.path.join(here, "..", "src"),
                    help="nvlink2-npu module sources (default: ../src)")
    args = ap.parse_args()

    TREE = os.path.abspath(args.tree)
    if not os.path.isdir(os.path.join(TREE, ".git")):
        sys.exit(f"{TREE}: not a git tree")
    SRC = os.path.abspath(args.src_dir)

    for step in TARGETS[args.target]:
        step()

    outdir = os.path.join(here, args.target)
    subprocess.run(["git", "format-patch", "-o", outdir,
                    "HEAD~%d..HEAD" % len(TARGETS[args.target])],
                   cwd=TREE, check=True)
    print("done: %s" % outdir)


if __name__ == "__main__":
    main()
