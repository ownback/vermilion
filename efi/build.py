#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build the OpenCore EFI for a machine profile (efi/machines/*.json), reproducibly.

Every input is pinned in efi/components.json (URL + SHA-256) and cached in ~/.cache/vermilion/efi. The config.plist
is generated from OpenCore's own Sample.plist plus the machine profile, so the settings live in reviewable JSON
instead of a hand-edited plist. SMBIOS serials are generated once per machine with OpenCore's macserial and kept in
~/.config/vermilion/smbios-<machine>.json (mode 0600), never in git.

Usage (Linux or macOS; needs python3, iasl for the ACPI tables):
  efi/build.py build   [--machine b650e-i-xtx] --stage <stage> [--placeholder-smbios]
                       (--stage is required: a default would silently pick the wrong EFI; `stages` lists them)
  efi/build.py smbios  [--machine b650e-i-xtx]           generate the SMBIOS file if it does not exist
  efi/build.py install --esp /boot --stage <stage>       copy EFI/OC onto an EFI partition (root; keeps EFI/OC.prev)
  efi/build.py acpi-dump [--machine ...]                 save this machine's DSDT for the DSDT fix (Linux, root)
  efi/build.py stages  [--machine ...]                   print what each stage contains

Output: build/efi/<machine>-<stage>/EFI/{BOOT,OC}. See efi/README.md.
"""
import argparse
import hashlib
import json
import os
import plistlib
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import uuid
import zipfile
from pathlib import Path

try:
    import pwd
except ImportError:                                     # not on Windows; build.py targets Linux and macOS
    pwd = None

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
CACHE = Path(os.environ.get("VERMILION_EFI_CACHE", Path.home() / ".cache" / "vermilion" / "efi"))


def user_home():
    """The invoking user's home, also when run through sudo (so secrets and dumps stay in their config dir)."""
    if os.environ.get("SUDO_USER") and pwd and os.geteuid() == 0:
        return Path(pwd.getpwnam(os.environ["SUDO_USER"]).pw_dir)
    return Path.home()


SECRETS = Path(os.environ.get("VERMILION_CONFIG", user_home() / ".config" / "vermilion"))
OUT = Path(os.environ.get("VERMILION_OUT", REPO / "build")) / "efi"
APPLE_NVRAM = "7C436110-AB2A-4BBB-A880-FE41995C9F82"


def die(msg):
    sys.exit(f"build.py: {msg}")


def load_json(path):
    with open(path) as f:
        return json.load(f)


# ---------------------------------------------------------------------------------------------------------- inputs

def fetch(components, name):
    """Return the cached path of a pinned download, downloading and verifying it if needed."""
    d = components["downloads"][name]
    want = d["sha256"].lower()
    dest = CACHE / want[:16] / Path(d["url"]).name
    if dest.is_file() and sha256(dest) == want:
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"  fetch {name} {d['version']}")
    tmp = dest.with_suffix(dest.suffix + ".part")
    req = urllib.request.Request(d["url"], headers={"User-Agent": "vermilion-efi-build"})
    with urllib.request.urlopen(req, timeout=120) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f)
    got = sha256(tmp)
    if got != want:
        tmp.unlink()
        die(f"{name}: SHA-256 mismatch (got {got}, components.json pins {want})")
    tmp.rename(dest)
    return dest


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def extract(zip_path, member_prefix, dest):
    """Extract one directory (or file) of a zip to dest/<its last path component>, refusing absolute paths and
    '..' (zip-slip). "X64/EFI" lands in dest/EFI, "Docs/Sample.plist" in dest/Sample.plist."""
    with zipfile.ZipFile(zip_path) as z:
        names = [n for n in z.namelist() if n == member_prefix or n.startswith(member_prefix.rstrip("/") + "/")]
        if not names:
            die(f"{zip_path.name}: no {member_prefix}")
        base = member_prefix.rstrip("/").rsplit("/", 1)[0] + "/" if "/" in member_prefix.rstrip("/") else ""
        for n in names:
            rel = n[len(base):]
            if rel.startswith("/") or ".." in Path(rel).parts:
                die(f"{zip_path.name}: unsafe path {n}")
            target = dest / rel
            if n.endswith("/"):
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with z.open(n) as src, open(target, "wb") as out:
                shutil.copyfileobj(src, out)
            mode = (z.getinfo(n).external_attr >> 16) & 0o777
            if mode:
                target.chmod(mode)


