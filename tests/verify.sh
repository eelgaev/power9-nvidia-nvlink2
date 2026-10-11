#!/usr/bin/env bash
# verify.sh: check NVLink2 / ATS / coherent GPU memory on a running system.
#
#   verify.sh [quick|full]     (quick: no stress test; default full)
#
# Needs the test programs built (make) and root for dmesg.
set -uo pipefail

cd "$(dirname "$0")"
MODE=${1:-full}
fail=0
ok()   { printf '  [ OK ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=1; }
info() { printf '  %s\n' "$*"; }
hdr()  { printf '\n== %s\n' "$*"; }

hdr "kernel and modules"
info "kernel $(uname -r)"
for m in nvidia nvidia_uvm; do
	lsmod | grep -q "^$m " && ok "$m loaded" || bad "$m not loaded"
done
# The NPU API comes from nvlink2-npu, or from the kernel itself on kernels
# that still carry it (e.g. RHEL 8)
if lsmod | grep -q '^nvlink2_npu '; then
	ok "NPU API from nvlink2-npu"
elif grep -qw pnv_npu2_init_context /proc/kallsyms; then
	ok "NPU API built into the kernel"
else
	bad "no NPU API (pnv_npu2_init_context): nvlink2-npu not loaded"
fi

if lsmod | grep -q '^nvlink2_npu '; then
	hdr "NPU EEH registrations"
	npu_devices=0
	for dev in /sys/bus/pci/devices/*; do
		read -r vendor < "$dev/vendor" || continue
		read -r device < "$dev/device" || continue
		[[ $vendor == 0x1014 && $device == 0x04ea ]] || continue
		npu_devices=$((npu_devices + 1))
		if [[ -f $dev/eeh_pe_config_addr ]]; then
			if ! read -r pe < "$dev/eeh_pe_config_addr"; then
				bad "${dev##*/}: cannot read saved EEH PE"
			elif [[ $pe == 0xffffffff ]]; then
				bad "${dev##*/}: invalid EEH PE (kernel patch 0006 missing?)"
			else
				ok "${dev##*/}: EEH PE $pe"
			fi
		else
			bad "${dev##*/}: missing EEH registration"
		fi
	done
	(( npu_devices > 0 )) || bad "no NPU devices remain"
fi

hdr "dmesg"
errs=$(dmesg | grep -iE 'nvlink2-npu|npu|NVRM|Xid|EEH:' |
	grep -iE 'error|fail|warn|Xid|BUG|blocked|DMA address not in addressable range' | grep -v 'ibm,nmmu-flush ignored')
[[ -z $errs ]] && ok "no NPU / NVRM errors" || { bad "NPU / NVRM errors:"; echo "$errs" | sed 's/^/         /'; }
dmesg | grep -E 'nvlink2-npu: NPU' | sed 's/^/  /'

if (( fail )); then
	bad "preflight failed; stopping before GPU queries or CUDA tests"
	exit 1
fi

hdr "NPU devices"
n=$(lspci -d 1014:04ea | wc -l)
(( n > 0 )) && ok "$n NPU links (1014:04ea)" || bad "no NPU PCI devices (kernel patch 0001 missing?)"

hdr "GPUs and NVLinks"
mapfile -t gpus < <(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader)
(( ${#gpus[@]} > 0 )) && ok "${#gpus[@]} GPUs" || bad "nvidia-smi sees no GPUs"
down=$(nvidia-smi nvlink -s | grep -ciE 'inactive|<inactive>')
up=$(nvidia-smi nvlink -s | grep -cE 'Link [0-9]+: [0-9.]+ GB/s')
(( up > 0 && down == 0 )) && ok "$up NVLinks up" || bad "NVLinks: $up up, $down inactive"

hdr "GPU memory as NUMA nodes"
for f in /proc/driver/nvidia/gpus/*/numa_status; do
	st=$(awk '/Status/ {print $2}' "$f")
	node=$(awk '/Node/ {print $2}' "$f")
	size=$(awk '/Size/ {print $2}' "$f")
	gpu=$(basename "$(dirname "$f")")
	[[ $st == online ]] && ok "$gpu node $node online, $(( 0x$size >> 20 )) MiB" ||
		bad "$gpu numa_status: $st"
done
numactl -H | grep -E '^node [0-9]+ size' | sed 's/^/  /'

[[ -x ./bw && -x ./ats_read && -x ./ats_stress ]] || { bad "tests not built (run make)"; exit 1; }

for g in "${gpus[@]}"; do
	idx=${g%%,*}
	bdf=$(echo "${g#*, }" | tr 'A-F' 'a-f' | sed 's/^0000\(....\)/\1/')
	node=$(cat "/sys/bus/pci/devices/$bdf/numa_node" 2>/dev/null)
	[[ $node =~ ^[0-9]+$ ]] || node=0
	# Pin CPU work to the GPU's socket without constraining GPU-memory nodes.
	# --membind to the CPU node can prevent UVM from migrating pages to VRAM.
	bind=(numactl --cpunodebind="$node")

	hdr "GPU $idx (CPU node $node)"
	"${bind[@]}" ./bw h2d -d "$idx" | sed 's/^/  /'
	"${bind[@]}" ./bw d2h -d "$idx" | sed 's/^/  /'
	if "${bind[@]}" ./ats_read -d "$idx" > out.$$ 2>&1; then
		sed 's/^/  /' out.$$; ok "ATS / managed reads"
	else
		sed 's/^/  /' out.$$; bad "ATS / managed reads"
	fi
	if [[ $MODE == full ]]; then
		if "${bind[@]}" ./ats_stress -d "$idx" > out.$$ 2>&1; then
			sed 's/^/  /' out.$$; ok "ATS invalidation stress"
		else
			sed 's/^/  /' out.$$; bad "ATS invalidation stress"
		fi
	fi
	rm -f out.$$
done

hdr "GPU <-> GPU"
./bw p2p | sed 's/^/  /'

hdr "result"
(( fail )) && echo "  FAIL" || echo "  PASS"
exit $fail
