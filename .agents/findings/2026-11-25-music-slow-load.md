<!-- SPDX-License-Identifier: MIT -->

# Music's slow first launch: passd waits 30 s for a Secure Element (Phase 2 item 2, 2026-11-25)

After #25 (NVMTLDriver `15204728`, live since the 17:04 boot), Music no longer crashes, but the owner reported that it
"takes ages to load" (first launch 17:12:10, one process). The research was read-only, on the XTX machine (macOS
26.7.1 25G241, SMBIOS MacPro7,1). Sources:

- `~/vermilion-captures/2026-11-25-maps/nvmtl-since-1704.log` (the plugin's `org.vermilion.nvmtl` log);
- `/usr/bin/log show` for Music, accountsd, passd and launchd;
- the spindump `Music_2026-11-23-071207_*.hang` in `/Library/Logs/DiagnosticReports`;
- `dyld_info` on `libAppleSSE.dylib`, and `AppleSSE.kext`'s `Info.plist`.

Nothing was installed or started, and Music wasn't opened.

## Result: not the GPU plugin

Music logs its own number: **`MusicUI bootstrap took: 32.374500 seconds`** (17:12:42.364). Of that, **30.36 s** is its
main thread blocked in one synchronous call, `-[ACAccountStore saveVerifiedAccount:]` to accountsd. The chain:

| Process, thread | Blocked in | From | To |
|---|---|---|---|
| Music, main thread | `accounts/save-verified-account` (AppleMediaServices `ams_saveVerifiedAccount:`), synchronous XPC to `com.apple.accountsd.accountmanager` | 17:12:11.959 | 17:12:42.316 |
| accountsd | `PassbookAccountNotificationPlugin` → `-[PKPassLibrary noteACAccountChanged:]`, synchronous XPC to `com.apple.passd.library`. accountsd logs `TIMING: Daemon save took 30.3563859462738` | 17:12:11.989 | 17:12:42.316 |
| passd (spawned for this call: launchd `Successfully spawned passd ... because ipc (mach)` at 17:12:11.996) | the `passd.library` listener `dispatch_sync`s onto `com.apple.passd.main`. That queue is in `-[PKSecureElement registerObserver:]` → `_registerPairingChangeHandler` → `SSESetEffacementNotificationHandler` → libAppleSSE `init` → `usleep`: **60 × "AppleSSE service not found, retrying..." every 0.5 s**, then `AssertMacros: service (value = 0x0)` and `err == 0 (value = 0xffffffffffffffec)` | 17:12:12.120 | 17:12:42.294 |

The 2026-11-23 07:12 hang report shows the same chain in its stacks. Music's main thread was unresponsive for
23.9 s. accountsd was "blocked by turnstile waiting for passd ... after 3 hops". In passd, the `passd.library`
listener thread waited on `passd.main`, which sat in `PKSecureElement registerObserver:` → libAppleSSE `init` +
`usleep`.

**Why the service is missing.** libAppleSSE imports `IOServiceGetMatchingService` and `usleep` and retries the lookup.
`AppleSSE.kext`'s x86 personality (`AppleSSE_x86`) matches `IOProviderClass = AppleSEPManager`, the T2's Secure Enclave.
This PC has no T2, so no `AppleSEPManager` and no `AppleSSE` service: `ioreg` has no AppleSSE class, and passd logs
`nfcd Code=58 "Unresponsive hardware"` and `Hardware check: 0`. Every Intel Mac that macOS 26 supports has a T2
(MacBook Pro 2019-2020, iMac 2020, Mac Pro 2019), so on a real Mac the lookup succeeds at once (inferred from the
matching rule; not seen on a real Mac).

**When it costs 30 s.** passd is started on demand, once per boot. Each cold start runs the 60 retries (seen at 11:53,
16:57 and 17:12 today: 60 retries each). An app that needs passd synchronously during those 30 s waits for all of it:

| Music launch | passd | Daemon save | MusicUI bootstrap |
|---|---|---|---|
| 2026-11-24 18:35 (before #25) | spawned by Music's save at 18:34:45.9 | 30.33 s | **32.32 s** |
| 2026-11-24 19:28 | already running | 0.013 s | **1.32 s** |
| 2026-11-25 17:12 (after #25) | spawned by Music's save at 17:12:11.996 | 30.36 s | **32.37 s** |

The 18:35 launch was before #25, so #25 didn't cause the slow load. It was there already, and the crashes made it
easy to miss. The hang reports of 2026-11-22 20:33 and 22:25 look like the same chain (unverified: the passd frames
are there, but only the 11-23 report was read in full).

## The plugin's share of the launch

| Plugin step in Music | Time | Thread |
|---|---|---|
| `initWithAcceleratorPort:` → `vk: driver opened directly` (RADV dlopen, ICD, device) | 0.36 s | `7ab7`, not the main thread |
| first buffer → first frames (pipelines from the caches: `fc cache`, `refl cache`, `spvcache` all HIT) | ~0.1 s | render thread |
| surface write-backs (`G13 surface-out`, the #25 fault-safe copy included) | 0.29-0.76 ms each, 6 in the session | execution queue |
| dead command buffers (the ~0.8 s OutOfMemory path) | none | |
| GL vblank wait | announced at load, no GL presents logged in Music | |

The suspects from #25 don't show up in this launch. The fault-safe readback costs under 1 ms per 600x600 plane here.
One `readback dropped, its plane went away` at 17:14:48: the old crash, now caught (the TODO "Music's skipped
readbacks").

There are two plugin-silent periods in the log. During 17:12:11.8-17:13:47, the main thread waits on accountsd
until 17:12:42, then idles (`kDevicesChanged` every 13 s, AppNap assertions) until the owner pressed Play at 17:13:47.
During 17:13:54-17:14:37 (`fps: 0.05 over 42.7 s`), MediaCoreUI logs `Backdrop pausing: ... isWindowOccluded=true`:
the window was covered. Neither is a GPU wait.

## The fix (design; nothing in the plugin)

A real MacPro7,1 answers the SSE lookup at once. This PC can't, so the 30 s belongs to the platform (no Secure
Enclave), not to Vermilion's GPU stack. Options, best first:

1. **Find the gate (research, M).** Find what makes `-[PKSecureElement registerObserver:]` run on this Mac at all:
   passd already knows there is no secure element (`Hardware check: 0`, nfcd "Unresponsive hardware"). If PassKit
   reads a platform property or capability that a Mac without a Secure Element reports, then reporting it from the
   platform makes libAppleSSE's `init` never run. That would be the Mac-like fix. This means reverse engineering
   PassKitCore and libAppleSSE, kept to notes, with no Apple code in the repo (rule 6). It belongs to the platform
   side (ryzentosh), not vermilion-xtx.
2. **Mitigation (S; unverified): start passd at login.** A per-user LaunchAgent (`RunAtLoad`) runs
   `launchctl kickstart gui/<uid>/com.apple.passd`. passd then spends its 30 s in the background right after login,
   and Music opened more than ~30 s after login finds it warm (1.3 s, as at 19:28). Apps opened sooner still wait for
   the rest. passd stayed up for at least 53 min (18:35 → 19:28) and was still running 6 min after 17:12; whether it
   idle-exits later is not known. No system-volume change; rollback is removing the agent. It's a workaround, not
   what Apple ships.
3. **Rejected:**
   - publishing an `AppleSEPManager` or `AppleSSE` stub: `AppleSSE.kext` would attach to it and drive a Secure
     Enclave mailbox that doesn't exist (a security component; risk of hangs or panics);
   - disabling `com.apple.passd`: it removes Apple Pay in Safari and Wallet passes, and on this project lost
     features are bugs.

No plugin change follows from this finding. The plugin TODOs for Music (step 2, a GPU write-back) stay as they are.

## Owner test: Music's load time, before and after

Measured by Music's own log line. Nothing is installed or started for test A.

- **A. Cold passd (what the owner saw).** After a boot, log in, wait 1 min, check that passd isn't running
  (`pgrep -x passd` prints nothing), open Music. Then run:

  ```
  /usr/bin/log show --last 5m --style compact --predicate 'eventMessage CONTAINS "MusicUI bootstrap took" OR eventMessage CONTAINS "Daemon save took" OR eventMessage CONTAINS "spawned passd"'
  ```

  Expected: `spawned passd`, `Daemon save took ~30`, `MusicUI bootstrap took ~32 seconds`.
- **B. Warm passd (the mitigation, by hand).** Quit Music, then open it again in the same boot. Or, after a fresh
  boot, run `launchctl kickstart gui/$(id -u)/com.apple.passd`, wait 35 s, then open Music. Same log command.
  Expected: no `spawned passd`, `Daemon save took` under 1 s, `MusicUI bootstrap took` about 1-2 s.

If B is fast and A is slow, passd's Secure Element wait is the whole difference (so far seen on 3 launches).
