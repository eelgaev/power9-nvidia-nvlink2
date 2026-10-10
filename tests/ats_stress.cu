// SPDX-License-Identifier: GPL-2.0-only
//
// ats_stress: look for missed GPU TLB invalidations (ATSD) on NVLink2 ATS.
//
// The GPU accesses plain anonymous memory (mmap) through ATS while the CPU
// changes the mappings underneath it. If an invalidation is missed, the GPU
// keeps using a stale translation and reads or writes a page the process no
// longer maps; every phase below turns that into a checksum mismatch.
//
//   1. remap:    munmap + mmap(MAP_FIXED) / MADV_DONTNEED between GPU passes;
//                the GPU must see the new pages' contents.
//   2. mprotect: the GPU checksums the buffer continuously while the CPU
//                toggles it read-only / read-write.
//   3. migrate:  GPU threads increment per-slot counters continuously while
//                the CPU migrates the pages between NUMA nodes (page
//                migration flushes one page at a time); lost increments
//                mean the GPU wrote to a page after it was copied.
//   4. fork:     after fork() the parent breaks COW and the GPU writes a new
//                generation; the parent must see it and the child's copy
//                must be untouched.
//
// Usage: ats_stress [-d gpu] [-m MiB] [-s seconds per concurrent phase]
//                   [-r rounds]
// Exit status 0 only if every phase passed.

#include <cuda_runtime.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef MPOL_MF_MOVE
#define MPOL_MF_MOVE (1 << 1)	/* move pages owned by this process */
#endif

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
	fprintf(stderr, "%s:%d: %s: %s\n", __FILE__, __LINE__, #x, \
		cudaGetErrorString(e_)); exit(2); } } while (0)

static size_t page_sz;
static size_t buf_sz = 256UL << 20;
static int seconds = 10, rounds = 50, dev;

// One 64-bit word per 8 bytes; slot value = f(generation, index)
__host__ __device__ static inline uint64_t tag(uint64_t gen, uint64_t i)
{
	uint64_t x = (gen << 40) ^ i ^ 0x9e3779b97f4a7c15ULL;
	x ^= x >> 31; x *= 0xbf58476d1ce4e5b9ULL; x ^= x >> 27;
	return x;
}

__global__ void k_fill(volatile uint64_t *p, size_t n, uint64_t gen)
{
	for (size_t i = blockIdx.x * blockDim.x + threadIdx.x; i < n;
	     i += (size_t)gridDim.x * blockDim.x)
		p[i] = tag(gen, i);
	__threadfence_system();
}

__global__ void k_check(const volatile uint64_t *p, size_t n, uint64_t gen,
			unsigned long long *bad)
{
	unsigned long long b = 0;
	for (size_t i = blockIdx.x * blockDim.x + threadIdx.x; i < n;
	     i += (size_t)gridDim.x * blockDim.x)
		b += p[i] != tag(gen, i);
	if (b)
		atomicAdd(bad, b);
}

// Continuous checksum until *stop; counts passes and mismatches
__global__ void k_check_loop(const volatile uint64_t *p, size_t n, uint64_t gen,
			     volatile int *stop, unsigned long long *bad,
			     unsigned long long *passes)
{
	while (!*stop) {
		unsigned long long b = 0;
		for (size_t i = blockIdx.x * blockDim.x + threadIdx.x; i < n;
		     i += (size_t)gridDim.x * blockDim.x)
			b += p[i] != tag(gen, i);
		if (b)
			atomicAdd(bad, b);
		if (blockIdx.x == 0 && threadIdx.x == 0)
			atomicAdd(passes, 1ULL);
	}
}

// Each thread owns slots i = tid + k*stride: increments them in system
// memory and keeps its own count in GPU memory.
__global__ void k_count_loop(volatile uint64_t *p, size_t n, volatile int *stop,
			     unsigned long long *count)
{
	size_t tid = blockIdx.x * blockDim.x + threadIdx.x;
	size_t stride = (size_t)gridDim.x * blockDim.x;
	unsigned long long c = 0;

	while (!*stop) {
		for (size_t i = tid; i < n; i += stride)
			p[i] = p[i] + 1;
		c++;
	}
	__threadfence_system();
	count[tid] = c;
}

static void *map_buf(void *at)
{
	void *p = mmap(at, buf_sz, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS | (at ? MAP_FIXED : 0), -1, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		exit(2);
	}
	return p;
}

static size_t cpu_check(const uint64_t *p, uint64_t gen)
{
	size_t bad = 0, n = buf_sz / 8;

	for (size_t i = 0; i < n; i++)
		bad += p[i] != tag(gen, i);
	return bad;
}

static void cpu_fill(uint64_t *p, uint64_t gen)
{
	for (size_t i = 0, n = buf_sz / 8; i < n; i++)
		p[i] = tag(gen, i);
}

static unsigned long long gpu_check(const uint64_t *p, uint64_t gen)
{
	unsigned long long *bad, r;

	CK(cudaMallocManaged(&bad, sizeof(*bad)));
	*bad = 0;
	k_check<<<160, 256>>>(p, buf_sz / 8, gen, bad);
	CK(cudaDeviceSynchronize());
	r = *bad;
	CK(cudaFree(bad));
	return r;
}

