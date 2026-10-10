// SPDX-License-Identifier: GPL-2.0-only
//
// bw: host<->GPU and GPU<->GPU bandwidth over NVLink2.
//
//   bw h2d|d2h [-d gpu] [-m MiB]   pinned copies (run under numactl to pick
//                                  the CPU socket / memory node)
//   bw p2p [-m MiB]                peer copies between every GPU pair
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
	fprintf(stderr, "%s:%d: %s: %s\n", __FILE__, __LINE__, #x, \
		cudaGetErrorString(e_)); exit(2); } } while (0)

static float time_copy(void *dst, int ddev, const void *src, int sdev,
		       size_t sz, cudaMemcpyKind kind, int reps)
{
	cudaEvent_t a, b;
	float ms;

	CK(cudaEventCreate(&a));
	CK(cudaEventCreate(&b));
	CK(cudaEventRecord(a));
	for (int i = 0; i < reps; i++) {
		if (kind == cudaMemcpyDefault)
			CK(cudaMemcpyPeerAsync(dst, ddev, src, sdev, sz));
		else
			CK(cudaMemcpyAsync(dst, src, sz, kind));
	}
	CK(cudaEventRecord(b));
	CK(cudaEventSynchronize(b));
	CK(cudaEventElapsedTime(&ms, a, b));
	return ms;
}

int main(int argc, char **argv)
{
	size_t sz = 1024UL << 20;
	int dev = 0, n, opt, reps = 10;
	const char *mode = argc > 1 ? argv[1] : "";

	optind = 2;
	while ((opt = getopt(argc, argv, "d:m:")) != -1) {
		if (opt == 'd')
			dev = atoi(optarg);
		else if (opt == 'm')
			sz = strtoul(optarg, NULL, 0) << 20;
	}
	CK(cudaGetDeviceCount(&n));

	if (!strcmp(mode, "h2d") || !strcmp(mode, "d2h")) {
		void *h, *d;
		int h2d = !strcmp(mode, "h2d");

		CK(cudaSetDevice(dev));
		CK(cudaHostAlloc(&h, sz, cudaHostAllocDefault));
		CK(cudaMalloc(&d, sz));
		memset(h, 1, sz);
		time_copy(h2d ? d : h, dev, h2d ? h : d, dev, sz,
			  h2d ? cudaMemcpyHostToDevice : cudaMemcpyDeviceToHost, 1);
		float ms = time_copy(h2d ? d : h, dev, h2d ? h : d, dev, sz,
			  h2d ? cudaMemcpyHostToDevice : cudaMemcpyDeviceToHost, reps);
		printf("GPU %d %s: %.1f GB/s\n", dev, mode, reps * sz / ms / 1e6);
		return 0;
	}

	if (!strcmp(mode, "p2p")) {
		void *buf[16];

		for (int i = 0; i < n; i++) {
			CK(cudaSetDevice(i));
			CK(cudaMalloc(&buf[i], sz));
			for (int j = 0; j < n; j++) {
				int ok;

				if (i == j)
					continue;
				CK(cudaDeviceCanAccessPeer(&ok, i, j));
				if (ok)
					CK(cudaDeviceEnablePeerAccess(j, 0));
			}
		}
		printf("peer copy GB/s (row: src, col: dst)\n    ");
		for (int j = 0; j < n; j++)
			printf("%8d", j);
		printf("\n");
		for (int i = 0; i < n; i++) {
			printf("%4d", i);
			for (int j = 0; j < n; j++) {
				if (i == j) {
					printf("%8s", "-");
					continue;
				}
				CK(cudaSetDevice(i));
				time_copy(buf[j], j, buf[i], i, sz, cudaMemcpyDefault, 1);
				float ms = time_copy(buf[j], j, buf[i], i, sz,
						     cudaMemcpyDefault, reps);
				printf("%8.1f", reps * sz / ms / 1e6);
			}
			printf("\n");
		}
		return 0;
	}

	fprintf(stderr, "usage: %s h2d|d2h [-d gpu] [-m MiB] | p2p [-m MiB]\n", argv[0]);
	return 2;
}
