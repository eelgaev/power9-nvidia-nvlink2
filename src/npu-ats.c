// SPDX-License-Identifier: GPL-2.0-only
/*
 * NVLink2 address translation services (ATS): per-mm NPU contexts and
 * address translation shootdowns (ATSD) towards the GPUs.
 *
 * From arch/powerpc/platforms/powernv/npu-dma.c (Linux v5.2 and RHEL 8),
 * Copyright Alistair Popple, IBM Corporation 2015.
 *
 * Changes from the in-kernel version:
 *  - the per-mm context is the mm's mmu_notifier subscription for our ops
 *    (mmu_notifier_get_locked()/mmu_notifier_put()) instead of the removed
 *    mm->context.npu_context field;
 *  - invalidations arrive through ->arch_invalidate_secondary_tlbs(), which
 *    the radix TLB flush code calls, instead of ->invalidate_range();
 *  - only the copro mode is supported (no "ibm,nmmu-flush"): explicit
 *    flush_all_mm() calls would now recurse into our own notifier.
 */
#include <linux/export.h>
#include <linux/mm.h>
#include <linux/mmu_context.h>
#include <linux/mmu_notifier.h>
#include <linux/sched/mm.h>
#include <linux/sizes.h>
#include <linux/slab.h>
#include <asm/mmu_context.h>
#include <asm/reg.h>
#include <asm/tlbflush.h>

#include "npu.h"

/* Protects npu_context::users and the copro accounting it drives. */
static DEFINE_SPINLOCK(npu_context_lock);

struct npu_context {
	struct mm_struct *mm;
	struct pci_dev *npdev[NV_MAX_NPUS][NV_MAX_LINKS];
	struct mmu_notifier mn;

	/* Number of GPUs (init_context calls) using this context */
	unsigned int users;

	/* Callback to stop translation requests on a given GPU */
	void (*release_cb)(struct npu_context *context, void *priv);

	/*
	 * Private pointer passed to the above callback for usage by
	 * device drivers.
	 */
	void *priv;
};

#define mn_to_npu_context(x) container_of(x, struct npu_context, mn)

struct mmio_atsd_reg {
	struct npu *npu;
	int reg;
};

/*
 * Find a free MMIO ATSD register and mark it in use. Return -ENOSPC
 * if none are available.
 */
static int get_mmio_atsd_reg(struct npu *npu)
{
	int i;

	for (i = 0; i < npu->mmio_atsd_count; i++) {
		if (!test_bit(i, &npu->mmio_atsd_usage))
			if (!test_and_set_bit_lock(i, &npu->mmio_atsd_usage))
				return i;
	}

	return -ENOSPC;
}

static void put_mmio_atsd_reg(struct npu *npu, int reg)
{
	clear_bit_unlock(reg, &npu->mmio_atsd_usage);
}

/* MMIO ATSD register offsets */
#define XTS_ATSD_LAUNCH 0
#define XTS_ATSD_AVA    1
#define XTS_ATSD_STAT   2

static unsigned long get_atsd_launch_val(unsigned long pid, unsigned long psize)
{
	unsigned long launch = 0;

	if (psize == MMU_PAGE_COUNT) {
		/* IS set to invalidate entire matching PID */
		launch |= PPC_BIT(12);
	} else {
		/* AP set to invalidate region of psize */
		launch |= (u64)mmu_get_ap(psize) << PPC_BITLSHIFT(17);
	}

	/* PRS set to process-scoped */
	launch |= PPC_BIT(13);

	/* PID */
	launch |= pid << PPC_BITLSHIFT(38);

	/* Leave "No flush" (bit 39) 0 so every ATSD performs a flush */

	return launch;
}

static void mmio_atsd_regs_write(struct mmio_atsd_reg
			mmio_atsd_reg[NV_MAX_NPUS], unsigned long offset,
			unsigned long val)
{
	struct npu *npu;
	int i, reg;

	for (i = 0; i < npu_count; i++) {
		reg = mmio_atsd_reg[i].reg;
		if (reg < 0)
			continue;

		npu = mmio_atsd_reg[i].npu;
		__raw_writeq_be(val, npu->mmio_atsd_regs[reg] + offset);
	}
}

static void mmio_invalidate_pid(struct mmio_atsd_reg mmio_atsd_reg[NV_MAX_NPUS],
				unsigned long pid)
{
	unsigned long launch = get_atsd_launch_val(pid, MMU_PAGE_COUNT);

	/* Invalidating the entire process doesn't use a va */
	mmio_atsd_regs_write(mmio_atsd_reg, XTS_ATSD_LAUNCH, launch);
}

