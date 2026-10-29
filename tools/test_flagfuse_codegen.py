"""Generator integration: fuse only when flags and entries are fully accounted for."""
import unittest
import subprocess
import tempfile
from pathlib import Path
from collections import Counter

from gen import Module, PATCHES
from lifter import Insn


class FusionEmission(unittest.TestCase):
    def module(self):
        m = Module.__new__(Module)
        m.lo, m.hi = 0x1000, 0x1010
        m.setjmp_stubs, m.stats = set(), Counter()
        m.flag_fusion = True
        seq = [Insn('op', code='(void)(subs64(c, c->x[0], c->x[1]));'),
               Insn('bcond', cond='COND_EQ(c)', target=0x100c),
               Insn('op', code='c->x[0] = 7;'), Insn('ret')]
        m.lift = lambda a: seq[(a - m.lo) // 4]
        return m

    def test_pair_fuses_and_retains_branch_target(self):
        m = self.module()
        text = '\n'.join(m.emit_function(0x1000, 0x1010, {0x100c}, {}, {}))
        self.assertNotIn('subs64(c', text)
        self.assertIn('goto L_100c;', text)
        self.assertEqual(m.stats['flag_fused'], 1)

    def test_patch_function_preserves_original_flags(self):
        m = self.module()
        PATCHES[0x1008] = lambda gen, a: 'c->x[0] = 9;'
        try:
            text = '\n'.join(m.emit_function(0x1000, 0x1010, {0x100c}, {}, {}))
        finally:
            del PATCHES[0x1008]
        self.assertIn('subs64(c', text)
        self.assertNotIn('flag_fused', m.stats)

    def test_jump_table_fallback_preserves_all_instruction_entries(self):
        m = self.module()
        text = '\n'.join(m.emit_function(0x1000, 0x1010, {0x100c}, {0x1008: [0x100c]}, {}))
        self.assertIn('subs64(c', text)
        self.assertIn('L_1004:;', text)
        self.assertIn('L_dispatch:', text)

    def test_external_conditional_successor_keeps_flags(self):
        m = self.module(); original = m.lift
        m.lift = lambda a: Insn('bcond', cond='COND_EQ(c)', target=0x2000) if a == 0x1004 else original(a)
        text = '\n'.join(m.emit_function(0x1000, 0x1010, set(), {}, {}))
        self.assertIn('subs64(c', text)

    def test_later_external_jump_keeps_flags(self):
        m = self.module(); original = m.lift
        m.lift = lambda a: Insn('b', target=0x2000) if a == 0x1008 else original(a)
        text = '\n'.join(m.emit_function(0x1000, 0x1010, {0x100c}, {}, {}))
        self.assertIn('subs64(c', text)

    def test_unknown_indirect_successor_keeps_flags(self):
        m = self.module(); original = m.lift
        m.lift = lambda a: Insn('br', target='c->x[8]') if a == 0x1008 else original(a)
        text = '\n'.join(m.emit_function(0x1000, 0x1010, {0x100c}, {}, {}))
        self.assertIn('subs64(c', text)

    def test_function_end_fallthrough_keeps_flags(self):
        m = self.module()
        seq = [Insn('op', code='(void)(subs64(c, c->x[0], c->x[1]));'),
               Insn('bcond', cond='COND_EQ(c)', target=0x100c),
               Insn('op', code='c->x[0] = 7;'), Insn('op', code='c->x[1] = 8;')]
        m.lift = lambda a: seq[(a - m.lo) // 4]
        text = '\n'.join(m.emit_function(0x1000, 0x1010, {0x100c}, {}, {}))
        self.assertIn('subs64(c', text)

    def test_compiled_loop_matches_reference(self):
        m = self.module(); m.hi = 0x1020
        seq = [Insn('op', code='c->x[19] = 0;'),
               Insn('op', code='(void)(subs64(c, c->x[0], c->x[1]));'),
               Insn('bcond', cond='COND_EQ(c)', target=0x1018),
               Insn('op', code='c->x[19] += c->x[0];'),
               Insn('op', code='c->x[0] -= 1;'), Insn('b', target=0x1004),
               Insn('op', code='c->x[0] = c->x[19];'), Insn('ret')]
        m.lift = lambda a: seq[(a - m.lo) // 4]
        emitted = '\n'.join(m.emit_function(0x1000, 0x1020, {0x1004, 0x1018}, {}, {}))
        self.assertNotIn('subs64(c', emitted)
        harness = '#include "cpu.h"\n#include <assert.h>\nvolatile int g_fnprof;\n' + \
            'void fnprof_hit(uint64_t a,uint64_t b,uint64_t d){}\n' + emitted + \
            '\nint main(void){for(uint64_t n=0;n<100;n++){Cpu c={0};c.x[0]=n;f_1000(&c);assert(c.x[0]==n*(n+1)/2);}return 0;}'
        with tempfile.TemporaryDirectory() as tmp:
            cfile=Path(tmp)/'loop.c'; exe=Path(tmp)/'loop'
            cfile.write_text(harness)
            subprocess.run(['clang','-O1','-I',str(Path(__file__).resolve().parents[1]/'runtime'),str(cfile),'-o',str(exe)],check=True)
            subprocess.run([str(exe)],check=True)

    def test_diagnostic_disable_keeps_original_emission(self):
        m = self.module(); m.flag_fusion = False
        text = '\n'.join(m.emit_function(0x1000, 0x1010, {0x100c}, {}, {}))
        self.assertIn('subs64(c', text)


if __name__ == '__main__':
    unittest.main()
