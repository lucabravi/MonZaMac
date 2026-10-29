# From Hexveil404/PokeZ-ARecomp cff8364 (MIT; copyright Peiikai).
#!/usr/bin/env python3
"""tools/flagfuse.py check: every fused compare-and-branch (op x width x condition, with and without a destination
register) against runtime/cpu.h's flag helpers and COND_ macros, compiled and run on edge and random values.
Usage: python tools/test_flagfuse.py [cc] (default clang)."""
import os, random, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import flagfuse

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cc = sys.argv[1] if len(sys.argv) > 1 else 'clang'
cases = []
for fn, conds in flagfuse._CONDS.items():
    for n in (32, 64):
        t = f'uint{n}_t'
        for cond in conds:
            for dst in (False, True):
                if fn == 'logic':
                    args = f'({t})(c->x[1] & c->x[2])'
                else:
                    args = f'(({t})c->x[1]), (({t})c->x[2])'
                code = (f'c->x[3] = ({t})({fn}{n}(c, {args}));' if dst else f'(void)({fn}{n}(c, {args}));')
                st = flagfuse.fused_stmt(code, f'COND_{cond}(c)')
                assert st, (fn, n, cond, dst)
                cases.append((code, cond, st.replace('{JUMP}', 'taken = 1;')))
                sv = flagfuse.fused_stmt(code, f'COND_{cond}(c)', 'fz_t')  # (the kept-condition form)
                cases.append((code, cond, sv + ' if (fz_t) taken = 1;'))
src = ['#include <stdio.h>', '#include <stdint.h>', '#include "cpu.h"']
for i, (code, cond, st) in enumerate(cases):
    src.append(f'static int ref{i}(Cpu *c) {{ {code} return COND_{cond}(c); }}')
    src.append(f'static int fus{i}(Cpu *c) {{ int taken = 0; {st} return taken; }}')
vals = [0, 1, 2, 0x7f, 0x80, 0xff, 0x7fffffff, 0x80000000, 0xffffffff, 0x100000000, 0x7fffffffffffffff,
        0x8000000000000000, 0xffffffffffffffff, 0xfffffffffffffffe, 0x80000001]
random.seed(1)
vals += [random.getrandbits(64) for _ in range(40)] + [random.getrandbits(32) for _ in range(20)]
src.append('static const uint64_t V[] = {' + ', '.join(f'{v:#x}ull' for v in vals) + '};')
src.append('int main(void) { int bad = 0; for (unsigned i = 0; i < sizeof V / 8; i++) for (unsigned j = 0; j < sizeof V / 8; j++) {')
for i in range(len(cases)):
    src.append(f'  {{ Cpu a = {{0}}, b = {{0}}; a.x[1] = b.x[1] = V[i]; a.x[2] = b.x[2] = V[j];'
               f' int r = ref{i}(&a), f = fus{i}(&b);'
               f' if (r != f || a.x[3] != b.x[3]) {{ if (bad++ < 10) printf("case {i} %llx %llx: %d %d\\n", (unsigned long long)V[i], (unsigned long long)V[j], r, f); }} }}')
src.append('} printf("%d cases, %d mismatches\\n", ' + str(len(cases)) + ', bad); return bad != 0; }')
# liveness: a pair is fused only when nothing else reads its flags
from lifter import Insn
CMP, BEQ = '(void)(subs64(c, c->x[1], c->x[2]));', 'COND_EQ(c)'
def prog(*ins):  # (kind, code / cond, target) from 0x1000
    out = {}
    for i, (k, x, t) in enumerate(ins):
        out[0x1000 + 4 * i] = Insn(k, x) if k in ('op', 'trap', 'asm') else Insn(k, None, target=t, cond=x)
    return out, 0x1000, 0x1000 + 4 * len(ins)
def fused(ins, labels=()):
    p, e, n = prog(*ins)
    return set(flagfuse.plan(p, e, n, set(labels) | {e}, {}))
assert fused([('op', CMP, 0), ('bcond', BEQ, 0x100c), ('op', 'c->x[3] = 1;', 0), ('ret', None, 0)]) == {0x1000, 0x1004}
assert fused([('op', CMP, 0), ('bcond', BEQ, 0x100c), ('op', 'c->x[3] = (COND_NE(c)) ? 1 : 0;', 0),
              ('ret', None, 0)]) == set()  # (a cset after the branch reads them)
assert fused([('op', CMP, 0), ('bcond', BEQ, 0x1010), ('op', 'rt_svc(c, 0x1, 0x1008);', 0),
              ('bcond', 'COND_NE(c)', 0x1010), ('ret', None, 0)]) == set()  # (read after an svc: kept)
assert fused([('op', CMP, 0), ('bcond', BEQ, 0x1010), ('bl', None, 0x2000), ('bcond', 'COND_NE(c)', 0x1000),
              ('ret', None, 0)]) == {0x1000, 0x1004}  # (a call ends them)
assert fused([('op', CMP, 0), ('bcond', BEQ, 0x100c), ('ret', None, 0)], labels={0x1004}) == set()  # (an entry between)
assert fused([('op', CMP, 0), ('op', 'ST64(c->x[1], 0);', 0), ('bcond', BEQ, 0x1010), ('op', 'c->x[3] = 1;', 0),
              ('ret', None, 0)]) == {0x1000, 0x1008}  # (a store between: the condition kept)
assert fused([('op', CMP, 0), ('op', 'c->x[4] = (COND_NE(c)) ? 1 : 0;', 0), ('bcond', BEQ, 0x1010),
              ('op', 'c->x[3] = 1;', 0), ('ret', None, 0)]) == set()  # (a flag reader between)
print('liveness checks ok')
d = tempfile.mkdtemp()
c_path, exe = os.path.join(d, 't.c'), os.path.join(d, 't.exe')
open(c_path, 'w').write('\n'.join(src))
subprocess.run([cc, '-O1', '-w', '-I', os.path.join(root, 'runtime'), c_path, '-o', exe], check=True)
sys.exit(subprocess.run([exe]).returncode)
