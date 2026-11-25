# SPDX-License-Identifier: MIT
# mkidx.py <export-dir> : writes names.tsv  name<TAB>address<TAB>relative-path  from decompile-index.json
import json,sys,os
d=sys.argv[1]
j=json.load(open(os.path.join(d,'decompile-index.json')))
with open(os.path.join(d,'names.tsv'),'w') as o:
    for f in j['functions']:
        if f.get('status')=='written':
            o.write(f"{f['name']}\t{f['address']}\t{f['relative_path']}\n")