# ---------------------------------------------------------------------------------------------------------- stages

def resolve_stage(machine, stage):
    stages = machine["stages"]
    if stage not in stages:
        die(f"unknown stage {stage!r} (have: {', '.join(stages)})")
    chain = []
    s = stage
    while s:
        if s in chain:
            die(f"stage inheritance loop at {s}")
        chain.append(s)
        s = stages[s].get("inherits")
    kexts, boot_args, csr, nvram, booter, accept, drivers_remove = [], [], None, {}, {}, [], []
    for s in reversed(chain):
        st = stages[s]
        drivers_remove += [d for d in st.get("uefi_drivers_remove", []) if d not in drivers_remove]
        accept += [a for a in st.get("ocvalidate_accept", []) if a not in accept]
        nvram.update({k: v for k, v in st.get("nvram_add", {}).items() if not k.startswith("_")})
        booter.update({k: v for k, v in st.get("booter_quirks", {}).items() if not k.startswith("_")})
        if "kexts" in st:
            kexts = list(st["kexts"])
        kexts += [k for k in st.get("kexts_add", []) if k not in kexts]
        if "boot_args" in st:
            boot_args = list(st["boot_args"])
        boot_args += [a for a in st.get("boot_args_add", []) if a not in boot_args]
        boot_args = [a for a in boot_args if a not in st.get("boot_args_remove", [])]
        csr = st.get("csr_active_config", csr)
    drivers = [e for e in machine["uefi_drivers"] if e.partition(" ")[0] not in drivers_remove]
    for d in drivers_remove:
        if not any(e.partition(" ")[0] == d for e in machine["uefi_drivers"]):
            die(f"stage {stage}: uefi_drivers_remove names {d}, which the machine's uefi_drivers don't have")
    return {"kexts": kexts, "boot_args": boot_args, "csr_active_config": csr or "00000000", "nvram_add": nvram,
            "booter_quirks": booter, "ocvalidate_accept": accept, "uefi_drivers": drivers}


# ---------------------------------------------------------------------------------------------------------- SMBIOS

def smbios_path(machine_id):
    return SECRETS / f"smbios-{machine_id}.json"


def read_smbios(machine_id, placeholder):
    if placeholder:
        return None
    p = smbios_path(machine_id)
    if not p.is_file():
        die(f"no SMBIOS for {machine_id}: run `efi/build.py smbios --machine {machine_id}` first "
            f"(or --placeholder-smbios for a test build that must not be booted)")
    if p.stat().st_mode & 0o077:
        die(f"{p} is readable by others; chmod 600 it")
    return load_json(p)


def generate_smbios(machine_id, machine, oc_dir):
    p = smbios_path(machine_id)
    if p.exists():
        print(f"{p} exists; not overwriting (delete it to make a new identity)")
        return
    macserial = oc_dir / "macserial" / ("macserial.linux" if sys.platform.startswith("linux") else "macserial")
    macserial.chmod(0o755)
    out = subprocess.run([str(macserial), "-m", machine["smbios_model"], "-g", "-n", "1"],
                         capture_output=True, text=True, check=True).stdout
    m = re.search(r"^\s*(\S+)\s*\|\s*(\S+)\s*$", out, re.M)
    if not m:
        die(f"unexpected macserial output: {out!r}")
    rom = None
    iface = machine.get("rom_from_interface")
    if iface and Path(f"/sys/class/net/{iface}/address").is_file():
        rom = Path(f"/sys/class/net/{iface}/address").read_text().strip().replace(":", "").upper()
    if not rom or len(rom) != 12:
        rom = secrets.token_hex(6).upper()
    data = {"SystemProductName": machine["smbios_model"], "SystemSerialNumber": m.group(1), "MLB": m.group(2),
            "SystemUUID": str(uuid.uuid4()).upper(), "ROM": rom}
    SECRETS.mkdir(parents=True, exist_ok=True)
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    print(f"wrote {p} (model {data['SystemProductName']}; keep it private, never commit it)")


