# SPDX-License-Identifier: MIT
# Work dir: $REA_WORK (holds kc/ dsc/ syms/ decomp/), default the parent of this folder.
# rd.py <bin> <vaddr-hex> <n-qwords|ints:N> : dump qwords with fixup decode + symbol, or N int32s
# Needs syms/<bin>.txt (README, "Reproduce" step 3).
import struct,sys,subprocess,os,bisect
S=os.environ.get('REA_WORK') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
b=sys.argv[1]; data=open(b,'rb').read(); va=int(sys.argv[2],16); mode=sys.argv[3]
out=subprocess.run(['otool','-l',b],capture_output=True,text=True).stdout
segs=[];cur={}
for l in out.splitlines():
    l=l.strip()
    if l.startswith('cmd '): cur={'cmd':l.split()[1]}
    for k in ('vmaddr','fileoff','filesize'):
        if l.startswith(k+' '): cur[k]=int(l.split()[1],0)
    if cur.get('cmd')=='LC_SEGMENT_64' and 'filesize' in cur and cur not in segs: segs.append(cur)
def v2o(v):
    for s in segs:
        if s['vmaddr']<=v<s['vmaddr']+s['filesize']: return s['fileoff']+v-s['vmaddr']
syms=[]
for l in open(f"{S}/syms/{os.path.basename(b)}.txt",errors='replace'):
    p=l.split(' ',2)
    try: syms.append((int(p[0],16),p[2].strip()))
    except: pass
syms.sort(); keys=[a for a,_ in syms]
def sym(a):
    i=bisect.bisect_right(keys,a)-1
    return f'{syms[i][1]}+{hex(a-syms[i][0])}' if i>=0 and a-syms[i][0]<0x100000 else ''
o=v2o(va)
if mode.startswith('ints:'):
    n=int(mode[5:]); print(struct.unpack_from(f'<{n}i',data,o)); sys.exit()
for i in range(int(mode)):
    v=struct.unpack_from('<Q',data,o+i*8)[0]
    t=v&0x3fffffff if (v>>40)&0xffffff else v
    print(hex(va+i*8), hex(v), (hex(t)+' '+sym(t)) if (v>>40)&0xffffff else '')
