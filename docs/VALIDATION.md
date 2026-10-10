# Validation guide

Compilation, module-load compatibility and ATS correctness are separate
checks. A successful kernel or DKMS build does not establish runtime support.

## Build and export checks

Run the isolated NVIDIA build against the generated kernel RPMs:

```sh
scripts/dkms-test.sh out/RPMS
```

This uses private source and DKMS trees. It checks the restored NPU API
imports and rejects GPL-only kernel imports from NVIDIA's core and UVM
modules. It does not install or load the modules.

NVIDIA UVM is Dual MIT/GPL, but inherits proprietary taint when it resolves
symbols from NVIDIA's proprietary core module. The module loader then rejects
GPL-only kernel exports. In particular, enabling VA-space/mm support adds
`mmput` and `__mmdrop` imports. NVIDIA patch 0002 requires usable non-GPL
exports of both functions, in addition to the restored production NPU API,
before enabling ATS on newer kernels. Kernel patch 0007 supplies non-GPL
MM exports when `CONFIG_PPC_POWERNV_NVLINK2` is enabled. A kernel lacking
that compatibility retains the restriction; a driver reload or reboot into
the same incompatible kernel does not resolve it.

Verify that both NVIDIA patches were applied to the target build. When
updating an existing DKMS entry, explicitly rebuild before installation;
installation alone can reuse an older build. See [INSTALL.md](INSTALL.md).

## Hardware preflight

Use a controlled test with automatic GPU workloads held back. Before CUDA
queries or tests:

- Confirm the selected kernel and loaded NVIDIA/NPU modules.
- Inspect the kernel log for EEH device removals, invalid PE registrations,
  module-load errors, DMA-range failures, Xids, memory failures, KFENCE reports
  and blocked driver calls. Resolve these before progressing.
- Confirm the NPU PCI devices are present. For each device, inspect
  `/sys/bus/pci/devices/<BDF>/eeh_pe_config_addr`: the saved PE must match the
  assigned PCI PE, rather than `0xffffffff`.

Kernel patch 0006 defers NPU EEH probing until PE assignment is complete. It
addresses invalid initial EEH registrations; it does not establish that other
memory, DMA or driver failures are resolved.

If EEH has removed devices or the driver is blocked, return to the known-working
kernel through the firmware boot menu. See [BOOT.md](BOOT.md).

## Capability and small functional tests

After preflight passes, check GPU visibility, NVLink status and GPU NUMA memory
status, then run small transfer and read tests:

```sh
cd tests
./bw h2d -d 0 -m 64 &&
./bw d2h -d 0 -m 64 &&
./ats_read -d 0 -m 64 -r 2
```

Host transfer bandwidth and a passing managed-memory checksum do not prove
ATS. The read test must report pageable memory access and actually run the
plain malloc test. If that test is skipped, ATS has not been validated.

## ATS invalidation tests

Only after the capability/read check passes and the kernel log remains clean:

```sh
./ats_stress -d 0 -m 64 -s 2 -r 5
```

The test must report pageable memory access via host page tables and execute
its invalidation phases. An "ATS not available" result is a skipped test,
not a successful ATS validation. Inspect checksums and the kernel log before
increasing the allocation or iteration count or testing additional GPUs.

Keep exact build identifiers, measurements and boot logs in local validation
records rather than the public installation instructions.
