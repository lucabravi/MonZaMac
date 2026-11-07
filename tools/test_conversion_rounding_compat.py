#!/usr/bin/env python3
"""Asset-free source compatibility for untouched I2F/F2F forms against develop v0.1.6."""
from pathlib import Path
import subprocess,tempfile
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
with tempfile.TemporaryDirectory(prefix='rounding-compat-')as tmp:
 tmp=Path(tmp);(tmp/'test.c').write_text(harness)
 (tmp/'baseline.c').write_bytes(subprocess.check_output(['git','show','fbff0b2:runtime/nvn/maxwell/translate.c'],cwd=root))
 outputs=[]
 for name,source in [('before',tmp/'baseline.c'),('after',root/'runtime/nvn/maxwell/translate.c')]:
  binary=tmp/name
  subprocess.run(['clang','-O1','-I',str(root/'runtime/nvn/maxwell'),str(tmp/'test.c'),str(source),'-lm','-o',str(binary)],check=True)
  result=subprocess.run([str(binary)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True)
  outputs.append(result.stdout);print(name,result.stderr.decode().strip())
 assert outputs[0]==outputs[1],'untargeted source changed'
 print('PASS: nearest and untargeted MSL/GLSL output byte-identical across register/cbuf/immediate forms and modifiers')
