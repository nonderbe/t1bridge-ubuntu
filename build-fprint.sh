#!/bin/bash
# Build the matched libfprint + fprintd packages with the T1Bridge patches,
# from Ubuntu's own source packages. Runs as a normal user.
#
#   ./build-fprint.sh                 newest versions in the Ubuntu archive
#   LIBFPRINT_VERSION=1:1.95.1+tod1-0ubuntu2 FPRINTD_VERSION=1.94.5-4 ./build-fprint.sh
#   CHECK=1 ./build-fprint.sh         also run the libfprint test suite (with internet access
#                                     metainfo-validate fails on a dead upstream issues URL)
#   SOURCE_ONLY=1 ./build-fprint.sh   source packages only (for a PPA upload)
#
# Build dependencies, once:
#   sudo apt install devscripts dpkg-dev
#   ./build-fprint.sh --fetch-only && sudo apt build-dep ./out/fprint/src/libfprint-*/ ./out/fprint/src/fprintd-*/
# Output: out/fprint/*.deb (version suffix +t1bridge1)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/out/fprint
SRC=$OUT/src
SUFFIX=+t1bridge1
LOCAL=+t1bridge	# dch --local appends the counter: +t1bridge1
FETCH_ONLY=0
[ "${1:-}" = --fetch-only ] && FETCH_ONLY=1
[ "$(id -u)" -ne 0 ] || { echo "run as your normal user" >&2; exit 1; }
SERIES=$(lsb_release -cs)

archive_version() { # newest non-local version of a binary package in the archive
	apt-cache madison "$1" | awk -F'|' '{gsub(/ /, "", $2); print $2}' |
		grep -v t1bridge | sort -V | tail -1
}

fetch() { # $1 source package, $2 version (with epoch): download and unpack into $SRC
	local pkg=$1 ver=$2 dir="$SRC/dl-$1"
	rm -rf "$dir"; mkdir -p "$dir"
	python3 -I - "$pkg" "$ver" "$SERIES" > "$dir/urls" <<'EOF'
import json, sys, urllib.parse, urllib.request
pkg, ver, series = sys.argv[1:4]
api = "https://api.launchpad.net/1.0/ubuntu/+archive/primary"
q = urllib.parse.urlencode({"ws.op": "getPublishedSources", "source_name": pkg,
    "exact_match": "true", "version": ver,
    "distro_series": f"https://api.launchpad.net/1.0/ubuntu/{series}"})
entries = json.load(urllib.request.urlopen(f"{api}?{q}"))["entries"]
if not entries:
    sys.exit(f"{pkg} {ver} not found for {series} on Launchpad")
link = entries[0]["self_link"]
for u in json.load(urllib.request.urlopen(f"{link}?ws.op=sourceFileUrls")):
    print(u)
EOF
	(cd "$dir" && while read -r u; do curl -fsSLO "$u"; done < urls)
	# dpkg-source checks every file against the checksums in the .dsc
	(cd "$SRC" && dpkg-source -x "$dir"/*.dsc)
}

LIBFPRINT_VERSION=${LIBFPRINT_VERSION:-$(archive_version libfprint-2-2)}
FPRINTD_VERSION=${FPRINTD_VERSION:-$(archive_version fprintd)}
echo "libfprint $LIBFPRINT_VERSION, fprintd $FPRINTD_VERSION ($SERIES)"

rm -rf "$SRC"; mkdir -p "$SRC"
fetch libfprint "$LIBFPRINT_VERSION"
fetch fprintd "$FPRINTD_VERSION"
LDIR=$(ls -d "$SRC"/libfprint-*/ | head -1)
FDIR=$(ls -d "$SRC"/fprintd-*/ | head -1)
[ "$FETCH_ONLY" = 1 ] && { echo "sources in $SRC"; exit 0; }

newver() { echo "${1#*:}$SUFFIX"; }	# for messages only; dch keeps the epoch

# libfprint: driver patch + one new TOD symbol
cp "$HERE/fprint/libfprint-t1bridge-driver.patch" "$LDIR/debian/patches/t1bridge-driver.patch"
echo t1bridge-driver.patch >> "$LDIR/debian/patches/series"
(cd "$LDIR" && DEBEMAIL="${DEBEMAIL:-t1bridge-ubuntu <noreply@localhost>}" \
	dch --local "$LOCAL" --distribution "$SERIES" "Add the T1Bridge (Apple T1 Touch ID) driver." 2>/dev/null)
LFULL=$(cd "$LDIR" && dpkg-parsechangelog -S Version)
grep -q '^ fpi_device_remove@LIBFPRINT_TOD_1.0.0 ' "$LDIR/debian/libfprint-2-tod1.symbols" ||
	{ echo "libfprint-2-tod1.symbols changed; update build-fprint.sh" >&2; exit 1; }
sed -i "s/^ fpi_device_remove@LIBFPRINT_TOD_1.0.0 .*\$/&\n fpi_device_remove_if_matches_usb_device@LIBFPRINT_TOD_1_1.95.1 $LFULL/" \
	"$LDIR/debian/libfprint-2-tod1.symbols"

# fprintd: native duplicate detection
cp "$HERE/fprint/fprintd-native-duplicates.patch" "$FDIR/debian/patches/t1bridge-native-duplicates.patch"
echo t1bridge-native-duplicates.patch >> "$FDIR/debian/patches/series"
(cd "$FDIR" && DEBEMAIL="${DEBEMAIL:-t1bridge-ubuntu <noreply@localhost>}" \
	dch --local "$LOCAL" --distribution "$SERIES" "Honor driver-native duplicate detection (T1Bridge)." 2>/dev/null)

if [ "${SOURCE_ONLY:-0}" = 1 ]; then
	# Source packages for a PPA (Launchpad builds and tests them).
	(cd "$LDIR" && dpkg-buildpackage -S -sa -d -us -uc)
	(cd "$FDIR" && dpkg-buildpackage -S -sa -d -us -uc)
	echo "source packages in $SRC"
	exit 0
fi

if [ "${CHECK:-0}" = 1 ]; then
	(cd "$LDIR" && dpkg-buildpackage -b -us -uc) # runs the test suite
else
	(cd "$LDIR" && DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -b -us -uc)
fi
(cd "$FDIR" && DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -b -us -uc)

# The driver must really be in the library (a silently unpatched build happened once).
lib=$(ls "$SRC"/libfprint-2-2_*"$SUFFIX"_amd64.deb)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
dpkg-deb -x "$lib" "$tmp"
# grep -c reads all input (grep -q would SIGPIPE strings and fail under pipefail)
[ "$(strings "$tmp"/usr/lib/*/libfprint-2.so.2.* | grep -c '/run/t1bridge/fingerprint.sock')" -ge 1 ] ||
	{ echo "built libfprint does not contain the T1Bridge driver" >&2; exit 1; }

mv "$SRC"/*.deb "$OUT"/
echo "built in $OUT: libfprint $(newver "$LIBFPRINT_VERSION"), fprintd $(newver "$FPRINTD_VERSION")"
