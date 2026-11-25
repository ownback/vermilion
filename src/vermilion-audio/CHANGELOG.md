# VermilionAudio.kext version history

Newest first.

- 1.7.3 (not on the box yet; owner decision 2026-11-25: RX 7900 XTX only): the AppleGFXHDA controller-table and
  factory-mask patch is applied only when the GPU function 1002:744c has PCI revision 0xC8 (the registry's
  `revision-id`; PhxGpuId.h). On any other board, or with no `revision-id`, it logs `skipped: the GPU is not an RX 7900
  XTX` and leaves AppleGFXHDA as Apple ships it. No change on the XTX.
- 1.7.2: `debug.phxaudio_event` also takes 1 and 2 (display re-delivery); the version on the box (EFI change 33).
