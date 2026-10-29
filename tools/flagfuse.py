# Adapted from Hexveil404/PokeZ-ARecomp cff8364, tools/flagfuse.py (MIT; copyright Peiikai).
"""Compare-and-branch fusion for the generated C (gen.py emit_function).

A flag-setting compare (cmp / cmn / tst, or subs / adds / ands into a register) followed by a conditional branch was
two statements: the helper (runtime/cpu.h subs64 ...) packed all four flags into c->nzcv, and the branch read one back.
Guest memory is reached through byte pointers, which may alias the Cpu struct, so the C compiler kept every one of
those stores and loads: a linear search loop of the game's (Pokémon Z-A, its resource lookups while a battle loads, a
1 s freeze) ran ~25 x86 instructions per element for ARM's 4. When the flags are read by that branch alone - dead on
both of its paths afterwards (a backward liveness pass over the function) - the pair becomes one `if` on the operands
and no flags are made at all.

Liveness: readers are the COND_ / FLAG_ macros, adc / sbc, an mrs (c->nzcv read) and the asm batches; writers the
flag helpers and c->nzcv stores. A call (bl / blr), a return or a trap ends them: AAPCS64 leaves NZCV
undefined across calls, and nothing in the runtime reads c->nzcv. An svc passes them through (Horizon keeps them).
Unknown outgoing jumps and end fallthrough keep flags live: generated function boundaries may split guest control flow.
Functions with entries the pass can't see - jump tables jumping anywhere, randomizer / hook / patch sites - are left
as they were. Checked by tools/test_flagfuse.py (the fused conditions against the helpers' flags, compiled).
"""
import re

_DEF = re.compile(r'\b(?:subs|adds|logic|adcs|sbcs)(?:32|64)\(c,|c->nzcv\s*=(?!=)')
_USE = re.compile(r'COND_|FLAG_|\b(?:adc|sbc|adcs|sbcs)(?:32|64)\(c,|c->nzcv(?!\s*=(?!=))')
_FUSE = re.compile(r'^(?:\(void\)|(?P<dst>c->x\[\d+\]|c->sp) = \((?P<dt>uint32_t|uint64_t)\))'
                   r'\((?P<fn>subs|adds|logic)(?P<n>32|64)\(c, (?P<args>.*)\)\);$')
_COND = re.compile(r'^COND_([A-Z]{2})\(c\)$')

# condition -> C on a_, b_ (operands, unsigned), r_ (result), s (the signed type); None: not fused (needs V or C)
_CONDS = {
    'subs': {'EQ': 'a_ == b_', 'NE': 'a_ != b_', 'CS': 'a_ >= b_', 'CC': 'a_ < b_', 'HI': 'a_ > b_', 'LS': 'a_ <= b_',
             'GE': '({s})a_ >= ({s})b_', 'LT': '({s})a_ < ({s})b_', 'GT': '({s})a_ > ({s})b_', 'LE': '({s})a_ <= ({s})b_',
             'MI': '({s})r_ < 0', 'PL': '({s})r_ >= 0'},
    'adds': {'EQ': 'r_ == 0', 'NE': 'r_ != 0', 'CS': 'r_ < a_', 'CC': 'r_ >= a_', 'MI': '({s})r_ < 0', 'PL': '({s})r_ >= 0'},
    'logic': {'EQ': 'r_ == 0', 'NE': 'r_ != 0', 'MI': '({s})r_ < 0', 'PL': '({s})r_ >= 0', 'GE': '({s})r_ >= 0',
              'LT': '({s})r_ < 0', 'GT': '({s})r_ > 0', 'LE': '({s})r_ <= 0'},
}


def split_args(s):
    """Top-level comma split of a C argument list."""
    out, depth, cur = [], 0, ''
    for ch in s:
        if ch in '([':
            depth += 1
        elif ch in ')]':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur.strip())
            cur = ''
        else:
            cur += ch
    out.append(cur.strip())
    return out


