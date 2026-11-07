#!/bin/bash
# Switch the MacBookPro14,2 T1 between the legacy apple-ibridge stack (USB
# configuration 1) and T1Bridge (configuration 2: Touch Bar + Touch ID).
#
#   sudo ./t1-switch.sh install   install T1Bridge + matched libfprint/fprintd, then reboot
#   sudo ./t1-switch.sh revert    back to apple-ibridge + stock libfprint/fprintd, then reboot
#   sudo ./t1-switch.sh status
#   sudo ./t1-switch.sh pam       Touch ID for sudo and Polkit (after a successful enroll)
#   sudo ./t1-switch.sh unpam     undo the PAM step
#   sudo ./t1-switch.sh greeter-on|greeter-off   Touch Bar on the GDM login screen (on by install)
#
# The lock screen and login screen are deliberately kept off fingerprint
# (a reader re-armed every ~30 s reportedly wedged the T1's Secure Enclave).
# Run install/revert from a terminal inside your graphical session.
# /etc/pam.d/polkit-1 (created by 'pam') shadows /usr/lib/pam.d/polkit-1; 'unpam' removes it.
# Do not run the 't1bridge' recovery subcommands: they are experimental and can
# leave the T1 in recovery mode.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DEBSRC=${DEBSRC:-$HERE/out/fprint}	# from ./build-fprint.sh
T1DEB=$(ls "$HERE"/out/t1bridge-ubuntu_*_amd64.deb 2>/dev/null | sort -V | tail -1 || :)
STATE=/var/lib/t1bridge-ubuntu-switch
OLD_RULE=/etc/udev/rules.d/90-apple-ibridge-t1.rules
GDM_DEFAULTS=/etc/gdm3/greeter.dconf-defaults
GDM_MARK='# t1bridge-ubuntu: no fingerprint on the login screen'
PAM_LINE='auth	sufficient	pam_fprintd.so max-tries=3 timeout=15	# t1bridge-ubuntu'
PAM_MARK='# t1bridge-ubuntu'
FP_PKGS="libfprint-2-2 libfprint-2-tod1 fprintd libpam-fprintd gir1.2-fprint-2.0 libfprint-2-dev"
LOG=/var/log/t1-switch.log
GREETER_PAM=/etc/pam.d/gdm-launch-environment
# GDM 49+ runs the login screen as a dynamic userdb user (gdm-greeter; -2, -3
# only while an old greeter is still closing). nss-systemd reads these
# membership drop-ins in initgroups(), so the greeter gets group t1bridge.
GREETER_USERS="gdm-greeter gdm-greeter-2 gdm-greeter-3"
USERDB_DIR=/etc/userdb
GDM_FP_PAM=/etc/pam.d/gdm-fingerprint
GDM_FP_LINE='auth	requisite	pam_deny.so	# t1bridge-ubuntu: no fingerprint at GDM or the lock screen'
GDM_FP_MARK='# t1bridge-ubuntu: no fingerprint at GDM or the lock screen'

