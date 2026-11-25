# VermilionAccel.kext version history

Newest first. VermilionAccel has no build counter like VermilionBoot's `PHX_KEXT_BUILD`: its `CFBundleVersion` is the
version, and a new one needs the "Allow" click in System Settings > Privacy & Security before the next restart
(docs/XTX.md, "Display settings").

- 0.1.1 (not on the box yet; owner decision 2026-11-25: RX 7900 XTX only): `NMXAccel::probe` and `start` read the PCI
  vendor, device and revision (PhxGpuId.h, shared with VermilionBoot) and start only on 1002:744c revision 0xC8. On any
  other board `probe` logs one `NMXAccel:` line and returns NULL; nothing on the GPU is read or written. VermilionBoot
  b161 refuses the same boards first, so this is the second gate. No behaviour change on the XTX.
- 0.1: the first VermilionAccel (formerly PhxAccel.kext).
