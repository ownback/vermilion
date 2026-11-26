# SPDX-License-Identifier: MIT
# dummy.sh: sourced by the release tests. Makes dummy build outputs (text files where a real build has Mach-O files)
# so the release scripts can be run without building anything. Nothing here is a real binary or a real firmware file.

# dummy_kexts <dir> <version>: VermilionBoot / Trust / Audio with an Info.plist and an executable
dummy_kexts() {
  local k
  for k in VermilionBoot VermilionTrust VermilionAudio; do
    mkdir -p "$1/$k.kext/Contents/MacOS"
    echo "dummy $k" >"$1/$k.kext/Contents/MacOS/$k"
    cat >"$1/$k.kext/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$k</string>
<key>CFBundleIdentifier</key><string>org.vermilion.dummy.$k</string>
<key>CFBundleShortVersionString</key><string>$2</string>
</dict></plist>
EOF
  done
}

# dummy_build <dir> <tag>: what scripts/build would leave for make-pkg.sh; <tag> is written into each file
dummy_build() {
  local f
  mkdir -p "$1"
  for f in NVMTLDriver libnvmtl_translate.dylib libvulkan_radeon.dylib phxctl mesboot metaltest spirv-val phxaudio; do echo "dummy $f $2" >"$1/$f"; done
  mkdir -p "$1/VermilionAccel.kext/Contents/MacOS"
  echo "dummy accel $2" >"$1/VermilionAccel.kext/Contents/MacOS/VermilionAccel"
  echo '<plist version="1.0"><dict/></plist>' >"$1/VermilionAccel.kext/Contents/Info.plist"
}

# dummy_air <dir> <tag>: scripts/build/llvm.sh's output folder
dummy_air() {
  mkdir -p "$1/LICENSES"
  echo "dummy llvm $2" >"$1/libLLVM.dylib"; echo "dummy zstd $2" >"$1/libzstd.1.dylib"
  echo "dummy notice" >"$1/LICENSES/LLVM.txt"
}
