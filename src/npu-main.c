// SPDX-License-Identifier: GPL-2.0-only
/*
 * nvlink2-npu: POWER9 NPU2 (NVLink2) support for GPU drivers.
 *
 * Provides the NPU API that Linux removed in v5.3 / v5.13 (the ATS context
 * management of pnv_npu2_init_context() and friends, and the NPU device
 * lookup helpers), with the same names and signatures, for kernels that
 * still probe the NPU2 NVLink PHBs (see kernel-patches/).
 *
 * Based on arch/powerpc/platforms/powernv/npu-dma.c,
 * Copyright Alistair Popple, IBM Corporation 2015,
 * and the work of its many contributors, see CREDITS.
 */
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/pci.h>
#include <asm/pci-bridge.h>

#include "npu.h"

struct npu npus[NV_MAX_NPUS];
int npu_count;

/* Find our NPU for an NPU PCI device (a device on an NPU PHB). */
struct npu *npu_from_pdev(struct pci_dev *npdev)
{
	struct pci_controller *hose = pci_bus_to_host(npdev->bus);
	int i;

	for (i = 0; i < npu_count; i++)
		if (npus[i].hose == hose)
			return &npus[i];

	return NULL;
}

static struct pci_controller *npu_find_hose(struct device_node *dn)
{
	struct pci_bus *bus = NULL;
	struct pci_controller *hose;

	while ((bus = pci_find_next_bus(bus))) {
		hose = pci_bus_to_host(bus);
		if (hose && hose->dn == dn)
			return hose;
	}

	return NULL;
}

static int npu_init_one(struct device_node *dn)
{
	struct npu *npu;
	u64 mmio_atsd;
	int i;

	if (npu_count >= NV_MAX_NPUS) {
		pr_warn(NPU_DRV_NAME ": more than %d NPUs, ignoring %pOF\n",
			NV_MAX_NPUS, dn);
		return -ENOSPC;
	}

	npu = &npus[npu_count];
	npu->hose = npu_find_hose(dn);
	if (!npu->hose) {
		/* The kernel does not probe NPU PHBs: the patch is missing */
		pr_err(NPU_DRV_NAME ": %pOF: NPU PHB not probed by the kernel\n",
		       dn);
		return -ENODEV;
	}

	if (of_property_read_u64(dn, "ibm,opal-phbid", &npu->opal_id)) {
		pr_err(NPU_DRV_NAME ": %pOF: no ibm,opal-phbid\n", dn);
		return -ENODEV;
	}

	/*
	 * Firmware asking for explicit nest MMU flushes is not supported:
	 * the copro accounting (global TLB invalidations) is used instead,
	 * as on every POWER9 firmware that ships with AC922 systems.
	 */
	if (of_property_read_bool(dn, "ibm,nmmu-flush"))
		pr_warn(NPU_DRV_NAME ": %pOF: ibm,nmmu-flush ignored\n", dn);

	for (i = 0; i < ARRAY_SIZE(npu->mmio_atsd_regs) &&
			!of_property_read_u64_index(dn, "ibm,mmio-atsd",
				i, &mmio_atsd); i++) {
		npu->mmio_atsd_regs[i] = ioremap(mmio_atsd, 32);
		if (!npu->mmio_atsd_regs[i])
			break;
	}
	npu->mmio_atsd_count = i;
	npu->mmio_atsd_usage = 0;
	npu->dn = of_node_get(dn);
	npu->index = npu_count++;

	pr_info(NPU_DRV_NAME ": NPU%d (PHB#%04x, %pOF): %d MMIO ATSD registers\n",
		npu->index, npu->hose->global_number, dn, npu->mmio_atsd_count);

	return 0;
}

static void npu_free_all(void)
{
	int i, j;

	for (i = 0; i < npu_count; i++) {
		for (j = 0; j < npus[i].mmio_atsd_count; j++)
			iounmap(npus[i].mmio_atsd_regs[j]);
		of_node_put(npus[i].dn);
	}
	npu_count = 0;
}

static int __init npu_module_init(void)
{
	struct device_node *dn;

	for_each_compatible_node(dn, NULL, "ibm,ioda2-npu2-phb")
		npu_init_one(dn);

	if (!npu_count) {
		pr_info(NPU_DRV_NAME ": no usable NVLink2 NPU found\n");
		return -ENODEV;
	}

	npu_map_all_gpus();

	return 0;
}

static void __exit npu_module_exit(void)
{
	npu_ats_exit();
	npu_free_all();
}

module_init(npu_module_init);
module_exit(npu_module_exit);

MODULE_DESCRIPTION("POWER9 NPU2 NVLink2 support (ATS contexts, NPU lookup)");
MODULE_AUTHOR("Alistair Popple (original npu-dma.c), see CREDITS");
MODULE_LICENSE("GPL v2");
