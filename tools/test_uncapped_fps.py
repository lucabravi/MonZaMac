"""Developer benchmark opt-in and frame-mode override, using real runtime code."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = r'''
#include "runtime/settings.h"
#include "runtime/rt.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
uint8_t g_game_build[8];
volatile uint64_t g_vsync_count;
static uint64_t now = 1;
uint64_t plat_now_ns(void) { return now; }
void rt_za_npc_capacity(void) {}
bool bind_settings_load(const char *k,const char *v) { return false; }
void bind_settings_save(FILE *f) {}
extern int32_t rt_za_frame_cfg(int32_t);
int main(int argc,char **argv) {
 settings_load();
 if (!strcmp(argv[1], "transition")) {
  const uint8_t build[8]={0xb1,0xf1,0x2f,0xd9,0x19,0xea,0xe8,0x6a}; memcpy(g_game_build,build,8);
  uint64_t addresses[]={0x7003393e20ull,0x700610b980ull};
  for(int i=0;i<2;i++){void *p=(void *)(addresses[i]&~0x3fffull);assert(mmap(p,0x4000,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON|MAP_FIXED,-1,0)==p);}
  ST64(addresses[0],16666667); ST64(addresses[0]+8,33333334);
  g_settings.fps60=true;
  rt_za_frame_cfg(1);now+=25000000;rt_za_frame_cfg(1);assert(LD64(addresses[0])==25000000);
  g_settings.dev_uncapped_fps=true;now+=1000000000;rt_za_frame_cfg(1);
  now+=1000000000;rt_za_frame_cfg(1);
  g_settings.dev_uncapped_fps=false;now+=16666667;rt_za_frame_cfg(1);
  now+=16666667;rt_za_frame_cfg(1);assert(LD64(addresses[0])==16666667);
  return 0;
 }
 assert(settings_uncapped_fps() == atoi(argv[1]));
 assert(rt_za_frame_cfg(1) == (atoi(argv[1]) ? 0 : 1));
 settings_save();
 return 0;
}
'''
with tempfile.TemporaryDirectory() as name:
    d=Path(name); (d/'check.c').write_text(SOURCE)
    subprocess.run(['clang','-I',str(ROOT),str(d/'check.c'),str(ROOT/'runtime/settings.c'),
                    str(ROOT/'runtime/hle/framepace.c'),'-lm','-o',str(d/'check')],check=True)
    for setting,override,want in [(None,None,False),(0,None,False),(1,None,True),(1,'0',False),(0,'1',True)]:
        ini=d/'settings.ini';ini.write_text('fps60 = 0\nfps60_steady = 1\n'+('' if setting is None else f'dev_uncapped_fps = {setting}\n'))
        env={k:v for k,v in os.environ.items() if not k.startswith('LARECOMP_')}
        env['LARECOMP_SETTINGS']=str(ini)
        if override is not None:env['LARECOMP_UNCAPPED_FPS']=override
        subprocess.run([str(d/'check'),str(int(want))],env=env,check=True,capture_output=True)
        text=ini.read_text(); assert f'dev_uncapped_fps = {int(bool(setting))}\n' in text
    subprocess.run([str(d/'check'),'transition'],env={k:v for k,v in env.items() if k!='LARECOMP_UNCAPPED_FPS'},check=True,capture_output=True)
    print('PASS: transition restoration; default-off, saved toggle, environment precedence and frame-mode override (5 cases)')
