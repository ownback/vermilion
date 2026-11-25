<!-- SPDX-License-Identifier: MIT -->

# passd's 30 s Secure Element wait: what triggers it, and the platform fix (2026-11-25)

This follows `2026-11-25-music-slow-load.md`. That finding showed that every cold start of passd spends 30 s in
libAppleSSE looking for an `AppleSSE` IOKit service, and that Music's first launch waits for it. This note answers what
makes passd run that lookup, whether any platform property skips it, and what a Mac-like fix looks like.

The work was read-only on the XTX machine (macOS 26.7.1 25G241, SMBIOS MacPro7,1, no T2). The sources were the
machine's own binaries, read with `otool`, `nm`, `strings` and `dyld_info`, plus `ipsw dyld extract` into a scratch
directory:

- `/usr/lib/libAppleSSE.dylib` and `PassKitCore` from the dyld shared cache;
- the standalone `PassKitCore.framework/passd`, the same build as in the 11-23 hang report (UUIDs match);
- `/System/Library/LaunchAgents/com.apple.passd.plist`, `AppleSSE.kext`'s `Info.plist`, `ioreg`;
- `/usr/bin/log show` for passd's cold start at 18:01:47, which the warm-up agent triggered.

Nothing was installed, started or changed. The notes below describe behaviour in our own words. No Apple code or
disassembly is in the repo (rule 6).

## 1. The trigger (high confidence: read in the binaries, matches the live log)

The chain has no condition a platform can set. Each step:

1. **passd's server init waits for three criteria:** iCloud restore done, file protection on, and "Hardware check".
   "Hardware check" means *the NFC check has finished*, not *a Secure Element is present*: it is bit 0 ("determined")
   of PassKit's Secure Element availability flags. The live log shows this: `Updated hardware state : 0` → nfcd
   `Code=58 "Unresponsive hardware"` → `passd initialization: criteria satisfied`, all at 18:01:47.417. So on a Mac
   with no Secure Element, the init still goes ahead.
2. **The init then always gets `+[PKSecureElement sharedSecureElement]`.** That method always creates the object.
   Its `init` checks `PKSecureElementIsAvailable()` (the nfcd answer), but only to decide whether to look up the NFC
   `embeddedSecureElement`. That lookup returns nil here: `Hardware state is unsupported`. Nothing in `init` concerns
   AppleSSE.
3. **The init calls `-[PKSecureElement registerObserver:]` with the server object (`PDServer`) as observer, with no
   condition.** `registerObserver:` calls `_registerPairingChangeHandler` for any observer that implements
   `secureElementPairingDidChangeForReason:`, and `PDServer` does.
4. **`_registerPairingChangeHandler` calls `SSESetEffacementNotificationHandler` without checking anything first.** It
   only returns early if a handler is already registered. On failure it logs `Error setting the Secure Element Pairing
   change handler: -20` and goes on. That is the only libAppleSSE function PassKitCore imports.
5. **libAppleSSE's `init` runs on the first call:**
   - it asks IOKit for a service matching the class `AppleSSE`;
   - if there is none, it sleeps 0.5 s and asks again, until 30 s of wall-clock time have passed since the first
     try. That gives the 60 `AppleSSE service not found, retrying...` lines;
   - then it gives up with -20.

   The library checks nothing else first: no SMBIOS model or board-id, no `hw.*` sysctl, no NVRAM, no
   `AppleSEPManager`. Its only MobileGestalt question is `InternalBuild`, which decides whether it writes
   `/Library/Logs/AppleSSE.log`. It also has an exported flag named `_sseSkipSEAvailabilityCheck` that its own code
   doesn't read. It may be a hook for other images; we didn't follow it, and changing it would mean patching memory
   anyway.
6. **After a timeout, the library doesn't mark itself as initialised.** Any later libAppleSSE call in the same process
   would wait another 30 s (inferred from the code, not seen). PassKit makes the call once per process, so passd pays
   once per start.

**What the service would answer if it were there.** When the service exists, libAppleSSE opens it and asks one
version/capability question. The one-byte answer says whether SSE is supported. If the answer is "no", the library
marks itself initialised with "no SSE" and every call fails at once. So Apple's design has a "service present, SSE not
supported" state that is fast. It has no fast "no service" state, because every Mac that runs macOS 26 has the service
(see 2).