# ---------------------------------------------------------------------------------------------------------- config

def amd_patches(patches_plist, cores):
    """AMD_Vanilla's kernel patches with the core count filled in (the four 'cpuid_cores_per_package' entries)."""
    with open(patches_plist, "rb") as f:
        patches = plistlib.load(f)["Kernel"]["Patch"]
    if not 1 <= cores <= 255:
        die(f"bad core count {cores}")
    n = 0
    for p in patches:
        if "cpuid_cores_per_package" in p["Comment"]:
            rep = bytearray(p["Replace"])
            rep[1] = cores                       # B8/BA <cores> 00 00 ...: the immediate's low byte
            p["Replace"] = bytes(rep)
            n += 1
    if n != 4:
        die(f"expected 4 core-count patches in AMD_Vanilla, found {n}")
    return patches


def make_config(sample, machine, stage, components, patches, acpi_files, smbios):
    c = sample
    c["ACPI"]["Add"] = [{"Comment": f.replace(".aml", ""), "Enabled": True, "Path": f} for f in acpi_files]
    c["ACPI"]["Delete"] = []
    template = dict(c["ACPI"]["Patch"][0]) if c["ACPI"]["Patch"] else {}
    c["ACPI"]["Patch"] = []
    for p in machine.get("acpi_patches", []):
        find = bytes.fromhex(p["find"])
        entry = dict(template)
        entry.update({"Base": "", "BaseSkip": 0, "Comment": p["comment"], "Count": p.get("count", 1), "Enabled": True,
                      "Find": find, "Limit": 0, "Mask": b"", "OemTableId": b"\x00" * 8,
                      "Replace": bytes.fromhex(p["replace"]) if "replace" in p else b"\xa3" * len(find),
                      "ReplaceMask": b"", "Skip": 0, "TableLength": 0, "TableSignature": p["table"].encode()})
        c["ACPI"]["Patch"].append(entry)
    c["ACPI"]["Quirks"].update({k: v for k, v in machine.get("acpi_quirks", {}).items() if not k.startswith("_")})

    c["Booter"]["MmioWhitelist"], c["Booter"]["Patch"] = [], []
    c["Booter"]["Quirks"].update({k: v for k, v in machine["booter_quirks"].items() if not k.startswith("_")})
    c["Booter"]["Quirks"].update(stage["booter_quirks"])     # a stage's own booter quirks win over the machine's

    c["DeviceProperties"]["Add"], c["DeviceProperties"]["Delete"] = {}, {}

    k = c["Kernel"]
    k["Add"] = []
    for name in stage["kexts"]:
        kx = components["kexts"][name]
        bundle = Path(kx["path"]).name
        k["Add"].append({"Arch": "x86_64", "BundlePath": bundle, "Comment": kx["comment"], "Enabled": True,
                         "ExecutablePath": kx["exec"], "MaxKernel": kx.get("max_kernel", ""), "MinKernel": kx["min_kernel"],
                         "PlistPath": "Contents/Info.plist"})
    k["Block"], k["Force"] = [], []
    k["Patch"] = patches + [{"Arch": "x86_64", "Base": "", "Comment": kp["comment"], "Count": kp.get("count", 0),
                             "Enabled": True, "Find": bytes.fromhex(kp["find"]), "Identifier": kp["identifier"],
                             "Limit": 0, "Mask": b"", "MaxKernel": kp.get("max_kernel", ""),
                             "MinKernel": kp.get("min_kernel", ""), "Replace": bytes.fromhex(kp["replace"]),
                             "ReplaceMask": b"", "Skip": 0} for kp in machine.get("kernel_patches", [])]
    k["Emulate"].update(machine["kernel_emulate"])
    k["Quirks"].update(machine["kernel_quirks"])

    m = c["Misc"]
    for section, values in machine["misc"].items():
        m[section].update(values)
    m["BlessOverride"], m["Entries"] = [], []
    m["Tools"] = [dict(t, Enabled=True) for t in m["Tools"] if t["Path"] in machine["tools"]]

    nv = c["NVRAM"]
    apple = nv["Add"][APPLE_NVRAM]
    for key in ("#INFO (prev-lang:kbd)", "ForceDisplayRotationInEFI"):
        apple.pop(key, None)
    apple["boot-args"] = " ".join(stage["boot_args"])
    apple["csr-active-config"] = bytes.fromhex(stage["csr_active_config"])
    apple["prev-lang:kbd"] = b"en-US:0"
    for key, value in stage["nvram_add"].items():     # Apple GUID variables, hex data; set again at every boot
        apple[key] = bytes.fromhex(value)
    delete = nv["Delete"].setdefault(APPLE_NVRAM, [])
    for key in ("boot-args", "csr-active-config", "prev-lang:kbd", *stage["nvram_add"]):
        if key not in delete:
            delete.append(key)
    nv["Delete"][APPLE_NVRAM] = [d for d in delete if d != "ForceDisplayRotationInEFI"]
    nv["WriteFlash"] = True

    pi = c["PlatformInfo"]
    pi["Automatic"] = True
    pi["UpdateSMBIOSMode"] = "Create"
    pi["Generic"]["SystemProductName"] = machine["smbios_model"]
    if smbios:
        pi["Generic"].update({"SystemSerialNumber": smbios["SystemSerialNumber"], "MLB": smbios["MLB"],
                              "SystemUUID": smbios["SystemUUID"], "ROM": bytes.fromhex(smbios["ROM"])})

    u = c["UEFI"]
    u["ConnectDrivers"] = True
    u["Drivers"] = []
    for entry in stage["uefi_drivers"]:            # "Driver.efi" or "Driver.efi --its --arguments"
        path, _, arguments = entry.partition(" ")
        u["Drivers"].append({"Arguments": arguments.strip(), "Comment": "", "Enabled": True, "HideVerbose": False,
                             "LoadEarly": False, "Path": path})
    u["Quirks"].update(machine["uefi_quirks"])
    return c


