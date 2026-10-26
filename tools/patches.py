"""Hand-written replacements for single guest instructions, applied while lifting (tools/gen.py): PATCHES maps an
address to a function (generator, address) -> C statement. Only Pokémon Legends: Z-A's: ZA_BUILDS names the builds
(main module build ids) and the address of the frame mode site each has; ZA_DOF, ZA_FXAA, ZA_BLOOM and ZA_WIDE the
sites of the graphics options (runtime/hle/za_mods.c), from StevensND's and Fl4sh9174's exefs mods."""
import struct

PATCHES = {}

ZA_BUILDS = {'7222e13ecf6adb32': 0x70019e37a8,  # 1.0.0
             '8a1c86c437394b69': 0x7001b29cf8,  # 2.0.0 (Mega Dimension; the same function)
             'b1f12fd919eae86a': 0x7001b296d8}  # 2.0.2
# The depth of field pass reads its intensity and skips itself at 0 (fcmp s0, #0; b.le): "Disable DOF"
ZA_DOF = {'7222e13ecf6adb32': 0x7000dee3f0,
          '8a1c86c437394b69': 0x7000f31e50,
          'b1f12fd919eae86a': 0x7000f31830}
# FXAA's two parameters (fdiv s0, s1, s0; str s0, [x9, #8] / #0xc): 0 turns it off. "Disable FXAA" zeroes the fdiv; we
# patch the stores after them
ZA_FXAA = {'7222e13ecf6adb32': (0x7000d2a418, 0x7000d2a438),
           '8a1c86c437394b69': (0x7000e6d758, 0x7000e6d778),
           'b1f12fd919eae86a': (0x7000e6d138, 0x7000e6d158)}
# Bloom: its intensity (the pass skips itself at 0) and a call whose result enables more of it: "Reduce Bloom"
ZA_BLOOM = {'7222e13ecf6adb32': (0x7000ded794, 0x7000decd80),
            '8a1c86c437394b69': (0x7000f311f4, 0x7000f307e0),
            'b1f12fd919eae86a': (0x7000f30bd4, 0x7000f301c0)}
# Widescreen: the 3D camera's aspect ratio (a 16:9 float in rodata) and the HUD's layout rectangle lookup (ldur q0,
# [x9, #4]): "21:9 Ultrawide" (2.0.x only: 1.0.0's has no HUD fix)
ZA_WIDE = {'8a1c86c437394b69': (0x700319ac7c, 0x7001803570),
           'b1f12fd919eae86a': (0x700319fc7c, 0x7001802f50)}


def _word(gen, a):
    return struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]


def _za_frame_cfg(gen, a, aspect=None):
    w = _word(gen, a)
    assert w == 0x39c08134, hex(w)  # ldrsb w20, [x9, #0x20]
    wide = ''
    if aspect:  # (once a frame: the camera's aspect follows the window)
        assert _word(gen, aspect) == 0x3fe38e39, hex(_word(gen, aspect))  # 16 / 9
        wide = f'extern void rt_za_aspect(uint64_t); rt_za_aspect({aspect:#x}); '
    return ('{ extern int32_t rt_za_frame_cfg(int32_t); ' + wide +
            'c->x[20] = (uint32_t)rt_za_frame_cfg((int8_t)LD8(c->x[9] + 0x20)); }'
            f'  /* {a:#x}: ldrsb w20, [x9, #0x20] (frame mode) */')


def _za_dof(gen, a):
    w = _word(gen, a)
    assert w == 0xbd4417e0, hex(w)  # ldr s0, [sp, #0x414]
    return ('{ extern uint32_t rt_za_dof(uint32_t); c->v[0] = rt_za_dof(LD32(c->sp + 0x414)); }'
            f'  /* {a:#x}: ldr s0, [sp, #0x414] (depth of field intensity) */')


def _za_fxaa(gen, a):
    off = {0xbd000920: 8, 0xbd000d20: 0xc}[_word(gen, a)]  # str s0, [x9, #8 / #0xc]
    return ('{ extern uint32_t rt_za_fxaa(uint32_t); c->v[0] = rt_za_fxaa((uint32_t)c->v[0]); '
            f'ST32(c->x[9] + {off:#x}, c->v[0]); }}  /* {a:#x}: str s0, [x9, #{off:#x}] (FXAA parameter) */')


def _za_bloom(gen, a):
    w = _word(gen, a)
    assert w == 0xbd411320, hex(w)  # ldr s0, [x25, #0x110]
    return ('{ extern uint32_t rt_za_bloom(uint32_t); c->v[0] = rt_za_bloom(LD32(c->x[25] + 0x110)); }'
            f'  /* {a:#x}: ldr s0, [x25, #0x110] (bloom intensity) */')


def _za_bloom_call(gen, a):
    w = _word(gen, a)
    assert w >> 26 == 0x25, hex(w)  # bl
    t = a + ((w & 0x3ffffff) ^ 0x2000000) * 4 - 0x8000000
    return ('{ extern uint32_t rt_za_bloom(uint32_t); if (rt_za_bloom(1)) { '
            f'c->x[30] = {a + 4:#x}; c->pc = {t:#x}; rt_dispatch(c); }} }}  /* {a:#x}: bl {t:#x} (bloom) */')


def _za_hud_rect(gen, a):
    w = _word(gen, a)
    assert w == 0x3cc04120, hex(w)  # ldur q0, [x9, #4]
    return ('{ extern __uint128_t rt_za_hud_rect(uint64_t); c->v[0] = rt_za_hud_rect(c->x[9] + 4); }'
            f'  /* {a:#x}: ldur q0, [x9, #4] (HUD layout rectangle) */')


def za_patches(build):
    aspect, hud = ZA_WIDE.get(build, (None, None))
    p = {ZA_BUILDS[build]: lambda gen, a: _za_frame_cfg(gen, a, aspect), ZA_DOF[build]: _za_dof,
         ZA_BLOOM[build][0]: _za_bloom, ZA_BLOOM[build][1]: _za_bloom_call}
    p.update({a: _za_fxaa for a in ZA_FXAA[build]})
    if hud:
        p[hud] = _za_hud_rect
    return p
