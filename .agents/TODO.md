# TODO

Open, actionable items only, grouped by the thread of the 2026-11-23 series that owned them
([ROADMAP.md](../ROADMAP.md) replaces that series with phases).
One or two lines each, with a link to the evidence. The machine's current state is in
[docs/PROJECT_KNOWLEDGE.md](../docs/PROJECT_KNOWLEDGE.md), questions only the owner can answer are in
[OWNER-TESTS.md](OWNER-TESTS.md), and the history up to 2026-11-23 (daily logs, done items, the old Phase 0-6
plan) is in [findings/2026-11-19..23-bringup-log.md](findings/2026-11-19..23-bringup-log.md).

Rules:
- `[ ]` open, `[~]` in progress, `[-]` dropped (say why). A finished item is deleted here and recorded where it
  belongs: the state in PROJECT_KNOWLEDGE, the evidence in a finding, the reason in decisions.
- **Before every EFI change:** write its check and rollback steps under the item, here, first (ROADMAP rule 3). Remove
  them once the change is verified and PROJECT_KNOWLEDGE's known-good section says what is booted.
- Something that works on a real Mac and not here goes in as a bug under the thread that owns it (ROADMAP, "Known limits").

## Staged now

State after thread 03's changes (verified, recorded in PROJECT_KNOWLEDGE, known-good): `EFI/OC` = change 23
(VermilionBoot b160, VermilionTrust with the video decoder, 14 cdhashes), `EFI/OC.prev` = change 22, `EFI/OC.bad` =
change 12; the system volume boots the snapshot with `PhxVideoDecoder.bundle`. Thread 03's check / rollback steps for
change 23 and the system-volume change: git history of this file (`ownback/apis-video`); the rollbacks are also in
PROJECT_KNOWLEDGE.