# ---------------------------------------------------------------------------------------------------------- build

def build(args):
    components = load_json(HERE / "components.json")
    machine = load_json(HERE / "machines" / f"{args.machine}.json")
    stage = resolve_stage(machine, args.stage)
    smbios = read_smbios(args.machine, args.placeholder_smbios)

    print(f"== {machine['name']} / stage {args.stage}")
    with tempfile.TemporaryDirectory(prefix="vermilion-efi-") as tmp:
        tmp = Path(tmp)
        oc = tmp / "OpenCore"
        oc.mkdir()
        oc_zip = fetch(components, "OpenCore")
        for member in ("X64/EFI", "Docs/Sample.plist", "Utilities/ocvalidate", "Utilities/macserial"):
            extract(oc_zip, member, oc)

        out = OUT / f"{args.machine}-{args.stage}"
        if out.exists():
            shutil.rmtree(out)
        efi = out / "EFI"
        (efi / "BOOT").mkdir(parents=True)
        shutil.copy2(oc / "EFI" / "BOOT" / "BOOTx64.efi", efi / "BOOT" / "BOOTx64.efi")
        ocd = efi / "OC"
        for sub in ("ACPI", "Drivers", "Kexts", "Tools", "Resources"):
            (ocd / sub).mkdir(parents=True)
        shutil.copy2(oc / "EFI" / "OC" / "OpenCore.efi", ocd / "OpenCore.efi")

        for drv in (entry.partition(" ")[0] for entry in stage["uefi_drivers"]):
            src = fetch(components, "HfsPlus") if drv == "HfsPlus.efi" else oc / "EFI" / "OC" / "Drivers" / drv
            if not Path(src).is_file():
                die(f"driver {drv} not found")
            shutil.copy2(src, ocd / "Drivers" / drv)
        for tool in machine["tools"]:
            shutil.copy2(oc / "EFI" / "OC" / "Tools" / tool, ocd / "Tools" / tool)

        acpi_files = []
        if not shutil.which("iasl"):
            die("iasl not found (Arch: pacman -S acpica; macOS: brew install acpica)")
        if machine.get("dsdt_fix"):
            acpi_files.append(fixed_dsdt(args.machine, tmp, ocd / "ACPI"))
        check_acpi_patches(args.machine, machine)
        for dsl in machine["acpi"]:
            aml = Path(dsl).with_suffix(".aml").name
            subprocess.run(["iasl", "-p", str(tmp / Path(aml).stem), str(HERE / "acpi" / dsl)],
                           check=True, capture_output=True)
            shutil.copy2(tmp / aml, ocd / "ACPI" / aml)
            acpi_files.append(aml)

        for name in stage["kexts"]:
            kx = components["kexts"][name]
            if kx["from"] == "local":
                shutil.copytree(HERE / kx["path"], ocd / "Kexts" / Path(kx["path"]).name)
            elif kx["from"] == "vermilion":
                src = Path(os.environ.get("VERMILION_KEXT_DIR", REPO / "build")) / kx["path"]
                if not src.is_dir():
                    die(f"{name}: {src} not found (build it on macOS with scripts/build/kext.sh)")
                shutil.copytree(src, ocd / "Kexts" / src.name)
            else:
                extract(fetch(components, kx["from"]), kx["path"], ocd / "Kexts")

        with open(oc / "Sample.plist", "rb") as f:
            sample = plistlib.load(f)
        patches = amd_patches(fetch(components, "AMD_Vanilla"), machine["cpu_physical_cores"])
        config = make_config(sample, machine, stage, components, patches, acpi_files, smbios)
        with open(ocd / "config.plist", "wb") as f:
            plistlib.dump(config, f, sort_keys=True)

        validator = oc / "ocvalidate" / ("ocvalidate.linux" if sys.platform.startswith("linux") else "ocvalidate")
        validator.chmod(0o755)
        r = subprocess.run([str(validator), str(ocd / "config.plist")], capture_output=True, text=True)
        out = (r.stdout + r.stderr).strip().splitlines()
        print("  " + "\n  ".join(out[-3:]))
        if r.returncode != 0:
            # a stage may accept named ocvalidate messages it takes on purpose (ocvalidate_accept, with its reason in the
            # stage's _comment); any other error still fails the build
            accept = stage.get("ocvalidate_accept", [])
            # the messages themselves: ocvalidate's progress and summary lines left out
            not_a_message = ("Completed validating", "Serialisation", "Check", "NOTE")
            errs = [l.strip() for l in out
                    if l.strip() and not l.lstrip().startswith(not_a_message) and "returns" not in l and "OCS:" not in l]
            unknown = [l for l in errs if l not in accept]
            if not accept or unknown or not errs:
                print("  " + "\n  ".join(out))
                die("ocvalidate failed (output above)")
            print("  ocvalidate: accepted on purpose by this stage: " + "; ".join(errs))

        if args.placeholder_smbios:
            (out / "NOT-BOOTABLE-placeholder-smbios").write_text("built with placeholder SMBIOS serials\n")
        print(f"  kexts: {', '.join(stage['kexts'])}")
        print(f"  boot-args: {' '.join(stage['boot_args'])}   csr-active-config: {stage['csr_active_config']}")
        print(f"  -> {efi}")