static int result(const char *phase, unsigned long long bad, const char *what)
{
	printf("  %-9s %s: %llu mismatches\n", phase, what, bad);
	return bad != 0;
}

static int phase_remap(void)
{
	uint64_t *p = (uint64_t *)map_buf(NULL);
	int fail = 0;

	for (int r = 0; r < rounds; r++) {
		uint64_t gen = 2 * r + 1;

		// GPU writes gen; CPU checks; GPU re-reads (caches translations)
		k_fill<<<160, 256>>>(p, buf_sz / 8, gen);
		CK(cudaDeviceSynchronize());
		fail |= cpu_check(p, gen) != 0;
		fail |= gpu_check(p, gen) != 0;

		// Replace the pages: odd rounds remap, even rounds zap
		if (r & 1) {
			map_buf(p);
		} else if (madvise(p, buf_sz, MADV_DONTNEED)) {
			perror("madvise");
			exit(2);
		}
		cpu_fill(p, gen + 1);

		// The GPU must see the new pages, not the freed ones
		unsigned long long bad = gpu_check(p, gen + 1);
		if (bad) {
			printf("  remap     round %d (%s): GPU saw stale data in %llu slots\n",
			       r, r & 1 ? "munmap/mmap" : "MADV_DONTNEED", bad);
			fail = 1;
		}
	}
	munmap(p, buf_sz);
	return result("remap", fail, "rounds with stale reads (0/1)");
}

struct loop_ctl {
	volatile int *stop;
	unsigned long long *bad, *passes;
};

static struct loop_ctl ctl_alloc(void)
{
	struct loop_ctl c;

	CK(cudaHostAlloc((void **)&c.stop, sizeof(int), cudaHostAllocMapped));
	CK(cudaMallocManaged(&c.bad, sizeof(*c.bad)));
	CK(cudaMallocManaged(&c.passes, sizeof(*c.passes)));
	*c.stop = 0;
	*c.bad = *c.passes = 0;
	return c;
}

static void ctl_free(struct loop_ctl c)
{
	CK(cudaFreeHost((void *)c.stop));
	CK(cudaFree(c.bad));
	CK(cudaFree(c.passes));
}

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static int phase_mprotect(void)
{
	uint64_t *p = (uint64_t *)map_buf(NULL);
	struct loop_ctl c = ctl_alloc();
	unsigned long toggles = 0;
	int *dstop;

	cpu_fill(p, 7);
	CK(cudaHostGetDevicePointer((void **)&dstop, (void *)c.stop, 0));
	k_check_loop<<<160, 256>>>(p, buf_sz / 8, 7, dstop, c.bad, c.passes);

	for (double end = now() + seconds; now() < end; toggles++) {
		size_t off = (toggles * 7919 % (buf_sz / page_sz)) * page_sz;
		size_t len = buf_sz - off;

		if (mprotect((char *)p + off, len, PROT_READ) ||
		    mprotect((char *)p + off, len, PROT_READ | PROT_WRITE)) {
			perror("mprotect");
			exit(2);
		}
	}
	*c.stop = 1;
	CK(cudaDeviceSynchronize());

	printf("  mprotect  %lu toggles, %llu GPU passes\n", toggles, *c.passes);
	int fail = result("mprotect", *c.bad, "GPU checksum") ||
		   result("mprotect", cpu_check(p, 7), "CPU checksum");
	ctl_free(c);
	munmap(p, buf_sz);
	return fail;
}

static int cpu_nodes(int nodes[2])
{
	char s[256] = "";
	FILE *f = fopen("/sys/devices/system/node/has_cpu", "r");
	int n = 0, a, b;
	char *t;

	if (!f || !fgets(s, sizeof(s), f))
		return 0;
	fclose(f);
	for (t = strtok(s, ",\n"); t && n < 2; t = strtok(NULL, ",\n")) {
		if (sscanf(t, "%d-%d", &a, &b) == 2) {
			nodes[n++] = a;
			if (n < 2 && b != a)
				nodes[n++] = b;
		} else if (sscanf(t, "%d", &a) == 1) {
			nodes[n++] = a;
		}
	}
	return n;
}

