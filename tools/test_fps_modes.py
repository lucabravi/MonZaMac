#!/usr/bin/env python3
"""Exercise real settings migration and frame timing without game files."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
#include "runtime/settings.h"
#include "runtime/rt.h"
#include <assert.h>
#include <stdlib.h>

#include <sys/mman.h>
#include <string.h>
volatile uint64_t g_vsync_count;
uint8_t g_game_build[8] = {0xb1,0xf1,0x2f,0xd9,0x19,0xea,0xe8,0x6a};
static uint64_t now;
uint64_t plat_now_ns(void) { return now += 25000000; }
void rt_za_npc_capacity(void) {}
bool bind_settings_load(const char *key, const char *val) { return false; }
void bind_settings_save(FILE *f) {}
extern int32_t rt_za_frame_cfg(int32_t cfg);
int main(int argc, char **argv) {
    settings_load();
    assert(g_settings.fps60 == atoi(argv[1]));
    assert(g_settings.volume == 0.75f);
    assert(g_settings.language == 6);
    uint64_t sites[] = {0x7003393e20, 0x700610b980};
    for (int i=0; i<2; i++) {
        void *p = (void *)(sites[i] & ~0x3fffull);
        assert(mmap(p, 0x4000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON|MAP_FIXED, -1, 0) == p);
    }
    ST64(sites[0],16666667); ST64(sites[0]+8,33333334);
    bool on = atoi(argv[2]);
    assert(rt_za_frame_cfg(1) == (on ? 0 : 1));
    assert(rt_za_frame_cfg(1) == (on ? 0 : 1));
    assert(LD64(sites[0]) == (on ? 25000000 : 16666667));
    settings_save();
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='fps-modes-') as tmp:
    tmp = Path(tmp)
    (tmp / 'check.c').write_text(HARNESS)
    subprocess.run(['cc', '-std=gnu11', '-I', str(ROOT), str(tmp/'check.c'),
                    str(ROOT/'runtime/settings.c'), str(ROOT/'runtime/hle/framepace.c'),
                    '-lm', '-o', str(tmp/'check')], check=True)
    cases = 0
    for fps in (None, 0, 1):
        for steady in (None, 0, 1):
            for override in (None, '30', '60'):
                ini = tmp/'settings.ini'
                ini.write_text('volume = 0.75\nlanguage = it\n' +
                               (f'fps60 = {fps}\n' if fps is not None else '') +
                               (f'fps60_steady = {steady}\n' if steady is not None else ''))
                enabled = fps != 0
                on = enabled if override is None else override == '60'
                env = {k:v for k,v in os.environ.items() if not k.startswith('LARECOMP_')}
                env.update(LARECOMP_SETTINGS=str(ini), LARECOMP_FPS_STEADY='0')
                if override is not None:
                    env['LARECOMP_FPS'] = override
                result = subprocess.run([str(tmp/'check'), str(int(enabled)), str(int(on))], env=env,
                                        capture_output=True, text=True)
                assert result.returncode == 0, result.stderr
                saved = ini.read_text()
                assert 'fps60_steady' not in saved
                assert f'fps60 = {int(enabled)}\n' in saved
                assert 'volume = 0.75\n' in saved and 'language = it\n' in saved
                cases += 1
    print(f'PASS: {cases} legacy/default/settings/override timing cases')
