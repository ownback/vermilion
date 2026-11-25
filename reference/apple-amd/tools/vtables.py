# SPDX-License-Identifier: MIT
# Work dir: $REA_WORK (holds kc/ dsc/ syms/ decomp/), default the parent of this folder.
# vtables.py <kext-binary> : writes <out>.vt.tsv  class<TAB>offset<TAB>method  for every "vtable for X" symbol
import struct,sys,subprocess,glob,os,re
S=os.environ.get('REA_WORK') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
syms={}
for p in glob.glob(S+'/syms/*.txt'):
    kern=p.endswith('kernel.txt')
    for l in open(p,errors='replace'):
        parts=l.rstrip('\n').split(' ',2)
        if len(parts)<3: continue
        try: a=int(parts[0],16)
        except: continue
        syms.setdefault(a,parts[2])
binp=sys.argv[1]; data=open(binp,'rb').read()
# segments
out=subprocess.run(['otool','-l',binp],capture_output=True,text=True).stdout
segs=[];cur={}
for l in out.splitlines():
    l=l.strip()
    if l.startswith('cmd '): cur={'cmd':l.split()[1]}; 
    for k in ('vmaddr','vmsize','fileoff','filesize'):
        if l.startswith(k+' '): cur[k]=int(l.split()[1],0)
    if cur.get('cmd')=='LC_SEGMENT_64' and 'filesize' in cur and cur not in segs: segs.append(cur)
def v2o(va):
    for s in segs:
        if s['vmaddr']<=va<s['vmaddr']+s['filesize']: return s['fileoff']+va-s['vmaddr']
    return None
def resolve(v):
    if v==0: return None
    tgt=v & 0x3fffffff; lvl=(v>>30)&3
    a = tgt+0xffffff8000100000 if lvl==0 else tgt
    return syms.get(a, f'?{hex(a)}')
base=os.path.basename(binp)
ownsyms=subprocess.run(['sh','-c',f"nm --defined-only '{binp}' | c++filt"],capture_output=True,text=True).stdout
with open(f'{S}/syms/{base}.vt.tsv','w') as o:
    for l in ownsyms.splitlines():
        m=re.match(r'([0-9a-f]+) \w vtable for (.*)$',l)
        if not m: continue
        va=int(m.group(1),16); cls=m.group(2); off=v2o(va)
        if off is None: continue
        i=2
        while True:
            v=struct.unpack_from('<Q',data,off+i*8)[0]
            r=resolve(v)
            if r is None or i>600: break
            o.write(f'{cls}\t{hex((i-2)*8)}\t{r}\n'); i+=1
print('ok',base)