static int phase_migrate(void)
{
	size_t npages = buf_sz / page_sz, n = buf_sz / 8;
	uint64_t *p = (uint64_t *)map_buf(NULL);
	struct loop_ctl c = ctl_alloc();
	const int blocks = 160, threads = 256;
	unsigned long long *count, expect_per_slot, lost = 0;
	void **pages = (void **)malloc(npages * sizeof(void *));
	int *where = (int *)malloc(npages * sizeof(int));
	int *status = (int *)malloc(npages * sizeof(int));
	unsigned long moves = 0, moved = 0;
	int nodes[2], *dstop;

	if (cpu_nodes(nodes) < 2) {
		printf("  migrate   skipped: fewer than two CPU NUMA nodes\n");
		return 0;
	}
	memset(p, 0, buf_sz);
	for (size_t i = 0; i < npages; i++)
		pages[i] = (char *)p + i * page_sz;

	CK(cudaMalloc(&count, blocks * threads * sizeof(*count)));
	CK(cudaHostGetDevicePointer((void **)&dstop, (void *)c.stop, 0));
	k_count_loop<<<blocks, threads>>>(p, n, dstop, count);

	for (double end = now() + seconds; now() < end; moves++) {
		for (size_t i = 0; i < npages; i++)
			where[i] = nodes[(moves + i) & 1];
		if (syscall(SYS_move_pages, 0, npages, pages, where, status,
			    MPOL_MF_MOVE) < 0) {
			perror("move_pages");
			exit(2);
		}
		for (size_t i = 0; i < npages; i++)
			moved += status[i] == where[i];
	}
	*c.stop = 1;
	CK(cudaDeviceSynchronize());

	// Slot i belongs to thread i % (blocks * threads)
	unsigned long long *h = (unsigned long long *)malloc(blocks * threads * sizeof(*h));
	CK(cudaMemcpy(h, count, blocks * threads * sizeof(*h), cudaMemcpyDeviceToHost));
	for (size_t i = 0; i < n; i++) {
		expect_per_slot = h[i % (blocks * threads)];
		if (p[i] != expect_per_slot)
			lost++;
	}
	printf("  migrate   %lu passes between nodes %d and %d, %lu page moves, "
	       "%llu GPU increments per slot\n", moves, nodes[0], nodes[1], moved, h[0]);
	if (!moved)
		printf("  migrate   WARNING: no page was migrated\n");

	free(h); free(pages); free(where); free(status);
	CK(cudaFree(count));
	ctl_free(c);
	munmap(p, buf_sz);
	return result("migrate", lost, "slots with lost increments");
}

static int phase_fork(void)
{
	uint64_t *p = (uint64_t *)map_buf(NULL);
	int fail = 0;

	for (int r = 0; r < rounds; r++) {
		uint64_t gen = 2 * r + 1;
		int pipefd[2], st;
		char go;

		k_fill<<<160, 256>>>(p, buf_sz / 8, gen);
		CK(cudaDeviceSynchronize());
		fail |= gpu_check(p, gen) != 0;

		if (pipe(pipefd)) {
			perror("pipe");
			exit(2);
		}
		pid_t pid = fork();
		if (pid < 0) {
			perror("fork");
			exit(2);
		}
		if (pid == 0) {
			// Child: no CUDA. Wait for the parent's GPU pass, then
			// check that our copy still holds generation gen.
			close(pipefd[1]);
			if (read(pipefd[0], &go, 1) != 1)
				_exit(3);
			_exit(cpu_check(p, gen) ? 1 : 0);
		}
		close(pipefd[0]);

		// Parent: break COW on every page, then let the GPU write
		for (size_t off = 0; off < buf_sz; off += page_sz)
			((volatile uint64_t *)p)[off / 8] = tag(gen, off / 8);
		k_fill<<<160, 256>>>(p, buf_sz / 8, gen + 1);
		CK(cudaDeviceSynchronize());

		if (write(pipefd[1], "x", 1) != 1)
			exit(2);
		close(pipefd[1]);
		waitpid(pid, &st, 0);

		size_t parent_bad = cpu_check(p, gen + 1);
		int child_bad = !WIFEXITED(st) || WEXITSTATUS(st) != 0;
		if (parent_bad || child_bad) {
			printf("  fork      round %d: parent missing %zu GPU writes, "
			       "child copy %s\n", r, parent_bad,
			       child_bad ? "CORRUPTED" : "ok");
			fail = 1;
		}
	}
	munmap(p, buf_sz);
	return result("fork", fail, "rounds with misdirected writes (0/1)");
}

int main(int argc, char **argv)
{
	int opt, attr, fail = 0;

	while ((opt = getopt(argc, argv, "d:m:s:r:")) != -1) {
		switch (opt) {
		case 'd': dev = atoi(optarg); break;
		case 'm': buf_sz = strtoul(optarg, NULL, 0) << 20; break;
		case 's': seconds = atoi(optarg); break;
		case 'r': rounds = atoi(optarg); break;
		default:
			fprintf(stderr, "usage: %s [-d gpu] [-m MiB] [-s sec] [-r rounds]\n",
				argv[0]);
			return 2;
		}
	}
	page_sz = sysconf(_SC_PAGESIZE);

	CK(cudaSetDevice(dev));
	CK(cudaDeviceGetAttribute(&attr, cudaDevAttrPageableMemoryAccessUsesHostPageTables, dev));
	printf("GPU %d: pageable memory via host page tables (ATS): %s; %zu MiB, "
	       "%zu KiB pages\n", dev, attr ? "yes" : "NO", buf_sz >> 20, page_sz >> 10);
	if (!attr) {
		printf("ATS not available, nothing to test\n");
		return 2;
	}

	fail |= phase_remap();
	fail |= phase_mprotect();
	fail |= phase_migrate();
	fail |= phase_fork();

	printf("%s\n", fail ? "FAIL" : "PASS");
	return fail;
}
