#!/bin/bash
# SPDX-License-Identifier: MIT
# pkg_scripts_test.sh: hardware-free test of the package scripts in scripts/release/pkg (preinstall, postinstall,
# vermilion-uninstall) against a fake root folder, with fake sw_vers / ioreg / dscl / pkgutil / launchctl / nvram /
# defaults. It checks: the preinstall refusals (macOS build, GPU revision, other boards), the rollback manifest, the
# postinstall's files, an update, and that the uninstaller puts back what was there before the first install.
# Nothing is installed on this machine: every path is under a temporary VERMILION_ROOT, no root, no chown.
# The install steps that need macOS itself (Installer, the real ioreg output on the XTX machine) are not covered.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../..
SR=$R/scripts/release
T=$(mktemp -d "${TMPDIR:-/tmp}/pkgscripts-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; [ -z "${2:-}" ] || sed 's/^/    /' "$2"; }
check() { if eval "$2"; then ok; else bad "$1" "${3:-}"; fi; }   # check <name> <shell condition> [log to show]

# ---- constants: the scripts' board constants are PhxGpuId.h's
H=$R/src/vermilion-boot/PhxGpuId.h
hv=$(sed -n 's/.*kVendorAmd = 0x\([0-9a-f]*\);.*/\1/p' "$H"); hd=$(sed -n 's/.*kDeviceNavi31 = 0x\([0-9a-f]*\);.*/\1/p' "$H"); hr=$(sed -n 's/.*kRevXtx = 0x\([0-9a-f]*\);.*/\1/p' "$H")
check "lib.sh vendor/device/revision are PhxGpuId.h's" '[ -n "$hv" ] && grep -q "^GPU_VENDOR=$hv\$" "$SR/pkg/lib.sh" && grep -q "^GPU_DEVICE=$hd\$" "$SR/pkg/lib.sh" && grep -q "^GPU_REV=$hr\$" "$SR/pkg/lib.sh"'
check "lib.sh names the four boards of the header" 'for r in c8 cc ce cf; do grep -q "^    $r) echo" "$SR/pkg/lib.sh" || exit 1; done'
check "lib.sh macOS build is 25G241" 'grep -q "^EXPECT_BUILD=25G241\$" "$SR/pkg/lib.sh"'

# ---- fakes
FB=$T/bin; mkdir -p "$FB"
cat >"$FB/sw_vers" <<'EOF'
#!/bin/sh
[ "$1" = -buildVersion ] && echo "${SIM_BUILD:-25G241}"
EOF
cat >"$FB/ioreg" <<'EOF'
#!/bin/sh
# SIM_PCI: space-separated vendor:device:rev (hex, as the device shows them), printed in ioreg's format
for d in $SIM_PCI; do
  v=${d%%:*}; r=${d#*:}; dev=${r%%:*}; rev=${r#*:}
  le() { printf '%s%s0000' "$(echo "$1" | cut -c3-4)" "$(echo "$1" | cut -c1-2)"; }
  echo "+-o DEV@0  <class IOPCIDevice, id 0x1000002e0, registered, matched, active, busy 0 (0 ms), retain 12>"
  echo "  |   {"
  echo "  |     \"vendor-id\" = <$(le "$v")>"
  echo "  |     \"device-id\" = <$(le "$dev")>"
  echo "  |     \"revision-id\" = <${rev}000000>"
  echo "  |   }"
done
EOF
cat >"$FB/pkgutil" <<'EOF'
#!/bin/sh
case "$*" in
  *--pkg-info*) [ -f "$SIM_RECEIPT" ] || exit 1; echo "package-id: org.vermilion.pkg"; echo "location: /";;
  *--forget*) rm -f "$SIM_RECEIPT";;
  *--only-files*) grep -v '/$' "$SIM_RECEIPT" | grep -v '^$';;
  *--only-dirs*) grep '/$' "$SIM_RECEIPT" | sed 's|/$||';;
