# SPDX-License-Identifier: MIT
# Work dir: $REA_WORK (holds kc/ dsc/ syms/ decomp/), default the parent of this folder.
import json,sys,os
d=sys.argv[1]
j=json.load(open(os.path.join(d,'decompile-index.json')))
with open(os.path.join(d,'names.tsv'),'w') as o:
    for f in j['functions']:
        if f.get('status')=='written':
            o.write(f"{f['name']}\t{f['address']}\t{f['relative_path']}\n")
