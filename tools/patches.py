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
# Improved FOV, Level of detail and 4K Shadows (2.0.2 only: the mods' sites for the other builds are not checked).
# FOV: the mod jumps from the camera's field of view load to a cave that adds 0.203125 (fadd s1, s1, s30).
ZA_FOV = {'b1f12fd919eae86a': 0x7000371e5c}
# LOD: the mod's LOD bias (-1.0, a load) and a branch the mod replaces with the anisotropic filtering constant (8.0)
ZA_LOD = {'b1f12fd919eae86a': (0x70018b58e4, 0x70018b5f68)}
# Shadows: the shadow map size is loaded from memory; the mod sets 4096
ZA_SHADOW = {'b1f12fd919eae86a': 0x7000a8aaa0}


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


def _za_fov(gen, a):
    assert _word(gen, a) == 0xbd407e81, hex(_word(gen, a))  # ldr s1, [x20, #0x7c]
    return ('{ extern uint32_t rt_za_fov(Cpu *, uint32_t); c->v[1] = rt_za_fov(c, LD32(c->x[20] + 0x7c)); }'
            f'  /* {a:#x}: ldr s1, [x20, #0x7c] (field of view) */')


def _za_lod_bias(gen, a):
    assert _word(gen, a) == 0xbd401e60, hex(_word(gen, a))  # ldr s0, [x19, #0x1c]
    return ('{ extern _Bool rt_za_lod(void); c->v[0] = rt_za_lod() ? 0xbf800000u : LD32(c->x[19] + 0x1c); }'
            f'  /* {a:#x}: ldr s0, [x19, #0x1c] (LOD bias: -1.0) */')


def _za_aniso(gen, a):
    assert _word(gen, a) == 0x1400002f, hex(_word(gen, a))  # b (the mod replaces it with fmov s0, #8.0)
    t = a + 0x2f * 4
    return ('{ extern _Bool rt_za_lod(void); if (!rt_za_lod()) { c->pc = ' f'{t:#x}; '
            '__attribute__((musttail)) return rt_dispatch(c); } c->v[0] = 0x41000000u; }'
            f'  /* {a:#x}: b {t:#x} (anisotropic filtering: 8.0) */')


def _za_shadow(gen, a):
    assert _word(gen, a) == 0xb9403109, hex(_word(gen, a))  # ldr w9, [x8, #0x30]
    return ('{ extern _Bool rt_za_shadows_4k(void); c->x[9] = rt_za_shadows_4k() ? 0x1000u : LD32(c->x[8] + 0x30); }'
            f'  /* {a:#x}: ldr w9, [x8, #0x30] (shadow map size: 4096) */')


def za_patches(build):
    aspect, hud = ZA_WIDE.get(build, (None, None))
    p = {ZA_BUILDS[build]: lambda gen, a: _za_frame_cfg(gen, a, aspect), ZA_DOF[build]: _za_dof,
         ZA_BLOOM[build][0]: _za_bloom, ZA_BLOOM[build][1]: _za_bloom_call}
    p.update({a: _za_fxaa for a in ZA_FXAA[build]})
    if hud:
        p[hud] = _za_hud_rect
    if build in ZA_FOV:
        p[ZA_FOV[build]] = _za_fov
        p[ZA_LOD[build][0]], p[ZA_LOD[build][1]] = _za_lod_bias, _za_aniso
        p[ZA_SHADOW[build]] = _za_shadow
    return p