esac
EOF
printf '#!/bin/sh\nexit 0\n' >"$FB/launchctl"
printf '#!/bin/sh\necho "nvram $*" >>"$SIM_LOG"\n[ "$1" = -p ] && printf "phxfb-squat\\t1\\n"\nexit 0\n' >"$FB/nvram"
printf '#!/bin/sh\necho "defaults $*" >>"$SIM_LOG"\n' >"$FB/defaults"
printf '#!/bin/sh\nexit 0\n' >"$FB/dscl"
printf '#!/bin/sh\nexit 0\n' >"$FB/plutil"
printf '#!/bin/sh\necho root\n' >"$FB/stat"   # the console user: nobody (the scripts use stat only for /dev/console)
chmod +x "$FB"/*

# ---- one fake system: $T/root, the user alice, the package scripts as the installer would get them
export VERMILION_TEST=1 VERMILION_NOCHOWN=1 VERMILION_USER=alice VERMILION_UHOME=/Users/alice
export PATH="$FB:$PATH" SIM_LOG=$T/sim.log SIM_RECEIPT=$T/receipt
reset_world() {
  rm -rf "$T/root" "$T/scripts" "$T/stage"; : >"$SIM_LOG"
  export VERMILION_ROOT=$T/root SIM_PCI="1002:744c:c8 1002:ab30:00" SIM_BUILD=25G241
  mkdir -p "$T/root/Users/alice" "$T/scripts" "$T/root/Library/LaunchDaemons"
  cp "$SR/pkg/preinstall" "$SR/pkg/postinstall" "$SR/pkg/lib.sh" "$T/scripts/"
  # the unit list make-pkg.sh gives the preinstall script
  sed -n "/units-payload.txt\" <<'EOF'/,/^EOF/p" "$SR/make-pkg.sh" | sed '1d;$d' >"$T/scripts/units-payload.txt"
}
# payload <tag>: what the Installer lays down, from a stage of dummy files (the paths of make-pkg.sh)
payload() {
  local P=$T/root LX=$T/root/usr/local/libexec/vermilion tag=$1
  mkdir -p "$P/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS" "$P/Library/GPUBundles/nvmtl" "$P/Library/Extensions/VermilionAccel.kext/Contents" \
           "$P/usr/local/sbin" "$P/usr/local/bin" "$LX/gpu/phxctl" "$LX/firmware" "$LX/tools" "$LX/air-runtime-src"
  echo "driver $tag" >"$P/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver"
  echo "vk $tag" >"$P/Library/GPUBundles/nvmtl/libvulkan_radeon.dylib"; echo '*' >"$P/Library/GPUBundles/nvmtl-allow.txt"
  echo "accel $tag" >"$P/Library/Extensions/VermilionAccel.kext/Contents/Info.plist"
  for f in phxctl mesboot; do echo "$f $tag" >"$P/usr/local/sbin/$f"; done
  echo "spirv-val $tag" >"$P/usr/local/bin/spirv-val"   # spirv-val is in bin, as make-pkg.sh lays it out
  cp "$SR/pkg/vermilion-uninstall" "$P/usr/local/sbin/"; cp "$SR/pkg/vermilion-firmware" "$P/usr/local/sbin/"
  echo "daemon $tag" >"$LX/gpu/phxboot-navi31.sh"; echo "up $tag" >"$LX/gpu/phxctl/navi31_up.sh"; echo "bin $tag" >"$LX/gpu/phxctl.bin"
  cp "$R/tools/phxctl/local.phxboot.plist.in" "$LX/"; cp "$SR/pkg/lib.sh" "$LX/lib.sh"; echo "0.1.0-$tag" >"$LX/VERSION"
  cp "$R/tools/phxctl/air_runtime_install.sh" "$LX/tools/"; echo "fetch" >"$LX/firmware/fetch_firmware.sh"
  echo "llvm $tag" >"$LX/air-runtime-src/libLLVM.dylib"; echo "zstd $tag" >"$LX/air-runtime-src/libzstd.1.dylib"
  # the receipt of a real package lists files the payload held; the AIR reader's source folder is in it too
  ( cd "$P" && find Library/GPUBundles Library/Extensions usr | sort | while read -r p; do [ -d "$p" ] && echo "$p/" || echo "$p"; done ) >"$SIM_RECEIPT"
}
pre() { sh "$T/scripts/preinstall" /x/p.pkg / / / >"$T/pre.out" 2>&1; echo $? >"$T/pre.rc"; }
post() { VERMILION_FETCH="${FETCH:-$T/fetch-ok}" sh "$T/scripts/postinstall" /x/p.pkg / / / >"$T/post.out" 2>&1; echo $? >"$T/post.rc"; }
un() { sh "$T/root/usr/local/sbin/vermilion-uninstall" "$@" >"$T/un.out" 2>&1; echo $? >"$T/un.rc"; }
printf '#!/bin/sh\nmkdir -p "$1"; echo fw >"$1/smu_13_0_0.bin"\n' >"$T/fetch-ok"; chmod +x "$T/fetch-ok"
printf '#!/bin/sh\necho "no network" >&2; exit 1\n' >"$T/fetch-fail"; chmod +x "$T/fetch-fail"
refused() { [ "$(cat "$T/pre.rc")" = 1 ] && grep -q "cannot be installed" "$T/pre.out" && grep -q "Nothing was changed" "$T/pre.out" && [ ! -d "$T/root/Library/Application Support/Vermilion/rollback" ]; }

# ---- preinstall: refusals
reset_world; pre
check "preinstall accepts macOS 25G241 with an RX 7900 XTX" '[ "$(cat "$T/pre.rc")" = 0 ]' "$T/pre.out"
reset_world; SIM_BUILD=25G222 pre
check "refuses another macOS build, and says which" 'refused && grep -q "25G241" "$T/pre.out" && grep -q "25G222" "$T/pre.out"' "$T/pre.out"
reset_world; SIM_PCI="1002:744c:cc" pre
check "refuses the RX 7900 XT (revision 0xCC) by name" 'refused && grep -q "RX 7900 XT " "$T/pre.out" && grep -q "0xcc" "$T/pre.out"' "$T/pre.out"
reset_world; SIM_PCI="1002:744c:ce" pre
check "refuses the RX 7900 GRE" 'refused && grep -q "RX 7900 GRE" "$T/pre.out"' "$T/pre.out"
reset_world; SIM_PCI="1002:744c:cf" pre
check "refuses the RX 7900M" 'refused && grep -q "RX 7900M" "$T/pre.out"' "$T/pre.out"
reset_world; SIM_PCI="1002:744c:c9" pre
check "refuses an unknown revision" 'refused && grep -q "unknown Navi 31" "$T/pre.out"' "$T/pre.out"
reset_world; SIM_PCI="1002:744c:c8 1002:744c:cc" pre
check "refuses an XTX next to another 744c board" 'refused' "$T/pre.out"
reset_world; SIM_PCI="1002:73bf:c1 10de:2204:a1" pre
check "refuses a Mac with other GPUs only" 'refused && grep -q "no AMD Radeon RX 7900 XTX" "$T/pre.out"' "$T/pre.out"
reset_world; SIM_PCI="" pre
check "refuses when ioreg shows no PCI device" 'refused' "$T/pre.out"
reset_world; SIM_PCI="1022:744c:c8" pre
check "refuses 744c from another vendor" 'refused' "$T/pre.out"
reset_world; SIM_PCI="1002:ab30:c8" pre
check "refuses revision c8 of another device (ab30, the audio function)" 'refused' "$T/pre.out"
reset_world; VERMILION_USER="" pre
check "a desktop user is needed (no console user, no single account)" 'refused && grep -q "no desktop user" "$T/pre.out"' "$T/pre.out"
reset_world; unset VERMILION_ROOT; sh "$T/scripts/preinstall" /x/p.pkg / /Volumes/Other / >"$T/pre.out" 2>&1; echo $? >"$T/pre.rc"
check "refuses another target volume" '[ "$(cat "$T/pre.rc")" = 1 ] && grep -q "running system volume" "$T/pre.out"' "$T/pre.out"

# ---- first install: preinstall (with an older file in the way), payload, postinstall
reset_world
mkdir -p "$T/root/usr/local/sbin" "$T/root/Users/alice/gpu"
echo "OLD phxctl" >"$T/root/usr/local/sbin/phxctl"
echo "OLD daemon" >"$T/root/Users/alice/gpu/phxboot-navi31.sh"; echo 777 >"$T/root/Users/alice/gpu/phxboot-uclk"
echo "OLD plist" >"$T/root/Library/LaunchDaemons/local.phxboot.plist"
pre; check "first preinstall passes" '[ "$(cat "$T/pre.rc")" = 0 ] && grep -q "an install that this package did not make" "$T/pre.out"' "$T/pre.out"
RB=$(cat "$T/root/Library/Application Support/Vermilion/.rollback-current")
check "preinstall kept the old phxctl in the rollback folder" '[ "$(cat "$RB/files$T/root/usr/local/sbin/phxctl")" = "OLD phxctl" ] && grep -q "^E $T/root/usr/local/sbin/phxctl\$" "$RB/MANIFEST"'
check "preinstall wrote N for a path that was not there" 'grep -q "^N $T/root/Library/Extensions/VermilionAccel.kext\$" "$RB/MANIFEST"'
payload v1; post
check "postinstall succeeds" '[ "$(cat "$T/post.rc")" = 0 ]' "$T/post.out"
G=$T/root/Users/alice/gpu
check "daemon and tools are in ~/gpu" '[ "$(cat "$G/phxboot-navi31.sh")" = "daemon v1" ] && [ "$(cat "$G/phxctl/navi31_up.sh")" = "up v1" ] && [ -x "$G/phxboot-navi31.sh" ] && [ -f "$G/phxctl.bin" ]'
check "the LaunchDaemon names the user and ~/gpu" 'grep -q "<string>/Users/alice/gpu/phxboot-navi31.sh</string>" "$T/root/Library/LaunchDaemons/local.phxboot.plist" && grep -q "<key>PHX_USER</key><string>alice</string>" "$T/root/Library/LaunchDaemons/local.phxboot.plist"'
check "the AIR reader is in the bundle and its source is gone" '[ "$(cat "$T/root/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime/libLLVM.dylib")" = "llvm v1" ] && [ ! -e "$T/root/usr/local/libexec/vermilion/air-runtime-src" ]'
check "the firmware step ran" '[ -f "$G/fw/navi31/smu_13_0_0.bin" ]'
check "first-boot flags created, an existing one kept" '[ -e "$G/phxboot-sdma" ] && [ -e "$G/phxboot-cg" ] && [ "$(cat "$G/phxboot-uclk")" = 777 ]'
check "phxboot-auto and phxboot-nohdr created for the user; the package writes no NVRAM" '[ -e "$G/phxboot-auto" ] && [ -e "$G/phxboot-nohdr" ] && ! grep -q "^nvram" "$SIM_LOG"' "$T/post.out"
check "the MANIFEST records both flags as not there before (N)" 'grep -q "^N $G/phxboot-auto\$" "$RB/MANIFEST" && grep -q "^N $G/phxboot-nohdr\$" "$RB/MANIFEST"'
check "shader cache folders exist" '[ -d "$T/root/Library/GPUBundles/nvmtl/aircache" ] && [ -d "$T/root/Library/GPUBundles/nvmtl/spvcache" ]'
check "the install marker names the version and user" 'grep -q "^version 0.1.0-v1" "$T/root/Library/Application Support/Vermilion/installed" && grep -q "^user alice" "$T/root/Library/Application Support/Vermilion/installed"'
check "the daemon was not started" '! grep -q "launchctl" "$SIM_LOG"'
check "the old daemon script and plist are in the rollback folder" '[ "$(cat "$RB/files$G/phxboot-navi31.sh")" = "OLD daemon" ] && [ "$(cat "$RB/files$T/root/Library/LaunchDaemons/local.phxboot.plist")" = "OLD plist" ]'
check "the Allow click step is printed" 'grep -q "Allow" "$T/post.out" && grep -q "Privacy & Security" "$T/post.out"' "$T/post.out"
check "nothing outside the fake root was written" '[ ! -e /Users/alice/gpu ] && [ ! -e "/Library/Application Support/Vermilion" ]'

# ---- a failed firmware fetch is a warning, the install stays
reset_world; pre; payload v1; FETCH=$T/fetch-fail post
check "failed firmware fetch: exit 0, a warning, the rest installed" '[ "$(cat "$T/post.rc")" = 0 ] && grep -q "WARNING: the firmware could not be fetched" "$T/post.out" && grep -q "basic display" "$T/post.out" && [ -f "$T/root/Users/alice/gpu/phxboot-navi31.sh" ]' "$T/post.out"

# ---- the closing text follows the welcome page: OpenCore part first
reset_world; pre; payload v1; post
check "the closing text says the OpenCore part comes first, one restart after Allow, the ready notification" 'grep -q "already in place and has booted once" "$T/post.out" && grep -q "OpenCore.zip first" "$T/post.out" && grep -q "restart when macOS asks (one restart)" "$T/post.out" && grep -q "Graphics acceleration is ready" "$T/post.out" && ! grep -q "phxfb-squat" "$T/post.out"' "$T/post.out"

# ---- update, then uninstall: everything back as it was before the first install
reset_world
mkdir -p "$T/root/usr/local/sbin"; echo "OLD phxctl" >"$T/root/usr/local/sbin/phxctl"
pre; payload v1; post; sleep 1
pre; payload v2; post
check "update replaced the files" '[ "$(cat "$T/root/usr/local/sbin/phxctl")" = "phxctl v2" ] && [ "$(cat "$T/root/Users/alice/gpu/phxboot-navi31.sh")" = "daemon v2" ]' "$T/post.out"
check "two rollback folders" '[ "$(ls "$T/root/Library/Application Support/Vermilion/rollback" | wc -l | tr -d " ")" = 2 ]'
# the uninstaller removes files named in the receipt and in the manifests; a file the daemon wrote stays
echo absent >"$T/root/Users/alice/gpu/phxboot-b21guard.orig"
un
check "uninstall exits 0" '[ "$(cat "$T/un.rc")" = 0 ]' "$T/un.out"
check "the file that existed before the first install is back, not the first release's" '[ "$(cat "$T/root/usr/local/sbin/phxctl")" = "OLD phxctl" ]' "$T/un.out"
check "Vermilion's files are gone" '[ ! -e "$T/root/usr/local/sbin/mesboot" ] && [ ! -e "$T/root/usr/local/sbin/vermilion-uninstall" ] && [ ! -e "$T/root/Library/Extensions/VermilionAccel.kext" ] && [ ! -e "$T/root/Library/GPUBundles/NVMTLDriver.bundle" ] && [ ! -e "$T/root/Library/GPUBundles/nvmtl-allow.txt" ] && [ ! -e "$T/root/usr/local/libexec/vermilion" ] && [ ! -e "$T/root/Library/LaunchDaemons/local.phxboot.plist" ] && [ ! -e "$T/root/Users/alice/gpu/phxboot-navi31.sh" ] && [ ! -e "$T/root/Users/alice/gpu/phxboot-sdma" ]' "$T/un.out"
check "spirv-val (bin) and the AIR reader are gone" '[ ! -e "$T/root/usr/local/bin/spirv-val" ] && [ ! -e "$T/root/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime" ]'
check "the empty ~/gpu/phxctl is gone; ~/gpu/fw stays while the firmware does" '[ ! -e "$T/root/Users/alice/gpu/phxctl" ] && [ -d "$T/root/Users/alice/gpu/fw/navi31" ]'
check "the firmware stays without --purge" '[ -f "$T/root/Users/alice/gpu/fw/navi31/smu_13_0_0.bin" ] && grep -q "fw/navi31" "$T/un.out"'
check "the receipt is forgotten and the marker is gone" '[ ! -f "$SIM_RECEIPT" ] && [ ! -f "$T/root/Library/Application Support/Vermilion/installed" ]'
check "the rollback folders are kept, marked used" '[ "$(ls "$T/root/Library/Application Support/Vermilion/rollback" | wc -l | tr -d " ")" = 2 ] && [ "$(ls "$T/root/Library/Application Support/Vermilion/rollback"/*/MANIFEST.used | wc -l | tr -d " ")" = 2 ] && ! ls "$T/root/Library/Application Support/Vermilion/rollback"/*/MANIFEST >/dev/null 2>&1'
check "phxboot-auto and phxboot-nohdr removed (they were not there before the install)" '[ ! -e "$T/root/Users/alice/gpu/phxboot-auto" ] && [ ! -e "$T/root/Users/alice/gpu/phxboot-nohdr" ]'
check "NVRAM variables deleted, login-window value put back" 'grep -q "nvram -d phxfb-squat" "$SIM_LOG" && grep -q "defaults delete /Library/Preferences/com.apple.loginwindow SHOWFULLNAME" "$SIM_LOG"'
check "it tells which EFI entries to remove, and prints the kmutil step" 'grep -q "VermilionBoot.kext" "$T/un.out" && grep -q "kmutil install --update-all" "$T/un.out"' "$T/un.out"
check "uninstall touched nothing outside the fake root" '[ ! -e /Users/alice ] && [ ! -e "/Library/Application Support/Vermilion" ]'

