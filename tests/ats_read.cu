// SPDX-License-Identifier: GPL-2.0-only
//
// ats_read: the GPU reads plain malloc() memory (ATS) and managed memory,
// checks the result against the CPU and reports read bandwidth.
//
//   ats_read [-d gpu] [-m MiB] [-r reps]
//
// Run under numactl --membind=<node of the GPU's socket> for local numbers.
#include <cuda_runtime.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
	fprintf(stderr, "%s:%d: %s: %s\n", __FILE__, __LINE__, #x, \
		cudaGetErrorString(e_)); exit(2); } } while (0)

__global__ void k_sum(const ulonglong2 *p, size_t n, unsigned long long *out)
{
	unsigned long long s = 0;

	for (size_t i = blockIdx.x * blockDim.x + threadIdx.x; i < n;
	     i += (size_t)gridDim.x * blockDim.x) {
		ulonglong2 v = p[i];
		s += v.x + v.y;
	}
	atomicAdd(out, s);
}

static double gpu_read(const void *p, size_t sz, int reps,
		       unsigned long long *sum)
{
	unsigned long long *d;
	cudaEvent_t a, b;
	float ms;

	CK(cudaMallocManaged(&d, sizeof(*d)));
	CK(cudaEventCreate(&a));
	CK(cudaEventCreate(&b));
	*d = 0;
	k_sum<<<640, 512>>>((const ulonglong2 *)p, sz / 16, d);	/* warm-up */
	CK(cudaDeviceSynchronize());
	*sum = *d;
	CK(cudaEventRecord(a));
	for (int i = 0; i < reps; i++)
		k_sum<<<640, 512>>>((const ulonglong2 *)p, sz / 16, d);
	CK(cudaEventRecord(b));
	CK(cudaEventSynchronize(b));
	CK(cudaEventElapsedTime(&ms, a, b));
	CK(cudaFree(d));
	return (double)reps * sz / (ms / 1e3) / (1UL << 30);
}

static int run(const char *what, uint64_t *p, size_t sz, int reps)
{
	unsigned long long cpu = 0, gpu;

	for (size_t i = 0; i < sz / 8; i++) {
		p[i] = i * 0x9e3779b97f4a7c15ULL;
		cpu += p[i];
	}
	double gib = gpu_read(p, sz, reps, &gpu);
	printf("  %-8s read %6.1f GiB/s, checksum %s\n", what, gib,
	       gpu == cpu ? "ok" : "MISMATCH");
	return gpu != cpu;
}

int main(int argc, char **argv)
{
	size_t sz = 1024UL << 20;
	int dev = 0, reps = 20, opt, attr, fail = 0;
	uint64_t *p;

	while ((opt = getopt(argc, argv, "d:m:r:")) != -1) {
		if (opt == 'd')
			dev = atoi(optarg);
		else if (opt == 'm')
			sz = strtoul(optarg, NULL, 0) << 20;
		else if (opt == 'r')
			reps = atoi(optarg);
	}
	CK(cudaSetDevice(dev));
	CK(cudaDeviceGetAttribute(&attr, cudaDevAttrPageableMemoryAccess, dev));
	printf("GPU %d: pageable memory access: %s\n", dev, attr ? "yes" : "NO");

	if (attr) {
		p = (uint64_t *)malloc(sz);
		fail |= run("malloc", p, sz, reps);
		free(p);
	}

	CK(cudaMallocManaged(&p, sz));
	fail |= run("managed", p, sz, reps);
	CK(cudaFree(p));

	return fail || !attr;
}
