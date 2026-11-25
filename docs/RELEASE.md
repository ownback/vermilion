<!-- SPDX-License-Identifier: MIT -->

# Releases: artefacts, installer, checklist

How a Vermilion release is built, what it contains, how it installs and uninstalls, and the checklist before a tag.
A design, written 2026-11-25. **Nothing here is built yet** unless marked. The audit behind it:
[`.agents/findings/2026-11-25-release-readiness.md`](../.agents/findings/2026-11-25-release-readiness.md).

## The end state, and the way there

A real Mac's GPU driver is one set of kexts and bundles that load at boot with no user step. Vermilion's end state
(ROADMAP, "Repositories"): **one kext dropped into `EFI/OC/Kexts` and one config snippet.** User-space parts that
can't live in the kext (the Metal driver, RADV, the translator, the decoder) need one package until macOS gives a
way to load them from OpenCore, which it doesn't.

| Release | Ships | Needs first |
|---|---|---|
| **`0.1.0-preview`** (reference machine only, RX 7900 XTX only) | OpenCore zip (the kexts + snippet) and an unsigned package (the user-space parts, VermilionAccel, the boot daemon in a system path, the post-install firmware fetch) | G1 revision gate (only `0xC8` runs), a clean-install test, CI builds, the release scan |
| **0.x** | the daemon shrinks as B1 lands; the decoder moves to `/Library/GPUBundles` (A6, no system-volume step) | the parity plan |
| **1.0** | OpenCore zip (VermilionBoot with Audio folded in, VermilionTrust) and a package with the user-space bundles and VermilionAccel | B1, B2, A6, A8, F1, R1 |

Owner decisions, 2026-11-25 (`.agents/decisions.md`, "Release decisions"): the first release is `0.1.0-preview`; RX
7900 XTX only, the kext refuses every other `0x744c` variant; no firmware is shipped, a post-install script that runs
in macOS fetches it; the package is unsigned, with a Gatekeeper step in INSTALL.md; the Allow click for VermilionAccel
stays as a known step (the plan item that moved VermilionAccel into OpenCore, B3, is dropped).

## Artefacts of a release

Built by CI from a tag, never on a developer's machine (build paths, host names and user names end up in binaries).

