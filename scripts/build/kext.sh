#!/bin/sh
# SPDX-License-Identifier: MIT
# kext.sh: VermilionBoot.kext (src/vermilion-boot; formerly PhxBringup.kext, docs/NAMING.md) -> $VERMILION_OUT/VermilionBoot.kext. Needs MKSDK and the generated
# src/vermilion-boot/phx_c3_hash.inc: the SHA-256 and CRC-32 of the C3 slice of $PHX_FW/dcn_3_2_0_dmcub.bin (made here, always, from the
# file the build fetched; tools/firmware/c3_image.py). The kext holds no firmware bytes: the boot daemon hands it the slice at run time.
. "$(dirname "$0")/lib.sh"
: "${MKSDK:?set MKSDK to a MacKernelSDK checkout}"
S="$ROOT/src/vermilion-boot"
FWD=${PHX_FW:-$HOME/gpu/fw/navi31}
python3 "$ROOT/tools/firmware/c3_image.py" --fw "$FWD/dcn_3_2_0_dmcub.bin" --out "$S/phx_c3_hash.inc"
(cd "$S" && sh ./build.sh "$MKSDK")
rm -rf "$OUT/VermilionBoot.kext"; cp -R "$S/build/VermilionBoot.kext" "$OUT/VermilionBoot.kext"
homecheck "$OUT/VermilionBoot.kext/Contents/MacOS/VermilionBoot"
echo "built $OUT/VermilionBoot.kext (OpenCore EFI/OC/Kexts; docs/INSTALL.md)"
