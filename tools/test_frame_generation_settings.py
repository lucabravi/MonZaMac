#!/usr/bin/env python3
"""Frame generation persistence and source timing, without Metal or game files."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = r'''
#include "runtime/settings.h"
#include "runtime/rt.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

volatile uint64_t g_vsync_count;
uint8_t g_game_build[8] = {0xb1,0xf1,0x2f,0xd9,0x19,0xea,0xe8,0x6a};
static uint64_t now = 1;
static bool supported;
bool fg_supported(void) { return supported; }
uint64_t plat_now_ns(void) { return now; }
void rt_za_npc_capacity(void) {}
bool bind_settings_load(const char *key, const char *val) { return false; }
void bind_settings_save(FILE *f) {}
extern int32_t rt_za_frame_cfg(int32_t cfg);
int main(int argc, char **argv) {
    supported = atoi(argv[6]);
    settings_load();
    assert(g_settings.frame_generation == atoi(argv[1]));
    assert(g_settings.frame_generation_performance == (getenv("TEST_FG_PERFORMANCE") && atoi(getenv("TEST_FG_PERFORMANCE"))));
    assert(g_settings.fps60 == atoi(argv[2]));
    assert(settings_frame_generation() == atoi(argv[3]));
    assert(settings_real_fps60() == atoi(argv[4]));
    uint64_t sites[] = {0x7003393e20, 0x700610b980};
    for (int i = 0; i < 2; i++) {
        void *p = (void *)(sites[i] & ~0x3fffull);
        assert(mmap(p, 0x4000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON|MAP_FIXED, -1, 0) == p);
    }
    ST64(sites[0], 16666667); ST64(sites[0] + 8, 33333334);
    bool uncapped = atoi(argv[5]);
    bool on = atoi(argv[4]);
    assert(rt_za_frame_cfg(1) == (on || uncapped ? 0 : 1));
    now += 25000000;
    assert(rt_za_frame_cfg(1) == (on || uncapped ? 0 : 1));
    assert(LD64(sites[0]) == (on && !uncapped ? 25000000 : 16666667));
    if (argc > 7) {
        g_settings.frame_generation = FRAME_GENERATION_30_60;
        now += 1000000000; assert(rt_za_frame_cfg(1) == 1);
        g_settings.frame_generation = FRAME_GENERATION_60_120;
        now += 1000000000; assert(rt_za_frame_cfg(1) == 0);
        assert(LD64(sites[0]) == 16666667);
        now += 16666667; rt_za_frame_cfg(1);
        assert(LD64(sites[0]) == 16666667);
        g_settings.frame_generation = FRAME_GENERATION_OFF;
        assert(settings_real_fps60() == g_settings.fps60);
    }
    settings_save();
    return 0;
}
'''
# mode text, normalized saved mode, fps preference, effective mode, real 60,
# support, FPS override, uncapped setting, uncapped override
CASES = [
    (None, 0, 1, 0, 1, True, None, 0, None),
    ('0', 0, 0, 0, 0, True, None, 0, None),
    ('1', 1, 1, 1, 0, True, None, 0, None),
    ('1', 1, 0, 1, 0, True, None, 0, None),
    ('2', 2, 0, 2, 1, True, None, 0, None),
    ('2', 2, 1, 2, 1, True, None, 0, None),
    ('2', 2, 0, 2, 1, True, '', 0, None),
    ('1', 1, 1, 0, 1, False, None, 0, None),
    ('2', 2, 0, 0, 0, False, None, 0, None),
    ('1', 1, 1, 0, 0, True, '30', 0, None),
    ('1', 1, 0, 0, 1, True, '60', 0, None),
    ('2', 2, 1, 0, 0, True, 'invalid', 0, None),
    ('2', 2, 0, 0, 0, True, None, 1, None),
    ('1', 1, 1, 0, 1, True, None, 0, '1'),
    ('1', 1, 1, 1, 0, True, None, 1, '0'),
]
for invalid in ('-1', '3', '999999999999999999999999', 'junk', '1junk', '2.0', ''):
    CASES.append((invalid, 0, 0, 0, 0, True, None, 0, None))
CASES.append(('2 \t', 2, 0, 2, 1, True, None, 0, None))

with tempfile.TemporaryDirectory(prefix='frame-generation-settings-') as name:
    tmp = Path(name)
    (tmp / 'check.c').write_text(SOURCE)
    cases = 0
    # Compile the native Apple guard and a non-Apple guard without linking any GPU code.
    for portable in (False, True):
        if not portable and sys.platform != 'darwin':
            continue
        binary = tmp / ('portable' if portable else 'native')
        subprocess.run(['cc', '-std=gnu11', *(['-U__APPLE__'] if portable else []),
                        '-I', str(ROOT), str(tmp / 'check.c'), str(ROOT / 'runtime/settings.c'),
                        str(ROOT / 'runtime/hle/framepace.c'), '-lm', '-o', str(binary)], check=True)
        for raw, saved, pref, effective, real60, support, fps, uncap, uncap_env in CASES:
            if portable and effective:
                effective, real60 = 0, pref
            ini = tmp / 'settings.ini'
            ini.write_text(f'fps60 = {pref}\ndev_uncapped_fps = {uncap}\n' +
                           (f'frame_generation = {raw}\n' if raw is not None else ''))
            env = {k: v for k, v in os.environ.items() if not k.startswith('LARECOMP_')}
            env['LARECOMP_SETTINGS'] = str(ini)
            if fps is not None:
                env['LARECOMP_FPS'] = fps
            if uncap_env is not None:
                env['LARECOMP_UNCAPPED_FPS'] = uncap_env
            active_uncap = uncap if uncap_env is None else int(uncap_env)
            args = list(map(str, (saved, pref, effective, real60, active_uncap, int(support))))
            result = subprocess.run([str(binary), *args], env=env, capture_output=True, text=True)
            assert result.returncode == 0, f'{raw=}, {portable=}: {result.stderr}'
            text = ini.read_text()
            assert f'frame_generation = {saved}\n' in text
            assert f'fps60 = {pref}\n' in text
            cases += 1
        for raw, expected in ((None, 0), ('0', 0), ('1', 1), ('junk', 0)):
            ini.write_text('fps60 = 1\nframe_generation = 0\n' +
                           (f'frame_generation_performance = {raw}\n' if raw is not None else ''))
            env = {k: v for k, v in os.environ.items() if not k.startswith('LARECOMP_')}
            env.update(LARECOMP_SETTINGS=str(ini), TEST_FG_PERFORMANCE=str(expected))
            subprocess.run([str(binary), '0', '1', '0', '1', '0', '1'], env=env, check=True, capture_output=True)
            assert f'frame_generation_performance = {expected}\n' in ini.read_text()
            cases += 1
        if not portable:
            ini.write_text('fps60 = 0\nframe_generation = 2\n')
            env = {k: v for k, v in os.environ.items() if not k.startswith('LARECOMP_')}
            env['LARECOMP_SETTINGS'] = str(ini)
            subprocess.run([str(binary), '2', '0', '2', '1', '0', '1', 'transition'],
                           env=env, check=True, capture_output=True)
    print(f'PASS: {cases} frame generation settings/timing cases and mode transition')
