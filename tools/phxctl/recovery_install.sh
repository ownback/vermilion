#!/bin/sh
# SPDX-License-Identifier: MIT
# recovery_install.sh: install Vermilion's userspace (docs/INSTALL.md sections 4 to 7) onto an installed macOS from
# Recovery's Terminal, for a machine whose desktop is too slow to use before the GPU driver runs. The XTX machine
# (docs/REFERENCE-MACHINES.md) gets its files this way: Linux stages this script and the payload on the EFI partition
# (tools/phxctl/esp_stage.sh), Recovery runs it, and the next normal boot runs the boot daemon.
#
#   mkdir -p /tmp/efi && diskutil mount -mountPoint /tmp/efi disk2s1 && sh /tmp/efi/vermilion/install.sh
#
# In Recovery disk0 and disk1 are Recovery's own disk image; the NVMe was disk2 on the XTX machine (2026-11-19).
# `diskutil list` shows the EFI partition (TYPE EFI). It is unlabeled ("NO NAME"), so mount it at a fixed point.
#
# It also runs on the live system (sudo sh .../install.sh), where it installs into /.
#
# What it does, in order (every replaced file is first copied to <home>/vermilion-rollback/<time>/):
#   1. finds the target Data volume (the one /Volumes entry with a local directory and /Users) and its one user
#      (uid >= 501, from the local directory, not from the file owners); VERMILION_USER picks one if there are several
#   2. /Library/GPUBundles: NVMTLDriver.bundle (Info.plist written here: Vermilion builds only the executable),
#      the plugin, the translator, RADV, the shader caches (owned by _windowserver), an allow list of "*"
#   3. /Library/Extensions/VermilionAccel.kext; /usr/local/sbin/phxctl, mesboot; /usr/local/bin/spirv-val
#   4. <home>/gpu: the daemon, the bring-up and helper scripts, phxctl.bin, metaltest, the firmware, the flags in
#      VERMILION_FLAGS (default none: every proven feature is on by default in the daemon, 2026-11-26), and
#      esp_flags.sh as the daemon's pre-hook (phxboot-pre.sh)
#   5. /Library/LaunchDaemons/local.phxboot.plist from the template
#   6. Software Update: no automatic download or install (the stack is pinned to macOS 26.7.1)
# It never touches the system volume, NVRAM or the EFI partition, and it sets no desktop-arm flag: the first boot runs
# the bring-up and gives apps Metal while WindowServer stays on the firmware framebuffer (docs/INSTALL.md 8.1).
# VERMILION_DATA=<dir>, VERMILION_NOCHOWN=1 and VERMILION_PLISTBUDDY=<path> are for tests (tests/mock/recovery_install_test.sh).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
P=${VERMILION_PAYLOAD:-$HERE/payload}
PB=${VERMILION_PLISTBUDDY:-/usr/libexec/PlistBuddy}   # VERMILION_PLISTBUDDY: the mock tests' PlistBuddy off macOS
say() { echo "vermilion-install: $*"; }
die() { echo "vermilion-install: ERROR: $*" >&2; exit 1; }
for f in build/NVMTLDriver build/libnvmtl_translate.dylib build/libvulkan_radeon.dylib build/VermilionAccel.kext \
         build/phxctl build/mesboot build/metaltest build/spirv-val build/phxaudio tools/phxctl/phxboot-navi31.sh \
         tools/phxctl/local.phxboot.plist.in tools/phxctl/esp_flags.sh fw/navi31/smu_13_0_0.bin; do
  [ -e "$P/$f" ] || die "payload incomplete: $P/$f missing"
done
[ "$(id -u)" = 0 ] || [ "${VERMILION_NOCHOWN:-0}" = 1 ] || die "run as root (Recovery's Terminal is root; on the live system use sudo)"

