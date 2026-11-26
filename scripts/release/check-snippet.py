# SPDX-License-Identifier: MIT
# check-snippet.py <config-snippet.plist>: exit 1 and name the path when the OpenCore snippet holds a key that
# identifies a machine (SMBIOS, serial, MLB, ROM, UUID). Run as `python3 -I`. docs/RELEASE.md: the snippet carries
# exactly the entries of INSTALL.md section 1 and no machine identity. Used by make-oc-zip.sh and tests/release.
import plistlib
import sys

FORBIDDEN = {
    "PlatformInfo", "Generic", "Smbios", "DataHub", "PlatformNVRAM", "SystemSerialNumber", "MLB", "ROM",
    "SystemUUID", "CustomUUID", "SystemProductName", "SystemMemoryStatus", "UpdateSMBIOSMode", "BoardProduct",
    "ProcessorType", "PlatformFeature",
}


def walk(obj, path=""):
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key in FORBIDDEN:
                yield f"{path}/{key}"
            yield from walk(value, f"{path}/{key}")
    elif isinstance(obj, list):
        for value in obj:
            yield from walk(value, path)


def main():
    with open(sys.argv[1], "rb") as f:
        found = list(walk(plistlib.load(f)))
    for p in found:
        print(f"check-snippet: machine identity key {p}", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
