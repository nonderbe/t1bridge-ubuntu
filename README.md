# t1bridge-ubuntu

Touch ID, Touch Bar and the private T1 link on **Ubuntu** for MacBook Pros with
an Apple **T1** chip, using [T1Bridge](https://github.com/standardagents/t1bridge)
(which only ships Arch packages). This repository holds only the Ubuntu
packaging and switch scripts. All T1 protocol work is T1Bridge's.

> [!CAUTION]
> Touch ID needs this Mac's original `EFI/APPLE/EMBEDDEDOS/FDRData` on the EFI
> partition. Read T1Bridge's README before you erase or repartition anything,
> and back the folder up.

Tested on a **MacBookPro14,2** (13", 2017) with **Ubuntu 26.04**, kernel
7.0.0-43, GNOME 50, T1Bridge **v0.1.12**:

- Touch Bar, ambient light, machine-data import, enrollment and verification work.
- The Touch Bar also works on the GDM login screen, and its volume, mute and
  media buttons work in GNOME (a small PipeWire/MPRIS desktop provider).
- fingerprint authentication works for `sudo` and Polkit (password always remains the fallback).
- The GDM login screen and the GNOME lock screen are kept off the reader on
  purpose. A reader re-armed every ~30 s by a lock screen reportedly wedged the
  T1's Secure Enclave.

**Not yet tested:** system sleep with T1Bridge
([#18](https://github.com/standardagents/t1bridge/issues/18)), other models,
and other Ubuntu releases.

## What it does

The T1 has two USB configurations:
- **Configuration 1** is what the older `apple-ibridge` / `apple-ib-tb` drivers use.
- **Configuration 2** is what T1Bridge needs for Touch ID.

You can't run both, so switching means replacing the legacy Touch Bar driver.
`t1-switch.sh revert` goes back.

| Piece | How |
| --- | --- |
| T1Bridge services, units, udev rules | `build-deb.sh`, which produces `out/t1bridge-ubuntu_*.deb` |
| Kernel modules: `t1_cfgsel`, `appletbdrm` (T1), `apple_t1_ncm` | DKMS source inside that `.deb`, built for every installed kernel |
| Sleep/wake call to the T1 (`ASOC.SOCW`) | `apple_t1_socw`, the SOCW part of the legacy apple-ibridge driver on its own. Upstream PR [#58](https://github.com/standardagents/t1bridge/pull/58) moves this into `appletbdrm`. |
| libfprint driver + fprintd fix | `build-fprint.sh`, which rebuilds Ubuntu's own source packages with T1Bridge's patches (`fprint/`) as `+t1bridge1` |
| xART port 61500 in ufw | a link-local-only rule on the `apple_t1_ncm` interface, added when the link comes up |
| Switch, revert, PAM | `t1-switch.sh` |

T1Bridge's experimental `t1-legacy-recovery` tool is not packaged.

## Use

```sh
# 0. T1Bridge source, built as your user (cargo downloads 27 crates once; the PPA source package vendors them)
git clone https://github.com/standardagents/t1bridge ~/src/t1bridge
cd ~/src/t1bridge && git checkout v0.1.12
# the binaries build as is; `cargo test` on Debian/Ubuntu also needs debian/patches/as-needed-link-order.patch
sudo apt install rustc cargo pkg-config libcurl4-openssl-dev libarchive-dev libssl-dev liblzma-dev libudev-dev libsystemd-dev devscripts dkms
cargo build --locked --release -p t1-touchbar-hw --bin t1-touchbar-hw --features service
cargo build --locked --release -p t1-touchbar --bin t1-touchbar
cargo build --locked --release -p t1-daemons --bin t1-xart-storage
cargo build --locked --release -p t1-daemons --bin t1-ncm-ready
cargo build --locked --release -p t1-daemons --bin t1-touchid
cargo build --locked --release -p t1-daemons --bin t1-keybag-relay --features keybag-relay-service
cargo build --locked --release -p t1-daemons --bin t1-touchid-auth --features auth-broker-service
cargo build --locked --release -p t1-import --bin t1bridge

# 1. packages (as your user)
cd ~/src/t1bridge-ubuntu
SRC=~/src/t1bridge ./build-deb.sh
./build-fprint.sh --fetch-only
sudo apt build-dep ./out/fprint/src/libfprint-*/ ./out/fprint/src/fprintd-*/
./build-fprint.sh

# 2. switch (from a terminal inside your graphical session), then shut down fully and power on
sudo ./t1-switch.sh install
sudo t1bridge status                      # every row "ready"; keybag "not-enrolled" is normal

# 3. Touch ID
sudo systemctl start t1bridge-import.service
fprintd-enroll -f right-index-finger      # if "enroll-unknown-error": sudo systemctl restart t1-touchid-auth.service, retry
fprintd-verify -f right-index-finger
sudo ./t1-switch.sh pam                   # sudo + Polkit; keep a root shell open while testing

# back to the legacy driver
sudo ./t1-switch.sh revert                # then shut down fully and power on
```

## From the PPA

A PPA with `t1bridge-ubuntu` and the matching `+t1bridge1` libfprint and
fprintd is prepared (`debian/`) but not uploaded yet. Once it is: **don't install them with plain `apt install`:** the package takes over
the T1 at the next boot. Use `t1-switch.sh install`, which points at local
`.deb`s, after downloading them with `apt download t1bridge-ubuntu libfprint-2-2
libfprint-2-tod1 fprintd libpam-fprintd` into `out/` and `out/fprint/`.

`t1-switch.sh install` keeps the currently installed Ubuntu fingerprint
packages for revert, so they must still be downloadable. Ubuntu keeps only the
newest version, so run `sudo apt upgrade` first.

## Things that bit us on Ubuntu

- **The initrd is built by dracut** (Ubuntu 26.04). dracut copies *every*
  module in `updates/` into the initrd, so all DKMS modules go in.
  - That is fine for `t1_cfgsel`.
  - It can break other DKMS drivers. A DKMS `brcmfmac` lost Wi-Fi this way;
    the fix was `omit_drivers` in `/etc/dracut.conf.d/`.
  - The package rebuilds the initrd on install and removal.
- **ufw:** per [t1bridge#57](https://github.com/standardagents/t1bridge/issues/57),
  an enabled ufw without a rule for TCP 61500 on the T1 link breaks Touch ID.
  The package adds a link-local-only rule for that interface (not tested with
  ufw enabled here). Never open that port on Wi-Fi or Ethernet.
- **Touch Bar brightness vs. GNOME automatic brightness:** T1Bridge sets the
  backlight through logind, and GNOME's ambient mode puts its own value back
  within a second, so the brightness buttons seem dead. Workaround: turn off
  Settings → Displays → Automatic Screen Brightness
  (`gsettings set org.gnome.settings-daemon.plugins.power ambient-enabled false`).
  Proposed upstream fix: optional brightness key taps (https://github.com/standardagents/t1bridge/issues/61).
- **Touch Bar dark on the login screen:** GDM 49+ runs the greeter as a
  dynamic userdb user (`gdm-greeter`), which can't be added to group
  `t1bridge` with `usermod`, and the hardware service checks that group with
  `SO_PEERGROUPS`. `nss-systemd` reads userdb membership drop-ins in
  `initgroups()`, so `t1-switch.sh greeter-on` (run by `install`) writes
  `/etc/userdb/gdm-greeter:t1bridge.membership`. The greeter only gets the
  Touch Bar while it is the active seat0 session.
- **Touch Bar not back after logout and login:** the upstream user unit is
  `WantedBy=default.target`, and the user manager outlives a logout, so nothing
  restarted the renderer. The package adds it to `graphical-session.target.wants`
  ([t1bridge#35](https://github.com/standardagents/t1bridge/issues/35) has the
  same root cause).
- **First enrollment** often fails with `enroll-unknown-error`. Restart
  `t1-touchid-auth.service` and try again.
- **If Touch ID breaks, don't run `fprintd-delete`.** It can leave an identity
  in the Secure Enclave that fprintd can no longer see
  ([t1bridge#57](https://github.com/standardagents/t1bridge/issues/57)).
- **Held packages:** the `+t1bridge1` fingerprint packages are held, so Ubuntu
  updates for them stop. Rebuild with `build-fprint.sh` when Ubuntu publishes
  a new libfprint or fprintd.

## Licences

- The scripts and packaging in this repository are MIT.
- `kernel/apple-t1-socw` is GPL-2.0.
- The patches in `fprint/` come from T1Bridge (MIT) and apply to libfprint
  (LGPL-2.1+) and fprintd (GPL-2.0+).
