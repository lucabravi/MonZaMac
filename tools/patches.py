"""Hand-written replacements for single guest instructions, applied while lifting (tools/gen.py): PATCHES maps an
address to a function (generator, address) -> C statement. Only Pokémon Legends: Z-A's: ZA_BUILDS names the builds
(main module build ids) and the address of the frame mode site each has, ZA_DOF their depth of field site."""
import struct

PATCHES = {}

ZA_BUILDS = {'7222e13ecf6adb32': 0x70019e37a8,  # 1.0.0
             '8a1c86c437394b69': 0x7001b29cf8,  # 2.0.0 (Mega Dimension; the same function)
             'b1f12fd919eae86a': 0x7001b296d8}  # 2.0.2
# The depth of field pass reads its intensity and skips itself at 0 (fcmp s0, #0; b.le): the site of StevensND's and
# Fl4sh9174's "Disable DOF" mods (exefs patch `fmov s0, wzr` there)
ZA_DOF = {'7222e13ecf6adb32': 0x7000dee3f0,
          '8a1c86c437394b69': 0x7000f31e50,
          'b1f12fd919eae86a': 0x7000f31830}


def _za_frame_cfg(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert w == 0x39c08134, hex(w)  # ldrsb w20, [x9, #0x20]
    return ('{ extern int32_t rt_za_frame_cfg(int32_t); '
            'c->x[20] = (uint32_t)rt_za_frame_cfg((int8_t)LD8(c->x[9] + 0x20)); }'
            f'  /* {a:#x}: ldrsb w20, [x9, #0x20] (frame mode) */')


def _za_dof(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert w == 0xbd4417e0, hex(w)  # ldr s0, [sp, #0x414]
    return ('{ extern uint32_t rt_za_dof(uint32_t); c->v[0] = rt_za_dof(LD32(c->sp + 0x414)); }'
            f'  /* {a:#x}: ldr s0, [sp, #0x414] (depth of field intensity) */')


def za_patches(build):
    return {ZA_BUILDS[build]: _za_frame_cfg, ZA_DOF[build]: _za_dof}