- [ ] **Phase 2 item 1: deploy the safety fixes** (branch `ownback/safety-fixes`), after the merge. Three parts in
  this order, each with its own boot, under the machine lock. Before each one: `bash tests/mock/run.sh`,
  `bash tests/mock/b15test.sh` and `bash tests/mock/bringup_warm_test.sh` green on main.
  - **(a) Daemon and bring-up scripts into `~/gpu`** (no EFI change, no system volume). **Installed 2026-11-25
    06:47; boot 2 (warm) passed** (`sOS check: C2PMSG_81=0x00000000 (cold)`, `SUCCESS at 06:50:12`); boot 1 (cold)
    passed 2026-11-25 11:40.
    - First, optional, through the `linux-queue` skill: hw-safety-reviewer's read-only check. Run
      `journalctl -k -b <n>` on a Linux boot that followed a warm reboot and look for `MODE1 reset` near amdgpu's
      probe. If it's absent, a warm reset leaves the sOS stopped.
    - Rollback copies: `mkdir -p ~/vermilion-rollback/safety-fixes-a` and `cp -p ~/gpu/phxboot-navi31.sh
      ~/gpu/phxctl/navi31_up.sh ~/gpu/phxctl/bringup_navi31.sh` into it.
    - Install: `install -m 755 tools/phxctl/navi31_up.sh tools/phxctl/bringup_navi31.sh ~/gpu/phxctl/`. Install the
      daemon by rename: `cp tools/phxctl/phxboot-navi31.sh ~/gpu/phxboot-navi31.sh.new && mv
      ~/gpu/phxboot-navi31.sh.new ~/gpu/phxboot-navi31.sh`, so the running daemon keeps the file it opened. Owner and
      mode as before (`ls -l`).
    - Check, boot 1, cold (the owner shuts down and powers on): `/var/log/phxboot.log` has
      `sOS check: C2PMSG_81=0x00000000 (cold)`, `navi31 up:` and `SUCCESS`. A stuck squat logs the new `nvstuck:`
      wording without "Reset NVRAM in the OpenCore picker".
    - Check, boot 2, warm (Apple menu > Restart): the same three lines. This answers whether a warm macOS restart
      leaves the sOS running (unverified until then).
    - If boot 2 logs `FAIL (warm GPU: bring-up refused`: a warm macOS restart is warm for the GPU, and this refusal
      would cost Metal after every restart. Roll back (below) and record it in a finding. The fix is then a
      different design: Linux's own answer is a Mode1 reset, which needs its own hw-safety review. The squat path
      after a refusal: one reboot, then a dark stuck squat that ssh still reaches.
    - Rollback: copy the three files back from `~/vermilion-rollback/safety-fixes-a` (the daemon by rename again).
      If the failure path ran, `rm -f ~/gpu/phxboot-off ~/gpu/phxboot-failed ~/gpu/phxboot-safe`. Then shut down
      fully and boot.
  - **(b) EFI change: no Reset NVRAM entry** (stage `vermilion-trust-bar1g-audio` without `ResetNvramEntry.efi`),
    its own boot. **Change 34, live since 2026-11-25 06:56, passed** (SUCCESS, trust enforce / 0 denied, audio
    attached; the live kexts reused via `VERMILION_KEXT_DIR`); the owner's picker check is open.
    - Build on the Mac (runbooks, "Building and installing the EFI on the Mac itself") with
      `--stage vermilion-trust-bar1g-audio`, not the default stage, using the kexts that are on the ESP now.
    - `sudo diff -rq /private/tmp/efi/EFI/OC build/efi/b650e-i-xtx-vermilion-trust-bar1g-audio/EFI/OC` may show only
      `Drivers/ResetNvramEntry.efi` (on the ESP only) and `config.plist`. In `config.plist` (`plutil -p`, both files)
      only the `UEFI > Drivers` entry of `ResetNvramEntry.efi` may be gone. Anything else: stop.
    - Install: `sudo python3 efi/build.py install --esp /private/tmp/efi --stage vermilion-trust-bar1g-audio`
      (`EFI/OC.prev` = change 33). Delete `build/efi/` afterwards (it holds the serials).
    - Check: the picker has no Reset NVRAM entry (the owner, by eye). `/var/log/phxboot.log`:
      `squat boot ...: 1` and `SUCCESS`. `sysctl debug.phxtrust_stat`: `mode=enforce`, `denied_unlisted=0`.
      `sysctl debug.phxaudio_stat`: the attach.
    - Rollback: `sudo mv /private/tmp/efi/EFI/OC /private/tmp/efi/EFI/OC.bad && sudo mv /private/tmp/efi/EFI/OC.prev
      /private/tmp/efi/EFI/OC` (from Linux: the same under `/boot/EFI`).
    - Any later rebuild of this stage (item 2's trust list, for example) carries this change too, so boot (b)
      first.
  - **(c) VermilionAccel without `debug.phxfb_kill_iondrv`** (AuxKC, the owner's Allow click), its own boot.
    **Live since 2026-11-25 07:01, passed** (unknown oid, UUID `6FDD9916` loaded, SUCCESS).
    - Build: `MKSDK=<MacKernelSDK> sh scripts/build/accel.sh`. The branch build's binary is sha256 `03c1e47d`
      (2026-11-24, no link gate). `fork/main` at `f8432a4` rebuilds the installed `2578b185` byte for byte, so this
      part changes only the removed sysctl.
    - Rollback copy: `cp -Rp /Library/Extensions/VermilionAccel.kext
      ~/vermilion-rollback/VermilionAccel.kext.pre-killiondrv`.
    - Install: [INSTALL.md](../docs/INSTALL.md) section 4, "To update the kext" (the Allow click rebuilds the AuxKC),
      then restart.
    - Check: `sysctl debug.phxfb_kill_iondrv` answers "unknown oid". `sysctl -n debug.phxgl` still answers.
      `/var/log/phxboot.log`: `NMXAccel up`, `PhxAMDFB on panel`, `SUCCESS`.
    - Rollback: the copy back the same way (Allow, restart).
  - Open, not in this branch: after a bring-up failure that isn't a warm refusal, `navi31_up.sh` and the daemon still
    go on to the claim, with the watchdog armed (hw-safety-reviewer, 2026-11-24). Fixed on `ownback/recovery-daemon`
    (item 3 step 1, below).

- [x] **Live and passed 2026-11-25 16:57 (#26; restart, all checks below green; fallback paths still unverified).**
  **Phase 2 item 3 step 1: deploy the daemon recovery without the manual rm** (branch `ownback/recovery-daemon`,
  [design](findings/2026-11-25-recovery-trap-design.md) plan step 1), after the merge. Daemon and `navi31_up.sh` only:
  no EFI, kext, NVRAM or system-volume change. One boot, under the machine lock. Everything below is mock-tested only
  (unverified on hardware).
  - Before: `bash tests/mock/run.sh`, `bash tests/mock/b15test.sh`, `bash tests/mock/bringup_warm_test.sh`,
    `bash tests/mock/daemon_install_test.sh` green on main. `ls ~/gpu/phxboot-off ~/gpu/phxboot-failed
    ~/gpu/phxboot-safe /var/db/phxboot.*`: on 2026-11-25 none of them existed, `~/gpu/phxboot-nvstuck` held `stuck`.
    A `phxboot-failed` left then is taken over into the record by the first boot (`record: ... taken over`); a
    `phxboot-off` is the owner's switch from now on: remove it first if an old daemon made it.
  - Rollback copies: `mkdir -p ~/vermilion-rollback/recovery-daemon-1` and `cp -p ~/gpu/phxboot-navi31.sh
    ~/gpu/phxctl/navi31_up.sh` into it.
  - Install: `install -m 755 tools/phxctl/navi31_up.sh ~/gpu/phxctl/`; the daemon by rename (`cp
    tools/phxctl/phxboot-navi31.sh ~/gpu/phxboot-navi31.sh.new && mv ~/gpu/phxboot-navi31.sh.new
    ~/gpu/phxboot-navi31.sh`), owner and mode as before (`ls -l`).
  - Check, one cold boot (the owner shuts down and powers on): `/var/log/phxboot.log` has `sOS check: C2PMSG_81=0x00000000
    (cold)`, `navi31 up:`, `SUCCESS at`, and once the new line `record: fails=0 clean=0 bfail=0 skipped=0 last=full
    (this boot: full)`; no `notice:` line and no `clean shutdown (TERM) ... during the bring-up` line;
    `sudo cat /var/db/phxboot.fails` the same five lines; no `/var/db/phxboot.notice-next`; 240 Hz as before.
  - Not tested by this boot (the paths need a failure): the safe desktop's return, the notification (`launchctl asuser`
    + `osascript` as the user, unverified), the notice kept across a restart after a failure, the loop guard, a
    shutdown during the bring-up (the TERM now reaches the trap at once), Safe Mode on the squat (still dark: it
    should leave the "Safe Mode can't show a picture" notice for the next boot; whether the daemon runs in Safe Mode at
    all is unverified). A later owner test can force one fallback without a GPU risk: `echo desktop | sudo tee
    /var/db/phxboot.pending` before a restart gives one safe desktop with the notification after login, and the boot
    after it the full desktop (OWNER-TESTS candidate).
  - Rollback: copy both files back from `~/vermilion-rollback/recovery-daemon-1` (the daemon by rename), `sudo rm -f
    /var/db/phxboot.fails /var/db/phxboot.notice /var/db/phxboot.notice-next`, shut down fully, boot. The old daemon
    ignores the record; it sets `~/gpu/phxboot-off` / `phxboot-failed` again after a failure.

- [ ] **Phase 2 item 2: deploy the plugin crash fixes** (branch `ownback/plugin-crash-fixes`, after the merge;
  [finding](findings/2026-11-25-plugin-crashes-root-cause.md)). A new `NVMTLDriver`, so also a VermilionTrust + EFI
  change (runbooks, "Deploying a plugin, translator or RADV build"). One EFI change, its own boot, under the machine
  lock, after item 1 (b) has booted (the EFI rebuild carries it). Everything below is (unverified) until that boot.
  - Before: on main, `VULKAN_HEADERS=<Vulkan-Headers>/include sh scripts/build/plugin.sh`, then the four host tests in
    `tests/plugin/` green (`test_copy_compat.c`, `test_safe_copy.c` as in their headers; `test_dead_cmdbuf.m` and
    `test_texture_nil_log.m` against `build/NVMTLDriver`). Note the new binary's cdhash (`codesign -dvvv
    build/NVMTLDriver 2>&1 | grep CDHash`).
  - Rollback copy: `mkdir -p ~/vermilion-rollback/NVMTLDriver.pre-crashfixes-<date> && cp -p
    /Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver` into it. The installed build is UUID `B42521DC`
    (cdhash `344c621f`, 2026-11-25); check that it still is before copying.
  - Install: the binary as `.new` next to the old one, then `mv` (a running WindowServer keeps the file it mapped).
    The path resolves through the `/Library/GPUBundles` symlink into `CoreTypes.bundle/Contents/Library/PhxGPU`, a
    firmlink into the Data volume: not a system-volume change. Then `PHXTRUST_KEEP=1 sh scripts/build/trust.sh` (the
    old cdhash stays as `-previous`) and rebuild the EFI on the Mac; `diff -rq` against the ESP shows only
    `Kexts/VermilionTrust.kext`. Install with `EFI/OC.prev` = the current EFI. Delete `build/efi/` afterwards.
  - Check after the boot:
    - `sysctl debug.phxtrust_stat`: `mode=enforce`, `denied_unlisted=0`; `sysctl debug.phxtrust_files` lists the new
      `NVMTLDriver` cdhash; accelerated desktop at 240 Hz; `/var/log/phxboot.log` ends in `SUCCESS`.
    - The plugin reaches the unified log: `log show --last 5m --predicate 'subsystem == "org.vermilion.nvmtl"' | head`
      shows `NVMTL:` lines from WindowServer.
    - Music (the owner, normal use): "Drake - Jaded" and a scroll through the album grid. No new `Music-*.ips`. Any
      `readback dropped` or `went away during the GPU wait` line in the log is the old crash, now caught.
    - Maps reproduction (the owner's OK first; a GPU load as large as normal Maps use): open Maps, pan and zoom over a
      city in Explore, switch to Satellite and 3D, stop at the crash or after 2 min. Then
      `log show --last 5m --predicate 'subsystem == "org.vermilion.nvmtl"' > ~/maps-nvmtl-log.txt`, note any new
      `Maps-*.ips`, and look for `texture nil:` lines: they name the path, the reason and the descriptor. The fix for
      that path is the item below ("Maps: the path the reproduction names").
  - Rollback: the old binary back from the rollback copy as `.new` + `mv` (the new trust list keeps it as
    `-previous`), restart; or `EFI/OC.prev` (the old list doesn't trust the new binary: restore the old binary first).
    If the desktop has no acceleration after the boot (WindowServer refused the plugin), restore the old binary over
    ssh and restart.
- [ ] **Phase 2 item 2, step 2: Music write-back as Apple does** (M; finding section 1, fix 2). No CPU copy through
  the app's address: import the IOSurface's pages when the texture is made (or let the kext take them by IOSurface
  ID), and write the private image back with a GPU copy (`vkCmdCopyImageToBuffer`, `bufferRowLength` 600) at the end
  of the command buffer that wrote it. This extends the multi-plane `_planeHost` path to single-plane surfaces with an
  unaligned pitch (2400 B), both ways. Step 1 (the fault-safe copy) is on `ownback/plugin-crash-fixes`.
- [ ] **Phase 2 item 2: deploy the Maps allocation fix** (branch `ownback/maps-alloc-limit`, after the merge;
  [finding](findings/2026-11-25-maps-allocation-limit.md)). The reproduction named the path: the kext's 4095 BO
  handles per process, held by Managed buffers' VRAM copies; the fix pools small device-local buffers. A new
  `NVMTLDriver` (branch build cdhash `06fd1ac9`), so a VermilionTrust + EFI change as for #25 above (same install,
  rollback copy, trust list with `PHXTRUST_KEEP=1`, `diff -rq` shows only `Kexts/VermilionTrust.kext`). One EFI change,
  its own boot, under the machine lock. Everything below is (unverified) until that boot.
  - Before: on main, `sh scripts/build/plugin.sh`; `tests/plugin/test_pool_range.c` and the four tests above green.
  - Rollback copy: the live `NVMTLDriver` (cdhash `15204728`) to `~/vermilion-rollback/NVMTLDriver.pre-allocfix-<date>`.
  - Check after the boot: `debug.phxtrust_stat` `denied_unlisted=0`, the new cdhash listed, 240 Hz, `SUCCESS`; the log
    has `buffer pool: device-local buffers up to 256 KiB ...` from WindowServer. Then, with the owner's OK (GPU load):
    `tests/plugin/test_private_pool_gpu.m` (header) all passed, and the Maps reproduction as for #25. Afterwards
    `sysctl debug.phxvm`: the `handles` count in `BO create refused` the same as before the run, no `texture nil:` line,
    no new `Maps-*.ips`; `buffer pool: block ... device-local` lines from Maps, few of them.
  - Rollback: as for #25 (the old binary back as `.new` + `mv`, kept trusted as `-previous`; or `EFI/OC.prev` after
    restoring the old binary).
- [ ] **Phase 2 item 2: the kext's 4095 BOs per process** (finding section 6). Images, buffers over 256 KiB and
  RADV's own BOs still take a handle each; a process with ~4000 live textures fails as Maps did. Choose: pool small
  images in the plugin, or let the kext's `bos` / `maps` tables grow (an N48N ABI minor with RADV; the VA map table is
  GPU VM work: `hw-safety-reviewer`).
- [ ] **Music's 30 s first launch: passd's Secure Element wait** (platform, not the plugin; finding
  `2026-11-25-music-slow-load.md`). Every cold start of passd runs libAppleSSE's 60 x 0.5 s lookup for an `AppleSSE`
  service that needs a T2. Music's account save waits for it through accountsd. First the owner test in the finding
  (cold vs warm passd). Then: find what makes `PKSecureElement registerObserver:` run on a Mac without a Secure
  Element, and report that from the platform (ryzentosh). Until then, a login agent that kickstarts passd is the
  mitigation: `tools/phxctl/local.phxpassd.plist`, installed 2026-11-25 ~18:05 in `~/Library/LaunchAgents` (owner's
  "go"; removal in the plist's header). Check at the next boot (unverified): `pgrep -x passd` within a minute of
  login, Music's `MusicUI bootstrap took` ~1-2 s. Remove it once the platform fix works.
- [x] **Done 2026-11-25 19:49-19:52 (fs3d-gpu, run2-gpu; WindowServer 37-42 % of GPU wall, Maps 17-24 %).** **Phase 2 item 2: Maps fullscreen, the phase-B GPU capture** (before the branch below is installed;
  [finding](findings/2026-11-25-maps-fullscreen-perf.md) section 5). The owner holds Maps in the 3D city view; the
  capture gets GPU time per process (`GPUTIME=1`) and per pass (`/tmp/nvmtl-passtime-request`) in fullscreen, in a
  window and with Maps in VRAM. It decides between Maps' passes (shaders, MSAA in system memory) and WindowServer's
  composite for the ~7.5 ms of GPU per frame.
- [ ] **Phase 2 item 2: WindowServer's composite behind Maps, the capture after the passtime change** (branch
  `ownback/ws-composite-cost`, [finding](findings/2026-11-25-windowserver-composite-cost.md) section 6). Install the
  plugin (trust + EFI, one boot), then phase B fullscreen with `GPUTIME=1` and one touch of the request file at 10 s
  and 20 s; copy WindowServer's passtime log at once (its TMPDIR is cleared at boot). Reads the present copy's GPU
  time, Maps' real frame rate and WindowServer's composites per Maps frame (fs3d: ~35 vs 119/s, ~3.1 ms each).
- [ ] **Passtime: review notes from the clean-up of #34** (plugin, measurement only; each is a behaviour change, none
  touches the path while the timer is off). (1) `nvmtl_pt_armed` runs on every encoding thread with no lock: two
  threads in one 250 ms poll can both arm for one touch (two ARMED lines, `arm` skips a number, lines of one window
  carry two numbers), and `g_pt_left--` can lose a count. A lock or a compare-and-swap around the poll fixes it.
  (2) `arm <n>` is read when the line is written, not when the pass was recorded, and counts per process: a process
  that drew nothing within 15 s of a touch is one behind the others. Match windows across processes by `t`, or log
  the request's mtime instead. (3) A touch that arrives while a process is still armed is taken only when its 400
  passes are done, and lost if that is more than 15 s later. (4) Presents are timed while `g_pt_left > 0` and never
  count it down: a process that presents but stops drawing passes logs (fprintf + fflush under the scan-out lock)
  on every present with no end. (5) The present line is written between `t1` and `t2`, so it counts as
  flicker-probe time in the `ws gpu present split` averages. (6) `gpu_us` of a `widen-cpu` present is the barriers
  only.
- [ ] **Phase 2 item 2: deploy the Maps CPU fixes** (branch `ownback/maps-gpu-saturation`; finding section 4): async
  `replaceRegion:` uploads, bounded, on by default outside WindowServer; cache-hit touches once a minute. A plugin
  install = trust + EFI change, one boot. Check: Maps' log has `vk: async texture upload ON` and `async texture upload
  #1`, WindowServer's says OFF; map tiles, labels and icons draw right while panning; no new `FAILED` lines or
  `Maps-*.ips`; an appcapture in phase A shows no main-thread wait under `replaceRegion:`. Rollback without a
  restart: create the file `/Library/GPUBundles/nvmtl/async-tex-upload-off` (root), relaunch the app.
- [ ] **Async uploads: one handle per image** (plugin, performance only). A second upload to an image waits for the
  first, and two threads uploading to one texture at once make one of them wait (the table keeps one entry per
  image). A chain of handles would let mip levels and 3D slices of one texture go without those waits. The review
  fixes of #31 (park, unlist by handle, buffer textures synchronous, barrier, byte recheck, atomics, appcapture trap)
  are on the branch ([finding](findings/2026-11-25-maps-fullscreen-perf.md) section 4), host-tested only.
- [ ] **Async surface copy-in: buffer-backed images stay synchronous** (S, plugin, behaviour change; second clean-up
  review of #31, read from the code, not seen on hardware). `nvmtl_surfin_async` (opt-in `NVMTL_ASYNC_SURFACE_IN`,
  off by default) does not test `placed == NVK_PLACED_IN_BUFFER` as `replaceRegion:` now does. A `_vramOn` surface
  texture is an image in the family's shared VRAM: `nvmtlSurfaceIn` marks that VRAM current right after the submit,
  so another process can skip its own copy-in and read the VRAM before this process's copy has run (queue order
  holds inside one process only). Also: `nvmtl_vk_image_migrate` (RES2, off on AMD) takes no upload barrier, unlike
  `nvmtl_vk_image_reback`; its copy is waited for, so the upload has landed, but the comments name migration.
- [ ] **Maps CPU: binary cache keys and the library reload** (S-M, plugin; finding section 4 "Not done here"): JSON
  keys over VideoToolbox's 242 function constants cost 11-12 % of Maps' CPU, the metallib re-read 5.7-7 %,
  `nvmtl_surface_keep` 2.4-3.2 %.
- [ ] **Phase 2 item 2: the plugin's other `syslog()` calls** (`NVMTLX420.m`, `nvmtl_imgmem.c`, `nvmtl_pitch_align.c`,
  `NVMTLWSCapture.m`, `NVMTLHolders.m`, the ANGLE line in `NVMTLDevice.m`) still bypass `nvlog`: move them to the
  `org.vermilion.nvmtl` subsystem too.

