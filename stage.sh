#!/bin/bash
# Install T1Bridge (already built with cargo) plus the Ubuntu additions into a
# package root. Shared by build-deb.sh (local .deb) and debian/rules (PPA).
#   stage.sh <t1bridge-source> <destdir> <extra-dir> [camera 0|1]
# <extra-dir> holds files/ and kernel/apple-t1-socw/ from t1bridge-ubuntu.
set -euo pipefail
SRC=$1
DEST=$2
EXTRA=$3
CAMERA=${4:-0}
UPSTREAM=0.1.12
DKMS_NAME=t1bridge
DKMS_DIR="$DEST/usr/src/$DKMS_NAME-$UPSTREAM"
R="$SRC/target/release"

for b in t1-touchbar-hw t1-touchbar t1-xart-storage t1-ncm-ready t1-keybag-relay \
	 t1-touchid-auth t1-touchid t1bridge; do
	[ -x "$R/$b" ] || { echo "missing $R/$b (cargo build first)" >&2; exit 1; }
done

# Binaries (layout as the Arch package; t1-legacy-recovery deliberately left
# out: it can drive the T1 FRST reset, which may leave the T1 in recovery mode).
install -Dm755 "$R/t1-touchbar-hw"  "$DEST/usr/lib/t1bridge/t1-touchbar-hw"
install -Dm755 "$R/t1-touchbar"     "$DEST/usr/lib/t1bridge/t1-touchbar"
install -Dm755 "$R/t1-xart-storage" "$DEST/usr/lib/t1bridge/t1-xart-storage"
install -Dm755 "$R/t1-ncm-ready"    "$DEST/usr/lib/t1bridge/t1-ncm-ready"
install -Dm755 "$R/t1-keybag-relay" "$DEST/usr/lib/t1bridge/t1-keybag-relay"
install -Dm755 "$R/t1-touchid-auth" "$DEST/usr/lib/t1bridge/t1-touchid-auth"
install -Dm755 "$R/t1-touchid"      "$DEST/usr/bin/t1-touchid"
install -Dm755 "$R/t1bridge"        "$DEST/usr/bin/t1bridge"
install -Dm755 "$EXTRA/files/t1-fw"  "$DEST/usr/lib/t1bridge/t1-fw"

# systemd, udev, sysusers, tmpfiles (unchanged upstream files)
S="$SRC/systemd"
for u in t1-touchbar-hw.service t1-touchbar-hw.socket t1-xart-storage@.service \
	 t1-ncm-ready@.service t1bridge-keybag.service t1-touchid-auth.service \
	 t1-touchid-auth.socket t1bridge-fingerprint.socket t1bridge-import.service; do
	install -Dm644 "$S/$u" "$DEST/usr/lib/systemd/system/$u"
done
install -Dm644 "$S/user/t1-touchbar.service" "$DEST/usr/lib/systemd/user/t1-touchbar.service"
install -Dm644 "$S/t1bridge.sysusers" "$DEST/usr/lib/sysusers.d/t1bridge.conf"
install -Dm644 "$S/t1bridge.conf" "$DEST/usr/lib/tmpfiles.d/t1bridge.conf"
install -Dm644 "$S/50-t1bridge-ncm.link" "$DEST/usr/lib/systemd/network/50-t1bridge-ncm.link"
install -Dm644 "$S/99-zz-t1bridge-touchbar.rules" "$DEST/usr/lib/udev/rules.d/99-zz-t1bridge-touchbar.rules"
install -Dm644 "$S/90-t1bridge-xart.rules" "$DEST/usr/lib/udev/rules.d/90-t1bridge-xart.rules"

# Ubuntu additions: per-interface ufw rule for the xART port, module blocks
install -Dm644 "$EXTRA/files/t1-xart-storage-ufw.conf" \
	"$DEST/usr/lib/systemd/system/t1-xart-storage@.service.d/50-ubuntu-ufw.conf"