| File | Contents |
|---|---|
| `Vermilion-<ver>-OpenCore.zip` | `Kexts/VermilionBoot.kext`, `VermilionTrust.kext`, `VermilionAudio.kext` (until folded in), `config-snippet.plist` (the entries of [INSTALL.md](../INSTALL.md#3-the-opencore-snippet), as a plist fragment `ocvalidate` accepts after merging), `README.txt`, `LICENSES/`, `NOTICE` |
| `Vermilion-<ver>.pkg` | the package below |
| `Vermilion-<ver>-source.tar.gz` | `git archive` of the tag: the LGPL translator's and FFmpeg's corresponding source, and everything else |
| `SHA256SUMS`, `SHA256SUMS.sig` | checksums of the three files; a signature (minisign key in the repo, or GitHub's build-provenance attestation) |

**Never in a release:** `build/efi/` or any `config.plist` (SMBIOS serials), AMD firmware or any excerpt of it (F1),
EDIDs, boot logs, `~/.config/vermilion/`, anything from Apple. `scripts/dev/release-scan.sh` checks each artefact
(below) and the release job fails on a finding.

### VermilionTrust and the cdhashes

VermilionTrust lets exactly the cdhashes of the shipped Mach-O files load. So CI builds the plugin, translator, RADV
and decoder first, signs them, then generates the cdhash list from those files (`src/vermilion-trust/gen_list.sh`) and
builds VermilionTrust last. The OpenCore zip and the package of one release are a matched pair; the package's
`preinstall` refuses to run when the loaded VermilionTrust (`sysctl debug.phxtrust_stat`) is from another version and
the zip of its own version isn't on the EFI partition yet. Each release's list also carries the previous release's
cdhashes (as the machine does with `-previous` today), so the order of updating doesn't strand WindowServer for a
boot. Later (TODO 06): the list as data in `Info.plist`, filled from a manifest.

## The package (`Vermilion-<ver>.pkg`)

A flat package built with `pkgbuild` / `productbuild`, identifier `org.vermilion.pkg` *(name per owner decision)*.

| Component | Installs to | Until |
|---|---|---|
| Metal driver bundle: `NVMTLDriver`, `libnvmtl_translate.dylib`, `libvulkan_radeon.dylib`, the AIR reader (R1), `spirv-val`, the bundle's `Info.plist`, license files in `Contents/Resources` | `/Library/GPUBundles/NVMTLDriver.bundle`, `/Library/GPUBundles/nvmtl` (with the sandbox relocation step of `relocate_gpubundle.sh` while sandboxed GPU processes need it) | always (user space) |
| Decoder: `PhxVA.bundle` and its dylibs | `/Library/GPUBundles` | A6 lands; before that the decoder is not in the package (no system-volume writes from an installer) |
| `VermilionAccel.kext` | `/Library/Extensions` (the package ends by asking for the Allow click, a known step: [INSTALL.md](../INSTALL.md#23-the-allow-click-a-known-step)) | always (owner decision) |
| Boot daemon, bring-up scripts, `phxctl`, `mesboot`, `metaltest`, the default flags | a root-owned system path and `/Library/LaunchDaemons` (names per [NAMING.md](NAMING.md)); no file in the user's home | B1 |
| `vermilion-uninstall`, `vermilion-firmware` | `/usr/local/sbin` *(name per owner)* | always |

Scripts (`preinstall`, `postinstall`), each refusing with one clear sentence and changing nothing:

1. **Checks:** macOS 25G241; a `1002:744c` function with revision `0xC8`, the RX 7900 XTX (G1); VermilionBoot loaded (its
   `phx-build` in `ioreg`); the SIP bits the components need; no older install in the user's home (offer the
   migration below).
2. **Firmware** (the post-install script, running in macOS): `vermilion-firmware fetch` downloads the files of `tools/firmware/fw.lock` from linux-firmware at the
   pinned commit (GitLab mirror, then git.kernel.org) into a root-owned firmware directory, checks every md5 and
   SHA-256, and refuses on any mismatch. `vermilion-firmware fetch --from <linux-firmware checkout or tarball>` works
   offline. The package never contains a firmware file. With B1, the same tool generates the firmware kext that
   OpenCore injects (design in the finding, unverified).
3. **Install** the components; keep every replaced file under `/Library/Application Support/Vermilion/rollback/<time>`
   *(path per NAMING)*.
4. **Settings:** Software Update's automatic install off (as `recovery_install.sh` does); sleep off while there's no
   GPU resume; nothing else.
5. **Migration** from a manual install: move `~/gpu` flags that differ from the defaults into the system path, then
   remove `~/gpu` after asking.

What it never does: write the system volume, NVRAM, or the EFI partition (the OpenCore part is the user's, or
ryzentosh's).

The base for the scripts is `tools/phxctl/recovery_install.sh` (it already checks its payload, finds the Data volume,
installs without touching the system volume, NVRAM or EFI, and keeps rollback copies), with its mock test.

### Signing

- Kexts injected by OpenCore need no Apple signature (`SecureBootModel Disabled`). VermilionAccel in the AuxKC is
  ad-hoc signed and needs the Allow click.
- The user-space Mach-O files are ad-hoc signed; VermilionTrust lists their cdhashes. A Developer ID signature would
  change the cdhash, so the list is generated after signing in either case.
- The package is **unsigned** (owner decision): no Developer ID Installer certificate, no notarisation. Gatekeeper
  blocks it the first time, and [INSTALL.md](../INSTALL.md#21-the-release-route-not-available-yet) says how to open
  it (System Settings > Privacy & Security > Open Anyway; unverified on 26.7.1 until a package exists). `SHA256SUMS`
  and its signature are what a user checks instead.

## Uninstaller (`vermilion-uninstall`)

From the package's receipt, in the order of [INSTALL.md](../INSTALL.md#6-uninstall):

1. `launchctl bootout` the daemon, remove its plist, `/var/db/phxboot.pending`, `/var/db/phxboot.fails`.
2. Put back the login-window value and the display overrides (the files the daemon marked as its own).
3. Remove VermilionAccel and rebuild the AuxKC (the `kmutil` step is unverified on 26.7.1).
4. Remove every file `pkgutil --files org.vermilion.pkg` lists, then `pkgutil --forget`.
5. Print what's left for the user: the OpenCore entries and kexts, the NVRAM variables (`phxfb-squat`, `phxfb-boot`)
   where macOS can't delete them, the firmware directory (kept unless `--purge`), the rollback folder.

It never touches the EFI partition; it tells the user what to remove there.

## Hand-off to ryzentosh

`efi/` moves to `ownback/ryzentosh` (ROADMAP). From then on:

- ryzentosh pins the release's `Vermilion-<ver>-OpenCore.zip` in its `components.json` by URL and SHA-256, like any
  other kext, and takes the snippet's entries from the zip's `config-snippet.plist`. It never builds Vermilion.
- vermilion-xtx owns the snippet: a new release that needs another boot-arg or patch changes the snippet, and
  ryzentosh's next build picks it up.
- The release profile (Apple logo, no picker, no verbose text, no OpenCore log) is ryzentosh's (B6).
- Users of other boards use the same zip and snippet with their own OpenCore.

## Versioning and the changelog

- **One release version** for the whole set, semantic versioning: `0.y.z` while experimental. The first release is
  `0.1.0-preview`. A `VERSION` file at the root; tags `v<version>`.
- Every kext's `CFBundleShortVersionString` is the release version; `CFBundleVersion` and VermilionBoot's
  `PHX_KEXT_BUILD` stay the internal build numbers (`src/vermilion-boot/CHANGELOG.md` keeps its per-build log).
- [`CHANGELOG.md`](../CHANGELOG.md) at the root is for users: one section per release, in the user's words (what
  works now, what changed, what to do when updating). The `Unreleased` section collects merged PRs that a user would
  notice.

## Release checklist

Before the tag:

- [ ] `main` is green: `bash tests/mock/run.sh`, `bash tests/mock/b15test.sh`, `sh tests/hooks/guard_test.sh`,
      `sh tests/release/release_scan_test.sh`, the kext and plugin tests.
- [ ] The Fable clean-up pass ran on every merged PR since the last release.
- [ ] `CHANGELOG.md`: the `Unreleased` section becomes the version's, with the date.
- [ ] `VERSION` and every kext's `CFBundleShortVersionString` match the tag.
- [ ] README, INSTALL, SUPPORT match STATUS (works / doesn't, the support matrix, the experimental box).
- [ ] `scripts/dev/release-scan.sh --commits <last tag>..HEAD .` is clean (no personal addresses in new commits).
- [ ] The owner ran `scripts/dev/private-patterns.sh` on the release machine, and the guard is active.

Build (CI, from the tag):

- [ ] Every component built from the tag, with `-ffile-prefix-map` (no build paths in binaries).
- [ ] VermilionTrust built last, from the signed files' cdhashes.
- [ ] `scripts/dev/release-scan.sh` on the unpacked zip, the expanded package and the source tarball: clean.
- [ ] `SHA256SUMS` and its signature.

Test (the reference machine, the owner):

- [ ] A clean install from the artefacts alone, onto a fresh 26.7.1 volume, following only INSTALL.md.
- [ ] An update from the previous release.
- [ ] A cold boot, a warm restart and a shutdown; `bootcheck.sh` clean.
- [ ] The uninstaller, then a boot without Vermilion.
- [ ] The owner tests of `.agents/OWNER-TESTS.md` that the changelog touches.

Publish (owner only):

- [ ] The GitHub Release as a pre-release while the version is `0.y.z`, with the experimental box at the top of the
      notes.