- [x] **03: VermilionAccel with `debug.phxgl`** (not an EFI change): installed 23:05, booted 23:18 (UUID `2B25514A`),
  OpenGL over Metal verified 23:25 (finding section 8). Rollback:
  `~/vermilion-rollback/VermilionAccel.kext.pre-phxgl-20261123`, `kmutil load -p`, Allow, restart; or just
  `rm ~/gpu/phxboot-gl` (GL off from the next boot) / `sysctl -w debug.phxgl=0`.

- [ ] **Boots that stop without a macOS log** (watch item, counter in [OWNER-TESTS](OWNER-TESTS.md) 01): #1 05:09
  cold (b155), #2 15:45 warm (b159; OpenCore stopped with "Missing compatible GOP"). A third one on b159 or later
  means reverting to EFI change 19 (`~/vermilion-rollback/EFI-OC.change19-20261123`, with the plugin it trusts)
  before going on. Every thread that restarts asks the owner to glance at the screen.

- [ ] **HDR off as a workaround since 2026-11-24 01:00** (`~/gpu/phxboot-nohdr`; remove it to get HDR back once fixed).
  After the HDMI / DP replug at 00:08 WindowServer composites in BGRA while the scan-out is 10-bit HDR, the plugin's
  CPU widen path presents stale frames: the picture freezes a few minutes after login (input works).
  [Finding](findings/2026-11-24-hdr-freeze-after-replug.md). Fix: the widen path in the plugin (a trust + EFI change)
  and the reason for the BGRA surfaces. The logger LaunchAgent `local.t04watch` is removed (2026-11-24; plist in
  the rollback folder).

- [x] **Daemon: auto-login fix** (works: 2026-11-24 01:46 boot, logged in at 01:46:51 by loginwindow pid 1101 with
  FirstRunKey 1, "loginUserIsAutoLoginUser") (installed 2026-11-24 ~01:33 by the auto-login thread, in the branch as commit
  "phxboot: remove loginwindow's first-run marker ..."): `al_on()` removes
  `/private/var/run/com.apple.loginwindow.didRunThisBoot` before the Metal WindowServer restart. **Never reinstall the
  daemon from a copy without these lines** (fork/main lacks them until 04 merges). Check after the next boot: `grep
  autologin: /var/log/phxboot.log | tail -3` ends with `first-run marker removed`, and no password prompt
  (OWNER-TESTS 04). If the prompt still shows, read `lastLoginPanic` in `/Library/Preferences/com.apple.loginwindow`.
  The boot of 01:27 predates the change (its log line has no marker part).

- [x] **04: EFI change 24 = stage `vermilion-trust-bar1g-audio`** with VermilionAudio 1.0.0. Booted 2026-11-24 01:18:
  desktop as before, `denied_unlisted=0`; after `kmutil load -b com.apple.driver.AppleGFXHDA` the stat reads "patched".
  The user-space personality add (`phxcatalog`, IOCatalogueSendData) returned 0 but the kernel log says "Not
  entitled": nothing matched. Hence 1.1.0.
- [x] **04: EFI change 25 = VermilionAudio 1.1.0** (the personality added in the kernel, `debug.phxaudio_match`).
  Booted 2026-11-24 01:27, desktop as before. `audio_match.sh on`: AppleGFXHDAEGController attaches to ab30 (codec
  0 present, `vendorcodecID` 0x1002aa01, `GFX BDF` found), then AppleGFXHDADriver stops: "Sound assertion in
  AppleGFXHDAFunctionGroupFactory at line 94", the codec factories don't know the controller ID ab30. `off` works.
- [x] **04: EFI change 26 = VermilionAudio 1.2.0** (ab30 in the two factory masks). Booted 2026-11-24 01:46, desktop
  as before, auto-login worked. `audio_match.sh on`: AppleGFXHDADriver starts (`HDMIDPAudioCapabilities`), but no
  audio engine: AppleGFXHDA's AppleDisplay notification fires inside `addMatchingNotification` for our existing
  display, before the notifier is stored, and the handler drops it (no `audio-selector` on PhxAMDFB, no EDID message).
- [x] **04: EFI change 27 = VermilionAudio 1.3.0** (re-delivers the AppleDisplay notification). Booted 2026-11-24
  01:57, auto-login again. After `audio_match.sh on`: "re-delivered for 1 display(s)", `audio-selector` = `dpXX` on
  PhxAMDFB. Still no engine, also after a display sleep / wake and after replaying Linux's 90 DC audio writes
  (`tools/phxctl/audio_dc_replay.sh`, retired since for `phxaudio apply`; plan from
  `tools/capture/audio_replay_plan.py`; all writes kr 0, picture fine).
  AppleGFXHDA's event path reads `connector-type`, `av-signal-type`, `AAPL,DisplayPipe` from the framebuffer.
- [x] **04: EFI change 28 = VermilionAudio 1.4.0** (framebuffer properties). Booted 2026-11-24 02:10. After `on`,
  the DC replay and a display sleep / wake: "Sound assertion in AppleGFXHDAController at line 3170": the event path
  now wants the framebuffer's `audio-codec-info` (codec address, function group node, pin node).
- [x] **04: EFI change 29 = the same stage, VermilionAudio 1.5.0** (`debug.phxaudio_codecinfo` puts head 0's
  `audio-codec-info` on PhxAMDFB at run time; `audio_match.sh on` writes 0x050100 = pin 5 first). Check after the
  boot: desktop as before; `sysctl debug.phxaudio_codecinfo` = 0. Rollback: `sudo diskutil mount disk0s1`, in
  `/Volumes/NO NAME/EFI`: `sudo mv OC OC.c29-bad && sudo mv OC.prev OC` (= change 28), restart (from Linux: the same
  under `/boot/EFI`, then power off fully). Or boot-arg `-phxaudiooff`. Change 23 is also in
  `~/vermilion-rollback/EFI-OC.change23-20261124`. **Result:** booted 02:16 and 07:46, desktop as before; after the
  three hand steps CoreAudio lists "LG ULTRAGEAR+" and the owner heard a test tone on the LG's jack (07:53).
