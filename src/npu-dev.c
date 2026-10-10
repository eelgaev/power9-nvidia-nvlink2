// SPDX-License-Identifier: GPL-2.0-only
/*
 * NPU <-> GPU PCI device lookup through the device tree.
 *
 * From arch/powerpc/platforms/powernv/npu-dma.c (Linux v5.12),
 * Copyright Alistair Popple, IBM Corporation 2015.
 */
#include <linux/export.h>
#include <linux/of.h>
#include <linux/pci.h>
#include <asm/pci-bridge.h>

#include "npu.h"

struct pci_dev *npu_get_pci_dev(struct device_node *dn)
{
	struct pci_dn *pdn = PCI_DN(dn);

	if (!pdn)
		return NULL;

	return pci_get_domain_bus_and_slot(pci_domain_nr(pdn->phb->bus),
					   pdn->busno, pdn->devfn);
}

/* Given a NPU device get the associated PCI device. */
struct pci_dev *pnv_pci_get_gpu_dev(struct pci_dev *npdev)
{
	struct device_node *dn;
	struct pci_dev *gpdev;

	if (WARN_ON(!npdev))
		return NULL;

	if (WARN_ON(!npdev->dev.of_node))
		return NULL;

	/* Get associated PCI device */
	dn = of_parse_phandle(npdev->dev.of_node, "ibm,gpu", 0);
	if (!dn)
		return NULL;

	gpdev = npu_get_pci_dev(dn);
	of_node_put(dn);

	return gpdev;
}
EXPORT_SYMBOL(pnv_pci_get_gpu_dev);

/* Given the real PCI device get a linked NPU device. */
struct pci_dev *pnv_pci_get_npu_dev(struct pci_dev *gpdev, int index)
{
	struct device_node *dn;
	struct pci_dev *npdev;

	if (WARN_ON(!gpdev))
		return NULL;

	/* Not all PCI devices have device-tree nodes */
	if (!gpdev->dev.of_node)
		return NULL;

	/* Get associated PCI device */
	dn = of_parse_phandle(gpdev->dev.of_node, "ibm,npu", index);
	if (!dn)
		return NULL;

	npdev = npu_get_pci_dev(dn);
	of_node_put(dn);

	return npdev;
}
EXPORT_SYMBOL(pnv_pci_get_npu_dev);
