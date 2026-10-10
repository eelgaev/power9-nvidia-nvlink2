#!/usr/bin/env bash
# Repackage an existing build-kernel.sh output without recompiling the kernel.
# Usage: bash kernel-patches/repackage-kernel.sh <output dir> [jobs]
set -euo pipefail

OUT=$(realpath "${1:?usage: $0 <output dir> [jobs]}")
JOBS=${2:-$(( $(nproc) / 2 ))}
IMAGE=${IMAGE:-p9-nvlink2-el8}
[[ -f $OUT/src/kernel.spec && -d $OUT/rpmbuild/BUILD ]] ||
	{ echo "missing saved spec or compiled tree in $OUT" >&2; exit 1; }

podman run --rm -v "$OUT:/build:z" "$IMAGE" bash -euo pipefail -c '
source /opt/rh/gcc-toolset-13/enable
python3 - <<"PY"
from pathlib import Path

spec = Path("/build/src/kernel.spec").read_text()
changes = {
    "%setup -q\n": "%setup -q -D -T\n",
    "make %{?_smp_mflags} KBUILD_BUILD_VERSION=%{release}\n":
        "# Reuse the compiled kernel and modules.\n",
}
for old, new in changes.items():
    if spec.count(old) != 1:
        raise SystemExit("unexpected saved spec: " + old)
    spec = spec.replace(old, new)
Path("/build/src/kernel-repackage.spec").write_text(spec)
PY
rpmbuild --define "_topdir /build/rpmbuild" --define "_smp_mflags -j$1" \
    --define "_build_id_links none" --target ppc64le \
    -bb /build/src/kernel-repackage.spec
mkdir -p /build/RPMS
mv /build/rpmbuild/RPMS/*/*.rpm /build/RPMS/
' repackage "$JOBS"

ls -l "$OUT/RPMS"