static void mmio_invalidate_range(struct mmio_atsd_reg
			mmio_atsd_reg[NV_MAX_NPUS], unsigned long pid,
			unsigned long start, unsigned long psize)
{
	unsigned long launch = get_atsd_launch_val(pid, psize);

	/* Write all VAs first */
	mmio_atsd_regs_write(mmio_atsd_reg, XTS_ATSD_AVA, start);

	/* Issue one barrier for all address writes */
	eieio();

	/* Launch */
	mmio_atsd_regs_write(mmio_atsd_reg, XTS_ATSD_LAUNCH, launch);
}

static void mmio_invalidate_wait(
	struct mmio_atsd_reg mmio_atsd_reg[NV_MAX_NPUS])
{
	struct npu *npu;
	int i, reg;

	/* Wait for all invalidations to complete */
	for (i = 0; i < npu_count; i++) {
		if (mmio_atsd_reg[i].reg < 0)
			continue;

		/* Wait for completion */
		npu = mmio_atsd_reg[i].npu;
		reg = mmio_atsd_reg[i].reg;
		while (__raw_readq(npu->mmio_atsd_regs[reg] + XTS_ATSD_STAT))
			cpu_relax();
	}
}

/*
 * Acquires all the address translation shootdown (ATSD) registers required to
 * launch an ATSD on all links this npu_context is active on.
 */
static void acquire_atsd_reg(struct npu_context *npu_context,
			struct mmio_atsd_reg mmio_atsd_reg[NV_MAX_NPUS])
{
	int i, j;
	struct npu *npu;
	struct pci_dev *npdev;

	for (i = 0; i < npu_count; i++) {
		mmio_atsd_reg[i].reg = -1;
		for (j = 0; j < NV_MAX_LINKS; j++) {
			/*
			 * There are no ordering requirements with respect to
			 * the setup of struct npu_context, but to ensure
			 * consistent behaviour we need to ensure npdev[][] is
			 * only read once.
			 */
			npdev = READ_ONCE(npu_context->npdev[i][j]);
			if (!npdev)
				continue;

			npu = &npus[i];
			if (!npu->mmio_atsd_count)
				continue;

			mmio_atsd_reg[i].npu = npu;
			mmio_atsd_reg[i].reg = get_mmio_atsd_reg(npu);
			while (mmio_atsd_reg[i].reg < 0) {
				mmio_atsd_reg[i].reg = get_mmio_atsd_reg(npu);
				cpu_relax();
			}
			break;
		}
	}
}

/*
 * Release previously acquired ATSD registers. To avoid deadlocks the registers
 * must be released in the same order they were acquired above in
 * acquire_atsd_reg.
 */
static void release_atsd_reg(struct mmio_atsd_reg mmio_atsd_reg[NV_MAX_NPUS])
{
	int i;

	for (i = 0; i < npu_count; i++) {
		/*
		 * We can't rely on npu_context->npdev[][] being the same here
		 * as when acquire_atsd_reg() was called, hence we use the
		 * values stored in mmio_atsd_reg during the acquire phase
		 * rather than re-reading npdev[][].
		 */
		if (mmio_atsd_reg[i].reg < 0)
			continue;

		put_mmio_atsd_reg(mmio_atsd_reg[i].npu, mmio_atsd_reg[i].reg);
	}
}

/*
 * Invalidate a virtual address range
 */
static void mmio_invalidate(struct npu_context *npu_context,
			unsigned long start, unsigned long size)
{
	struct mmio_atsd_reg mmio_atsd_reg[NV_MAX_NPUS];
	unsigned long pid = npu_context->mm->context.id;
	unsigned long atsd_start = 0;
	unsigned long end = start + size - 1;
	int atsd_psize = MMU_PAGE_COUNT;

	/*
	 * Convert the input range into one of the supported sizes. If the range
	 * doesn't fit, use the next larger supported size. Invalidation latency
	 * is high, so over-invalidation is preferred to issuing multiple
	 * invalidates.
	 *
	 * A 4K page size isn't supported by NPU/GPU ATS, so that case is
	 * ignored.
	 */
	if (size == SZ_64K) {
		atsd_start = start;
		atsd_psize = MMU_PAGE_64K;
	} else if (ALIGN_DOWN(start, SZ_2M) == ALIGN_DOWN(end, SZ_2M)) {
		atsd_start = ALIGN_DOWN(start, SZ_2M);
		atsd_psize = MMU_PAGE_2M;
	} else if (ALIGN_DOWN(start, SZ_1G) == ALIGN_DOWN(end, SZ_1G)) {
		atsd_start = ALIGN_DOWN(start, SZ_1G);
		atsd_psize = MMU_PAGE_1G;
	}

	/*
	 * Loop over all the NPUs this process is active on and launch
	 * an invalidate.
	 */
	acquire_atsd_reg(npu_context, mmio_atsd_reg);

	if (atsd_psize == MMU_PAGE_COUNT)
		mmio_invalidate_pid(mmio_atsd_reg, pid);
	else
		mmio_invalidate_range(mmio_atsd_reg, pid, atsd_start,
					atsd_psize);

	mmio_invalidate_wait(mmio_atsd_reg);

	/*
	 * The GPU requires two flush ATSDs to ensure all entries have been
	 * flushed. We use PID 0 as it will never be used for a process on the
	 * GPU.
	 */
	mmio_invalidate_pid(mmio_atsd_reg, 0);
	mmio_invalidate_wait(mmio_atsd_reg);
	mmio_invalidate_pid(mmio_atsd_reg, 0);
	mmio_invalidate_wait(mmio_atsd_reg);

	release_atsd_reg(mmio_atsd_reg);
}

