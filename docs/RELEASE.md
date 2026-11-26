<!-- SPDX-License-Identifier: MIT -->

# Releases: artefacts, installer, checklist

How a Vermilion release is built, what it contains, how it installs and uninstalls, and the checklist before a tag.
A design, written 2026-11-25, and its first implementation (P1, 2026-11-26): the scripts in `scripts/release/`, the
workflow `.github/workflows/release.yml` and the tests in `tests/release/`. **(built)** marks what exists in the
repository; everything marked **(unverified)** has never run where it matters: no release was published, the workflow
never ran on a GitHub runner, and the package was never opened by the Installer on a Mac. What was run: the
hardware-free tests, a package and a zip built from dummy files, and the release scan over them. The audit behind it:
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
| `Vermilion-<ver>-OpenCore.zip` | `Kexts/VermilionBoot.kext`, `VermilionTrust.kext`, `VermilionAudio.kext` (until folded in), `config-snippet.plist` (the entries of [INSTALL.md](../INSTALL.md#what-the-opencore-snippet-changes), as a plist fragment `ocvalidate` accepts after merging), `README.txt`, `LICENSES/`, `NOTICE` |
| `Vermilion-<ver>.pkg` | the package below |
| `Vermilion-<ver>-source.tar.gz` | `git archive` of the tag: the LGPL translator's and FFmpeg's corresponding source, and everything else |
| `Vermilion-<ver>-air-runtime.tar.gz` | the AIR reader the package installs (`libLLVM.dylib`, `libzstd.1.dylib`, `MD5SUMS`, `LICENSES/`), built by `air-reader.yml` |
| `SHA256SUMS`, `SHA256SUMS.sig` | checksums of the four files **(built)**; a signature (minisign key in the repo, or GitHub's build-provenance attestation) is **not built**: open |

The zip, the package and `SHA256SUMS` are built by `scripts/release/make-oc-zip.sh`, `make-pkg.sh` and `make-sums.sh`
**(built)**; see "Building a release" below.

**Never in a release:** `build/efi/` or any `config.plist` (SMBIOS serials), AMD firmware or any excerpt of it (F1),
EDIDs, boot logs, `~/.config/vermilion/`, anything from Apple. `scripts/dev/release-scan.sh` checks each artefact
(below) and the release job fails on a finding.

### VermilionTrust and the cdhashes

VermilionTrust lets exactly the cdhashes of the shipped Mach-O files load. So CI builds the plugin, translator, RADV
and decoder first, signs them, then generates the cdhash list from those files (`src/vermilion-trust/gen_list.sh`) and
builds VermilionTrust last **(built in release.yml: `trust.sh` gets the five files the package installs)**. The
OpenCore zip and the package of one release are a matched pair. Planned, **not built**: the package's `preinstall`
refuses to run when the loaded VermilionTrust (`sysctl debug.phxtrust_stat`) is from another version and the zip of
its own version isn't on the EFI partition yet; and each release's list also carries the previous release's cdhashes
(as the machine does with `-previous` today, `PHXTRUST_KEEP=1`), so the order of updating doesn't strand WindowServer
for a boot. Later (TODO 06): the list as data in `Info.plist`, filled from a manifest.

## The package (`Vermilion-<ver>.pkg`) (built, unverified)

A flat product archive made by `scripts/release/make-pkg.sh` with `pkgbuild` / `productbuild`, identifier
`org.vermilion.pkg` *(name per owner decision)*, x86_64 hosts only, installable on the system volume only, unsigned.
The bundle is not relocatable and not version-checked (an install over the same version replaces the files).

| Component | Installs to | Until |
|---|---|---|
| Metal driver bundle: `NVMTLDriver`, `libnvmtl_translate.dylib`, the bundle's `Info.plist`, licence files in `Contents/Resources` (the AIR reader is added by the post-install script) | `/Library/GPUBundles/NVMTLDriver.bundle` | always (user space) |
| `libvulkan_radeon.dylib` (RADV), the allow list `*`, `spirv-val` | `/Library/GPUBundles/nvmtl`, `/Library/GPUBundles/nvmtl-allow.txt`, `/usr/local/bin/spirv-val` | always |
| Decoder: `PhxVA.bundle` and its dylibs | `/Library/GPUBundles` | A6 lands; before that the decoder is not in the package (no system-volume writes from an installer) |
| `VermilionAccel.kext` | `/Library/Extensions` (the package ends by asking for the Allow click, a known step: [INSTALL.md](../INSTALL.md#34-the-allow-click)) | always (owner decision) |
| `phxctl`, `mesboot`, `vermilion-uninstall`, `vermilion-firmware` | `/usr/local/sbin` | always |
| Boot daemon, bring-up scripts, `phxctl.bin`, `metaltest`, `phxaudio`: a pristine copy, `fetch_firmware.sh` + `fw.lock`, the LaunchDaemon template, `lib.sh`, the AIR reader's files (removed after use) | `/usr/local/libexec/vermilion` | always |
| the same daemon and scripts, the firmware (no flag files: every proven feature is on by default in the daemon) | **the desktop user's `~/gpu`**, written by the post-install script | B1 |
| `local.phxboot.plist` (written, not loaded) | `/Library/LaunchDaemons` | B1 |

**Deviation from the first design:** the design put the daemon in a root-owned system path with no file in the user's
home. The daemon and its helper scripts hard-code `~/gpu` (`navi31_up.sh`, `bringup_navi31.sh`, `b15_boot.sh` and more),
and moving them is a change to GPU bring-up scripts that nobody can test without the hardware, so the preview package
uses the layout that has run on the reference machine (`tools/phxctl/recovery_install.sh` writes the same files). The
known risk stays: scripts the desktop user can write run as root at boot (TODO 06 item 3, closed by B1).

Scripts (`scripts/release/pkg/`), each refusing with one sentence and changing nothing before its checks pass:

1. **preinstall (built).** Refuses unless the target is the running volume; macOS is build `25G241`; the I/O registry
   shows a `1002:744c` function of PCI revision `0xC8` (the RX 7900 XTX, G1) and no other `744c` board (the XT, GRE,
   7900M and unknown revisions are named in the message); a desktop user can be named (console user, else the only
   account with uid 501 or more). The values are `PhxGpuId.h`'s, and `tests/release/pkg_scripts_test.sh` compares
   them with the header. The revision comes from `ioreg`'s `revision-id` property of the `IOPCIDevice`
   (`c8000000` on the XTX machine, read 2026-11-26; `install-check.sh` exited 0 there). If it can't be read, the
   package refuses. Then it opens the rollback folder and copies away every path the
   payload is about to replace. The refusal text is in `/var/log/install.log`; the installer window says only that
   the install failed. **(unverified)** that the Installer shows no more than that.
   Not built from the design: VermilionBoot loaded (`phx-build` in `ioreg`; the zip may be applied later, so a warning
   would do), the SIP bits, the VermilionTrust version match, the migration of a manual install (the preinstall
   notes it and the rollback folder keeps what the package replaces).
2. **postinstall (built).** Installs `~/gpu` and the LaunchDaemon (each replaced file copied to the rollback folder
   first), fetches the firmware, installs the AIR reader, creates the shader cache folders (no flag files, below),
   writes the install marker, prints the Allow-click step. It does not start the daemon.
   The firmware step runs `tools/firmware/fetch_firmware.sh` into `~/gpu/fw/navi31`: the 20 files of `fw.lock`, from
   linux-firmware at the pinned commit (GitLab mirror, then git.kernel.org), md5 and SHA-256 checked, any mismatch
   refused; `--from <linux-firmware checkout>` works offline. **A failed fetch is a warning, not a failed install**:
   the Installer rolls nothing back, so a half-failed package would be worse; the GPU stays on the basic display and
   the message says to run `sudo vermilion-firmware`. The package contains no firmware file. With B1 the same tool
   would generate a firmware kext that OpenCore injects (design in the finding, unverified).
3. **Rollback copies (built).** `/Library/Application Support/Vermilion/rollback/<time>/` holds `MANIFEST` (one line
   per path: `E <path>` it existed and its copy is under `files/`, `N <path>` it didn't) and the copies. One folder per
   install attempt.
4. **Settings (not built).** The package changes neither Software Update nor sleep; INSTALL.md section 1 says to set
   them, and the post-install text repeats it. (The design had Software Update's automatic install off, as
   `recovery_install.sh` does.)

The package writes no flag files (2026-11-26): the daemon's features are on by default (`phxboot-<name>-off` turns one
off), HDR is off by default (broken in this preview), and automatic login and the second monitor stay off without
their file. The MANIFEST therefore has no flag lines; an uninstall leaves the user's own flag files alone. **The
package does not write NVRAM.** The daemon arms the accelerated desktop: on a GOP boot whose bring-up and claim
finished, unless `phxboot-auto-off` exists, it sets `phxfb-squat` for the next boot (read back) and posts "Graphics
acceleration is ready". That needs the firmware and
VermilionAccel, so a missing firmware or Allow click never arms a dark squat boot; a GOP boot without VermilionAccel
loaded starts no bring-up, counts no failure and posts "Graphics acceleration needs your approval". The uninstaller
deletes `phxfb-squat` where macOS can. **(Unverified on a Mac; mock-tested.)**

What it never does: write the system volume or the EFI partition (the OpenCore part is the user's, or
ryzentosh's).

Two checks refuse a wrong Mac, with the same rules (`lib.sh`: macOS build `EXPECT_BUILD`, an RX 7900 XTX and no other
1002:744c board): `installCheck()` in `distribution.xml` runs `install-check.sh` from the archive's Resources when the
package is opened and shows a plain message (exit code 1 build, 2 no XTX, 3 another 744c board); the preinstall
script checks again as root, which also covers `installer -pkg` from a terminal. `system.run` needs
`allow-external-scripts="yes"` in `<options>`; with it the Installer first tells the user that the package runs a
program to check whether it can be installed. **(unverified):** that the Installer runs `system.run` scripts from an
unsigned package and shows the message; `install-check.sh` itself ran on the XTX machine and exited 0.

The test hooks of `lib.sh` and the scripts (`VERMILION_TEST`, `_ROOT`, `_NOCHOWN`, `_USER`, `_UHOME`, `_FETCH`) are
cut out of every shipped copy by `scripts/release/strip-hooks.sh` (make-pkg.sh fails if one is left), so the caller's
environment cannot steer a script that runs as root. The tests keep using the source scripts.

Tested without a Mac install: `tests/release/pkg_scripts_test.sh` runs the three scripts against a fake root with a
fake `ioreg`, `sw_vers` and `pkgutil` (refusals, first install over older files, an update, the uninstall back to the
state before the first install, `--purge`); `pkg_build_test.sh` builds a package from dummy files, expands it and checks
the payload, the scripts and the release scan. **(unverified):** a real Installer run, Gatekeeper's behaviour, that
`/usr/local/libexec` and `/usr/local/sbin` are created with the right owners, and the `--ownership recommended`
result on the files.

### Signing

- Kexts injected by OpenCore need no Apple signature (`SecureBootModel Disabled`). VermilionAccel in the AuxKC is
  ad-hoc signed and needs the Allow click.
- The user-space Mach-O files are ad-hoc signed; VermilionTrust lists their cdhashes. A Developer ID signature would
  change the cdhash, so the list is generated after signing in either case.
- The package is **unsigned** (owner decision): no Developer ID Installer certificate, no notarisation. Gatekeeper
  blocks it the first time, and [INSTALL.md](../INSTALL.md#33-open-the-package-gatekeeper) says how to open
  it (System Settings > Privacy & Security > Open Anyway, or `sudo installer -pkg ... -target /`; both **unverified**
  on 26.7.1: no package has been opened there). `SHA256SUMS` is what a user checks instead; its signature is open.

## Uninstaller (`vermilion-uninstall`) (built, unverified)

`sudo vermilion-uninstall [--purge] [--rebuild-kc]`, installed by the package in `/usr/local/sbin`, in the order of
[INSTALL.md](../INSTALL.md#7-update-and-uninstall):

1. `launchctl bootout` the daemon, remove `/var/db/phxboot.pending` and `/var/db/phxboot.fails`, delete the NVRAM
   variables `phxfb-squat` and `phxfb-boot` where macOS can.
2. Put back the login-window value (`phxboot-b21guard.orig`) and remove the display overrides that carry `phx-override`.
3. Remove every file `pkgutil --files org.vermilion.pkg` lists (and the emptied folders with Vermilion's names), the
   AIR reader (the post-install script put it in the bundle, so no receipt lists it) and
   `/usr/local/libexec/vermilion`; all before step 4, so that step 4 can put back what stood there before.
4. For every path a rollback `MANIFEST` names, oldest folder first, the first line decides: `E` puts the saved copy
   back, `N` leaves the path removed. So an update never turns a Vermilion file into "the user's own", and a file
   the user had before the first install comes back. The firmware folder is skipped unless `--purge`. Then the
   folders the install made in `~/gpu` (`phxctl`, `fw`, `~/gpu` itself) are removed when they are empty. Each
   `MANIFEST` is then renamed `MANIFEST.used` (the copies stay), so a later install and uninstall start from what is
   there then: a file the user puts at a payload path after an uninstall comes back after the next one.
   The uninstaller also works when `lib.sh` is already gone.
5. `pkgutil --forget`; print what's left for the user: the AuxKC rebuild (`kmutil install --update-all` and
   `kmutil clear-staging`, printed, run only with `--rebuild-kc`; **unverified** on 26.7.1), the OpenCore entries and
   kexts, NVRAM variables macOS couldn't delete, the firmware (kept unless `--purge`), the rollback folders.

It never touches the EFI partition; it tells the user what to remove there.

## Building a release (built, unverified on a runner)

All inputs are paths on the command line; the scripts build nothing themselves.

```sh
sh scripts/release/make-oc-zip.sh --version 0.1.0-preview --kexts build --out dist     # Vermilion-<ver>-OpenCore.zip
sh scripts/release/make-pkg.sh --version 0.1.0-preview --build build --air-runtime build/air-runtime --out dist
sh scripts/release/make-sums.sh dist <the files>                                      # SHA256SUMS
bash scripts/dev/release-scan.sh dist/Vermilion-<ver>.pkg dist/Vermilion-<ver>-OpenCore.zip ...
bash tests/release/run.sh                                                             # the hardware-free release tests
```

`make-oc-zip.sh` refuses a kext whose `CFBundleShortVersionString` isn't the release version (the numeric part is
enough for a pre-release) and a snippet with a machine-identity key (`check-snippet.py`). `config-snippet.plist` holds
the entries of INSTALL.md section 1, "What the OpenCore snippet changes" (Lilu's entry, the three kexts, the AGDP
patch, `csr-active-config`, `boot-args` and their Delete entries, `SecureBootModel`, `ResizeAppleGpuBars`) and no
SMBIOS; `tests/release/oc_zip_test.sh` checks both.

`.github/workflows/release.yml` does it on a `v*` tag: a call of `air-reader.yml`, then one job on `macos-15-intel`
that builds every component from pinned inputs, runs the hardware-free tests, builds VermilionTrust last, makes the
files, runs the release scan on them and the commit scan since the previous tag, and a last job that creates a **draft
pre-release** (the owner publishes). By hand (`workflow_dispatch`) it builds and keeps the files without publishing.
Actions are pinned by commit SHA. **Open:** the job stops at the release scan until F1 (VermilionBoot carries a slice of
AMD's firmware, `kext.sh` generates it from the downloaded file: rule 4 says no); the signature of `SHA256SUMS`; the
previous release's cdhashes in VermilionTrust; the kext link gate (it needs Apple's kernel collections); the kext and
plugin host tests (only `gpu_id_test.cpp` runs); the Xcode 26 SDK on the runner image (checked by the first step).

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
      `bash tests/release/run.sh` (release scan, zip and snippet, package scripts, package build), the kext and
      plugin tests.
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