die() { echo "error: $*" >&2; exit 1; }
say() { echo "== $*"; echo "$(date -Is) $*" >> "$LOG"; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
USER_NAME=${SUDO_USER:-}
[ -n "$USER_NAME" ] && [ "$USER_NAME" != root ] || die "run with sudo from your own account"
USER_ID=$(id -u "$USER_NAME")

t1_config() { # bConfigurationValue of the internal T1 (05ac:8600), or "none"
	local d
	for d in /sys/bus/usb/devices/*; do
		[ -f "$d/idVendor" ] || continue
		if [ "$(cat "$d/idVendor")" = 05ac ] && [ "$(cat "$d/idProduct")" = 8600 ]; then
			cat "$d/bConfigurationValue"; return
		fi
	done
	echo none
}

installed() { dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -qx installed; }

# Debs for the fingerprint packages that are installed now, from directory $1
pick_debs() {
	local dir=$1 p f out=()
	for p in $FP_PKGS; do
		installed "$p" || continue
		f=$(ls "$dir"/"${p}"_*.deb 2>/dev/null | grep -v -- -doc_ | sort -V | tail -1 || :)
		[ -n "$f" ] || die "no $p .deb in $dir"
		out+=("$f")
	done
	printf '%s\n' "${out[@]}"
}

user_gsetting() { # run gsettings as the user, in their running session
	[ -S "/run/user/$USER_ID/bus" ] || return 1
	runuser -u "$USER_NAME" -- env HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)" \
		XDG_RUNTIME_DIR="/run/user/$USER_ID" \
		DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" gsettings "$@"
}

no_fp_in_common_auth() {
	! grep -q '^[^#]*pam_fprintd' /etc/pam.d/common-auth ||
		die "pam_fprintd is in common-auth (pam-auth-update 'Fingerprint authentication'); that would put the reader on the lock screen. Disable it with: pam-auth-update --disable fprintd"
}

gdm_fp_block() { # backstop: GDM's fingerprint PAM service always fails
	[ -f "$GDM_FP_PAM" ] || return 0
	grep -qF "$GDM_FP_MARK" "$GDM_FP_PAM" && return 0
	grep -q '^#%PAM-1.0' "$GDM_FP_PAM" || die "$GDM_FP_PAM has no '#%PAM-1.0' header; not touching it"
	sed -i "0,/^#%PAM-1.0/s//&\n$(printf '%s' "$GDM_FP_LINE" | sed 's/[&/\]/\\&/g')/" "$GDM_FP_PAM"
	sed -n '2p' "$GDM_FP_PAM" | grep -qF "$GDM_FP_MARK" || die "could not add the pam_deny backstop to $GDM_FP_PAM"
}

gdm_fp_unblock() {
	[ -f "$GDM_FP_PAM" ] && grep -qF "$GDM_FP_MARK" "$GDM_FP_PAM" || return 0
	sed -i "/$GDM_FP_MARK\$/d" "$GDM_FP_PAM"
}

do_install() {
	[ -n "$T1DEB" ] || die "no out/t1bridge-ubuntu_*.deb; run ./build-deb.sh first"
	[ -f /boot/efi/EFI/APPLE/EMBEDDEDOS/FDRData ] || die "Apple EFI data missing: /boot/efi/EFI/APPLE/EMBEDDEDOS/FDRData"
	[ -d "/lib/modules/$(uname -r)/build" ] || die "no kernel headers for $(uname -r)"
	[ "$(t1_config)" != none ] || die "T1 (05ac:8600) not found"
	[ ! -e "$STATE/installed" ] || die "already switched (see status); revert first"
	[ -e /etc/modprobe.d/macbook-touchbar-off.conf ] && die "remove /etc/modprobe.d/macbook-touchbar-off.conf (macbook-hw touchbar off) first"
	[ -S "/run/user/$USER_ID/bus" ] || die "run this from a terminal inside your graphical session (needed to switch the lock screen off fingerprint)"
	no_fp_in_common_auth
	mapfile -t NEW < <(pick_debs "$DEBSRC")

	# Keep the exact Ubuntu builds installed now, for revert.
	mkdir -p "$STATE/stock-debs"; chmod 700 "$STATE"
	for p in $FP_PKGS; do
		installed "$p" || continue
		v=$(dpkg-query -W -f='${Version}' "$p")
		case "$v" in *t1bridge*) die "$p is already a +t1bridge build ($v); revert first" ;; esac
		(cd "$STATE/stock-debs" && apt-get download "$p=$v") || die "could not download $p $v for revert"
	done
	pick_debs "$STATE/stock-debs" >/dev/null	# fail now, not at revert time
	say "install: T1 config $(t1_config), kernel $(uname -r), $(basename "$T1DEB")"

	# Lock screen and login screen off fingerprint before any reader exists.
	say "keeping GDM and the lock screen off fingerprint"
	user_gsetting set org.gnome.login-screen enable-fingerprint-authentication false ||
		die "could not change your GNOME setting (gsettings failed)"
	[ "$(user_gsetting get org.gnome.login-screen enable-fingerprint-authentication)" = false ] ||
		die "GNOME setting enable-fingerprint-authentication is not false"
	if [ -f "$GDM_DEFAULTS" ] && ! grep -qF "$GDM_MARK" "$GDM_DEFAULTS"; then
		grep -q '^\[org/gnome/login-screen\]' "$GDM_DEFAULTS" ||
			printf '\n[org/gnome/login-screen]\n' >> "$GDM_DEFAULTS"
		sed -i "0,/^\[org\/gnome\/login-screen\]/s//&\n$GDM_MARK\nenable-fingerprint-authentication=false/" "$GDM_DEFAULTS"
	fi
	gdm_fp_block

	say "installing $(basename "$T1DEB")"
	apt-get install -y --no-remove "$T1DEB"
	say "installing ${NEW[*]##*/}"
	apt-get install -y --no-remove "${NEW[@]}"
	# shellcheck disable=SC2086
	apt-mark hold $(for p in $FP_PKGS; do installed "$p" && echo "$p"; done)

	if [ -e "$OLD_RULE" ]; then
		say "moving $OLD_RULE aside"
		mv "$OLD_RULE" "$STATE/"
	fi

	say "adding $USER_NAME to group t1bridge; enabling units"
	usermod -aG t1bridge "$USER_NAME"
	systemctl daemon-reload
	systemctl enable t1-touchbar-hw.service t1-touchid-auth.socket t1bridge-fingerprint.socket
	systemctl --global enable t1-touchbar.service
	greeter_on

	say "rebuilding initramfs (picks up the module blocks)"
	update-initramfs -u -k all

	touch "$STATE/installed"
	say "done. Shut down fully, power on, log in, then: sudo t1bridge status"
}

