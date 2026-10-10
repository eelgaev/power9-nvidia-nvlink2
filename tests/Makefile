# SPDX-License-Identifier: GPL-2.0-only
NVCC ?= /usr/local/cuda/bin/nvcc
NVCCFLAGS ?= -O2 -arch=sm_70

PROGS = ats_read ats_stress bw

all: $(PROGS)

%: %.cu
	$(NVCC) $(NVCCFLAGS) -o $@ $<

clean:
	rm -f $(PROGS)

.PHONY: all clean