# ---- --purge, and an uninstall with the receipt already gone
reset_world; pre; payload v1; post; un --bogus
check "unknown option is refused" '[ "$(cat "$T/un.rc")" = 1 ]'
rm -f "$SIM_RECEIPT"; un --purge
check "--purge removes the firmware; no receipt: the manifests still decide" '[ "$(cat "$T/un.rc")" = 0 ] && [ ! -e "$T/root/Users/alice/gpu/fw/navi31" ] && [ ! -e "$T/root/usr/local/sbin/mesboot" ]' "$T/un.out"

check "--purge leaves no empty ~/gpu, ~/gpu/phxctl, ~/gpu/fw" '[ ! -e "$T/root/Users/alice/gpu" ]' "$T/un.out"

# ---- ~/gpu keeps a file that is not Vermilion's, and its folder
reset_world; pre; payload v1; post; echo mine >"$T/root/Users/alice/gpu/notes.txt"; un --purge
check "a user's file in ~/gpu stays, with its folder; phxctl and fw are gone" '[ "$(cat "$T/root/Users/alice/gpu/notes.txt")" = mine ] && [ ! -e "$T/root/Users/alice/gpu/phxctl" ] && [ ! -e "$T/root/Users/alice/gpu/fw" ]' "$T/un.out"

