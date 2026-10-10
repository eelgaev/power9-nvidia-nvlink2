#!/usr/bin/env bash
# Incrementally rebuild a saved build-kernel.sh output under a new suffix.
# Usage: bash rebuild-kernel.sh <previous output> <additional patches> <output> <suffix> [jobs]
# The patch directory contains only patches not applied to the previous tree.
# The previous output is mounted read-only and the new output must not exist.
set -euo pipefail

PREVIOUS=$(realpath "${1:?previous build output required}")
PATCHES=$(realpath "${2:?additional patch directory required}")
OUT=$(realpath -m "${3:?new output directory required}")
SUFFIX=${4:?new kernel suffix required}
JOBS=${5:-$(( $(nproc) / 2 ))}
IMAGE=${IMAGE:-p9-nvlink2-el8}

[[ -d $PREVIOUS/rpmbuild/BUILD && -f $PREVIOUS/src/kernel.spec ]] ||
	{ echo "missing saved build in $PREVIOUS" >&2; exit 1; }
[[ ! -e $OUT && $OUT != "$PREVIOUS" && $OUT != "$PREVIOUS"/* ]] ||
	{ echo "output must be a new directory outside the previous build" >&2; exit 1; }
[[ $SUFFIX =~ ^[A-Za-z0-9_]+$ && $JOBS =~ ^[1-9][0-9]*$ ]] ||
	{ echo "invalid suffix or job count" >&2; exit 1; }
patches=("$PATCHES"/0*.patch)
[[ -f ${patches[0]} ]] || { echo "no additional patches" >&2; exit 1; }

mkdir -p "$OUT"
podman run --rm \
	-v "$PREVIOUS:/previous:ro,z" \
	-v "$PATCHES:/in/patches:ro,z" \
	-v "$OUT:/build:z" \
	"$IMAGE" bash -euo pipefail -c '
JOBS=$1 SUFFIX=$2
source /opt/rh/gcc-toolset-13/enable
trees=(/previous/rpmbuild/BUILD/kernel-*)
[[ ${#trees[@]} == 1 && -f ${trees[0]}/include/config/kernel.release ]] ||
    { echo "expected exactly one saved compiled kernel tree" >&2; exit 1; }
read -r old < "${trees[0]}/include/config/kernel.release"
[[ $old =~ ^([0-9.]+-[0-9.]+)\.[A-Za-z0-9_]+(\.el[0-9_]+\.ppc64le)$ ]] ||
    { echo "unrecognized previous release: $old" >&2; exit 1; }
new="${BASH_REMATCH[1]}.$SUFFIX${BASH_REMATCH[2]}"
[[ $new != "$old" ]] || { echo "suffix must change the release" >&2; exit 1; }
kp=kernel-${new//-/_}
mkdir -p /build/src /build/rpmbuild/BUILD
cp -a --reflink=auto "${trees[0]}" "/build/rpmbuild/BUILD/$kp"
cd "/build/rpmbuild/BUILD/$kp"
for p in /in/patches/0*.patch; do
    echo "applying $(basename "$p")"
    patch --dry-run -p1 -s < "$p"
    patch -p1 -s < "$p"
done
base=$(make -s kernelversion)
krel=${new#"$base"}
scripts/config --set-str LOCALVERSION "$krel" \
    --set-str BUILD_SALT "${krel#-}" --disable LOCALVERSION_AUTO
make -s olddefconfig
make -s prepare
[[ $(make -s kernelrelease) == "$new" ]] ||
    { echo "kernel release mismatch" >&2; exit 1; }
echo "incremental kernel release: $new"
make -j"$JOBS" KBUILD_BUILD_VERSION=1
KERNELRELEASE=$new MAKE=make srctree=. \
    RCS_TAR_IGNORE=--exclude=.git sh scripts/package/mkspec > /build/src/kernel.spec
python3 - <<"PY"
from pathlib import Path
spec = Path("/build/src/kernel.spec").read_text()
changes = {
    "%setup -q\n": "%setup -q -D -T\n",
    "make %{?_smp_mflags} KBUILD_BUILD_VERSION=%{release}\n":
        "# Already incrementally rebuilt before packaging.\n",
}
for old, new in changes.items():
    if spec.count(old) != 1:
        raise SystemExit("unexpected generated spec: " + old)
    spec = spec.replace(old, new)
Path("/build/src/kernel-rebuild.spec").write_text(spec)
PY
rpmbuild --define "_topdir /build/rpmbuild" --define "_smp_mflags -j$JOBS" \
    --define "_build_id_links none" --target ppc64le \
    -bb /build/src/kernel-rebuild.spec
mkdir -p /build/RPMS
mv /build/rpmbuild/RPMS/*/*.rpm /build/RPMS/
' rebuild "$JOBS" "$SUFFIX"

ls -l "$OUT/RPMS"