Other users of libAppleSSE are `SEService.framework`, `/usr/libexec/nfcd` and `/usr/libexec/seserviced`. Securityd
and the keychain don't link it. In the last 6 h of logs, only passd ran the retry loop: three cold starts (16:57,
17:12, 18:01), 60 retries each.

## 2. A real Mac, and what the community does

- **Every Mac that runs macOS 26 has the `AppleSSE` service.** On Intel, `AppleSSE.kext`'s x86 personality matches
  `AppleSEPManager`, the T2's Secure Enclave. On Apple silicon, it matches the SEP's `sse` endpoint. Every Intel Mac
  that macOS 26 supports has a T2. So libAppleSSE's lookup succeeds at once, and the 30 s path is one Apple's
  supported hardware never takes (inferred from the matching rules; not seen on a real Mac).
- **A real T2 Mac also starts passd at login.** `com.apple.passd.plist` has an IOKit launch event on
  `AppleEmbeddedOSSupportHost` (IOServiceFirstMatch), the T2 host driver. Of all the system LaunchAgents and
  LaunchDaemons, only passd and `eoshostd` (the T2 host daemon) use it. On a T2 Mac, that service exists when the user
  session starts, so launchd starts passd at login, and apps find it running. This PC has neither
  `AppleEmbeddedOSSupportHost` nor `AppleSEPManager` (`ioreg`), so passd starts only when a client first calls it.
  That's why the 30 s lands in Music's launch. (Inferred from the job definition; not seen on a real Mac.)
- **A real Mac without a Secure Enclave:** none runs macOS 26. The last Intel Mac without a T1 or T2, the 2019 iMac
  (iMac19,x), stopped at macOS 15. We don't know whether passd waited the same way on those Macs (unverified). Logs
  from such a Mac on macOS 15 would show whether Apple ever shipped a "no service" path.