greeter_on() { # Touch Bar on the login screen: group t1bridge for GDM's greeter user
	local u f gid
	greeter_pam_cleanup
	gid=$(getent group t1bridge | cut -d: -f3) || gid=
	[ -n "$gid" ] || { echo "   (group t1bridge missing; login-screen Touch Bar skipped)"; return 0; }
	install -d -m 0755 "$USERDB_DIR"
	for u in $GREETER_USERS; do
		f="$USERDB_DIR/$u:t1bridge.membership"
		[ -e "$f" ] || { printf '{}\n' > "$f"; chmod 0644 "$f"; }
	done
	if getent initgroups gdm-greeter | tr ' ' '\n' | grep -qx "$gid"; then
		say "Touch Bar enabled on the GDM login screen ($USERDB_DIR/gdm-greeter:t1bridge.membership)"
	else
		echo "   warning: gdm-greeter does not resolve to group t1bridge (is 'systemd' in the group: line of /etc/nsswitch.conf?)" >&2
	fi
}

greeter_off() {
	local u f had=
	greeter_pam_cleanup
	for u in $GREETER_USERS; do
		f="$USERDB_DIR/$u:t1bridge.membership"
		[ -e "$f" ] && { rm -f "$f"; had=1; }
	done
	rmdir "$USERDB_DIR" 2>/dev/null || :
	[ -z "$had" ] || say "Touch Bar on the login screen disabled (takes effect at the next login screen)"
}

greeter_pam_cleanup() { # 0.1.12-3 used a pam_exec ACL hook; remove it
	[ -f "$GREETER_PAM" ] && grep -qF "$PAM_MARK" "$GREETER_PAM" || return 0
	sed -i "/$PAM_MARK\$/d" "$GREETER_PAM"
	say "removed the old ACL hook line from $GREETER_PAM"
}

do_unpam() {
	local f
	for f in /etc/pam.d/sudo /etc/pam.d/sudo-i; do
		[ -f "$f" ] && grep -q "$PAM_MARK" "$f" && { sed -i "/$PAM_MARK\$/d" "$f"; say "removed fingerprint line from $f"; }
	done
	if [ -f /etc/pam.d/polkit-1 ] && grep -q "$PAM_MARK" /etc/pam.d/polkit-1; then
		if [ -f "$STATE/polkit-1.created" ]; then
			rm -f /etc/pam.d/polkit-1 "$STATE/polkit-1.created"
			say "removed /etc/pam.d/polkit-1 (back to /usr/lib/pam.d/polkit-1)"
		else
			sed -i "/$PAM_MARK\$/d" /etc/pam.d/polkit-1
			say "removed fingerprint line from /etc/pam.d/polkit-1"
		fi
	fi
}

do_revert() {
	[ -d "$STATE/stock-debs" ] || die "no saved state in $STATE; nothing to revert"
	say "revert: T1 config $(t1_config)"
	do_unpam
	mapfile -t OLD < <(pick_debs "$STATE/stock-debs")
	# shellcheck disable=SC2086
	apt-mark unhold $FP_PKGS >/dev/null 2>&1 || :
	if dpkg-query -W -f='${db:Status-Status}' t1bridge-ubuntu 2>/dev/null |
		grep -qvE '^(not-installed|config-files)?$'; then
		say "removing t1bridge-ubuntu (enrolled data stays in /var/lib/t1bridge)"
		apt-get remove -y t1bridge-ubuntu ||
			dpkg --remove --force-remove-reinstreq t1bridge-ubuntu
	fi
	say "reinstalling stock ${OLD[*]##*/}"
	apt-get install -y --no-remove --allow-downgrades "${OLD[@]}"
	if [ -e "$STATE/$(basename "$OLD_RULE")" ]; then
		mv "$STATE/$(basename "$OLD_RULE")" "$OLD_RULE"
		say "restored $OLD_RULE"
	fi
	if [ -f "$GDM_DEFAULTS" ] && grep -qF "$GDM_MARK" "$GDM_DEFAULTS"; then
		sed -i "/^$GDM_MARK\$/{N;d}" "$GDM_DEFAULTS"
	fi
	gdm_fp_unblock
	greeter_off
	user_gsetting reset org.gnome.login-screen enable-fingerprint-authentication ||
		echo "   (as yourself, run: gsettings reset org.gnome.login-screen enable-fingerprint-authentication)"
	systemctl --global disable t1-touchbar.service 2>/dev/null || :
	gpasswd -d "$USER_NAME" t1bridge >/dev/null 2>&1 || :
	systemctl daemon-reload
	update-initramfs -u -k all
	rm -f "$STATE/installed"
	say "done. Shut down fully and power on (the T1 then comes up in configuration 1)."
}

