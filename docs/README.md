# Vermilion documentation

Vermilion is a macOS Tahoe driver for the AMD RX 7900 XTX (Navi 31). Upstream also drove the RX 7900 XT; this fork refuses it. These pages
are written for two audiences at once: **people** installing or hacking on it, and **language models** that need
context before they change code. Coding agents also have [`../CLAUDE.md`](../CLAUDE.md) and the working notes in
[`../.agents/`](../.agents/).

## Reading order

| If you want to... | Read |
|---|---|
| know what this is and whether it can work for you | [`../README.md`](../README.md), then [`../SUPPORT.md`](../SUPPORT.md) and [REFERENCE-MACHINES.md](REFERENCE-MACHINES.md) |
| install, update, uninstall or recover it (users) | [`../INSTALL.md`](../INSTALL.md) |
| know how releases are built and what they contain | [RELEASE.md](RELEASE.md), [`../CHANGELOG.md`](../CHANGELOG.md) |
| understand how it works | [ARCHITECTURE.md](ARCHITECTURE.md), with [GLOSSARY.md](GLOSSARY.md) open |
| run it on an RX 7900 XTX | [XTX.md](XTX.md) |
| build it | [BUILD.md](BUILD.md) |
| install every part by hand (the expert reference) | [INSTALL.md](INSTALL.md) (upstream's guide, written for the XT reference machine this fork no longer supports) |
| get the AMD firmware it loads | [FIRMWARE.md](FIRMWARE.md) |
| know why names start with `phx` / `nv` / `nmx` | [NAMING.md](NAMING.md) |
| know where the fallback EDIDs come from | [EDID.md](EDID.md) |
| see the machine's state, the known-good configuration and the cross-thread map | [PROJECT_KNOWLEDGE.md](PROJECT_KNOWLEDGE.md) |
| see what is planned | [`../ROADMAP.md`](../ROADMAP.md) (phases), [`../.agents/TODO.md`](../.agents/TODO.md) (open tasks) |

## Conventions in these docs

- **Measured or unverified.** A statement about hardware behaviour was seen on a named machine
  ([REFERENCE-MACHINES.md](REFERENCE-MACHINES.md)). Anything not tested is marked *(unverified)*.
- **Paths** are relative to the repository root. `~/gpu` is the desktop user's tools directory on the macOS
  machine.
- **Names:** the installable parts are called Vermilion (`VermilionBoot.kext`, `VermilionAccel.kext`). Classes,
  sysctls, NVRAM variables and on-disk paths keep their old `Phx`/`NV`/`NMX` names ([NAMING.md](NAMING.md)).
- **Dates** are absolute (YYYY-MM-DD).
- **No personal data:** no serials, MLB/ROM, UUIDs, MAC addresses or monitor serials in docs or examples.
