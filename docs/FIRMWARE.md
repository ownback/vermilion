# AMD firmware

The bring-up (`tools/phxctl/bringup_navi31.sh`, `vcn_up.sh`) loads AMD microcode from linux-firmware `amdgpu/`
through the PSP, and VermilionBoot's cold-boot PHY fix (`debug.phxc3`, `src/vermilion-boot/PhxC3Load.h`) streams one slice of
`dcn_3_2_0_dmcub.bin` to the PHY (the kext holds none of it: the boot daemon hands it over at run time, step 2). These files are AMD's, under `LICENSE.amdgpu` ([`../LICENSES/LICENSE.amdgpu.txt`](../LICENSES/LICENSE.amdgpu.txt)):
redistribution in binary form only, no reverse engineering, decompilation or disassembly.

**This repository ships no firmware and no excerpt of it**, following nullarc (its `.gitignore` keeps `*.bin` out of
the tree and `tools/fetch_test_firmware.sh` downloads the blobs from linux-firmware). Instead:

1. `tools/firmware/fetch_firmware.sh [--from <dir>] [dest]` downloads the 20 files in
   [`../tools/firmware/fw.lock`](../tools/firmware/fw.lock) from linux-firmware (default dest `~/gpu/fw/navi31`,
   where the box scripts read them) and checks each md5 and SHA-256. `--from <dir>` takes them from a linux-firmware
   checkout instead (offline), with the same checks. A file whose md5 or SHA-256 differs is rejected: offsets and
   sizes in the bring-up were measured on exactly those revisions. The release package's post-install script runs
   this tool ([RELEASE.md](RELEASE.md)). The files come from the linux-firmware commit pinned in `fw.lock`,
   `add225168d0d1ba4c174d5eb15272b53de01ad5a` (release tag `20250917`, the first release with all 20 revisions;
   they are unchanged up to tag `20251111`, and later releases replace most of them: GC, PSP, SMU and VCN, then SDMA
   and DCN). It tries the GitLab mirror first, then git.kernel.org. `LINUX_FIRMWARE_REF=<commit>` picks another
   commit, `LINUX_FIRMWARE_URL` another mirror.
2. `tools/firmware/c3_image.py [--fw <dcn_3_2_0_dmcub.bin>]` generates `src/vermilion-boot/phx_c3_hash.inc` from your copy:
   the length, CRC-32 and SHA-256 of the C3 slice (offset 0xE200, 0xA000 bytes), no firmware bytes (it checks the slice's
   sha256 prefix first). `scripts/build/kext.sh` runs it on every build; `.gitignore` keeps the header out. At run time
   `m7_boot.sh` runs `phxctl c3image <installed dcn_3_2_0_dmcub.bin>`, which writes the slice to `debug.phxc3_image`;
   the kext keeps it only if its SHA-256 and CRC-32 match, otherwise `debug.phxc3=9` and `debug.phxdplink` refuse.