# ---- the AIR reader goes even when no rollback line names the bundle (it is not in the receipt)
reset_world; pre; payload v1; post
RB=$(cat "$T/root/Library/Application Support/Vermilion/.rollback-current")
grep -v "NVMTLDriver.bundle" "$RB/MANIFEST" >"$RB/MANIFEST.new"; mv "$RB/MANIFEST.new" "$RB/MANIFEST"
AIRD=$T/root/Library/GPUBundles/NVMTLDriver.bundle/Contents
check "(setup) the AIR reader is installed, and in no receipt line" '[ -f "$AIRD/MacOS/air-runtime/libLLVM.dylib" ] && ! grep -q "MacOS/air-runtime" "$SIM_RECEIPT"'
un
check "uninstall removes the AIR reader without a MANIFEST line for the bundle" '[ "$(cat "$T/un.rc")" = 0 ] && [ ! -e "$AIRD/MacOS/air-runtime" ] && [ ! -e "$AIRD/Resources/air-runtime" ]' "$T/un.out"

# ---- a /usr/local/libexec/vermilion that existed before the first install is put back, not deleted
reset_world; mkdir -p "$T/root/usr/local/libexec/vermilion"; echo "OLD libexec file" >"$T/root/usr/local/libexec/vermilion/keep.txt"
pre; payload v1; post; un
check "the libexec folder of before the install is restored; Vermilion's files in it are gone" '[ "$(cat "$T/root/usr/local/libexec/vermilion/keep.txt")" = "OLD libexec file" ] && [ ! -e "$T/root/usr/local/libexec/vermilion/lib.sh" ] && [ ! -e "$T/root/usr/local/libexec/vermilion/VERSION" ]' "$T/un.out"
reset_world; pre; payload v1; post; un
check "with none before, the libexec folder is gone" '[ ! -e "$T/root/usr/local/libexec/vermilion" ]'

