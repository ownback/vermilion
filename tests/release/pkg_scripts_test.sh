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
  for f in phxctl mesboot spirv-val; do echo "$f $tag" >"$P/usr/local/sbin/$f"; done
  cp "$SR/pkg/vermilion-uninstall" "$P/usr/local/sbin/"; cp "$SR/pkg/vermilion-firmware" "$P/usr/local/sbin/"
  echo "daemon $tag" >"$LX/gpu/phxboot-navi31.sh"; echo "up $tag" >"$LX/gpu/phxctl/navi31_up.sh"; echo "bin $tag" >"$LX/gpu/phxctl.bin"
  cp "$R/tools/phxctl/local.phxboot.plist.in" "$LX/"; cp "$SR/pkg/lib.sh" "$LX/lib.sh"; echo "0.1.0-$tag" >"$LX/VERSION"
  cp "$R/tools/phxctl/air_runtime_install.sh" "$LX/tools/"; echo "fetch" >"$LX/firmware/fetch_firmware.sh"
  echo "llvm $tag" >"$LX/air-runtime-src/libLLVM.dylib"; echo "zstd $tag" >"$LX/air-runtime-src/libzstd.1.dylib"
  { cd "$P" && find Library/GPUBundles Library/Extensions usr | sort | while read -r p; do [ -d "$p" ] && echo "$p/" || echo "$p"; done; } >"$SIM_RECEIPT"
  # the receipt of a real package lists files the payload held; the AIR reader's source folder is in it too
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
check "shader cache folders exist" '[ -d "$T/root/Library/GPUBundles/nvmtl/aircache" ] && [ -d "$T/root/Library/GPUBundles/nvmtl/spvcache" ]'
check "the install marker names the version and user" 'grep -q "^version 0.1.0-v1" "$T/root/Library/Application Support/Vermilion/installed" && grep -q "^user alice" "$T/root/Library/Application Support/Vermilion/installed"'
check "the daemon was not started" '! grep -q "launchctl" "$SIM_LOG"'
check "the old daemon script and plist are in the rollback folder" '[ "$(cat "$RB/files$G/phxboot-navi31.sh")" = "OLD daemon" ] && [ "$(cat "$RB/files$T/root/Library/LaunchDaemons/local.phxboot.plist")" = "OLD plist" ]'
check "the Allow click step is printed" 'grep -q "Allow" "$T/post.out" && grep -q "Privacy & Security" "$T/post.out"' "$T/post.out"
check "nothing outside the fake root was written" '[ ! -e /Users/alice/gpu ] && [ ! -e "/Library/Application Support/Vermilion" ]'

# ---- a failed firmware fetch is a warning, the install stays
reset_world; pre; payload v1; FETCH=$T/fetch-fail post
check "failed firmware fetch: exit 0, a warning, the rest installed" '[ "$(cat "$T/post.rc")" = 0 ] && grep -q "WARNING: the firmware could not be fetched" "$T/post.out" && grep -q "basic display" "$T/post.out" && [ -f "$T/root/Users/alice/gpu/phxboot-navi31.sh" ]' "$T/post.out"

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
check "the firmware stays without --purge" '[ -f "$T/root/Users/alice/gpu/fw/navi31/smu_13_0_0.bin" ] && grep -q "fw/navi31" "$T/un.out"'
check "the receipt is forgotten and the marker is gone" '[ ! -f "$SIM_RECEIPT" ] && [ ! -f "$T/root/Library/Application Support/Vermilion/installed" ]'
check "the rollback folders are kept" '[ "$(ls "$T/root/Library/Application Support/Vermilion/rollback" | wc -l | tr -d " ")" = 2 ]'
check "NVRAM variables deleted, login-window value put back" 'grep -q "nvram -d phxfb-squat" "$SIM_LOG" && grep -q "defaults delete /Library/Preferences/com.apple.loginwindow SHOWFULLNAME" "$SIM_LOG"'
check "it tells which EFI entries to remove, and prints the kmutil step" 'grep -q "VermilionBoot.kext" "$T/un.out" && grep -q "kmutil install --update-all" "$T/un.out"' "$T/un.out"
check "uninstall touched nothing outside the fake root" '[ ! -e /Users/alice ] && [ ! -e "/Library/Application Support/Vermilion" ]'

# ---- --purge, and an uninstall with the receipt already gone
reset_world; pre; payload v1; post; un --bogus
check "unknown option is refused" '[ "$(cat "$T/un.rc")" = 1 ]'
rm -f "$SIM_RECEIPT"; un --purge
check "--purge removes the firmware; no receipt: the manifests still decide" '[ "$(cat "$T/un.rc")" = 0 ] && [ ! -e "$T/root/Users/alice/gpu/fw/navi31" ] && [ ! -e "$T/root/usr/local/sbin/mesboot" ]' "$T/un.out"

echo "pkg_scripts_test: $PASS passed, $FAIL failed"
[ $FAIL = 0 ]
