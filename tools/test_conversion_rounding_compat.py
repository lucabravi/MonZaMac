#!/usr/bin/env python3
"""Asset-free: forms the directed-rounding change leaves alone must translate exactly as before.

Compares against the merge-base with develop (or LARECOMP_COMPAT_BASE) while the change is unmerged; the helper check always runs."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
harness=r'''
#include "shader.h"
#include <stdio.h>
#include <string.h>
int main(void){unsigned n=0;
for(unsigned family=0;family<2;family++)for(unsigned form=0;form<3;form++)
for(unsigned src=family?1:0;src<(family?3:4);src++)for(unsigned dst=1;dst<(family?3:4);dst++)
for(unsigned mode=0;mode<4;mode++)for(unsigned integer=0;integer<(family?2:1);integer++)
for(unsigned sign=0;sign<(family?1:2);sign++)for(unsigned mod=0;mod<4;mod++)for(unsigned glsl=0;glsl<2;glsl++){
 if((!family&&src==2&&dst==2&&mode)||(family&&src==2&&dst==1&&mode))continue;
 uint64_t top=family?0x5ca8:0x5cb8;if(form==1)top-=0x1000;if(form==2)top=family?0x38a8:0x38b8;
 uint64_t code[32]={0};code[0]=0x001f8000fc0007e0ull;
 code[1]=(top<<48)|((uint64_t)src<<10)|((uint64_t)dst<<8)|((uint64_t)mode<<39)|((uint64_t)sign<<13)|7ull<<16|9;
 if(form==0)code[1]|=2ull<<20;else if(form==1)code[1]|=2ull<<34;
 if(family)code[1]|=(uint64_t)integer<<42;
 code[1]|=(mod&1?1ull<<45:0)|(mod&2?1ull<<49:0);
 code[2]=0xe30000000007000full;code[3]=0xe2400fffff87000full;
 ShaderKey key={0};key.glsl=glsl;ShaderInfo*s=maxwell_translate((uint8_t*)code,sizeof code,STAGE_COMPUTE,&key);
 if(!s||!s->msl)return 2;printf("CASE %u\n%s\n",n++,s->msl);maxwell_free(s);
}fprintf(stderr,"programs=%u\n",n);}
'''
def base_source():
    """translate.c of the branch point with develop, or of LARECOMP_COMPAT_BASE (any git revision)."""
    base=os.environ.get('LARECOMP_COMPAT_BASE')
    if not base:
        for ref in ('origin/develop','monzamac/develop','develop'):
            found=subprocess.run(['git','merge-base','HEAD',ref],cwd=root,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
            if found.returncode==0:
                base=found.stdout.strip();break
    if not base:return None
    shown=subprocess.run(['git','show',base+':runtime/nvn/maxwell/translate.c'],cwd=root,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
    return shown.stdout if shown.returncode==0 else None
def build_and_run(tmp,name,source):
    binary=tmp/name
    subprocess.run(['clang','-O1','-I',str(root/'runtime/nvn/maxwell'),str(tmp/'test.c'),str(source),'-lm','-o',str(binary)],check=True)
    result=subprocess.run([str(binary)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True)
    print(name,result.stderr.decode().strip())
    return result.stdout
with tempfile.TemporaryDirectory(prefix='rounding-compat-')as tmp:
 tmp=Path(tmp);(tmp/'test.c').write_text(harness)
 after=build_and_run(tmp,'after',root/'runtime/nvn/maxwell/translate.c')
 # Always true, needs no baseline: none of these programs uses a directed form the translator handles.
 assert b'i2f_round' not in after and b'f2h_round' not in after,'a nearest or unsupported form got a directed-rounding helper'
 current=(root/'runtime/nvn/maxwell/translate.c').read_bytes()
 before_source=base_source()
 if before_source is None:print('SKIP baseline comparison: no base revision (set LARECOMP_COMPAT_BASE)')
 elif before_source==current:print('SKIP baseline comparison: translate.c equals the base (change already merged)')
 else:
  (tmp/'baseline.c').write_bytes(before_source)
  assert build_and_run(tmp,'before',tmp/'baseline.c')==after,'untargeted source changed'
  print('PASS: untargeted MSL/GLSL output byte-identical to the base across register/cbuf/immediate forms and modifiers')
 print('PASS: nearest and unsupported forms emit no directed-rounding helper')