def fused_stmt(code, cond, var=None):
    """The flag op `code` and a branch on `cond` as one statement with the jump as {JUMP}; None: not fusable. With
    var: the op alone, keeping the branch's condition in uint8_t `var` (declared here) for a branch further on."""
    m, mc = _FUSE.match(code), _COND.match(cond)
    if not m or not mc:
        return None
    fn, n = m.group('fn'), m.group('n')
    expr = _CONDS[fn].get(mc.group(1))
    if expr is None:
        return None
    args = split_args(m.group('args'))
    if len(args) != (1 if fn == 'logic' else 2):
        return None
    t, s = f'uint{n}_t', f'int{n}_t'
    if fn == 'logic':
        decl = f'{t} r_ = ({t})({args[0]});'
    else:
        op = '-' if fn == 'subs' else '+'
        decl = f'{t} a_ = ({t})({args[0]}), b_ = ({t})({args[1]}), r_ = ({t})(a_ {op} b_); (void)b_;'
    dst = f' {m.group("dst")} = ({m.group("dt")})(r_);' if m.group('dst') else ''
    if var:  # (a declaration at statement level: C lets gotos pass it; the block's own temporaries stay inside)
        return f'uint8_t {var}; {{ ' + decl + dst + f' {var} = {expr.format(s=s)}; }}'
    return '{ ' + decl + dst + f' if ({expr.format(s=s)}) {{ {{JUMP}} }} }}'


def plan(insns, entry, end, labels, tables):
    """{address: replacement} for this function's instructions (a -> Insn): a flag op's fused statement ({JUMP}: its
    branch's jump), '' for a branch fused into it, or a branch's `if` on the op's kept condition."""
    addrs = list(range(entry, end, 4))
    use, kill, succ = {}, {}, {}
    for a in addrs:
        ins = insns[a]
        k = ins.kind
        nxt = [a + 4]  # an external fallthrough may consume the flags
        if k in ('op', 'trap'):
            code = ins.code or ''
            use[a] = bool(_USE.search(code)) or ('if (' in code and bool(_DEF.search(code)))
            kill[a] = bool(_DEF.search(code)) or k == 'trap'  # (an svc keeps them: Horizon preserves NZCV)
            succ[a] = [] if k == 'trap' else nxt
        elif k == 'asm':
            use[a], kill[a], succ[a] = True, False, nxt
        elif k == 'bcond':
            use[a], kill[a] = True, False
            t = ins.target
            succ[a] = nxt + [t if isinstance(t, int) else None]
        elif k == 'b':
            t = ins.target
            use[a], kill[a] = False, False
            succ[a] = [t]
        elif k == 'br':
            jt = tables.get(a)
            if jt == 'all':
                return {}
            use[a], kill[a], succ[a] = not jt, False, list(jt) if jt else []
        elif k in ('bl', 'blr', 'ret'):
            use[a], kill[a], succ[a] = False, True, (nxt if k != 'ret' else [])
        else:
            return {}
    live = {a: False for a in addrs}  # live into a
    changed = True
    while changed:
        changed = False
        for a in reversed(addrs):
            out = any(live.get(s, True) for s in succ[a])
            v = use[a] or (out and not kill[a])
            if v != live[a]:
                live[a] = v
                changed = True
    res = {}
    for a in addrs:
        if insns[a].kind != 'op' or not kill[a] or a in res:
            continue
        # its branch: the next flag reader, in the same block (no entry, nothing else touching the flags between)
        b = a + 4
        while b < end and b not in labels and insns[b].kind == 'op' and not use[b] and not kill[b]:
            b += 4
        if b >= end or b in labels or insns[b].kind != 'bcond':
            continue
        if any(live.get(s, True) for s in succ[b]):
            continue
        if b == a + 4:
            st = fused_stmt(insns[a].code, insns[b].cond)
            if st:
                res[a], res[b] = st, ''
        else:
            var = f'fz_{a:x}'
            st = fused_stmt(insns[a].code, insns[b].cond, var)
            if st:
                res[a], res[b] = st, f'if ({var}) {{ {{JUMP}} }}'
    return res
