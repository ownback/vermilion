#!/bin/bash
# SPDX-License-Identifier: MIT
# show.sh <export-dir> <exact-name-regex> [maxlines] : the decompiled text of the matching functions (default 200 lines)
d="$1"; pat="$2"; n="${3:-200}"
grep -E "^${pat}	" "$d/names.tsv" | while IFS=$'\t' read name addr rel; do echo "/////// $name @ $addr"; grep -v -E '^// |^\s*$' "$d/$rel" | head -n "$n"; done
