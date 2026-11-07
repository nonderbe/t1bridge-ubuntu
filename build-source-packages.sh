#!/bin/bash
# Build signed-ready source packages for a Launchpad PPA in out/ppa/:
#   t1bridge-ubuntu   (T1Bridge services + DKMS + Ubuntu additions, built from source on Launchpad)
#   libfprint, fprintd (Ubuntu's packages + the T1Bridge patches, via build-fprint.sh)
# Runs as a normal user. Upload yourself afterwards:
#   debsign -k <your key> out/ppa/*_source.changes
#   dput ppa:<you>/t1bridge out/ppa/*_source.changes
#
#   SRC=<t1bridge git clone> ./build-source-packages.sh        all three
#   ONLY=t1bridge ./build-source-packages.sh                   just t1bridge-ubuntu
#   TEST=1 ...                                                 also build the t1bridge binary package locally
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$HERE/../t1bridge}
UPSTREAM=0.1.12
UPSTREAM_COMMIT=81cbdf81026a16e02f0bea74735c6b029a8ffae2	# tag v0.1.12 ("Ship experimental native T1 online recovery in v0.1.12 (#45)")
REV=${REV:-1~ppa1}	# PPA suffix: an official package can supersede it
SERIES=$(lsb_release -cs)
OUT=$HERE/out/ppa
NAME=t1bridge-ubuntu
[ "$(id -u)" -ne 0 ] || { echo "run as your normal user" >&2; exit 1; }
mkdir -p "$OUT"

build_t1bridge() {
	local dir="$OUT/$NAME-$UPSTREAM" orig="$OUT/${NAME}_$UPSTREAM.orig.tar.xz"
	git -C "$SRC" cat-file -e "$UPSTREAM_COMMIT^{commit}" ||
		{ echo "$SRC does not have T1Bridge commit $UPSTREAM_COMMIT" >&2; exit 1; }
	rm -rf "$dir" "$OUT/${NAME}_$UPSTREAM-"* "$OUT/${NAME}_$UPSTREAM.orig"*
	# Pristine upstream tree as the orig tarball (reproducible from the commit).
	git -C "$SRC" archive --format=tar --prefix="$NAME-$UPSTREAM/" "$UPSTREAM_COMMIT" | xz -9 > "$orig"
	tar -xJf "$orig" -C "$OUT"
	# Registry crates (t1-import's base64, quick-xml, sha2, serde_json, ...)
	# as a second orig component, because Launchpad builds offline.
	local vtmp; vtmp=$(mktemp -d)
	(cd "$dir" && cargo vendor --locked --versioned-dirs "$vtmp/vendor" >/dev/null)
	tar -C "$vtmp" --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 -cf - vendor |
		xz -9 > "$OUT/${NAME}_$UPSTREAM.orig-vendor.tar.xz"
	cp -a "$vtmp/vendor" "$dir/vendor"
	rm -rf "$vtmp"
	cp -a "$HERE/debian" "$dir/debian"
	mkdir -p "$dir/debian/extra"
	cp -a "$HERE/stage.sh" "$HERE/files" "$dir/debian/extra/"
	mkdir -p "$dir/debian/extra/kernel"
	cp -a "$HERE/kernel/apple-t1-socw" "$dir/debian/extra/kernel/"
	for s in postinst prerm postrm; do
		# Same maintainer scripts as the local .deb, plus the debhelper token.
		sed -e "s/@UPSTREAM@/$UPSTREAM/g" -e 's/^exit 0$/#DEBHELPER#\nexit 0/' \
			"$HERE/files/$s" > "$dir/debian/$NAME.$s"
	done
	sed -i -e "s/@VERSION@/$UPSTREAM-$REV/" -e "s/@SERIES@/$SERIES/" \
		-e "s/@DATE@/$(date -R)/" "$dir/debian/changelog"
	(cd "$dir" && dpkg-buildpackage -S -sa -d -us -uc)
	if [ "${TEST:-0}" = 1 ]; then
		local t="$OUT/test"; rm -rf "$t"; mkdir -p "$t"
		(cd "$t" && dpkg-source -x "$OUT/${NAME}_$UPSTREAM-$REV.dsc" >/dev/null &&
			cd "$NAME-$UPSTREAM" && dpkg-buildpackage -b -us -uc)
		echo "test build: $(ls "$t"/*.deb)"
	fi
}

build_fprint() {
	# Launchpad mails the Changed-By address; use the uploader's identity.
	DEBEMAIL=${DEBEMAIL:-"$(git -C "$HERE" config user.name) <$(git -C "$HERE" config user.email)>"} \
		SOURCE_ONLY=1 "$HERE/build-fprint.sh"
	cp "$HERE"/out/fprint/src/*.dsc "$HERE"/out/fprint/src/*_source.changes \
		"$HERE"/out/fprint/src/*.debian.tar.* "$HERE"/out/fprint/src/*.orig.tar.* "$OUT"/
}

case "${ONLY:-all}" in
t1bridge) build_t1bridge ;;
fprint) build_fprint ;;
all) build_t1bridge; build_fprint ;;
*) echo "ONLY=t1bridge|fprint" >&2; exit 2 ;;
esac
echo "source packages in $OUT:"; ls "$OUT"/*_source.changes
