#!/bin/sh
# SPDX-License-Identifier: MIT
# strip-hooks.sh <in> <out>: write <in> to <out> without the test hooks of tests/release (VERMILION_TEST, VERMILION_ROOT,
# VERMILION_NOCHOWN, VERMILION_USER, VERMILION_UHOME, VERMILION_FETCH). make-pkg.sh runs every script it ships through
# this, so an installed script, which runs as root, cannot be steered by the caller's environment. The tests keep
# using the source scripts. Exits 1 when a hook is left (a new hook needs a rule here).
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
