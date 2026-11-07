#!/bin/bash
# Build t1bridge-ubuntu_<ver>_amd64.deb from an already compiled t1bridge tree.
# Runs as the normal user; changes nothing on the system.
#   ./build-deb.sh            Touch Bar, Touch ID, private link; Ubuntu's own uvcvideo
#   CAMERA=1 ./build-deb.sh   also ship t1bridge's uvcvideo override (T1 H.264 camera)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$HERE/../t1bridge}	# T1Bridge source tree, already built with cargo
UPSTREAM=0.1.12
REV=${REV:-1}
VER="$UPSTREAM-$REV"
CAMERA=${CAMERA:-0}
OUT="$HERE/out"
STAGE="$OUT/stage"
DKMS_NAME=t1bridge
DKMS_DIR="$STAGE/usr/src/$DKMS_NAME-$UPSTREAM"
R="$SRC/target/release"

[ "$(id -u)" -ne 0 ] || { echo "run as your normal user" >&2; exit 1; }
grep -q "^version = \"$UPSTREAM\"" "$SRC/Cargo.toml" 2>/dev/null ||
	grep -q "$UPSTREAM" "$SRC/packaging/arch/t1bridge/PKGBUILD" ||
	{ echo "source tree is not t1bridge $UPSTREAM" >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN"
"$HERE/stage.sh" "$SRC" "$STAGE" "$HERE" "$CAMERA"
sed -e "s/@VER@/$VER/" -e "s/@UPSTREAM@/$UPSTREAM/g" "$HERE/files/control" > "$STAGE/DEBIAN/control"
for s in postinst prerm postrm; do
	sed "s/@UPSTREAM@/$UPSTREAM/g" "$HERE/files/$s" > "$STAGE/DEBIAN/$s"
	chmod 755 "$STAGE/DEBIAN/$s"
done

chmod -R go-w "$STAGE"
mkdir -p "$OUT"
dpkg-deb --root-owner-group --build "$STAGE" "$OUT/t1bridge-ubuntu_${VER}_amd64.deb"
echo "built $OUT/t1bridge-ubuntu_${VER}_amd64.deb (camera override: $CAMERA)"
