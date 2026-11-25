Vermilion @VERSION@ - the OpenCore part

An experimental preview of a macOS Tahoe 26.7.1 (build 25G241) driver for the AMD Radeon RX 7900 XTX only.
Read INSTALL.md of the release (https://github.com/ownback/vermilion-xtx) before you start.

What is here
  Kexts/VermilionBoot.kext    brings the GPU up
  Kexts/VermilionTrust.kext   lets only Vermilion's own code past library validation (needs Lilu, loads after it)
  Kexts/VermilionAudio.kext   DisplayPort audio (needs Lilu, loads after it)
  config-snippet.plist        the entries your config.plist needs: merge them by hand, then run ocvalidate
  LICENSES/, NOTICE           licences and notices
Not here: Lilu (take it from its own release), your SMBIOS and ACPI (make your own), AMD firmware (the package of the
same release downloads it in macOS), and the Metal driver (the .pkg of the same release).

The zip and the .pkg of one release are a pair: VermilionTrust holds the exact fingerprints of the code the .pkg
installs. Update both, then restart once.

Rules
  - Keep a copy of your working EFI folder and a second way to boot before you change anything.
  - One EFI change per boot.
  - From Linux or Windows to macOS, always shut down and power on again; never restart into macOS.
  - Never Reset NVRAM. Never update macOS.
  - Check the files against SHA256SUMS from the release page.
