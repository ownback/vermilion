#!/bin/bash
# SPDX-License-Identifier: MIT
# flow.sh <export> <regex> <class> : call flow only, deduped
python3 -I $(dirname $0)/ann.py "$@" | grep -v -E 'getName\(this,0\)|stringFromReturn|^\s*(if|else|LAB_|goto|return|do|while)\b.{0,60}$|^\s*\}|^\s*pcVar[0-9]+ = "\[%s\]|\(\*\*\(code \*\*\)\(lVar[0-9]+ \+ 0x118\)\)|func_0x00010114\("%s::|printChildrenNodes' | sed -E 's/^\s+/  /' | awk '!seen[$0]++'