def acpi_dir(machine_id):
    return SECRETS / "acpi" / machine_id


def dmi(field):
    try:
        return Path(f"/sys/class/dmi/id/{field}").read_text().strip()
    except OSError:
        return None


def booted_through_opencore():
    """OpenCore rewrites SMBIOS (and may replace ACPI tables) for every OS it starts, Linux included."""
    return dmi("bios_vendor") == "Acidanthera"


def bios_version():
    """The firmware's BIOS version, or None when unknown (not Linux, or OpenCore's SMBIOS hides it)."""
    return None if booted_through_opencore() else dmi("bios_version")


def acpi_dump(args):
    """Copy this machine's firmware DSDT (Linux, root) to ~/.config/vermilion/acpi/<machine>/, outside git."""
    src = Path("/sys/firmware/acpi/tables/DSDT")
    if os.geteuid() != 0:
        die("acpi-dump reads /sys/firmware/acpi/tables and needs root (sudo efi/build.py acpi-dump)")
    if not src.exists():
        die("no /sys/firmware/acpi/tables/DSDT (run it on the target machine under Linux)")
    version = bios_version()
    if booted_through_opencore():
        # The DSDT seen now may be OpenCore's replacement, and the BIOS version is OpenCore's SMBIOS.
        if not args.bios_version or not args.opencore_without_dsdt:
            die("this Linux was booted through OpenCore: its DSDT may be OpenCore's and the BIOS version is fake. "
                "Boot Linux directly (firmware boot menu) and dump again, or, if the running OpenCore replaces "
                "no DSDT, pass --opencore-without-dsdt --bios-version <the real version>")
        version = args.bios_version
    d = acpi_dir(args.machine)
    d.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, d / "DSDT.aml")
    (d / "bios-version").write_text((version or "unknown") + "\n")
    # The live ACPI namespace says which of the DSDT's conditional blocks are really active (fix_dsdt.py resolve).
    paths = sorted(p.read_text().strip() for p in Path("/sys/bus/acpi/devices").glob("*/path"))
    (d / "namespace.txt").write_text("\n".join(paths) + "\n")
    if os.environ.get("SUDO_USER") and pwd:
        u = pwd.getpwnam(os.environ["SUDO_USER"])
        for p in (SECRETS, SECRETS / "acpi", d, d / "DSDT.aml", d / "bios-version", d / "namespace.txt"):
            os.chown(p, u.pw_uid, u.pw_gid)
    print(f"  wrote {d / 'DSDT.aml'} (BIOS {version}); dump it again after every BIOS update")


