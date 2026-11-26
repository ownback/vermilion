#!/bin/sh
# SPDX-License-Identifier: MIT
# strip-hooks.sh <in> <out>: write <in> to <out> without the test hooks of tests/release (VERMILION_TEST,
# VERMILION_ROOT, VERMILION_NOCHOWN, VERMILION_USER, VERMILION_UHOME, VERMILION_FETCH). make-pkg.sh runs every script
# it ships through this, so an installed script, which runs as root, cannot be steered by the caller's environment.
# The tests keep using the source scripts. Exits 1 when a hook is left (a new hook needs a rule here).
# The rules, in the order of the sed expressions below:
#   - the comment blocks between `#@test-hooks-begin` and `#@test-hooks-end` go;
#   - user_home's VERMILION_UHOME line goes (the whole line);
#   - `|| [ VERMILION_NOCHOWN = 1 ]` and `|| [ -n VERMILION_ROOT ]` go from the root and target-volume checks;
#   - `[ VERMILION_NOCHOWN = 1 ] ||` and `[ VERMILION_TEST = 1 ] ||` go, so chown and the fixed PATH always apply;
#   - `${VERMILION_ROOT:-}` becomes nothing (every system path is the real one);
#   - console_user's `u=${VERMILION_USER:-}` becomes `u=`;
#   - `${VERMILION_UHOME:-$(...)}` and `${VERMILION_FETCH:-"..."}` become their defaults.
set -eu
IN=${1:?usage: strip-hooks.sh <in> <out>}; OUT=${2:?usage: strip-hooks.sh <in> <out>}
sed -e '/^#@test-hooks-begin/,/^#@test-hooks-end/d' \
    -e '/\${VERMILION_UHOME:-}" \] || { echo/d' \
    -e 's/ || \[ "\${VERMILION_NOCHOWN:-0}" = 1 \]//' \
    -e 's/ || \[ -n "\${VERMILION_ROOT:-}" \]//' \
    -e 's/\[ "\${VERMILION_NOCHOWN:-0}" = 1 \] || //' -e 's/\[ "\${VERMILION_TEST:-0}" = 1 \] || //' \
    -e 's/\${VERMILION_ROOT:-}//g' \
    -e 's/^\( *\)u=\${VERMILION_USER:-}$/\1u=/' \
    -e 's/\${VERMILION_UHOME:-\(\$(.*)\)}$/\1/' \
    -e 's/\${VERMILION_FETCH:-\("[^"]*"\)}/\1/' \
    "$IN" >"$OUT"
if grep -n 'VERMILION_\(TEST\|ROOT\|NOCHOWN\|USER\|UHOME\|FETCH\)' "$OUT" >&2; then
  echo "strip-hooks: a test hook is left in $IN (above): add a rule to scripts/release/strip-hooks.sh" >&2
  rm -f "$OUT"; exit 1
fi