- [x] **04: EFI change 30 = the same stage, VermilionAudio 1.6.0** (the attach is one-way, once per boot: the ab30
  personality is removed again right after the controller is up, `debug.phxaudio_match=0` and a second `=1` return
  EBUSY; `audio_match.sh off` is gone). Why: 2026-11-24 07:55, `off` then `on` under 1.5.0 made IOPCIFamily hot-reset the
  whole GPU ([finding](findings/2026-11-24-gfxhda-detach-gpu-hot-reset.md)). Check after the boot: desktop as before;
  `sudo ~/gpu/audio_match.sh on`, the DC replay, a display sleep / wake: "LG ULTRAGEAR+" listed, `ioreg` shows no
  ab30 personality left in the catalogue, a second `on` says "already attached". Rollback: `sudo mkdir -p
  /private/tmp/efi && sudo diskutil mount -mountPoint /private/tmp/efi disk0s1`, in `/private/tmp/efi/EFI`: `sudo mv OC
  OC.c30-bad && sudo mv OC.prev OC` (= change 29), restart (from Linux: the same under `/boot/EFI`, then power off
  fully). Or boot-arg `-phxaudiooff`.
  **Result:** booted 2026-11-24 17:35, desktop at 240 Hz, auto-login. After the three steps "LG ULTRAGEAR+" is
  listed again; the match key is only on the attached controller; a second `on` says "already attached", `off` exits 2,
  `sysctl -w debug.phxaudio_match=0` gives "Resource busy".

## Direct scan-out (#40) follow-ups (2026-11-26)

- [ ] Switching `ws-direct` on while GPU present runs does nothing until GPU present starts again (a restart, a plane
      loss): `nvmtl_scan_direct_choose_locked` runs only from `nvmtl_scan_start_locked`. Switch-off works live. Make
      the copy path notice the switch and restart GPU present into direct (or document "restart after creating it")
- [ ] About 16 % of display writes wait for a flip (1.7 ms average) at the desktop: measure in Maps fullscreen; the
      bounce slot or triple buffering if it costs frames
- [ ] Screenshots while bound may show a stale frame (the IOSurface pages are not updated): check Screenshot.app

## 01 GPU stability

- [~] The sink does not answer AUX at the first access after D3 (b153 03:51 and 04:15, b154 04:36). Linux's DC sends every
      DPCD access through drm_dp_dpcd_access (32 tries; at once after a timeout, 500 us after a NACK / DEFER); the
      trainer stopped after 4 timeouts or 1 NACK. **b155** (`f95b4baf`, on the box since 04:52): drm's rule for the
      trainers' DPCD accesses, a `dpcd_aux:` line in `debug.phxp0odm_stat`. Result: it does not cover this miss. At
      the boot after the Linux session the LG NACKed all 32 tries twice (`gave_up=2 nacks=74`), the training attempt
      failed and b154's redo ran (finding section 11). Open: what Linux does differently at that first access (it
      trains every window first time in the captures)
- [x] **Failed DP link training at a login mode switch** (1440p60 HDR, 2026-11-22 20:19, once, b150): black screen,
      every later switch refused until reboot. b151: Linux's 4 training attempts per link window, a failed from plan
      runs once more (2 per boot); b152 / b153: per-window record, Linux's pause; b154: a retried last window re-runs
      the switch. On the box 2026-11-23 03:11-04:36: every login switch at 1440p60 HDR trained, 5 needed a retry, one
      (04:15, b153) stayed black on a locked link until a re-switch, which b154 now does by itself (04:36)
- [x] The daemon reported `SUCCESS` during that black screen: `disp_check` (`DARK`, the engines' state in
      `/var/log/phxdark-*.txt`, one restart) for a failed engine; deployed 03:08. Its limit: the 04:15 kind of black
      (link locked, frames presented) reads as healthy; b154 covers that case at the source
- [ ] **Panic reports:** none is saved, because `DisableVariableWrite` blocks the kernel's NVRAM panic log (from the
      config; not watched failing here). The NVRAM test (change 12) is **inconclusive**: change 12 was rolled back from
      Linux at an unknown time, so the boots 04:06 / 04:10 / 04:15 may all have run change 11 (writes blocked). Open
      for the Linux session: read the firmware's variables from Linux (efivars) and redo the test as its own EFI
      change. Then a deliberate test panic is the only way to prove a report is saved (owner's call). Needed first for
      the restart panic of 2026-11-19 22:44 (cause unknown)
- [x] **Physical size 903 x 508 mm** (= 2560 x 1440 px at 72 dpi), where the EDID says 590 x 333 mm: every mode's
      `imageWidth / imageHeight` was 0 ([finding](findings/2026-11-23-gpu-stability.md) section 3). PhxAccel with the
      EDID's size installed 2026-11-23 04:15: `CGDisplayScreenSize` 591.1 x 332.5 mm
- [ ] Scaled ("looks like") modes: macOS lists only the native-pixel 2560-wide modes (no HiDPI twins); find what a
      real Mac's driver reports for them before adding any (low priority)
- [x] Changing the VRR floor gives macOS a new display identity (colour profile and settings reset), because the
      floor label is patched into the EDID PhxAccel serves. **Owner's decision 2026-11-23:** keep the patch (label
      60-240); documented in [XTX.md](../docs/XTX.md) ("A floor change resets the display's settings")
- [x] OpenCore logs: written at every boot, named in UTC (one hour behind CET); PROJECT_KNOWLEDGE fixed
- [~] Tearing at 1440p60 with GPU present; input lag at 60 Hz. **Input lag measured 2026-11-23** (finding section 9):
      posted mouse event -> OTG0 frame start median 27-30 ms at 60 Hz, 8.3 ms at 240 Hz; WindowServer composites at
      vsync and flips ~3 ms later, the flip waits for the next vblank (14 ms at 60 Hz): the normal one-frame compositor
      pipeline, no extra driver frame. Idea, not planned: start the composite later in the frame (late latch).
      **Tearing:** every flip is a vsync flip (FLIP_TYPE 0 in 40000 samples, never immediate), so a tear cannot come
      from the flip; still needs the owner's phone video (OWNER-TESTS 01) to say what is seen
- [~] DRR double buffer for the whole boot as on Linux, not only while Variable is on (decisions 2026-11-22,
      "Revisit"), then re-verify every plan. **b155** adds `debug.phxp0odm_dbuf` (live, 0 at boot): after the b155
      boot, set 1 and run session switches through every 1440p rate (SDR / HDR), post checks and the owner's eye; if
      all land, make 1 the default in a later build. **2026-11-23 04:56:** HDR 144, 240 (ODM + DSC), 120, 60 under
      mode 2: all DONE, first-attempt training, no underflow, owner saw every one land. Left: the SDR plans and the
      1080p / small modes under mode 2
- [x] Display sleep: tested 2026-11-23 (b155): the signal stays up while macOS's display sleeps; the LG never goes to
      standby. Linux's DPMS sequence captured; the fix moved to **05 Sleep and wake** (coordination thread, owner's OK)
- [ ] b138 freeze at 1280x1024 (low priority): leading guess is GPU present restarting on the small slot layout
      ([finding](findings/2026-11-20-b138-freeze-and-squat-loop.md)); then GPU present at every size
- [ ] Music's skipped readbacks: the `nvmtl_plane_mapped` guard and the fault-safe readback copy (phase 2 item 2)
      stop the crash, but those pixels never reach the surface. A GPU mapping of the IOSurface pages, as a real
      driver does: "Phase 2 item 2, step 2" under Staged now
- [ ] b150's underflow fix was checked at 144 Hz only (4 vs 0 underflows); check at 240 with ODM + DSC
- [ ] `bringup_navi31.sh` says "this card is rev 0xcc" and "non-kicker firmware": name both revisions; find out
      whether the XTX needs kicker firmware ([docs/XTX.md](../docs/XTX.md) #6)
- [ ] CHANGELOG 146-150 still mark as "(unverified)" what the owner has since confirmed (floor, ramp, 10-bit,
      Variable -> HDR)

## 03 Graphics APIs and video

03 keeps the API-level work (ROADMAP): Zink / OpenGL / OpenCL on the GPU, VCN decode, WebGL / WebGPU. Performance of
what already runs is thread 13's (section "13 Performance parity" below). Done so far (2026-11-23,
[finding](findings/2026-11-23-apis-video.md)): `gpuTimeReset` answered (harmless, no change); VCN up at every boot;
HEVC 8 / 10-bit and AV1 decode on VCN system-wide through VideoToolbox, bit-exact; Safari's GPU process has the
plugin (WebGL 1 / 2, WebGPU); Quick Look = `sips`; Vulkan window surface (patch 0020) with an opt-in loader + ICD.