# ---- install, uninstall, a user's own file at a payload path, install again, uninstall: the user's file comes back
reset_world; pre; payload v1; post; un
mkdir -p "$T/root/usr/local/sbin"; echo "MINE phxctl" >"$T/root/usr/local/sbin/phxctl"; sleep 1
pre; payload v1; post
check "(setup) the reinstall replaced the user's file" '[ "$(cat "$T/root/usr/local/sbin/phxctl")" = "phxctl v1" ]' "$T/post.out"
un
check "a second uninstall restores the user's file put there after the first uninstall" '[ "$(cat "$T/un.rc")" = 0 ] && [ "$(cat "$T/root/usr/local/sbin/phxctl")" = "MINE phxctl" ]' "$T/un.out"

# ---- an uninstall without lib.sh still puts the login-window value back
reset_world; pre; payload v1; post
echo absent >"$T/root/Users/alice/gpu/phxboot-b21guard.orig"; : >"$SIM_LOG"
rm -f "$T/root/usr/local/libexec/vermilion/lib.sh"
un
check "no lib.sh: the uninstall works and restores the login-window value" '[ "$(cat "$T/un.rc")" = 0 ] && grep -q "defaults delete /Library/Preferences/com.apple.loginwindow SHOWFULLNAME" "$SIM_LOG" && grep -q "login-window value put back" "$T/un.out" && [ ! -e "$T/root/Users/alice/gpu/phxboot-b21guard.orig" ]' "$T/un.out"