static void pnv_npu2_mn_release(struct mmu_notifier *mn,
				struct mm_struct *mm)
{
	struct npu_context *npu_context = mn_to_npu_context(mn);

	/* Call into device driver to stop requests to the NMMU */
	if (npu_context->release_cb)
		npu_context->release_cb(npu_context, npu_context->priv);

	/*
	 * There should be no more translation requests for this PID, but we
	 * need to ensure any entries for it are removed from the TLB.
	 */
	mmio_invalidate(npu_context, 0, ~0UL);
}

/*
 * Called by the radix TLB flush code after the CPU TLB invalidation, with
 * an exclusive end; (0, -1UL) means the whole address space.
 */
static void pnv_npu2_mn_invalidate_secondary_tlbs(struct mmu_notifier *mn,
					struct mm_struct *mm,
					unsigned long start, unsigned long end)
{
	struct npu_context *npu_context = mn_to_npu_context(mn);

	mmio_invalidate(npu_context, start, end - start);
}

static struct mmu_notifier *pnv_npu2_mn_alloc(struct mm_struct *mm)
{
	struct npu_context *npu_context;

	npu_context = kzalloc(sizeof(*npu_context), GFP_KERNEL);
	if (!npu_context)
		return ERR_PTR(-ENOMEM);

	npu_context->mm = mm;

	return &npu_context->mn;
}

static void pnv_npu2_mn_free(struct mmu_notifier *mn)
{
	kfree(mn_to_npu_context(mn));
}

static const struct mmu_notifier_ops nv_nmmu_notifier_ops = {
	.release = pnv_npu2_mn_release,
	.arch_invalidate_secondary_tlbs = pnv_npu2_mn_invalidate_secondary_tlbs,
	.alloc_notifier = pnv_npu2_mn_alloc,
	.free_notifier = pnv_npu2_mn_free,
};

static int npu_link_index(struct pci_dev *npdev, u32 *nvlink_index)
{
	struct device_node *nvlink_dn;
	int ret;

	nvlink_dn = of_parse_phandle(npdev->dev.of_node, "ibm,nvlink", 0);
	if (!nvlink_dn)
		return -ENODEV;

	ret = of_property_read_u32(nvlink_dn, "ibm,npu-link-index",
				   nvlink_index);
	of_node_put(nvlink_dn);
	if (ret || *nvlink_index >= NV_MAX_LINKS)
		return -ENODEV;

	return 0;
}

/*
 * Setup the nmmu context for the current task in the NPU. This must be
 * called to setup the context tables before the GPU issues ATRs. pdev
 * should be a pointed to PCIe GPU device.
 *
 * A release callback should be registered to allow a device driver to
 * be notified that it should not launch any new translation requests
 * as the final TLB invalidate is about to occur.
 *
 * Returns an error if there no contexts are currently available or a
 * npu_context which should be passed to pnv_npu2_handle_fault().
 *
 * mmap_lock must be held in write mode and must not be called from interrupt
 * context.
 */