def fixed_dsdt(machine_id, tmp, acpi_out):
    """The machine's own DSDT, made loadable by macOS with acpi/fix_dsdt.py, as ACPI/DSDT.aml."""
    d = acpi_dir(machine_id)
    if not (d / "DSDT.aml").is_file():
        die(f"no DSDT dump for {machine_id}: run `sudo efi/build.py acpi-dump --machine {machine_id}` on that machine")
    dumped = (d / "bios-version").read_text().strip() if (d / "bios-version").is_file() else "unknown"
    now = bios_version()
    if now and dumped != now and Path("/sys/firmware/acpi/tables/DSDT").exists():
        die(f"the DSDT dump is from BIOS {dumped}, this machine runs {now}: run acpi-dump again")
    sys.path.insert(0, str(HERE / "acpi"))
    import fix_dsdt
    shutil.copyfile(d / "DSDT.aml", tmp / "DSDT-firmware.aml")
    subprocess.run(["iasl", "-d", str(tmp / "DSDT-firmware.aml")], check=True, capture_output=True)
    text = (tmp / "DSDT-firmware.dsl").read_text()
    if (d / "namespace.txt").is_file():
        namespace = {fix_dsdt.norm(p) for p in (d / "namespace.txt").read_text().split()}
        text, plan = fix_dsdt.resolve(text, namespace)
        for action, cond, line, why in plan:
            print(f"  DSDT: line {line}: {action:6} {cond[:70]}  ({why})")
    else:
        print("  DSDT: no namespace.txt (old dump): only the Scope wrap is applied; run acpi-dump again")
    fixed, changes = fix_dsdt.fix(text)
    for path, cond, line in changes:
        print(f"  DSDT: Scope (\\{path}) at line {line} wrapped in {cond}")
    if not changes:
        print("  DSDT: no top-level Scope needed wrapping")
    (tmp / "DSDT.dsl").write_text(fixed)
    r = subprocess.run(["iasl", "-p", str(tmp / "DSDT"), str(tmp / "DSDT.dsl")], capture_output=True, text=True)
    if r.returncode != 0:
        die("the fixed DSDT does not compile:\n" + r.stdout[-2000:] + r.stderr[-2000:])
    shutil.copy2(tmp / "DSDT.aml", acpi_out / "DSDT.aml")
    return "DSDT.aml"