# ---- the Installer's own check (install-check.sh, run by distribution.xml)
ic() { cp "$SR/pkg/install-check.sh" "$SR/pkg/lib.sh" "$T/scripts/"; sh "$T/scripts/install-check.sh" >"$T/ic.out" 2>&1; echo $? >"$T/ic.rc"; }
reset_world; ic
check "install-check: 0 on macOS 25G241 with an RX 7900 XTX, and it prints nothing" '[ "$(cat "$T/ic.rc")" = 0 ] && [ ! -s "$T/ic.out" ]' "$T/ic.out"
reset_world; SIM_BUILD=25G222 ic
check "install-check: 1 on another macOS build" '[ "$(cat "$T/ic.rc")" = 1 ]'
reset_world; SIM_PCI="1002:73bf:c1" ic
check "install-check: 2 with no RX 7900 XTX" '[ "$(cat "$T/ic.rc")" = 2 ]'
reset_world; SIM_PCI="" ic
check "install-check: 2 with no PCI device at all" '[ "$(cat "$T/ic.rc")" = 2 ]'
reset_world; SIM_PCI="1002:744c:cc" ic
check "install-check: 3 for the RX 7900 XT" '[ "$(cat "$T/ic.rc")" = 3 ]'
reset_world; SIM_PCI="1002:744c:c8 1002:744c:ce" ic
check "install-check: 3 for an XTX next to a GRE" '[ "$(cat "$T/ic.rc")" = 3 ]'
DX=$SR/pkg/distribution.xml.in
check "distribution.xml.in is well-formed, allows system.run and has an installation-check that runs install-check.sh" 'python3 -I -c "import sys, xml.dom.minidom as m; m.parse(sys.argv[1])" "$DX" && grep -q "<installation-check script=\"installCheck()\"/>" "$DX" && grep -q "system.run(.install-check.sh.)" "$DX" && grep -q "allow-external-scripts=\"yes\"" "$DX"'
check "distribution.xml.in words each exit code and gives a Fatal result" 'for c in 1 2 3; do grep -q "rc == $c" "$DX" || exit 1; done; grep -q "my.result.type = .Fatal." "$DX" && grep -q "0xC8" "$DX"'
check "preinstall keeps its own GPU and macOS checks" 'grep -q "^check_gpu" "$SR/pkg/preinstall" && grep -q "EXPECT_BUILD" "$SR/pkg/preinstall"'

