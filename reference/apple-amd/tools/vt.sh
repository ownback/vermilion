#!/bin/bash
# SPDX-License-Identifier: MIT
# vt.sh <class-regex> <off> [off...] : the method at each vtable offset (hex, as in syms/*.vt.tsv)
# Work dir: $REA_WORK, default the parent of this folder.
S=${REA_WORK:-$(dirname $(dirname $0))}; c="$1"; shift
for o in "$@"; do awk -F'\t' -v c="^${c}\$" -v o="$o" '$1 ~ c && $2==o {print o" "$1" "$3}' $S/syms/*.vt.tsv; done