struct npu_context *pnv_npu2_init_context(struct pci_dev *gpdev,
			unsigned long flags,
			void (*cb)(struct npu_context *, void *),
			void *priv)
{
	u32 nvlink_index;
	struct mm_struct *mm = current->mm;
	struct mmu_notifier *mn;
	struct npu *npu;
	struct npu_context *npu_context;
	bool first;

	/*
	 * At present we don't support GPUs connected to multiple NPUs and I'm
	 * not sure the hardware does either.
	 */
	struct pci_dev *npdev = pnv_pci_get_npu_dev(gpdev, 0);

	if (!npdev)
		/* No nvlink associated with this GPU device */
		return ERR_PTR(-ENODEV);

	/* The device holds its own reference; npdev[][] needs no other */
	pci_dev_put(npdev);

	/* We only support DR/PR/HV in pnv_npu2_map_lpar_dev() */
	if (flags & ~(MSR_DR | MSR_PR | MSR_HV))
		return ERR_PTR(-EINVAL);

	if (WARN_ON(npu_link_index(npdev, &nvlink_index)))
		return ERR_PTR(-ENODEV);

	if (!mm || mm->context.id == 0) {
		/*
		 * Kernel thread contexts are not supported and context id 0 is
		 * reserved on the GPU.
		 */
		return ERR_PTR(-EINVAL);
	}

	npu = npu_from_pdev(npdev);
	if (!npu)
		return ERR_PTR(-ENODEV);

	/*
	 * One context per mm: returns the existing subscription with a new
	 * reference, or allocates and registers one. Parallel allocation is
	 * prevented by the mmap_lock held for write.
	 */
	mn = mmu_notifier_get_locked(&nv_nmmu_notifier_ops, mm);
	if (IS_ERR(mn))
		return ERR_CAST(mn);
	npu_context = mn_to_npu_context(mn);

	spin_lock(&npu_context_lock);
	first = npu_context->users == 0;
	if (!first && (npu_context->release_cb != cb ||
		       npu_context->priv != priv)) {
		spin_unlock(&npu_context_lock);
		mmu_notifier_put(mn);
		return ERR_PTR(-EINVAL);
	}
	npu_context->users++;
	npu_context->release_cb = cb;
	npu_context->priv = priv;
	spin_unlock(&npu_context_lock);

	/*
	 * npdev is a pci_dev pointer setup by the PCI code. We assign it to
	 * npdev[][] to indicate to the mmu notifiers that an invalidation
	 * should also be sent over this nvlink. The notifiers don't use any
	 * other fields in npu_context, so we just need to ensure that when they
	 * deference npu_context->npdev[][] it is either a valid pointer or
	 * NULL.
	 */
	WRITE_ONCE(npu_context->npdev[npu->index][nvlink_index], npdev);

	/*
	 * Mark the mm for global TLB invalidations so that they also reach
	 * the nest MMU, which walks the page tables on behalf of the GPU.
	 */
	if (first)
		mm_context_add_copro(mm);

	return npu_context;
}
EXPORT_SYMBOL(pnv_npu2_init_context);

/*
 * Destroy a context on the given GPU. May free the npu_context if it is no
 * longer active on any GPUs. Must not be called from interrupt context.
 */
void pnv_npu2_destroy_context(struct npu_context *npu_context,
			struct pci_dev *gpdev)
{
	struct npu *npu;
	struct pci_dev *npdev = pnv_pci_get_npu_dev(gpdev, 0);
	struct mm_struct *mm = npu_context->mm;
	u32 nvlink_index;
	bool last;

	if (WARN_ON(!npdev))
		return;
	pci_dev_put(npdev);

	npu = npu_from_pdev(npdev);
	if (!npu)
		return;
	if (WARN_ON(npu_link_index(npdev, &nvlink_index)))
		return;
	WRITE_ONCE(npu_context->npdev[npu->index][nvlink_index], NULL);

	spin_lock(&npu_context_lock);
	last = --npu_context->users == 0;
	spin_unlock(&npu_context_lock);

	/*
	 * Drop the copro reference taken by the first init_context. This
	 * flushes the whole mm (CPU and nest MMU) when the count reaches zero;
	 * skip it once the address space is gone, there is nothing to flush.
	 */
	if (last && mmget_not_zero(mm)) {
		mm_context_remove_copro(mm);
		mmput(mm);
	}

	/* Unregisters and frees the context after an SRCU grace period */
	mmu_notifier_put(&npu_context->mn);
}
EXPORT_SYMBOL(pnv_npu2_destroy_context);

/*
 * Assumes mmap_lock is held for the contexts associated mm.
 */
int pnv_npu2_handle_fault(struct npu_context *context, uintptr_t *ea,
			unsigned long *flags, unsigned long *status, int count)
{
	u64 rc = 0, result = 0;
	int i, is_write;
	struct page *page[1];

	/* mmap_lock should be held so the struct_mm must be present */
	struct mm_struct *mm = context->mm;

	mmap_assert_locked(mm);

	for (i = 0; i < count; i++) {
		is_write = flags[i] & NPU2_WRITE;
		rc = get_user_pages_remote(mm, ea[i], 1,
					   is_write ? FOLL_WRITE : 0,
					   page, NULL);

		if (rc != 1) {
			status[i] = rc;
			result = -EFAULT;
			continue;
		}

		/* Make sure partition scoped tree gets a pte */
		(void)READ_ONCE(*(char *)page_address(page[0]));

		status[i] = 0;
		put_page(page[0]);
	}

	return result;
}
EXPORT_SYMBOL(pnv_npu2_handle_fault);

void npu_ats_exit(void)
{
	/* Wait for pending free_notifier callbacks into this module */
	mmu_notifier_synchronize();
}
