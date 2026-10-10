/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * nvlink2-npu: POWER9 NPU2 (NVLink2) support for GPU drivers.
 *
 * Internal definitions shared by the module's source files.
 */
#ifndef _NVLINK2_NPU_H
#define _NVLINK2_NPU_H

#include <linux/pci.h>
#include <linux/of.h>
#include <asm/mmu.h>		/* NV_MAX_NPUS */
#include <asm/pci.h>		/* exported API, declared by the kernel patch */
#include <asm/powernv.h>

#define NPU_DRV_NAME		"nvlink2-npu"

/* Maximum number of NVLinks per NPU */
#define NV_MAX_LINKS		6

/* Maximum number of ATSD register sets per NPU we use */
#define NV_NMMU_ATSD_REGS	8

/* One per NPU2 NVLink PHB ("ibm,ioda2-npu2-phb") */
struct npu {
	int index;			/* 0 .. npu_count - 1 */
	struct device_node *dn;		/* PHB device tree node */
	struct pci_controller *hose;
	u64 opal_id;			/* "ibm,opal-phbid" */

	/* Address translation shootdown (ATSD) registers */
	int mmio_atsd_count;
	unsigned long mmio_atsd_usage;	/* bit lock per register */
	__be64 __iomem *mmio_atsd_regs[NV_NMMU_ATSD_REGS];
};

extern struct npu npus[NV_MAX_NPUS];
extern int npu_count;

/* npu-main.c */
struct npu *npu_from_pdev(struct pci_dev *npdev);

/* npu-dev.c */
struct pci_dev *npu_get_pci_dev(struct device_node *dn);

/* npu-ats.c */
void npu_ats_exit(void);

/* npu-lpar.c */
void npu_map_all_gpus(void);

#endif /* _NVLINK2_NPU_H */