do_pam() {
	[ -e "$STATE/installed" ] || die "T1Bridge is not installed (run install first)"
	no_fp_in_common_auth
	fprintd-list "$USER_NAME" 2>/dev/null | grep -q -- '- #' ||
		die "no enrolled finger for $USER_NAME yet (fprintd-enroll first)"
	local ts f
	ts=$(date +%s)
	for f in /etc/pam.d/sudo /etc/pam.d/sudo-i; do
		[ -f "$f" ] && cp -a "$f" "$STATE/$(basename "$f").bak.$ts"
	done
	for f in /etc/pam.d/sudo /etc/pam.d/sudo-i; do
		[ -f "$f" ] || continue
		grep -q "$PAM_MARK" "$f" && continue
		grep -q '^@include common-auth' "$f" || die "$f has no '@include common-auth'; not touching it"
		sed -i "0,/^@include common-auth/s//$(printf '%s' "$PAM_LINE" | sed 's/[&/\]/\\&/g')\n@include common-auth/" "$f"
		say "added fingerprint before the password stack in $f"
	done
	if [ ! -e /etc/pam.d/polkit-1 ]; then
		cp /usr/lib/pam.d/polkit-1 /etc/pam.d/polkit-1
		touch "$STATE/polkit-1.created"
	fi
	if ! grep -q "$PAM_MARK" /etc/pam.d/polkit-1; then
		grep -q '^@include common-auth' /etc/pam.d/polkit-1 || die "polkit-1 has no '@include common-auth'"
		sed -i "0,/^@include common-auth/s//$(printf '%s' "$PAM_LINE" | sed 's/[&/\]/\\&/g')\n@include common-auth/" /etc/pam.d/polkit-1
		say "added fingerprint before the password stack in /etc/pam.d/polkit-1"
	fi
	for f in /etc/pam.d/sudo /etc/pam.d/sudo-i /etc/pam.d/polkit-1; do
		[ -f "$f" ] || continue
		# The password stack must still follow the fingerprint line.
		awk -v m="$PAM_MARK" 'index($0,m){s=1;next} s && /^@include common-auth/{ok=1} END{exit !ok}' "$f" ||
			{ do_unpam; die "check of $f failed; PAM step undone"; }
	done
	echo "Test in a NEW terminal (keep this one open): sudo -k; sudo true"
}

do_status() {
	echo "T1 USB configuration: $(t1_config) (1 = apple-ibridge, 2 = T1Bridge)"
	echo "switched:             $([ -e "$STATE/installed" ] && echo yes || echo no)"
	for p in t1bridge-ubuntu $FP_PKGS; do
		printf '  %-18s %s\n' "$p" "$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || echo -)"
	done
	echo "held: $(apt-mark showhold | tr '\n' ' ')"
	echo "modules: $(lsmod | awk '$1 ~ /^(t1_cfgsel|appletbdrm|apple_t1_ncm|apple_t1_socw|apple_ibridge|apple_ib_tb|apple_ib_als|hid_sensor_als|uvcvideo)$/{printf "%s ", $1}')"
	echo "PAM fingerprint lines: $(grep -l "$PAM_MARK" /etc/pam.d/* 2>/dev/null | tr '\n' ' ')"
	if grep -q '^[^#]*pam_fprintd' /etc/pam.d/common-auth 2>/dev/null; then
		echo "Login/lock screen fingerprint: ON (pam_fprintd in common-auth, via pam-auth-update)"
	elif grep -qF "$GDM_FP_MARK" "$GDM_FP_PAM" 2>/dev/null; then
		echo "Login/lock screen fingerprint: off (gdm-fingerprint blocked)"
	else
		echo "Login/lock screen fingerprint: not blocked"
	fi
	echo "Touch Bar on login screen: $([ -e "$USERDB_DIR/gdm-greeter:t1bridge.membership" ] && echo on || echo off)"
	if command -v t1bridge >/dev/null; then t1bridge status || :; fi
}

case "${1:-}" in
install) do_install ;;
revert) do_revert ;;
pam) do_pam ;;
unpam) do_unpam ;;
greeter-on) mkdir -p "$STATE"; greeter_on ;;
greeter-off) greeter_off ;;
status) do_status ;;
*) sed -n '2,12p' "$0"; exit 2 ;;
esac