def check_acpi_patches(machine_id, machine):
    """Each DSDT Find must occur exactly once in the machine's dumped DSDT, or the patch would hit the wrong bytes."""
    patches = [p for p in machine.get("acpi_patches", []) if p["table"] == "DSDT"]
    if not patches:
        return
    dump = acpi_dir(machine_id) / "DSDT.aml"
    if not dump.is_file():
        die(f"{machine_id} has DSDT patches but no DSDT dump to check them against (sudo efi/build.py acpi-dump)")
    data = dump.read_bytes()
    for p in patches:
        n = data.count(bytes.fromhex(p["find"]))
        if n != 1:
            die(f"ACPI patch matches {n} times in the dumped DSDT (needs exactly 1): {p['comment']}")
    print(f"  ACPI: {len(patches)} DSDT patches, each matches exactly once in the dumped DSDT")
    check_patch_bios(machine_id, machine)


def check_patch_bios(machine_id, machine):
    """The DSDT patches are byte patterns for one BIOS version. Refuse a dump or a live firmware of another version.

    The dump records its BIOS version (acpi-dump). The profile's acpi_patches_bios names the version the patches were
    derived for. Under Linux booted directly the live version is known too; elsewhere (macOS, or Linux through
    OpenCore, whose SMBIOS hides it) only the dump can be checked, so say that a BIOS update needs a new dump.
    A build on another Linux machine than the target (a second PC, CI) sets VERMILION_EFI_OTHER_HOST=1: then the live
    firmware is not compared.
    """
    f = acpi_dir(machine_id) / "bios-version"
    dumped = f.read_text().strip() if f.is_file() else "unknown"
    wanted = machine.get("acpi_patches_bios")
    if wanted and dumped != wanted:
        hint = "run acpi-dump again (this dump records no version)" if dumped == "unknown" else \
               "re-derive the patches (efi/acpi/fix_dsdt.py resolve) or dump the right firmware"
        die(f"the DSDT patches are for BIOS {wanted}, the DSDT dump is from BIOS {dumped}: {hint}")
    now = None if os.environ.get("VERMILION_EFI_OTHER_HOST") == "1" else bios_version()
    if now and now != dumped:
        die(f"the DSDT dump is from BIOS {dumped}, this machine runs {now}: run acpi-dump again and re-derive the "
            f"DSDT patches (building for another machine from this Linux: VERMILION_EFI_OTHER_HOST=1)")
    if now:
        print(f"  ACPI: dump and firmware are both BIOS {dumped}")
    else:
        print(f"  ACPI: dump is from BIOS {dumped}; the live BIOS version can't be read here. After a BIOS update, "
              f"dump again under Linux before building")