install -Dm644 "$EXTRA/files/t1bridge.modprobe.conf" "$DEST/usr/lib/modprobe.d/t1bridge.conf"
install -Dm644 "$EXTRA/files/t1bridge.modules-load.conf" "$DEST/usr/lib/modules-load.d/t1bridge.conf"

# DKMS source
K="$SRC/kernel"
mkdir -p "$DKMS_DIR/kernel"/{t1-cfgsel,appletbdrm-t1,apple-t1-ncm,apple-t1-socw,dkms}
install -m644 "$K/t1-cfgsel/"{Makefile,t1_cfgsel.c,t1_recovery_reset.h} "$DKMS_DIR/kernel/t1-cfgsel/"
install -m644 "$K/appletbdrm-t1/"{Makefile,appletbdrm.c,appletbdrm_resume.h,appletbdrm_protocol.h} "$DKMS_DIR/kernel/appletbdrm-t1/"
install -m644 "$K/apple-t1-ncm/"{Makefile,apple_t1_ncm.c} "$DKMS_DIR/kernel/apple-t1-ncm/"
install -m644 "$EXTRA/kernel/apple-t1-socw/"{Makefile,apple_t1_socw.c} "$DKMS_DIR/kernel/apple-t1-socw/"
SUBDIRS="t1-cfgsel appletbdrm-t1 apple-t1-ncm apple-t1-socw"
if [ "$CAMERA" = 1 ]; then
	mkdir -p "$DKMS_DIR/kernel/uvcvideo-t1"
	install -m644 "$K/uvcvideo-t1/"{Makefile,uvc_*.c,uvc_*.h,uvcvideo.h} "$DKMS_DIR/kernel/uvcvideo-t1/"
	SUBDIRS="$SUBDIRS uvcvideo-t1"
fi
{
	echo 'KDIR ?= /lib/modules/$(shell uname -r)/build'
	echo 'KERNEL_ROOT := $(abspath $(CURDIR)/..)'
	echo '.PHONY: all clean'
	echo 'all:'
	for d in $SUBDIRS; do printf '\t$(MAKE) -C $(KERNEL_ROOT)/%s KDIR=$(KDIR)\n' "$d"; done
	echo 'clean:'
	for d in $SUBDIRS; do printf '\t$(MAKE) -C $(KERNEL_ROOT)/%s KDIR=$(KDIR) clean\n' "$d"; done
} > "$DKMS_DIR/kernel/dkms/Makefile"
{
	echo "PACKAGE_NAME=\"$DKMS_NAME\""
	echo "PACKAGE_VERSION=\"$UPSTREAM\""
	echo 'MAKE[0]="make -C kernel/dkms KDIR=/lib/modules/${kernelver}/build"'
	echo 'CLEAN="make -C kernel/dkms clean"'
	i=0
	for m in t1_cfgsel:t1-cfgsel appletbdrm:appletbdrm-t1 apple_t1_ncm:apple-t1-ncm \
		 apple_t1_socw:apple-t1-socw $([ "$CAMERA" = 1 ] && echo uvcvideo:uvcvideo-t1); do
		echo "BUILT_MODULE_NAME[$i]=\"${m%%:*}\""
		echo "BUILT_MODULE_LOCATION[$i]=\"kernel/${m#*:}\""
		echo "DEST_MODULE_LOCATION[$i]=\"/updates/dkms\""
		i=$((i + 1))
	done
	echo 'AUTOINSTALL="yes"'
} > "$DKMS_DIR/dkms.conf"
chmod 644 "$DKMS_DIR/dkms.conf" "$DKMS_DIR/kernel/dkms/Makefile"

install -Dm644 "$SRC/LICENSE" "$DEST/usr/share/doc/t1bridge-ubuntu/LICENSE"
install -Dm644 "$SRC/THIRD_PARTY_NOTICES.md" "$DEST/usr/share/doc/t1bridge-ubuntu/THIRD_PARTY_NOTICES.md"
install -Dm644 "$SRC/kernel/LICENSE.md" "$DEST/usr/share/doc/t1bridge-ubuntu/KERNEL-LICENSES.md"
