# SPDX-License-Identifier: MIT
# Work dir: $REA_WORK (holds kc/ dsc/ syms/ decomp/), default the parent of this folder.
# srch.py <regex> [export-dir-name ...] : which functions contain regex
import sys,os,re
S=os.environ.get('REA_WORK') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
rx=re.compile(sys.argv[1]); dirs=sys.argv[2:] or sorted(os.listdir(S+'/decomp'))
for d in dirs:
    p=f'{S}/decomp/{d}'
    if not os.path.exists(p+'/names.tsv'): continue
    for l in open(p+'/names.tsv'):
        n,a,r=l.rstrip('\n').split('\t')
        t=open(f'{p}/{r}',errors='replace').read()
        if rx.search(t): print(d,n,a)
