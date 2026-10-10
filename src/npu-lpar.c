// SPDX-License-Identifier: GPL-2.0-only
/*
 * Binding GPUs to the host partition (LPAR) and setting up their NPU
 * translation contexts in firmware.
 *
 * From arch/powerpc/platforms/powernv/npu-dma.c (Linux v5.12),
 * Copyright Alistair Popple, IBM Corporation 2015.
 */
#include <linux/export.h>
#include <linux/pci.h>
#include <asm/opal.h>
#include <asm/reg.h>

#include "npu.h"

int pnv_npu2_map_lpar_dev(struct pci_dev *gpdev, unsigned int lparid,
		unsigned long msr)
{
	int ret;
	struct pci_dev *npdev = pnv_pci_get_npu_dev(gpdev, 0);
	struct npu *npu;

	if (!npdev)
		return -ENODEV;

	npu = npu_from_pdev(npdev);
	pci_dev_put(npdev);
	if (!npu) {
		dev_info_once(&gpdev->dev, "Nvlink1 does not support contexts");
		return 0;
	}

	dev_dbg(&gpdev->dev, "Map LPAR opalid=%llu lparid=%u\n",
			npu->opal_id, lparid);
	/*
	 * Currently we only support radix and non-zero LPCR only makes sense
	 * for hash tables so skiboot expects the LPCR parameter to be a zero.
	 */
	ret = opal_npu_map_lpar(npu->opal_id, pci_dev_id(gpdev), lparid,
				0 /* LPCR bits */);
	if (ret) {
		dev_err(&gpdev->dev, "Error %d mapping device to LPAR\n", ret);
		return ret;
	}

	dev_dbg(&gpdev->dev, "init context opalid=%llu msr=%lx\n",
			npu->opal_id, msr);
	ret = opal_npu_init_context(npu->opal_id, 0/*__unused*/, msr,
				    pci_dev_id(gpdev));
	if (ret < 0)
		dev_err(&gpdev->dev, "Failed to init context: %d\n", ret);

	return 0;
}
EXPORT_SYMBOL_GPL(pnv_npu2_map_lpar_dev);

int pnv_npu2_unmap_lpar_dev(struct pci_dev *gpdev)
{
	int ret;
	struct pci_dev *npdev = pnv_pci_get_npu_dev(gpdev, 0);
	struct npu *npu;

	if (!npdev)
		return -ENODEV;

	npu = npu_from_pdev(npdev);
	pci_dev_put(npdev);
	if (!npu) {
		dev_info_once(&gpdev->dev, "Nvlink1 does not support contexts");
		return 0;
	}

	dev_dbg(&gpdev->dev, "destroy context opalid=%llu\n", npu->opal_id);
	ret = opal_npu_destroy_context(npu->opal_id, 0/*__unused*/,
				       pci_dev_id(gpdev));
	if (ret < 0) {
		dev_err(&gpdev->dev, "Failed to destroy context: %d\n", ret);
		return ret;
	}

	/* Set LPID to 0 anyway, just to be safe */
	dev_dbg(&gpdev->dev, "Map LPAR opalid=%llu lparid=0\n", npu->opal_id);
	ret = opal_npu_map_lpar(npu->opal_id, pci_dev_id(gpdev), 0 /*LPID*/,
				0 /* LPCR bits */);
	if (ret)
		dev_err(&gpdev->dev, "Error %d mapping device to LPAR\n", ret);

	return ret;
}
EXPORT_SYMBOL_GPL(pnv_npu2_unmap_lpar_dev);

/*
 * The kernel used to do this at boot for every device behind an IODA2 PHB
 * (pnv_npu2_map_lpar() from pnv_pci_ioda_setup_nvlink()); devices without
 * an NVLink are skipped by pnv_pci_get_npu_dev() returning NULL.
 */
void npu_map_all_gpus(void)
{
	struct pci_dev *gpdev = NULL;
	struct pci_dev *npdev;

	for_each_pci_dev(gpdev) {
		npdev = pnv_pci_get_npu_dev(gpdev, 0);
		if (!npdev)
			continue;
		pci_dev_put(npdev);

		pnv_npu2_map_lpar_dev(gpdev, 0, MSR_DR | MSR_PR | MSR_HV);
	}
}
