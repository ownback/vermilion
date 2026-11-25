# SPDX-License-Identifier: MIT
# Work dir: $REA_WORK (holds kc/ dsc/ syms/ decomp/), default the parent of this folder.
# ann.py <export-dir> <name-regex> <this-class> [full] : condensed listing, vcalls on `this` named, IOService-range
# calls hinted. FAM=<class family> also names vcalls on member objects. Needs names.tsv (mkidx.py) and syms/*.vt.tsv
# (vtables.py).
import sys,os,re,glob
S=os.environ.get('REA_WORK') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
d,pat,cls=sys.argv[1],sys.argv[2],sys.argv[3]; full=len(sys.argv)>4
vt={}
for p in glob.glob(S+'/syms/*.vt.tsv'):
    for l in open(p):
        c,o,m=l.rstrip('\n').split('\t',2); vt.setdefault(c,{})[int(o,16)]=m
tv=vt.get(cls,{})
hint=vt.get('AMDRadeonX6000_AMDNavi21GraphicsAccelerator',{})
def short(m): return re.sub(r'\(.*$','',m)
fam=os.environ.get('FAM','')
fields={}
if fam:
    for l in open(os.path.join(d,'names.tsv')):
        n,a,r=l.rstrip('\n').split('\t')
        if fam not in n: continue
        t=open(os.path.join(d,r)).read()
        for m in re.finditer(r'(\w+) = (?:\([^)]*\))?\s*([A-Za-z0-9_]+)::(?:create|new)\w*\s*\((?:.|\n){0,200}?\*\((?:long|undefined8) \*\)\(this \+ (0x[0-9a-f]+)\) = \1;',t):
            fields.setdefault(int(m.group(3),16),m.group(2))
frx=re.compile(r'\(\*\*\(code \*\*\)\(\*\*\(long \*\*\)\(this \+ (0x[0-9a-f]+)\) \+ (0x[0-9a-f]+|[0-9]+)\)\)')
def fsub(m):
    fo=int(m.group(1),16); vo=int(m.group(2),0); c=fields.get(fo)
    if not c: return m.group(0)
    meth=vt.get(c,{}).get(vo)
    if not meth:
        for k,v in vt.items():
            if k.startswith(c) and vo in v: meth=v[vo]; break
    return f'[{c}@{hex(fo)}]->'+(short(meth) if meth else f'vcall[{hex(vo)}]')
rx=re.compile(r'\(\*\*\(code \*\*\)\(\*\(long \*\)(this|\(this \+ 0x[0-9a-f]+\)|[A-Za-z_0-9]+) \+ (0x[0-9a-f]+)\)\)')
keep=re.compile(r'[A-Za-z0-9_]+::[A-Za-z0-9_~]+ *\(|"[^"]{2,}"|^\s*(if|else|while|for|do|return|switch|case|goto)\b|^LAB_|vcall|->')
for l in open(os.path.join(d,'names.tsv')):
    name,addr,rel=l.rstrip('\n').split('\t')
    if not re.fullmatch(pat,name): continue
    print(f'/////// {name} @ {addr}')
    for line in open(os.path.join(d,rel)):
        if line.startswith('// ') or not line.strip(): continue
        def sub(m):
            obj,off=m.group(1),int(m.group(2),16)
            if obj=='this' and off in tv: return f'this->{short(tv[off])}'
            h=hint.get(off)
            if h and ('IORegistryEntry' in h or 'IOService' in h): return f'{obj}->{short(h)}?'
            return f'{obj}->vcall[{hex(off)}]'
        line=frx.sub(fsub,rx.sub(sub,line.rstrip()))
        line=re.sub(r'func_0x000100(ba|be)\(\)','__stack_chk_fail()',line)
        if full or keep.search(line):
            if line.strip().startswith('/*'): continue
            print(line[:200])
