#!/bin/sh
# SPDX-License-Identifier: MIT
# compile-commands.sh: writes compile_commands.json at the repo root (git-ignored) for clangd and Serena, by running
# the kext build scripts with a clang/clang++ shim on PATH that records every compile and then runs the real
# compiler. Needs what the builds need (MKSDK, LILU; docs/BUILD.md). The build output itself is discarded.
#
#   MKSDK=... LILU=... sh scripts/dev/compile-commands.sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
for cc in clang clang++; do
  real=$(command -v "$cc")
  cat > "$T/bin/$cc" <<EOF
#!/bin/sh
python3 -I -c 'import json, os, sys; print(json.dumps({"directory": os.getcwd(), "arguments": ["$real"] + sys.argv[1:]}))' "\$@" >> "$T/log.jsonl"
exec "$real" "\$@"
EOF
  chmod +x "$T/bin/$cc"
done
: "${MKSDK:?set MKSDK to a MacKernelSDK checkout (docs/BUILD.md)}"
# VermilionBoot includes a header of hashes generated from linux-firmware (git-ignored; tools/firmware/c3_image.py), made
# again on every run as kext.sh does, so the index never reads hashes of an older firmware file
FWD=${PHX_FW:-$HOME/gpu/fw/navi31}
[ ! -f "$FWD/dcn_3_2_0_dmcub.bin" ] ||
  (cd "$ROOT" && python3 tools/firmware/c3_image.py --fw "$FWD/dcn_3_2_0_dmcub.bin" --out src/vermilion-boot/phx_c3_hash.inc >/dev/null)
export PATH="$T/bin:$PATH"
# VermilionTrust includes its generated cdhash list (gen_list.sh, git-ignored): index it with a stub when it's missing
STUB="$ROOT/src/vermilion-trust/phxtrust_list.inc"
if [ ! -f "$STUB" ]; then
  printf '%s\n' '// compile-commands.sh stub, removed after indexing' 'static const uint8_t kPhxTrustList[][20] = {{0}};' \
    'static const char *const kPhxTrustNames[] = {"stub"};' 'static constexpr size_t kPhxTrustCount = 0;' > "$STUB"
  trap 'rm -rf "$T" "$STUB"' EXIT
fi
for d in vermilion-boot vermilion-accel vermilion-trust; do
  s="$ROOT/src/$d/build.sh"
  [ -f "$s" ] || continue
  if ! (cd "$ROOT/src/$d" && sh ./build.sh "$MKSDK" ${LILU:+"$LILU"}) > "$T/$d.log" 2>&1; then
    echo "compile-commands: $d did not build; its files are missing from the database:" >&2
    tail -3 "$T/$d.log" >&2
  fi
  rm -rf "$ROOT/src/$d/build"
done
python3 -I - "$T/log.jsonl" "$ROOT/compile_commands.json" <<'EOF'
import json, os, sys
out, seen = [], set()
for line in open(sys.argv[1]) if os.path.exists(sys.argv[1]) else []:
    e = json.loads(line)
    args = e["arguments"]
    if "-c" not in args:
        continue                       # link steps
    src = next((a for a in args if a.endswith((".c", ".cc", ".cpp", ".mm", ".m"))), None)
    if not src:
        continue
    path = os.path.normpath(os.path.join(e["directory"], src))
    if path in seen:
        continue
    seen.add(path)
    out.append({"directory": e["directory"], "file": path, "arguments": args})
json.dump(out, open(sys.argv[2], "w"), indent=1)
print(f"compile_commands.json: {len(out)} files")
EOF
