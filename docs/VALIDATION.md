# Hardware validation status

## First RHEL 9.9 boot: npu1

Build and isolated DKMS checks passed, but the first hardware boot failed.
These checks establish compilation and symbol compatibility, not runtime
correctness.

The NPU module loaded, discovered two NPU2 PHBs with eight ATSD register
sets each, and NVIDIA loaded. GPU memory was also onlined. Subsequently,
PCI config reads triggered EEH recovery for NPU devices at PE `ffffffff`.
EEH declared permanent failure and removed the devices. IRQ teardown
warned about live `NPU Device` handlers, followed by NVIDIA Xids and
blocked driver calls.

### Identified EEH registration defect

`pcibios_init()` calls `pci_bus_add_devices()` before the platform final
fixup. The restored NPU controller has no DMA setup hook, so the early
EEH probe copies an unassigned PE (`IODA_INVALID_PE`, -1) from the
reverse map. The final fixup later assigns the PCI PEs but does not
refresh the already-created EEH entries.

An all-ones config read reaches `pnv_ioda_get_pe_state()` with this
invalid PE. It returns permanently unavailable without calling firmware.
The RHEL 8 EEH core treats `EEH_STATE_NOT_SUPPORT` as a false positive;
RHEL 9.9's EEH core can instead start recovery and device removal.

Patch **0006** defers NPU EEH probing while its PE is unassigned, then
completes registration after NPU PE setup. It does not weaken the generic
EEH failure policy, affect other PHB types, or alter the ATS module source.
The correction is built under a distinct **npu2** release. A successful
build is not proof that the hardware failure is resolved.

The `npu2` kernel and kernel-devel RPM build passed in the UBI 8 container
with gcc-toolset-13. The RPM payload contains the correction and NPU
module, and its NPU export CRCs match `npu1`. The ATS source files are
unchanged. `npu2` has not yet been validated on hardware.

### Earlier unresolved events

Before the EEH removal, the first boot also logged a recovered memory
failure at a GPU-memory PFN and a NVIDIA DMA-range rejection. The rejected
DMA address corresponded to CPU node 8 RAM plus the PCI bypass offset,
outside the driver's reported addressable range. These events require
separate validation; patch 0006 does not claim to fix them.

## Next hardware test

Perform the next boot as a controlled test with automatic GPU workloads
held back. First inspect the kernel log and verify NPU device presence and
driver initialization. Only proceed to bandwidth and ATS stress tests
once there are no EEH removals, DMA-range failures, Xids or blocked calls.

For each NPU PCI device, inspect its saved
`/sys/bus/pci/devices/<BDF>/eeh_pe_config_addr`: it must contain the PE
assigned during NPU setup, not `0xffffffff`. `tests/verify.sh` checks
these registrations on the restored-module kernel and stops before GPU
queries or CUDA tests if this preflight or the kernel-log check fails.

If the driver is already blocked or EEH has removed NPU devices, return
to the known-working stock kernel through the firmware boot menu rather
than attempting live module reloads or device recovery during the test.