# ---- the shipped copies carry no test hooks (strip-hooks.sh), and the hooks do not steer them
SH=$SR/strip-hooks.sh; mkdir -p "$T/shipped"
for f in "$SR/pkg/preinstall" "$SR/pkg/postinstall" "$SR/pkg/lib.sh" "$SR/pkg/install-check.sh" "$SR/pkg/vermilion-uninstall" "$SR/pkg/vermilion-firmware" "$R/tools/phxctl/air_runtime_install.sh"; do
  b=$(basename "$f")
  check "strip-hooks: $b has no hook left and is valid shell" 'sh "$SH" "$f" "$T/shipped/$b" 2>"$T/strip.err" && ! grep -q "VERMILION_\(TEST\|ROOT\|NOCHOWN\|USER\|UHOME\|FETCH\)" "$T/shipped/$b" && sh -n "$T/shipped/$b"' "$T/strip.err"
done
check "strip-hooks: the source scripts keep their hooks (the tests use them)" 'grep -q VERMILION_ROOT "$SR/pkg/lib.sh" && grep -q VERMILION_NOCHOWN "$SR/pkg/postinstall"'
printf 'x=${VERMILION_ROOT:-}\ny=$VERMILION_NOCHOWN\n' >"$T/new-hook.sh"
check "strip-hooks: a hook it has no rule for fails the build" '! sh "$SH" "$T/new-hook.sh" "$T/new-hook.out" 2>/dev/null && [ ! -e "$T/new-hook.out" ]'
# the shipped lib.sh ignores the caller's environment
env VERMILION_TEST=1 VERMILION_ROOT=/elsewhere VERMILION_USER=mallory VERMILION_UHOME=/tmp/mallory PATH=/nonexistent:/usr/bin:/bin \
    sh -c '. "$1"; echo "R=$R|$LIBEXEC|$(console_user)|$PATH"' _ "$T/shipped/lib.sh" >"$T/env.out" 2>&1
