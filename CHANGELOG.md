<!-- SPDX-License-Identifier: MIT -->

# Changelog

What changes for people who run Vermilion, release by release. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), the versions [semantic versioning](https://semver.org) (`0.y.z`
while Vermilion is experimental). Per-build details of the boot kext: [`src/vermilion-boot/CHANGELOG.md`](src/vermilion-boot/CHANGELOG.md).
How releases are made: [docs/RELEASE.md](docs/RELEASE.md).

## Unreleased

No release has been made yet. What `main` has, as a user would notice it (the reference machine, 2026-11-25):

### Added

- RX 7900 XTX support next to upstream's RX 7900 XT: the card is detected by its PCI revision and named correctly.
- 2560x1440 at 60, 120, 144 and 240 Hz and Variable refresh (60-240 Hz) on the LG 27GS95QE.
- HEVC and AV1 hardware decode (optional; the decoder bundle sits on the system volume for now).
- DisplayPort audio to the monitor (VermilionAudio, a Lilu plugin).
- VermilionTrust: AMFI stays on; only Vermilion's own code passes library validation.

### Fixed

- Music and Maps no longer crash in the Metal driver; Maps no longer runs out of GPU buffers.
- After a failed boot the machine returns to the full desktop by itself after clean boots (unverified on hardware:
  no boot has failed since the change).
- A warm GPU is refused instead of being loaded with firmware again; the picker no longer offers Reset NVRAM.

### Known issues

See the [README](README.md#what-works-what-doesnt) and [SUPPORT.md](SUPPORT.md).