# 1. target Data volume and user
D=${VERMILION_DATA-}
if [ -z "${VERMILION_DATA+x}" ]; then
  n=0
  for v in /Volumes/*; do
    [ -d "$v/private/var/db/dslocal/nodes/Default/users" ] && [ -d "$v/Users" ] || continue
    D=$v; n=$((n+1))
  done
  if [ $n = 0 ] && [ -d /private/var/db/dslocal/nodes/Default/users ] && [ -d /Users ] && [ ! -d /System/Installation ]; then
    D=""; n=1; say "no Data volume under /Volumes: installing into the running system"
  fi
  [ $n = 1 ] || die "found $n Data volumes under /Volumes; mount exactly the target one (diskutil mount 'Macintosh HD - Data')"
  if [ -n "$D" ]; then diskutil enableOwnership "$D" >/dev/null 2>&1 || say "note: diskutil enableOwnership failed on $D"; fi
fi
UD=$D/private/var/db/dslocal/nodes/Default/users
U=${VERMILION_USER:-}
if [ -z "$U" ]; then
  for f in "$UD"/*.plist; do
    id=$("$PB" -c "Print :uid:0" "$f" 2>/dev/null || echo 0)
    [ "$id" -ge 501 ] 2>/dev/null || continue
    [ -z "$U" ] || die "several users (uid >= 501); pick one with VERMILION_USER=<short name>"
    U=$(basename "$f" .plist)
  done
fi
[ -n "$U" ] || die "no user with uid >= 501 in $UD (finish Setup Assistant first)"
UID_=$("$PB" -c "Print :uid:0" "$UD/$U.plist"); GID_=$("$PB" -c "Print :gid:0" "$UD/$U.plist" 2>/dev/null || echo 20)
UH=$("$PB" -c "Print :home:0" "$UD/$U.plist")           # e.g. /Users/name, as the live system sees it
H=$D$UH; [ -d "$H" ] || die "home $H missing"
say "target: ${D:-/} user $U (uid $UID_, home $UH)"
RB=$H/vermilion-rollback/$(date +%Y%m%d-%H%M%S)

own() {   # own <uid:gid> <mode> <path>...: owner and mode, recursively for directories
  o=$1; m=$2; shift 2
  [ "${VERMILION_NOCHOWN:-0}" = 1 ] || chown -R "$o" "$@"
  chmod -R "$m" "$@"
}
put() {   # put <src> <dst> <uid:gid> <mode>: copy, keeping the old one in the rollback dir, then move into place
  s=$1; t=$2
  mkdir -p "$(dirname "$t")"
  if [ -e "$t" ]; then mkdir -p "$RB$(dirname "${t#$D}")"; cp -Rp "$t" "$RB${t#$D}"; fi
  rm -rf "$t.vnew"; cp -R "$s" "$t.vnew"; own "$3" "$4" "$t.vnew"; rm -rf "$t"; mv "$t.vnew" "$t"
}

# 2. GPU bundles
GB=$D/Library/GPUBundles; B=$GB/NVMTLDriver.bundle/Contents
mkdir -p "$B/MacOS" "$GB/nvmtl"
if [ ! -f "$B/Info.plist" ]; then
  cat >"$B/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>NVMTLDriver</string>
	<key>CFBundleIdentifier</key>
	<string>com.nullmoth.NVMTLDriver</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>NVMTLDriver</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>CFBundleVersion</key>
	<string>0.1</string>
</dict>
</plist>
EOF
  say "wrote NVMTLDriver.bundle/Contents/Info.plist (same keys as the bundle the reference machine runs)"
fi
put "$P/build/NVMTLDriver" "$B/MacOS/NVMTLDriver" 0:0 755
put "$P/build/libnvmtl_translate.dylib" "$B/MacOS/libnvmtl_translate.dylib" 0:0 755
put "$P/build/libvulkan_radeon.dylib" "$GB/nvmtl/libvulkan_radeon.dylib" 0:0 755
own 0:0 go-w,a+rX "$GB/NVMTLDriver.bundle"
[ "${VERMILION_NOCHOWN:-0}" = 1 ] || chown 0:0 "$GB" "$GB/nvmtl"; chmod 755 "$GB" "$GB/nvmtl"   # not -R: the caches below keep their owner
# the shared shader caches: WindowServer's (_windowserver, uid 88), writable by nobody else; existing entries are kept
for c in aircache spvcache; do mkdir -p "$GB/nvmtl/$c"; [ "${VERMILION_NOCHOWN:-0}" = 1 ] || chown 88:0 "$GB/nvmtl/$c"; chmod 0755 "$GB/nvmtl/$c"; done
printf '*\n' >"$GB/nvmtl-allow.txt"; own 0:0 644 "$GB/nvmtl-allow.txt"
say "GPU bundles installed"

# 3. kext and system tools (on the Data volume: /Library and /usr/local are not on the sealed system volume)
put "$P/build/VermilionAccel.kext" "$D/Library/Extensions/VermilionAccel.kext" 0:0 go-w,a+rX
put "$P/build/phxctl" "$D/usr/local/sbin/phxctl" 0:0 755
put "$P/build/mesboot" "$D/usr/local/sbin/mesboot" 0:0 755
put "$P/build/spirv-val" "$D/usr/local/bin/spirv-val" 0:0 755
say "VermilionAccel.kext, phxctl, mesboot, spirv-val installed"

# 4. ~/gpu (owned by the user: the daemon runs these as root from a directory the user can write; INSTALL.md 6)
G=$H/gpu; T=$P/tools/phxctl; UO=$UID_:$GID_
mkdir -p "$G/phxctl"
for f in phxboot-navi31.sh gfx_cg.sh sdma_idle.sh uclk.sh smumetrics.py ptwalk.sh m7_boot.sh m7_phase.sh dispovr.sh \
         b15_boot.sh wm144.sh det.sh dalwm.sh dal.sh hubp_dlg.sh p0prefetch.sh idle_dpm.sh audio_match.sh; do put "$T/$f" "$G/$f" "$UO" 755; done
for f in navi31_up.sh bringup_navi31.sh; do put "$T/$f" "$G/phxctl/$f" "$UO" 755; done
put "$T/esp_flags.sh" "$G/phxboot-pre.sh" "$UO" 755
put "$P/build/phxctl" "$G/phxctl.bin" "$UO" 755
put "$P/build/metaltest" "$G/metaltest" "$UO" 755
put "$P/build/phxaudio" "$G/phxaudio" "$UO" 755   # DP audio (on by default): the display engine's audio blocks
put "$P/fw/navi31" "$G/fw/navi31" "$UO" u+rwX,go+rX
for fl in ${VERMILION_FLAGS-}; do
  case "$fl" in *=*) printf '%s\n' "${fl#*=}" >"$G/${fl%%=*}"; fl=${fl%%=*};; *) : >"$G/$fl";; esac
  own "$UO" 644 "$G/$fl"
done
own "$UO" u+rwX "$G"
say "$UH/gpu installed (flags: $(cd "$G" && ls phxboot-* 2>/dev/null | grep -v -e '^phxboot-navi31.sh$' -e '^phxboot-pre.sh$' | tr '\n' ' '))"

# 5. LaunchDaemon
LD=$D/Library/LaunchDaemons/local.phxboot.plist; mkdir -p "$(dirname "$LD")"
sed -e "s|@PHX_ROOT@|$UH/gpu|g" -e "s|@PHX_USER@|$U|g" "$T/local.phxboot.plist.in" >"$LD.vnew"
plutil -lint "$LD.vnew" >/dev/null || die "rendered LaunchDaemon does not lint"
[ -e "$LD" ] && { mkdir -p "$RB/Library/LaunchDaemons"; cp -p "$LD" "$RB/Library/LaunchDaemons/"; }
own 0:0 644 "$LD.vnew"; mv "$LD.vnew" "$LD"
say "LaunchDaemon local.phxboot installed"

# 6. Software Update: check, but never download or install by itself
SU=$D/Library/Preferences/com.apple.SoftwareUpdate.plist
for k in AutomaticDownload AutomaticallyInstallMacOSUpdates; do
  "$PB" -c "Set :$k false" "$SU" >/dev/null 2>&1 || "$PB" -c "Add :$k bool false" "$SU" >/dev/null
done
say "Software Update: automatic download and macOS install off"
[ -d "$RB" ] && [ "${VERMILION_NOCHOWN:-0}" != 1 ] && chown -R "$UO" "$H/vermilion-rollback"
sync
say "done. Restart into Macintosh HD and do not log in for ~3 minutes; /var/log/phxboot.log tells what happened."