check "shipped lib.sh: VERMILION_ROOT, _TEST (PATH) and _USER are not honoured" 'grep -q "^R=|/usr/local/libexec/vermilion|" "$T/env.out" && ! grep -q "mallory\|elsewhere\|nonexistent" "$T/env.out"' "$T/env.out"
check "shipped scripts: no chown switch, no fetch command from the environment" '! grep -q "NOCHOWN" "$T/shipped/postinstall" "$T/shipped/preinstall" "$T/shipped/vermilion-uninstall" "$T/shipped/vermilion-firmware" "$T/shipped/air_runtime_install.sh" && grep -q "^FETCH=\"sh " "$T/shipped/postinstall"'

# ---- fetch_firmware.sh --from: a SHA-256 mismatch is reported with the expected SHA-256
FW=$T/fw; mkdir -p "$FW/src" "$FW/dst"; cp "$R/tools/firmware/fetch_firmware.sh" "$FW/"
printf 'right' >"$FW/right.bin"; printf 'wrong' >"$FW/src/a.bin"
md=$( (md5 -q "$FW/right.bin" 2>/dev/null) || md5sum "$FW/right.bin" | cut -d' ' -f1 )
sha=$( (shasum -a 256 "$FW/right.bin" 2>/dev/null) || sha256sum "$FW/right.bin" ); sha=${sha%% *}
printf '# linux-firmware-commit: %s\na.bin %s 5 %s\n' 0123456789012345678901234567890123456789 "$md" "$sha" >"$FW/fw.lock"
sh "$FW/fetch_firmware.sh" --from "$FW/src" "$FW/dst" >"$T/fw.out" 2>&1; echo $? >"$T/fw.rc"
check "fetch_firmware --from: a mismatch fails and names the expected SHA-256" '[ "$(cat "$T/fw.rc")" = 1 ] && grep -q "SHA-256 $sha" "$T/fw.out" && [ ! -e "$FW/dst/a.bin" ]' "$T/fw.out"
cp "$FW/right.bin" "$FW/src/a.bin"; sh "$FW/fetch_firmware.sh" --from "$FW/src" "$FW/dst" >"$T/fw.out" 2>&1
check "fetch_firmware --from: the right file is copied" '[ "$(cat "$FW/dst/a.bin")" = right ]' "$T/fw.out"

# ---- help text, layout
check "the --rebuild-kc text names vermilion-uninstall" '! grep -n "[^-]uninstall --rebuild-kc" "$SR/pkg/vermilion-uninstall" && grep -q "vermilion-uninstall --rebuild-kc runs it" "$SR/pkg/vermilion-uninstall"'
check "make-pkg.sh lays spirv-val out in usr/local/bin, as this test's payload does" 'grep -q "\"\$BUILD/spirv-val\" \"\$P/usr/local/bin/\"" "$SR/make-pkg.sh" && grep -qx "/usr/local/bin/spirv-val" "$T/scripts/units-payload.txt"'

echo "pkg_scripts_test: $PASS passed, $FAIL failed"
[ $FAIL = 0 ]