- [x] **Owner, by eye** (OWNER-TESTS 03, 2026-11-23): boot clean; WebGPU `workloadSimulator` (useGl) fine; some
      webgpu-samples error, glitch or are slow (table: [finding](findings/2026-11-23-apis-video.md) section 7, all to
      13); **4K YouTube (AV1 2160p60 10-bit HDR) stutters and glitches**. Decode is bit-exact at that size (section 7:
      600 / 600 frames of the real YouTube stream = dav1d; 4K HEVC Main10 60 / 60 = Apple's decoder), so the glitch is
      presentation or timing: thread 13 (item 11). Still open by eye: Photos, a video wallpaper, an HEVC `.mov`
- [ ] **4K YouTube stopgap** (coordination 2026-11-23): advertise AV1 only up to what we keep up with, so YouTube
      serves VP9 at 4K (Safari: VP9 2160p60 `supported`, not `smooth`, in software). Needs the bundle's capabilities
      (system volume) or the plugin's registration: a restart either way, so not shipped; whether VideoToolbox reads a
      per-decoder `VTMaxPlaybackLevel` from the bundle is (unverified). Until 13: pick 1440p in YouTube's quality menu
      and report its "Stats for nerds" dropped frames (OWNER-TESTS 03)
- [x] The AV1 fallback and H.264 on VCN moved to 13 (item 13): both change the decoder bundle on the system volume
- [x] **OpenGL on the GPU** (2026-11-23): Apple's `AppleMetalOpenGLRenderer` on our Metal device, `debug.phxgl` +
      daemon flag `phxboot-gl`; Minecraft 26.3 runs on it (finding section 8). Zink not needed. Speed: thread 13
- [ ] OpenGL by use: days with `phxboot-gl` (crash reports from OpenGL apps; anything that drew right on the software
      renderer and not now)
- [x] **OpenCL on the GPU** (2026-11-23, finding section 9): system-wide, through the same `IOGLBundleName` as
      OpenGL; a 4M-element kernel matches the CPU. Speed (1.44 ms for 32 MB in + out, system-memory buffers): 13
- [x] **Blender Cycles lists only the CPU:** Blender's own check (Apple-silicon GPUs only since 4.2), not the driver;
      same as a real Intel Mac with an AMD GPU. Known limits row in ROADMAP. Not spoofed
- [ ] OpenCL by use: an OpenCL app (Geekbench 6 OpenCL, DaVinci Resolve, clpeak without its MPS pass) once the owner
      wants one; the clpeak GPU hang (TODO 13) may show up here
- [ ] Vulkan apps by default: whether MoltenVK apps get pointed at the RADV ICD is TODO 13 item 6 (the window
      surface's speed too: a host-memory copy plus a Metal blit per frame today)
- [ ] The plugin's RADV still lacks patch 0020 (no visible effect: it presents through IOSurfaces). Picked up by the
      next RADV build for the plugin (a trust + EFI change), not on its own
- [ ] Install docs for decode (flags `phxboot-vcn`, `phxdec-av1`; the bundle on the system volume),
      `relocate_gpubundle.sh` and the opt-in Vulkan stack: written in `docs/INSTALL.md` 5.5 / 5.6, not run end to
      end on a fresh install yet (the agent skills that held them were dropped on 2026-11-24)

## 04 DP / HDMI audio, HDMI output

- [x] **04: EFI change 31 = the same stage, VermilionAudio 1.7.0** (`debug.phxaudio_event`: a write of 8 delivers
  `kIOFBNotifyDidPowerOn` on head 0's PhxAMDFB inside its work-loop gate; links IOGraphicsFamily). Why: 2026-11-24 18:08
  the daemon's `audio_boot` programmed the display engine and attached AppleGFXHDA, but no engine came within 10 s; a
  mode switch didn't bring it either, a display sleep / wake (events 7 / 8) did. `audio_match.sh` now delivers 8 when no
  engine came within 2 s. Check after the boot: desktop as before; `grep audio: /var/log/phxboot.log | tail -6` ends
  "DP audio engine up", no display blanking at that moment; "LG ULTRAGEAR+" listed. Rollback: `sudo mkdir -p
  /private/tmp/efi && sudo diskutil mount -mountPoint /private/tmp/efi disk0s1`, in `/private/tmp/efi/EFI`: `sudo mv OC
  OC.c31-bad && sudo mv OC.prev OC` (= change 30), restart (from Linux: the same under `/boot/EFI`, then power off
  fully). Or boot-arg `-phxaudiooff`, or `rm ~/gpu/phxboot-audio`.
  **Result:** booted 2026-11-24 18:15, desktop fine, but VermilionAudio 1.7.0 did not load (`debug.phxaudio_stat`
  unknown; the daemon logged "VermilionAudio not loaded"): IOGraphicsFamily is in the System KC and a kext OpenCore
  injects into the boot KC can't link against it. `scripts/build/linkgate` passed it anyway (open: teach the gate).
- [x] **04: EFI change 32 = the same stage, VermilionAudio 1.7.1** (no IOGraphicsFamily link: Lilu resolves
  `IOFramebuffer::deliverFramebufferNotification` when IOGraphicsFamily loads). Check after the boot: `sysctl
  debug.phxaudio_stat` answers; `grep audio: /var/log/phxboot.log | tail -6` ends "DP audio engine up"; "LG ULTRAGEAR+"
  listed. Rollback: `sudo mkdir -p /private/tmp/efi && sudo diskutil mount -mountPoint /private/tmp/efi disk0s1`, then
  `sudo mv /private/tmp/efi/EFI/OC /private/tmp/efi/EFI/OC.c32-bad && sudo cp -R
  ~/vermilion-rollback/EFI-OC.change30-20261124 /private/tmp/efi/EFI/OC` (= change 30; OC.prev is change 31, which
  boots but has no audio). From Linux: copy the same folder (on a USB stick) to `/boot/EFI/OC`, then power off fully.
  **Result:** booted 2026-11-24 18:22, the plugin loaded, the daemon programmed the display engine and attached
  AppleGFXHDA, event 8 was delivered (0x0) and reached AppleGFXHDA's handler, but no engine came (nor with 7 then 8).
  A ktrace of the handler (subclass 0x0524) during a display sleep / wake shows events 90 / 92, 1, 2, 91 / 93, no 7 / 8
  (PhxAMDFB's `handleEvent` runs off IOFramebuffer's power thread, which drops them): the engine starts on the mode
  change 1 / 2. The 18:10 mode-switch test that seemed to say otherwise was void (the 144 Hz switch did not take).
- [x] **04: EFI change 33 = the same stage, VermilionAudio 1.7.2** (`debug.phxaudio_event` also takes 1 and 2;
  `audio_match.sh` sends 1 then 2). Check after the boot: `grep audio: /var/log/phxboot.log | tail -6` ends "DP audio
  engine up", nothing visible on the screen at that moment; "LG ULTRAGEAR+" listed. Rollback: `sudo mkdir -p
  /private/tmp/efi && sudo diskutil mount -mountPoint /private/tmp/efi disk0s1`, in `/private/tmp/efi/EFI`: `sudo mv OC
  OC.c33-bad && sudo mv OC.prev OC` (= change 32), restart (from Linux: the same under `/boot/EFI`, then power off
  fully). Or `rm ~/gpu/phxboot-audio`.
  **Result:** booted 2026-11-24 18:30: the daemon at 18:32 "display engine programmed (90 writes, end state ok)",
  AppleGFXHDA attached, "display mode change events delivered", "DP audio engine up after 2 s"; "LG ULTRAGEAR+" listed
  (the default output, the owner's earlier choice); a 3 s tone: 0 late cycles, 0 discontinuities, -12 ppm.
- [~] **DP audio works by hand** (2026-11-24 07:53, EFI change 29, [finding](findings/2026-11-23-dp-hdmi-audio-inventory.md)
      section 6): `audio_match.sh on`, `audio_dc_replay.sh plan-240.txt` (now `phxaudio apply`), a display sleep / wake,
      then the owner heard a tone from the LG's jack. To make it automatic and real-Mac-like:
  - [ ] PhxAMDFB: the framebuffer properties (`connector-type`, `av-signal-type`, `AAPL,DisplayPipe`,
        `audio-codec-info`) and `'aud '` in `setAttributeForConnectionExt` (assertion "EngineOutputDP line 262");
        AuxKC rebuild + owner's Allow click
  - [ ] VermilionBoot audio programmer: the DC audio sequence from the EDID (DTO from the pixel clock, ELD / SAD from
        the CEA block) instead of the replay plan; pin from the DIG / endpoint, not the fixed 0x050100
  - [x] Daemon: `audio_boot` (flag `~/gpu/phxboot-audio`, after `done`; automatic since EFI change 33, 2026-11-24 18:32): `~/gpu/phxaudio apply` (the display engine
        from the EDID, `tools/phxctl/phxaudio.c`; plan equal to the Linux trace, 90/90), then `audio_match.sh on` (waits
        10 s for the engine). Installed 2026-11-24 17:58 with the flag; the previous daemon is
        `~/vermilion-rollback/phxboot-navi31.sh.pre-audio-20261124`. Rollback: `rm ~/gpu/phxboot-audio`. Check after the
        next boot: `grep audio: /var/log/phxboot.log | tail -4`. Open: does the engine come up without a display sleep /
        wake when the display engine is programmed first? No (18:08); the mode change events 1 / 2 do (EFI change 33).
        `0x52` reads 0 before the first audio write (18:08), so Linux's writes leave it at 0x10, not only a toggle.
        Mode switches keep the state: 2026-11-24 17:54, 240 -> 144 -> 240 through p0odm (3 mode sets, link retrained),
        `phxaudio state` all ok after each (sound after a switch not yet heard).
  - [ ] After a mode change / replug / wake: the audio must come back (re-program, re-deliver)
  - [ ] hw-safety review 2026-11-24 (decision "DP audio merged with Linux sequencing differences"): (a) `audio_boot`
        waits for a settled display (p0odm state line + OTG0 `H_TOTAL`, as `idle_dpm.sh`) before `phxaudio apply`, or the
        kext serialises it with p0odm; (b) before a pipe-0 plan replay with audio on, Linux's audio-off writes, then
        `apply` again; (c) the `DP1_DP_SEC_CNTL` audio packet enables at Linux's point, not in the mode-set plans;
        (d) `debug.phxaudio_event` accepts only 1 and 2 (7 / 8 go to every framebuffer listener)
  - [ ] Seen in the clean-up pass of 2026-11-24, left alone because each changes machine code or a script:
        (a) VermilionAudio's head-0 test differs by function: `applyCodecInfo` / `deliverHead0` skip any PhxAMDFB that
        carries `phx-head`, `publishFbProps` and `phxaudio` read its value (absent = 0); one rule for all;
        (b) `gStat` / `gMatchStat` / `gEventStat` are written and read without a lock (`debug.phxaudio_stat` can read a
        half-written line); (c) `phxaudio state` writes the endpoint index register, so it needs `phxdebug=1` and is
        not read-only; `apply` ignores the read errors of its "before" line; (d) `pa_put`'s overflow result is dropped
        (the plan is 90 of `PA_PLAN_MAX` 128 writes today); (e) the version sits in `Info.plist` (twice) and in
        `kmod_info.c`; (f) the daemon's `audio_boot` comment says VermilionAudio 1.6.0 where `audio_match.sh` says
        1.7.2 (comment only; left so the branch's daemon stays equal to the installed one); (g) `audio_boot` runs in
        the daemon's foreground: up to 5 s in the kernel (the notifier wait), 5 s for the attach, ENGINE_WAIT (10 s)
- [ ] HDMI output: the LG over HDMI shows black (2026-11-24, as expected: no plan for it); needs a Linux capture of the LG
      on HDMI
- [ ] Bug: after a DP unplug / replug the LG stays black (link trains, HBR3 x4 locked); only a restart brought it back

## 05 Sleep and wake

- [ ] **Display sleep (DPMS), from thread 01.** Today `pmset displaysleepnow` puts PhxAMDFB in power state 0, but
      OTG0, the link and the stream stay up (DPCD lanes locked, frames counting): the LG shows black and never goes to
      standby (owner, 2026-11-23 04:58, b155); wake (`caffeinate -u`) brings the picture back at once. A real Mac stops
      the signal; for the OLED that also means no standby-time panel care.
      - Capture (done 2026-11-23 05:05, Linux 7.2.15, capture v5 `tools/capture/linux_display_capture.py --dpms`):
        `~/vermilion-captures/dpms/display-20261123-050500` (not in git; no serials), every 1440p rate SDR and HDR:
        `trace-dpms-off.txt` (549-2409 writes; while off `OTG0_CONTROL 0x00001200`, no frames), `regs-off.txt`,
        `dpcd-off-*`, `trace-dpms-on.txt` (3778-10310 writes, 502-2127 DMUB commands: a full stream enable with link
        training). Finding: [2026-11-23-gpu-stability.md](findings/2026-11-23-gpu-stability.md) sections 10-11.
      - Plan: (1) a DPMS mode for `tools/capture/p0odm_from_trace.py` (its burst detection refuses both traces today:
        "no OTG0 unlock", "fewer than 2 bursts"); generate `phx_p0odm_<mode>_dpmsoff/_dpmson.inc` per 1440p mode;
        (2) replay engine: a `dark` state (off plan from the current mode, on plan back to it; b154's retry rule and
        the redo apply to the on plan's link windows); (3) PhxAccel: run them at power state 0 / 1 (IOFramebuffer
        power), with GPU present yielding the plane while OTG0 is off; (4) host tests, then one boot + the Allow click.
        Other resolutions: fixed rates today, keep the signal (or capture them too)
- [ ] Platform S3 test on a `-phxbringupoff` boot (one EFI change, `disablesleep 0` for that boot): wake by keyboard,
      mouse, power button; then USB, NVMe, Wi-Fi, Bluetooth, audio
- [ ] GPU resume path (the driver assumes a cold GPU today), after the S3 test
- [ ] Then sleep allowed again: `sudo pmset -a disablesleep 0` (blocked since 2026-11-23 00:58)

## 06 Fresh-install path

- [ ] **First:** can VermilionAccel load from OpenCore instead of the AuxKC (its IOGraphics / IOAccelerator
      dependencies)? Removes the Allow click and unblocks SIP / Secure Boot (09)
- [ ] VermilionTrust's cdhash list as an `Info.plist` property filled by `efi/build.py` from the installed files or a
      release manifest (EFI buildable on Linux); keep `PHXTRUST_KEEP`
- [ ] Daemon out of `~/gpu` into a system path; its arm logic compatible with a FileVault login (it refuses with a
      user logged in today)
- [ ] `phxfb-squat` set by OpenCore (`nvram_add`, Apple GUID) instead of from Linux *(unverified: does the daemon
      treat an OpenCore-set value the same?)*. Reset NVRAM deletes it today
- [ ] Monitor replay plans as data loaded at boot, not compiled into VermilionBoot
- [ ] Daemon flags (`sdma`, `cg`, `uclk`, `p0modes`, `wscdcopy`, `waitstep`, `vrrmin`, `autologin`) from the machine
      profile; `ws-gpu-present*` files, colour profiles (`~/gpu/tools/colorprofile.swift` is outside the repo),
      `smumetrics.py`, `metalbench`, `apiprobe` installed by the installer
- [ ] `recovery_install.sh` / `esp_stage.sh`: the air-runtime reader; pick the APFS Data role in Recovery (3
      candidates found)
- [ ] GitHub Releases and CI (mock tests on a Linux runner, a macOS runner building kexts, plugin, translator).
      #41 (AIR reader workflow) and #42 (`release.yml`, pkg, OpenCore zip, uninstaller) are merged; neither has run
      on a runner yet, and `release.yml` stops at release-scan until F1 lands (the C3 slice in VermilionBoot)
- [ ] Package fixes from #42's clean-up review (2026-11-26):
  - the uninstaller misses the AIR reader (not in the receipt; only the rollback MANIFEST removes it), leaves empty
    `~/gpu`, `~/gpu/phxctl`, `~/gpu/fw`, deletes a `/usr/local/libexec/vermilion` it had just restored, and skips the
    login-window restore when `lib.sh` is missing (`user_home` undefined);
  - the shipped scripts honour the test hooks `VERMILION_TEST`, `VERMILION_ROOT` and `VERMILION_NOCHOWN`: strip them
    from the package build (whether Installer passes the caller's environment is unverified);
  - `distribution.xml` has no check of its own: the GPU and macOS gate is `preinstall` only;
  - `fetch_firmware.sh --from` reports only the md5 on a SHA-256 mismatch; the `--rebuild-kc` text says
    `uninstall --rebuild-kc`; the test payload puts `spirv-val` in `sbin`, the real one in `bin`
- [ ] `INSTALL.md` rewritten for the one-kext release (it is upstream's manual XT guide); recovery and troubleshooting:
      black screen after a failed switch, the squat loop, booting `OC.prev`

## 07 Wireless and Continuity

- [ ] **Step 1, in this order:**
      1. router on 5 GHz channel 44 (not DFS 52);
      2. MtkWireless 1.1.2 (one EFI change; it claims the AirDrop `missingEndpoint` fix);
      3. `netstat -rn -f inet6 | grep awdl0` (look for a `fe80::%awdl0/64` route) and `ndp -an` (look for an entry
         for the peer);
      4. AirDrop both ways with `amtk_awdl_offchan=0`.

      Background in [the finding](findings/2026-11-22-audio-connectivity-inventory.md). The route / NDP check
      comes from issue #10 below *(unverified, web research 2026-11-23)*.
- [ ] [MtkWireless issue #10](https://github.com/Dino-VN/MtkWireless/issues/10) (closed, fixed in 1.1.2, commit
      `5715618`) is nearly this machine: a Ryzen 9 7900X, ASUS ROG STRIX B650E-F, MT7922 `14c3:0616`, Bluetooth
      `0489:e0e2` with MtkWirelessBT 1.1.1 + BlueToolFixup 2.7.2, MacPro7,1, macOS 26.7.3, and an iPhone17,1 on
      iOS 27.0.1.
      - AirDrop worked both ways there after a patch. The root cause was a missing `fe80::%awdl0/64` route and no NDP
        entry for the peer.
      - It only worked while the Mac was **associated on 5 GHz channel 44**. Unassociated, or on 2.4 GHz channel 6,
        AWDL never synced (the same as issue #6).
      - Check which of their extra patches are in 1.1.2 and how each interacts with our `amtk_awdl_offchan=0`: ROC
        grant reuse (`liveGrantServesNext`), clock re-acquire (`amtk_awdl_reacquire`), and mDNS replies on the query
        channel (`amtk_awdl_mdns_query_channel=1`).

      *(unverified, web research 2026-11-23)*
- [ ] Research option, not a plan: macOS 26 ships Apple's own MediaTek driver (`AppleSunriseWLAN.dext` +
      `AppleSunrise.kext`; [mediatek-sunrise-hackintosh](https://github.com/GeekAudio/mediatek-sunrise-hackintosh),
      from tonymacx86 thread 332855).
      - On 26.7.1 the MT7922's Bluetooth firmware is built in, but its Wi-Fi firmware is missing.
      - The route needs a device-id spoof (SSDT), the HAL kext from Apple's KDK, and the firmware written into the
        sealed system volume with authenticated-root off.
      - AWDL there: "seen on 26.3 beta, limited success on MT7922".
      - It would be Apple's own stack (Mac parity), but it conflicts with 09's SIP / sealed-system goals.
      - Apple's kext must never be redistributed: the user would extract it from their own KDK.

      *(unverified, web research 2026-11-23)*
- [ ] MtkWirelessBT's bluetoothd patches (BLE advertising for AirDrop / Handoff) exist only for 25G241 (26.7.1) and
      25G332 (26.7.2), and Instant Hotspot needs 25G332. So any macOS update (ROADMAP rule 8) is decided together
      with 09 *(unverified, web research 2026-11-23)*. Open: issue #10's machine ran 26.7.3 with AirDrop working,
      so find out which features really need the build-specific patches.
- [ ] Study [ForbiddenItlwm](https://github.com/retropineaple/ForbiddenItlwm) (fork of AirportItlwm, GPL-2.0; AWDL for
      Intel AX200/201/210/211) as the reference design for the MtkWireless fork: its AWDL, the separate `llw0`
      interface (Continuity Camera) and `BTLEAdvFixup.kext`; read its `docs/HOW-IT-WORKS.md` and `DEBUGGING.md`, and
      its credits (FranciumOS-org/AirPort_RTW89, DrogaBox/RTL8814Native for the Continuity Camera peer-cache records,
      seemoo-lab/owl). It claims, on 26.7.1-26.7.3: AirDrop both ways at ~20 MB/s, Universal Clipboard, Handoff,
      Continuity Camera; AirDrop prefers channel 149 / 80 MHz, iPhones use 44 where 149 isn't allowed. Public beta
      (0.6.0-beta.4, 2026-11-22), written with AI help. MtkWireless shares its zxystd driver layer and licence, so
      ideas and code can be ported *(unverified, owner's find 2026-11-23)*
- [ ] **Owner decides:** an Intel AX210 M.2 card (~20 EUR) with ForbiddenItlwm + IntelBluetoothFirmware instead of the
      MT7922. Community-maintained, not ours; the profile's `wifi:` field must then support both cards. One EFI change
      per boot as always *(unverified, owner's find 2026-11-23)*
- [ ] Universal Clipboard (probably the same AWDL link *(unverified)*), Continuity Camera wired (no frames,
      `EADDRNOTAVAIL` on the USB link) and wireless, Sidecar / Universal Control, Auto Unlock
- [ ] Fork MtkWireless only for what's left: adaptive AWDL off-channel, shorter windows, the per-second
      `mismatch of channel sequence` re-program
- [ ] Wi-Fi throughput drops for ~30 s every ~5 min (owner, 2026-11-19; never reproduced since the AWDL fix). Measure
      first: a 15 min ping / throughput log next to `log stream --predicate 'process == "airportd"'`
- [ ] Bluetooth / Wi-Fi coexistence (`wdutil`: BTC Mode Off): AirPods while transferring on 2.4 GHz
- [ ] Regulatory domain (driver country `00`; System Information shows DE / ETSI); possibly half the Wi-Fi
      throughput (upstream issue #11): measure on the LAN first
- [ ] Profile field `wifi:` for other cards (Intel, Broadcom)

## 09 Security and updates

- [ ] **Blocker: the system volume is unsealed** (since 2026-11-23 18:20, thread 03: `PhxVideoDecoder.bundle` in
      `/System/Library/Video/Plug-Ins`, booted snapshot `com.apple.bless.00B2C242...`; decisions 2026-11-23). Costs:
      full updates only, no sealed-snapshot boot, in the way of SIP towards `0x0` and Apple Secure Boot. Undo:
      `sudo bless --mount / --last-sealed-snapshot` + restart (system-wide HEVC / AV1 hardware decode then stops; set
      `phxdec-off` first or AV1 sessions fail). Research: can VideoToolbox load our decoder from a place that keeps the
      seal?
      - `/Library/Video/Plug-Ins`: an **ad-hoc** bundle there is dropped (verified, thread 03); a properly signed one
        (Developer ID) (unverified)
      - a supplemental-decoder registration early enough (WebKit's `registerSupplementalVP9Decoder` uses
        `VTRegisterSupplementalVideoDecoderIfAvailable`; whether that SPI takes a third-party decoder in
        `VTDecoderXPCService` and the WebKit GPU process) (unverified)
      - a cryptex or another auxiliary route (OpenCore-injected, Preboot) (unverified)
      - AppleGVA's route, as a real AMD Mac decodes: the accelerator publishes `IODVDBundleName` and AppleGVA loads
        `PhxVA.bundle` from `/Library/GPUBundles` (`src/video-accel/PhxVA.c` is an M0 stub today; audit 2026-11-24)
        (unverified on 26.7.1)
      **Any change to the system volume needs the owner's OK first** (coordination, 2026-11-23)
- [ ] **VermilionTrust layout check:** at boot, decode `_mac_file_check_library_validation`, `_mac_file_check_mmap`
      and `_mac_file_check_mmap_downgrade` and check the slots they call through; a pre-update check against the new
      `ipsw`. Today a shifted layout most likely panics or wraps the wrong hook; it does **not** refuse cleanly
- [ ] `ipc_control_port_options=0`: find what needs it, then one boot without it
- [ ] AMFIPass 1.4.1: still loaded, probably useless next to VermilionTrust; one boot without it
- [ ] SIP `0x0A03` -> `0x0203` (check the daemon doesn't need unauthenticated root), then towards `0x0` after 06
- [ ] Apple Secure Boot (`SecureBootModel`) once nothing needs the AuxKC
- [ ] FileVault, after 06's daemon change
- [ ] Update policy: pending Safari 27.2, Rapid Security Responses (`CriticalUpdateInstall = 0`), the pre-update
      checklist (offsets, link gate, AuxKC), rollback. **No macOS update until then** (ROADMAP rule 8)
- [ ] Drop `NVMTLDriver-previous` (`8f6eb933`) from the trust list once the old plugin is gone
- [ ] Widevine in Chrome / Firefox ([OWNER-TESTS](OWNER-TESTS.md))

## 13 Performance parity (after 09)

- [ ] **Re-rank before phase 4** (thread 02's proposal, 2026-11-24,
      [finding](findings/2026-11-24-audit-thread-handover.md)): M3 plus the faster buffer clear first; the Linux twins
      second; per-submit cost (#7a) behind the composite; the direct Vulkan ICD (#6) as the main MoltenVK fix,
      multi-draw (#5) only interim; drop the CPU `_CST` item (#7b) or make it a known limit
- [ ] **Hardware encode** (H.264 / HEVC through VideoToolbox: FaceTime, exports, AirPlay sender): every encoder is
      software today (audit 2026-11-24). VCN encode through RADV Vulkan Video encode; new VCN programming, so
      `hw-safety-reviewer` first

Thread 02 is merged; what is left of "Linux GPU parity in every app" is here, run as thread 13 after 09 and before 10
(ROADMAP) so ryzentosh pins the final driver. Baselines: PROJECT_KNOWLEDGE, "Parity baselines at the end of thread
02"; evidence: [horizon-present-cost](findings/2026-11-23-horizon-present-cost.md),
[vram-bo-design](findings/2026-11-23-vram-bo-design.md), [perf-power](findings/2026-11-23-perf-power.md).
**Every plugin, translator or RADV install is also an EFI change** (VermilionTrust's cdhash list) and a restart (the
plugin loads into WindowServer at boot); a kext change is an EFI change; a daemon change is a restart, no EFI change.
Effort: S about a day, M days, L weeks. Ranked by the gap each closes:

- [ ] **1. WindowServer's composite.** About 2.2 ms of GPU per 1440p frame, the largest part of Horizon's 3.4 ms
  (Horizon 292 fps vs 4370 on Linux, ~15x). C3, the display surface tiled as upstream wrote it, was worse (230 vs 292
  fps: a 14.7 MB copy to the pages after each of WindowServer's ~3 command buffers per frame). Redo: one copy per frame
  at the swap commit, or GPU present copying the tiled image straight into its VRAM slot. Effort M. Plugin: EFI
  change + restart (the daemon flag `wstiled` is already there).
  Maps (2026-11-25, [finding](findings/2026-11-25-windowserver-composite-cost.md)): ~3.1 ms per composite at 119/s while
  Maps draws ~35/s. The Maps layer from system memory ~1.0 ms (2.8 ms with a new frame), glass and UI ~0.8 ms (a
  ~13 us floor per pass), GPU present's full read-back of the display surface ~1 ms copy+wait. The Mac way for a
  composited fullscreen app: **scan out CoreDisplay's display surfaces from VRAM** (no present copy; kext + plugin, L).
  `hw-safety-reviewer` set five conditions before it is built (finding section 4 fix 1: the large slots, the 1 GiB BAR
  check, no host import of BAR pages, Linux's flip-complete test, flip away before free). Then item 2.
  **Built 2026-11-25** (branch `ownback/ws-vram-scanout`, VermilionBoot b162 + NVMTLDriver, switch file `ws-direct`,
  hw-safety re-check OK; finding section 8). Not installed. Deploy: b162 alone (one boot), then plugin + VermilionTrust
  (one boot), then the switch file live; owner test and rollback in section 8.
- [ ] **1b. Narrow render-pass dependencies** (plugin, S-M): every pass has image-less ALL_COMMANDS / MEMORY_* entry
  and exit dependencies, likely an L2 flush per pass in RADV (unverified); ~0.4-0.5 ms of WindowServer's frame is
  the ~13 us per-pass floor. Measure RADV's flush bits per pass (or A/B `NVMTL_RP_K1=1`) before changing it.
- [ ] **2. GPU-used IOSurfaces resident in VRAM** (app drawables, WindowServer's surfaces): removes the per-frame copy
  of each tiled drawable to its system-memory pages (~0.6 ms at 1440p, not timed alone) and WindowServer's
  system-memory reads. Gap: the rest of Horizon's frame after item 1. Effort L. Kext + plugin: EFI change + restart.
- [ ] **3. VRAM BOs for every app by default (M3)**, now that b160 cannot leak. Gap: an app not in
  `debug.phxbo_vram_proc` copies at 43.7 GB/s vs Linux's 823-837 (~19x); Minecraft's GPU time per submission was 5.2x
  higher before `java` joined the list. Before M3: **the buffer clear**, ~8 GB/s today (256 MiB in 31 ms; Linux clears
  on SDMA, its speed not measured), or every allocation pays it. Effort M (the clear) + S (the default). Kext: EFI
  change + restart; the default alone could be a daemon flag (restart only). Final call on M3 in 11 if still open.
- [ ] **4. Per-draw waste in the plugin.** Minecraft (Vulkan through MoltenVK), 854x480: 134 fps, CPU-bound (GPU 37 %
  busy); of 2011 render-thread samples, 371 in `objc_release` called by
  `-[NVMTLRenderCommandEncoder drawIndexedPrimitives:...indirectBuffer:...]` and 305 in `nvmtlBindSamplerPipeline`
  (re-binding per draw). Linux twin not measured yet: measure Minecraft on Linux first. Effort S-M. Plugin: EFI change
  + restart.
- [ ] **5. Consecutive indirect draws merged into one multi-draw.** Sodium issues one multi-draw; MoltenVK splits it
  into one Metal indirect draw per section (Metal has none), the plugin makes each a single Vulkan draw: 555 of the
  2011 samples in `radv_CmdDrawIndexedIndirect`. Fold draws with the same state and buffer into one
  `vkCmdDrawIndexedIndirect` with `drawCount > 1`. Gap: as item 4. Effort M. Plugin: EFI change + restart.
- [ ] **6. A direct Vulkan ICD for macOS apps** (RADV as the app's Vulkan driver with a `CAMetalLayer` / IOSurface
  swapchain, skipping MoltenVK -> Metal -> Vulkan). Removes items 4 and 5 for Vulkan apps; Linux runs RADV directly.
  03 built the loader, the ICD manifest and the window surface (patch 0020, opt-in in `/usr/local/lib/vermilion`,
  2026-11-23: a host-memory copy plus a Metal blit per frame); 13 points MoltenVK apps at it, gives the swapchain a
  direct IOSurface path and measures. Effort L. RADV: EFI change + restart.
- [ ] **7. CPU side.** (a) The plugin adds ~55-80 us per waited Metal submit over Vulkan (`metalbench` 207 vs
  `vkbench` 124 us median for the 512x512 job; Vulkan alone is at parity, 32 vs 37 us): effort M, plugin (EFI change +
  restart). (b) CPU idle package 39.5-41.3 W vs Linux 37.8 W, one thread 5.02-5.12 vs 5.16 GHz: the `_CST` idle kext
  was declined for ~2-3 W (decisions 2026-11-23); revisit only if a workload shows the clock gap. Effort M, a kext: EFI
  change. (c) WindowServer's ~280 wakeups/s on an idle desktop: compare with a real Mac first. Effort S.
- [ ] **8. The 6 GiB Metal working set** (`phx_globals.cpp`) sized from VRAM, now that BOs can live there. Effort S.
  Kext: EFI change + restart.
- [ ] **9. Fable's follow-ups from #15** (each changes machine code: one kext build bump, b161, one EFI change):
  - ~~Check `gpuTimeReset`~~: answered by 03 (2026-11-23, [finding](findings/2026-11-23-apis-video.md) section 1):
    retiring the VCN queue there is harmless (VCN entries carry `kNoCtx`); the helper below may include or skip it.
  - Fold the retire loop that appears three times in `phx_gputime.cpp` into one helper.
  - `gpuSubmit`'s timestamp path uses `fbAper` without the null check `gpuTimeAccount` has: confirm a ready queue
    implies `fbAper`, or add the check.
  - `doBoCreate`: the b156 and b159 blocks duplicate the free-handle search and the scalar outputs.
  - `goldenTsc()` uses literal `0x16a2d` / `0x16a2e` (`kGoldenTscUpper` is defined later, in `phx_client.cpp`).
- [ ] **10. Linux twins for the real-app set:** WebGL / WebGPU in Safari and Chromium, a Metal game for 20 min,
  Minecraft (F3), the same scenes on Linux; until then the gap for each is unknown. Effort M (one Linux session).
- [ ] **11. 4K video in Safari** (from 03, 2026-11-23, [finding](findings/2026-11-23-apis-video.md) section 7):
  YouTube AV1 2160p60 10-bit HDR stutters and glitches on the owner's screen; decode is bit-exact, so the glitch is
  presentation or timing. Our decoder works one frame at a time in the WebKit GPU process (decode 6.45 + VCN wait 4.03
  + copy into the IOSurface 2.81 = ~13.3 ms per frame, spikes to 64 ms; a 60 fps stream has 16.7). Fix: several
  frames in flight (async VCN fences), decode straight into the IOSurface (no copy), then find the glitch with the
  stream at full rate; remove the 4K stopgap if 03's TODO shipped one. Effort M. Decoder dylib: trust + EFI change.
- [ ] **12. GPU robustness leftovers** (13 is the last GPU thread before ryzentosh: it takes these too). From 03's
  webgpu-samples run (finding section 7): AIR -> SPIR-V translator failures ("native emitter: unknown SSA value",
  "graph walk ... opcode=tail", `ImageQuerySizeLod` contract, a sampler operand), indirect command buffers
  (`newIndirectCommandBufferWithDescriptor` -> nil: WebGPU render bundles; they **crash Safari's GPU process**,
  SIGTRAP in `icbCommandClampFunction`, 4 reports on 2026-11-23), textures that sample black (`texturedCube`,
  `cameras`, `generateMipmap`, `timestampQuery`). Rerun `tools/metaltest/wgsamples.m` after each fix. Effort M-L.
  Translator / plugin: trust + EFI change.
- [ ] **13. Decode leftovers from 03** (each changes the decoder bundle on the system volume: owner's OK first,
  decisions 2026-11-23; plus trust + EFI for the dylibs):
  - [ ] AV1 has no fallback: with the bundle installed, an AV1 session our decoder refuses (VCN down, `phxdec-off`)
        fails (`-12906`) instead of falling back, while `VTIsHardwareDecodeSupported(av1)` says true. VideoToolbox's
        decoder list has Apple's "SW AV1 Decoder" (`com.apple.videotoolbox.videodecoder.av1.sw`, 2026-11-23); find
        out why it is not tried; then either refuse AV1 in the bundle's matching when VCN is down (a second bundle
        entry?) or document. `phxdec-av1` is set meanwhile
  - [ ] H.264 on VCN (a real Mac decodes it in hardware): FFmpeg's `h264_vulkan` + RADV's H.264 decode are there;
        `phxdec_hevc.c` and the bundle handle HEVC / AV1 only

Other open items from 02 (not ranked; none is a parity gap on its own):
- [ ] Days of use for interrupt waits (`irqwait`) and idle DPM (`idledpm`, `idledpm-dcf`), then INSTALL's recommended
      set; idle power at 60 / 120 / 144 Hz and SDR seen only through the mock ([perf finding](findings/2026-11-23-perf-power.md) 4, 9)
- [ ] VRAM BOs: the real-app set before / after and days of use (OWNER-TESTS 02)
- [ ] **GPU hang under clpeak's MPS / CoreML pass** (2026-11-23 09:15, VRAM BOs off, no VM fault;
      [finding](findings/2026-11-23-clpeak-hang.md)): find the MPS kernel that does not finish; clpeak stays out of
      the benchmark set. 03 may hit it first (MPS is API-level)
- [ ] Fan readings: `SMCSuperIO` for the **NCT6799D at 0x2e:0x290** ([linux-02b](findings/2026-11-23-linux-02b.md)); its
      own EFI change, the owner's call when
- [ ] Per-core clock SMC keys missing from SMCProcessorAMD (low priority; `tools/sensors/cpuclk.c` covers it)
- [ ] `smumetrics.py` `CurrClock[GFXCLK]` always reads 1200 MHz: a mis-read field or a target
- [ ] RADV's canned `navi31` firmware versions (ME 1486, PFP 1525, MEC 494) vs Linux's (2540 / 2710 / 2790): compare with
      what the firmware macOS loads reports, and whether RADV keys anything off them
- [ ] The `nvmtl-mesa ... Permission denied` line on stderr of command-line Metal tools, if a tool still prints it

## 10 ryzentosh

- [x] Installer partition `disk0s4`: deleted on the owner's request (2026-11-23, thread 02: the Data volume was full)
      and the container grown to 107.4 GB. Left: a 26.7.1 reinstall path off the disk (Recovery would install the
      newest macOS), and fix `efi/README.md`
- [ ] NVMe shown as "external": `device_properties` in `efi/build.py` and the profile, `built-in = <01>` on
      `PciRoot(0x0)/Pci(0x1,0x2)/Pci(0x0,0x0)` (from ioreg, not checked with gfxutil); one EFI change (cosmetic)
- [ ] Generators: DSDT NOP patches (`fix_dsdt.py resolve` emits the plan, the patches were copied by hand),
      SSDT-CPUR from the MADT, the USB map from `usbwatch.py` (ports beyond 15 need two passes)
- [ ] ACPI dump without Linux (OpenCore SysReport, or macOS after a first boot from a generic profile)
- [ ] `iasl` and `smcread` pinned and fetched (both built or copied by hand today)
- [ ] Post-install check that `en0` is built-in before the Apple Account sign-in; a fix script with backups
- [ ] ROM when the build doesn't run on Linux on the target (`rom_from_interface: eno1` is a Linux name)
- [ ] OpenCore debug settings (`Target = 67`, `-v`) to `0` once stability is proven. No OpenCore log was written
      since 2026-11-22 23:20 although `Target = 67` is set (cause unknown)
- [ ] Optional: a Limine menu entry that chainloads OpenCore
- [ ] BIOS settings table (dGPU boot display, ReBAR, CSM off, C-states) checked against the board's menus

## 11 Final validation

- [ ] USB 3 halves of every rear port (paired by convention, never seen at SuperSpeed)
- [ ] Ethernet link with a cable; fallback AppleIntelI210Ethernet + `e1000=0` if the built-in driver fails;
      LAN throughput with an `iperf3` peer
- [ ] Time Machine first backup and restore; Recovery boot (with the GPU thread's OK)
- [ ] Stress and soak: 30 min CPU, 30 min `metalbench`, both together, `memtester`, 8 h idle
- [ ] Audio: hot-plug of the line-out, microphone, 24-bit default, the bass distortion at 50 %
- [ ] Desktop performance baseline: app launch times, Mission Control / Stage Manager smoothness, idle CPU
- [ ] Sharing (Screen Sharing, SSH, SMB; the Public folder is guest-writable), printers, Xcode and simulators
- [ ] The three JetsamEvent memory-pressure kills (not read yet)
- [ ] Shutdown stall report at almost every restart (~2-3 s, normal teardown; low priority)
- [ ] Cold shutdown (not restart): SMART "Unsafe Shutdowns" still 212

## 12 Final refactor

- [ ] Regenerate every replay plan from a capture directory and compare, in a script (by hand today)
- [ ] The connector table from the VBIOS parser (`PhxVbios.h` already produces the same table)
- [ ] Machine-specific values into per-board / per-monitor data files with detection
- [ ] Latent on the XTX ([docs/XTX.md](../docs/XTX.md)): `mesboot.c` `SYSTEM_APERTURE_HIGH` from `FB_LOCATION_TOP`
      (sized for 20 GiB), the pipe-1 HUBP1 aperture, the Metal core count from the profile (`nvmtl_corecount.c`)
- [ ] EDID: the E-DDC segment pointer and all 384 bytes (`PhxDdc.h`, `PhxEdid.h`); mode matching by EDID timings
      instead of the fixed tables
- [ ] One boot log line with the PCI revision, DMCUB version, OTG0 totals, DP link rate / lanes, BAR0 length, VRAM
- [ ] Split `nvmtl_vk.c`, `NVMTLObjects.m`, `nvrm-accel.cpp` where reviews get easier, in separate commits
- [ ] Mock tests: five suites that already failed before thread 00 (`phxctl_serve_test.sh` 1 failed;
      `b21guard_mut.sh` 1 bad, `bootflags_mut.sh` 2 bad, `bootrate_mut.sh` 4 missed + 1 bad, `wsprefs_mut.sh` 1 bad);
      a first run on a real Linux machine
      ([finding](findings/2026-11-18-mock-tests-on-linux.md))
- [ ] Upstream PRs to leolivm (VermilionTrust first, the XTX profile and detection, derived apertures, portable tests)

## Later: virtualization (after the series)

- [ ] macOS as a VM with the dGPU passed through (VFIO), Linux on the iGPU: reset strategy for Navi 31 (Vermilion
      needs a cold GPU), VM definition, the `macos` launcher. The macOS guest still has no Hypervisor.framework