def install(args):
    src = OUT / f"{args.machine}-{args.stage}" / "EFI" / "OC"
    if not (src / "config.plist").is_file():
        die(f"build {args.machine}-{args.stage} first")
    if (src.parent.parent / "NOT-BOOTABLE-placeholder-smbios").exists():
        die("this build has placeholder SMBIOS serials; rebuild without --placeholder-smbios")
    esp = Path(args.esp)
    if not (esp / "EFI").is_dir():
        die(f"{esp} has no EFI directory; is it the EFI partition?")
    if os.geteuid() != 0:
        die("install needs root (it writes to the EFI partition)")
    dst, prev = esp / "EFI" / "OC", esp / "EFI" / "OC.prev"
    if dst.exists():
        if prev.exists():
            shutil.rmtree(prev)
        dst.rename(prev)
        print(f"  kept the previous EFI/OC as {prev}")
    shutil.copytree(src, dst)
    if args.with_fallback:
        shutil.copy2(src.parent / "BOOT" / "BOOTx64.efi", esp / "EFI" / "BOOT" / "BOOTx64.efi")
        print("  wrote EFI/BOOT/BOOTx64.efi (removable-media fallback)")
    else:
        print("  EFI/BOOT left untouched")
    print(f"  installed {src} -> {dst}")


def show_stages(args):
    machine = load_json(HERE / "machines" / f"{args.machine}.json")
    for name in machine["stages"]:
        s = resolve_stage(machine, name)
        mark = "  (default)" if name == machine.get("default_stage", "install") else ""
        print(f"{name}:{mark}\n  kexts: {', '.join(s['kexts'])}\n  boot-args: {' '.join(s['boot_args'])}\n"
              f"  csr-active-config: {s['csr_active_config']}")
        if s["booter_quirks"]:
            print(f"  booter quirks: {', '.join(f'{k}={v}' for k, v in s['booter_quirks'].items())}")
        print(f"  uefi drivers: {', '.join(e.partition(' ')[0] for e in s['uefi_drivers'])}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("build", "smbios", "install", "stages", "acpi-dump"):
        p = sub.add_parser(name)
        p.add_argument("--machine", default="b650e-i-xtx")
        if name in ("build", "install"):
            p.add_argument("--stage", help="a stage of the machine profile (required; `efi/build.py stages` lists them)")
        if name == "build":
            p.add_argument("--placeholder-smbios", action="store_true",
                           help="use Sample.plist's dummy serials (for tests; never boot this)")
        if name == "acpi-dump":
            p.add_argument("--bios-version", help="the real BIOS version, when Linux was booted through OpenCore")
            p.add_argument("--opencore-without-dsdt", action="store_true",
                           help="the OpenCore that booted this Linux replaces no DSDT (so the DSDT seen is the firmware's)")
        if name == "install":
            p.add_argument("--esp", required=True, help="mount point of the EFI partition, e.g. /boot")
            p.add_argument("--with-fallback", action="store_true",
                           help="also write EFI/BOOT/BOOTx64.efi (USB sticks only; on the internal disk it is Limine's)")
    args = ap.parse_args()
    if getattr(args, "stage", "") is None:
        machine = load_json(HERE / "machines" / f"{args.machine}.json")
        default = machine.get("default_stage")
        names = ", ".join(f"{n} (everyday)" if n == default else n for n in machine["stages"])
        ap.error(f"{args.cmd} needs --stage <stage>; there is no default (the wrong stage is the wrong EFI). "
                 f"Stages of {args.machine}: {names}")
    if args.cmd == "build":
        build(args)
    elif args.cmd == "install":
        install(args)
    elif args.cmd == "stages":
        show_stages(args)
    elif args.cmd == "acpi-dump":
        acpi_dump(args)
    else:
        components = load_json(HERE / "components.json")
        machine = load_json(HERE / "machines" / f"{args.machine}.json")
        with tempfile.TemporaryDirectory(prefix="vermilion-efi-") as tmp:
            extract(fetch(components, "OpenCore"), "Utilities/macserial", Path(tmp))
            generate_smbios(args.machine, machine, Path(tmp))


if __name__ == "__main__":
    main()