- **Community:** no OpenCore or Hackintosh source describes this wait or a fix for it (searched 2026-11-25). The
  closest is OpenCore Legacy Patcher on real **T1** Macs (dortania/OpenCore-Legacy-Patcher#1103). Sonoma dropped the
  T1 relay in `AppleSSE`, `AppleKeyStore` and `AppleCredentialManager`, and OCLP restores older copies of those kexts
  and frameworks with a root patch. That needs real T1 hardware and an unsealed system volume, so it doesn't apply
  here. Hackintosh guides treat Apple Pay and Touch ID as unavailable without T2 hardware, and they don't mention
  passd's delay.

## 3. The fix

**There is no platform property that skips the lookup.** Apple's code doesn't check one. An SMBIOS change wouldn't
help either: no supported non-T2 model exists, and nothing in the chain reads the model. That rules out an OpenCore
config change too.

What the platform can do Mac-like is reproduce **when** a T2 Mac starts passd, without claiming hardware it lacks:

1. **Recommended: report the absence honestly, and start passd at login as a T2 Mac does.**
   - The platform publishes no `AppleSEPManager`, `AppleSSE` or `AppleEmbeddedOSSupportHost`, as now.
   - The login agent `local.phxpassd` (on `ownback/megamind`, commit 3b79dfc; installed, it ran at 18:01:47) uses
     `RunAtLoad` plus `launchctl kickstart gui/<uid>/com.apple.passd`. That stands in for the IOKit launch event that
     on a T2 Mac fires at session start. passd then spends its 30 s in the background right after login, as a T2 Mac
     spends its (much shorter) init.
   - So the agent isn't a workaround for a bug in our stack. It's the platform's equivalent of the T2's launch
     trigger. It belongs in **ryzentosh** as a platform component (installed per user, not an EFI or system-volume
     change). It should leave `tools/phxctl/` in vermilion-xtx, and its comment should say this instead of
     "mitigation".
   - What stays different from a real Mac: for about 30 s after login, passd's main queue is still busy. An app that
     needs passd in that window (Music, TV, App Store account saves, a first Apple Pay sheet, Wallet pass imports)
     waits for the rest of it. A real T2 Mac doesn't.
2. **Possible, not recommended: a kext that publishes an "SSE not supported" service.** It would answer
   libAppleSSE's capability question with "no", the state described in section 1, so the lookup would end at once
   with no 30 s anywhere. But IOKit matches by class name, so the service would have to be a class named `AppleSSE`
   that speaks Apple's private user-client ABI. That means:
   - impersonating an Apple driver class (our classes carry our own names, `docs/NAMING.md`; it also collides with
     `AppleSSE.kext` if that ever loads);
   - following a private ABI on every macOS update;
   - changing what nfcd, seserviced and SEService see.

   It's an imitation of Apple's service even though it reports "absent", so it's close to the rejected "fake
   AppleSSE". Only the owner can decide on it, and only if the 30 s after login turns out to matter.
3. **Rejected:**
   - a stub `AppleSEPManager`, `AppleSSE` that claims to work, or `AppleEmbeddedOSSupportHost`: faking T2 hardware,
     and `AppleSSE.kext` or `eoshostd` would try to drive it;
   - patching libAppleSSE or PassKitCore, in memory (Lilu, user space) or on disk: a binary hack, and it needs
     library-validation or system-volume changes;
   - disabling passd: loses Apple Pay and Wallet passes;
   - changing SMBIOS: no model avoids it (see above).

### What each feature gets, today and with the recommended fix

| Feature | Uses libAppleSSE here? | Effect of the absent SSE | With the login-start fix |
|---|---|---|---|
| **Pay with iPhone in Safari** (iPhone/Watch over Continuity; the iPhone's Secure Element signs) | no, PassKit only registers the pairing handler | first request after a passd cold start waits for the 30 s | no wait once 30 s have passed since login. Works at all? **unverified** |
| **Wallet passes** (boarding passes, tickets added from Safari or Mail) | no | first import after a cold start waits | same as above |
| **Apple Pay on the Mac itself** (Touch ID Macs only) | yes | not available: no Touch ID, no Secure Element. Same as a T2 Mac without Touch ID (inferred) | unchanged |
| **Keychain, iCloud Keychain** | no (securityd doesn't link libAppleSSE) | none | none |
| **Music, TV, App Store account saves** | indirectly, through accountsd → passd | 30 s on a cold passd | fast after the first 30 s of the session |

## 4. Deploy and test

The recommended fix is already deployed on the XTX machine: `local.phxpassd` is in `launchctl list` with exit status
0. What's left is moving it to ryzentosh and these owner tests (each is unverified until run):

1. **Login start (the fix itself).**
   1. Cold boot, log in, wait 60 s.
   2. Run `/usr/bin/log show --last 3m --style compact --predicate 'eventMessage CONTAINS "spawned passd" OR eventMessage CONTAINS "AppleSSE service not found" OR eventMessage CONTAINS "criteria satisfied"'`.

   Expected: passd spawned within a few seconds of login, then the 60 retries in the following 30 s.
2. **Music after the window.** Open Music, then run the command from the music finding's test A. Expected:
   `Daemon save took` under 1 s, `MusicUI bootstrap took` about 1-2 s.
3. **Music inside the window (the remaining gap).**
   1. Cold boot, log in, open Music within 10 s.
   2. Run the same command.

   Expected: bootstrap of about 30 s minus the time since login.
4. **passd's lifetime.** passd uses `EnableTransactions`, so launchd may stop it when it's idle or under memory
   pressure. Over a working day, check `ps -o etime= -p $(pgrep -x passd)`, and look for `spawned passd` lines
   after login. If passd restarts mid-session, each restart costs 30 s again. That would need a follow-up: watching
   for passd's exit wouldn't be Mac-like, so the follow-up would have to be something else.
5. **Pay with iPhone.**
   1. In Safari, open an Apple Pay demo page, with an iPhone signed in to the same Apple ID nearby, Bluetooth and
      Handoff on.
   2. Expected on a Mac without Touch ID: a "Pay with iPhone" option.
   3. Look in `log show --predicate 'process == "passd"'` for `payment-continuity` activity.

   Nobody has checked this on this machine.

## 5. What stays unverified

- Real-Mac behaviour: `AppleSSE` answers at once, and passd starts at login through `AppleEmbeddedOSSupportHost`.
  Both are inferred from the matching rules and launchd jobs; no real T2 Mac was observed.
- That a later libAppleSSE call in the same process would wait 30 s again: read in the code, not seen.
- The fast "SSE not supported" path: never seen. Option 2 depends on it.
- Pay with iPhone, Wallet pass import and Apple Pay sheets on this machine: not tested.
- passd's lifetime over a session: seen up to 53 min, and from 18:01 to at least 18:15 today.
- Whether nfcd, seserviced or SEService would call libAppleSSE in situations we didn't log, for example Continuity
  payments.
