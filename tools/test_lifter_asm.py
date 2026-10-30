"""Native SIMD batches against Unicorn, using only synthetic instructions.

Cross-compiles the real generated inline assembly to AArch64 ELF, then executes
it in Unicorn. Works on non-ARM hosts; needs clang with the AArch64 target and
the normal generator dependencies. Run: python3 tools/test_lifter_asm.py
"""
import os
import struct
import subprocess
import tempfile
import unittest
from collections import Counter
from pathlib import Path

import unicorn as uc
from unicorn import arm64_const as A

from gen import Module
from lifter import Lifter


GUEST, HOST, STATE, STACK = 0x100000, 0x200000, 0x300000, 0x400000
LITERAL, STOP = GUEST + 0x4000, HOST + 0x8000
PRELUDE = '''
typedef unsigned long long uint64_t;
typedef unsigned int uint32_t;
typedef struct {
    uint64_t x[32], sp, pc, nzcv;
    unsigned char pad[512 - 280];
    __uint128_t v[32];
} Cpu;
_Static_assert(__builtin_offsetof(Cpu, v) == 512, "v offset");
#define FN_ENTER(a) ((void)0)
'''


def compile_text(source):
    """Read the sole function's .text from a relocation-free ELF64 object."""
    with tempfile.TemporaryDirectory() as tmp:
        src, obj = Path(tmp) / 'batch.c', Path(tmp) / 'batch.o'
        src.write_text(PRELUDE + source)
        subprocess.run([os.environ.get('CC', 'clang'), '--target=aarch64-none-elf',
                        '-O1', '-ffreestanding', '-fno-stack-protector',
                        '-fno-unwind-tables', '-fno-asynchronous-unwind-tables',
                        '-Werror', '-c', str(src), '-o', str(obj)], check=True)
        data = obj.read_bytes()
    assert data[:6] == b'\x7fELF\x02\x01', 'expected little-endian ELF64'
    shoff = struct.unpack_from('<Q', data, 40)[0]
    entsize, count, names_idx = struct.unpack_from('<HHH', data, 58)
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + i * entsize)
                for i in range(count)]
    names = sections[names_idx]
    strings = data[names[4]:names[4] + names[5]]
    text = None
    for s in sections:
        name = strings[s[0]:].split(b'\0', 1)[0]
        assert not (s[1] in (4, 9) and s[5]), 'unexpected unresolved relocation'
        if name == b'.text':
            text = data[s[4]:s[4] + s[5]]
    assert text, 'missing generated code'
    return text


def gpr(i):
    return A.UC_ARM64_REG_X0 + i if i < 29 else (A.UC_ARM64_REG_X29 if i == 29 else A.UC_ARM64_REG_X30)


def machine():
    mu = uc.Uc(uc.UC_ARCH_ARM64, uc.UC_MODE_ARM)
    for addr in (GUEST, HOST, STATE, STACK):
        mu.mem_map(addr, 0x10000)
    mu.reg_write(A.UC_ARM64_REG_CPACR_EL1, 0x300000)
    mu.mem_write(LITERAL, bytes(range(256)))
    return mu


class NativeSimdBatch(unittest.TestCase):
    def assert_matches(self, words):
        # The generator's real batching, including its scratch-exhaustion split.
        m = Module.__new__(Module)
        m.lo, m.hi = GUEST, GUEST + 4 * (len(words) + 1)
        m.words = words + [0xd65f03c0]  # ret
        m.lifter = Lifter(GUEST, 'asm')
        m.cache, m.stats, m.setjmp_stubs = {}, Counter(), set()
        m.flag_fusion = False
        source = '\n'.join(m.emit_function(m.lo, m.hi, {m.lo}, {}, {}))
        code = compile_text(source)
        ref, got = machine(), machine()
        x = [0x3ff0000000000000 + (i << 44) for i in range(31)]
        v = [(i << 96) | 0x4000000000000000 for i in range(32)]
        sp, nzcv = STACK + 0x8000, 0xa0000000
        state = bytearray(1024)
        struct.pack_into('<31Q', state, 0, *x)
        struct.pack_into('<Q', state, 256, sp)
        struct.pack_into('<Q', state, 272, nzcv)
        for i, value in enumerate(v):
            state[512 + 16 * i:528 + 16 * i] = value.to_bytes(16, 'little')
            ref.reg_write(A.UC_ARM64_REG_Q0 + i, value)
        for i, value in enumerate(x):
            ref.reg_write(gpr(i), value)
        ref.reg_write(A.UC_ARM64_REG_SP, sp)
        ref.reg_write(A.UC_ARM64_REG_NZCV, nzcv)
        ref.mem_write(GUEST, struct.pack(f'<{len(words)}I', *words))
        ref.emu_start(GUEST, GUEST + len(words) * 4, count=len(words))

        got.mem_write(HOST, code)
        got.mem_write(STATE, bytes(state))
        got.reg_write(A.UC_ARM64_REG_X0, STATE)
        got.reg_write(A.UC_ARM64_REG_X30, STOP)
        got.reg_write(A.UC_ARM64_REG_SP, STACK + 0xff00)
        got.emu_start(HOST, STOP, count=10000)
        self.assertEqual(got.reg_read(A.UC_ARM64_REG_PC), STOP, 'generated function did not return')
        result = bytes(got.mem_read(STATE, len(state)))
        for i in range(31):
            self.assertEqual(struct.unpack_from('<Q', result, 8 * i)[0], ref.reg_read(gpr(i)), f'x{i}')
        self.assertEqual(struct.unpack_from('<Q', result, 256)[0], ref.reg_read(A.UC_ARM64_REG_SP), 'sp')
        self.assertEqual(struct.unpack_from('<Q', result, 272)[0], ref.reg_read(A.UC_ARM64_REG_NZCV), 'nzcv')
        for i in range(32):
            self.assertEqual(int.from_bytes(result[512 + 16 * i:528 + 16 * i], 'little'),
                             ref.reg_read(A.UC_ARM64_REG_Q0 + i), f'v{i}')

    def test_flag_temporary_preserves_guest_registers(self):
        for count in (7, 8, 9, 10):
            for flag_at in (0, count // 2, count):
                with self.subTest(registers=count, flag_at=flag_at):
                    words = [0x9e670000 | (i << 5) | i for i in range(count)]  # fmov dI, xI
                    words.insert(flag_at, 0x1e602000)  # fcmp d0, d0
                    self.assert_matches(words)

    def test_flag_temporary_preserves_integer_results(self):
        words = [0x9e660000 | (i << 5) | i for i in range(9)]  # fmov xI, dI
        self.assert_matches(words + [0x1e602000])

    def test_literal_scratch_exhaustion_splits_the_batch(self):
        words = [0x5c000000 | (((LITERAL + 8 * i - (GUEST + 4 * i)) // 4) << 5) | i
                 for i in range(10)]  # ldr dI, literal
        self.assert_matches(words)

    def test_flags_and_literals_share_scratch_capacity(self):
        words = [0x9e670000 | (i << 5) | i for i in range(3)]
        words.append(0x1e602000)
        for i in range(7):
            words.append(0x5c000000 | (((LITERAL + 8 * i - (GUEST + 4 * len(words))) // 4) << 5) | (i + 3))
        self.assert_matches(words)


if __name__ == '__main__':
    unittest.main()
