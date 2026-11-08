#!/usr/bin/env python3
"""Upscaler persistence and temporal eligibility without Metal or game files."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = r'''
#include "runtime/settings.h"
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>

#ifdef __APPLE__
static bool temporal_available, generation_available;
bool fg_supported(void) { return generation_available; }
bool temporal_supported(void) { return temporal_available; }
#endif
extern bool settings_temporal_upscale(void);
bool bind_settings_load(const char *key, const char *val) { return false; }
void bind_settings_save(FILE *f) {}
int main(int argc, char **argv) {
#ifdef __APPLE__
    temporal_available = atoi(argv[1]);
    generation_available = atoi(argv[2]);
#endif
    settings_load();
    printf("%d %d %d %d %d %d %d %d %d\n", g_settings.upscaler, settings_temporal_upscale(),
           g_settings.antialias, g_settings.fxaa, g_settings.frame_generation, settings_frame_generation(),
           g_settings.frame_generation_performance, g_settings.res_mode, g_settings.fps60);
#ifdef __APPLE__
    if (argc > 3) {
        assert(g_settings.upscaler == 3 && settings_temporal_upscale());
        temporal_available = false;
        assert(!settings_temporal_upscale() && g_settings.upscaler == 3);
        temporal_available = true;
        g_settings.upscaler = UPSCALE_METALFX;
        assert(!settings_temporal_upscale());
        g_settings.upscaler = 3;
        assert(settings_temporal_upscale());
    }
#endif
    settings_save();
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='temporal-upscale-settings-') as name:
    tmp = Path(name)
    (tmp / 'check.c').write_text(SOURCE)
    cases = 0
    for portable in (False, True):
        if not portable and sys.platform != 'darwin':
            continue
        binary = tmp / ('portable' if portable else 'native')
        subprocess.run(['cc', '-std=gnu11', *(['-U__APPLE__'] if portable else []),
                        '-I', str(ROOT), str(tmp / 'check.c'), str(ROOT / 'runtime/settings.c'),
                        '-o', str(binary)], check=True)
        sharp = 2 if portable else 1
        def run(settings, temporal_support=True, generation_support=True, overrides=None, transition=False):
            ini = tmp / 'settings.ini'
            ini.write_text(settings)
            env = {k: v for k, v in os.environ.items() if not k.startswith('LARECOMP_')}
            env['LARECOMP_SETTINGS'] = str(ini)
            env.update(overrides or {})
            result = subprocess.run([str(binary), str(int(temporal_support)), str(int(generation_support)),
                                     *(['transition'] if transition else [])],
                                    env=env, capture_output=True, text=True, check=True)
            fields = ('upscaler', 'temporal', 'aa', 'fxaa', 'generation', 'effective_generation',
                      'performance', 'resolution', 'fps60')
            return dict(zip(fields, map(int, result.stdout.split()))), ini.read_text()

        for raw, expected, saved in (
            (None, sharp, 'fsr1' if portable else 'metalfx'),
            ('bilinear', 0, 'bilinear'),
            ('metalfx', sharp, 'fsr1' if portable else 'metalfx'),
            ('fsr1', sharp, 'fsr1' if portable else 'metalfx'),
            ('metalfx_temporal', 3, 'metalfx_temporal'),
            ('junk', sharp, 'fsr1' if portable else 'metalfx'),
            ('', sharp, 'fsr1' if portable else 'metalfx'),
            ('metalfx_temporaljunk', sharp, 'fsr1' if portable else 'metalfx'),
        ):
            values, text = run(f'upscaler = {raw}\n' if raw is not None else '')
            assert values['upscaler'] == expected, f'{raw=}, {portable=}: {values}'
            assert values['temporal'] == int(raw == 'metalfx_temporal' and not portable), values
            assert f'upscaler = {saved}\n' in text, f'{raw=}, {portable=}'
            # Reading and saving an older configuration keeps every new mode opt-in.
            assert values['generation'] == 0 and values['performance'] == 0, values
            assert values['aa'] == 1 and values['fxaa'] == 1, values
            cases += 1
        # Temporal eligibility must not clear saved AA, FXAA, frame rate, resolution or FG quality,
        # including when either GPU feature is unavailable or FPS overrides disable only generation.
        for support in (False, True):
            for fg_support in (False, True):
                for mode in (0, 1, 2):
                    for aa, fxaa in (('off', 0), ('smaa', 1), ('smaa', 0), ('off', 1)):
                        for overrides in ({}, {'LARECOMP_FPS': '30'}, {'LARECOMP_UNCAPPED_FPS': '1'}):
                            settings = (f'upscaler = metalfx_temporal\nantialias = {aa}\ngame_fxaa = {fxaa}\n'
                                        f'frame_generation = {mode}\nframe_generation_performance = 1\n'
                                        'resolution = 1.5x\nfps60 = 0\n')
                            values, text = run(settings, support, fg_support, overrides)
                            expected_fg = mode if fg_support and not portable and not overrides else 0
                            assert values == {'upscaler': 3, 'temporal': int(support and not portable),
                                              'aa': int(aa == 'smaa'), 'fxaa': fxaa, 'generation': mode,
                                              'effective_generation': expected_fg, 'performance': 1,
                                              'resolution': 13, 'fps60': 0}, values
                            for line in ('upscaler = metalfx_temporal', f'antialias = {aa}', f'game_fxaa = {fxaa}',
                                         f'frame_generation = {mode}', 'frame_generation_performance = 1',
                                         'resolution = 1.5x', 'fps60 = 0'):
                                assert line + '\n' in text, line
                            cases += 1
        if not portable:
            run('upscaler = metalfx_temporal\n', transition=True)
            cases += 1
    print(f'PASS: {cases} temporal upscaler settings cases')
