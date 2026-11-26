# VermilionAccel.kext version history

Newest first. VermilionAccel has no build counter like VermilionBoot's `PHX_KEXT_BUILD`: its `CFBundleVersion` is the
version, and a new one needs the "Allow" click in System Settings > Privacy & Security before the next restart
(docs/XTX.md, "Display settings").

- 0.1.2 (not on the box yet; plan A4, branch ownback/device-info; needs VermilionBoot b168 for the keys): the
  accelerator's `PerformanceStatistics` carries Apple's AMD keys `Device Utilization %` (GFX + compute busy share since
  the previous read, at least 50 ms apart) and `vramFreeBytes` (the device-local memory RADV is offered minus what every
  client holds), as `AMDAccelStatistics::writeInternalStats` adds them. `NMXAccel::newStatistics` returns the new
  `NMXAccelStatistics` (nmx_stats.h; base class reconstructed in iofam/IOAccelStatistics2.h, vtable checked against
  the family's), which asks VermilionBoot's "phxGpuStats" (PhxGpuStats.h). With an older VermilionBoot the keys stay
  absent. Activity Monitor's GPU History reads the first (unverified on hardware).
- 0.1.1 (not on the box yet; owner decision 2026-11-25: RX 7900 XTX only): `NMXAccel::probe` and `start` read the PCI
  vendor, device and revision (PhxGpuId.h, shared with VermilionBoot) and start only on 1002:744c revision 0xC8. On any
  other board `probe` logs one `NMXAccel:` line and returns NULL; nothing on the GPU is read or written. VermilionBoot
  b161 refuses the same boards first, so this is the second gate. No behaviour change on the XTX.
- 0.1: the first VermilionAccel (formerly PhxAccel.kext).
