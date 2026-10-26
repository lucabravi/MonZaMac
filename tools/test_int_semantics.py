#!/usr/bin/env python3
"""Integer ops of runtime/nvn/maxwell/translate.c against reference formulas (Ryujinx's / yuzu's semantics): each
instruction is translated alone (compute, MSL), the expression assigned to its destination is compiled as C++ (uint /
ulong / long as in MSL) and compared with the reference over random and edge-case register values.
Covers SHF, IADD3 (half select, .LS / .RS), FLO, SHR, IMUL / IMUL32I .HI. Needs cc + c++.
SHF boundary reference: Mesa NAK's hardware-tested folding, including the signed shift fix in
https://github.com/chaotic-cx/mesa-mirror/commit/d3e917ea031bc3c50644cd20c601d7005c57793e .
usage: tools/test_int_semantics.py
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "test_int_semantics")

GEN = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "shader.h"
int main(int argc, char **argv) {  // translate one instruction, print the expression assigned to r9
    uint64_t code[8] = {0, strtoull(argv[1], 0, 16), 0xe30000000007000full, 0xe2400fffff87000full};
    ShaderInfo *s = maxwell_translate((const uint8_t *)code, sizeof code, STAGE_COMPUTE, NULL);
    if (!s->msl) { printf("FAIL %s\n", s->error); return 1; }
    char *p = NULL, *q = s->msl;
    while ((q = strstr(q, "    r9 = "))) p = q += 4;
    if (!p) return 1;
    *strchr(p, '\n') = 0;
    printf("%s\n", p + 5);
    return 0;
}
'''

PRELUDE = r'''
#include <cstdint>
#include <cstdio>
typedef uint32_t uint; typedef uint64_t ulong;
static uint min(uint a, uint b) { return a < b ? a : b; }
static uint clz(uint v) { return v ? __builtin_clz(v) : 32u; }
static uint reverse_bits(uint v) { uint r = 0; for (int i = 0; i < 32; i++) if (v >> i & 1) r |= 1u << (31 - i); return r; }
static uint mulhi(uint a, uint b) { return (uint)(((uint64_t)a * b) >> 32); }
static int mulhi(int a, int b) { return (int)(((int64_t)a * b) >> 32); }
static uint msbu(uint v) { for (int i = 31; i >= 0; i--) if (v >> i & 1) return i; return 0xFFFFFFFFu; }
static uint msbs(uint v) { return (int)v < 0 ? msbu(~v) : msbu(v); }
static uint rnd() { static uint64_t s = 88172645463325252ull; s ^= s << 13; s ^= s >> 7; s ^= s << 17; return (uint)s; }
static const uint edge[16] = {0, 1, 2, 31, 32, 33, 40, 63, 64, 65, 100, 0x7fffffffu, 0x80000000u, 0xffffffffu, 0xffffu, 0x10000u};
'''


def bit(n):
    return 1 << n


def enc(top, extra=0, c=0):  # Rd = r9, Ra = r1, Rb = r2, Rc = c (r3 where used)
    return (top << 48) | 9 | (1 << 8) | (2 << 20) | (c << 39) | (7 << 16) | extra


def cases():
    v = "(((uint64_t)r3 << 32) | r1)"
    for right in (1, 0):
        for maxs in (0, 2, 3):
            if maxs == 3 and not right:
                continue
            for wrap in (0, 1):
                lim = 64 if maxs >= 2 else 32
                n = f"(r2 & {lim - 1}u)" if wrap else f"(r2 < {lim}u ? r2 : {lim}u)"
                if right and maxs == 3:
                    ref = f"(uint)((int64_t){v} >> ({n} > 63u ? 63u : {n}))"
                elif right:
                    ref = f"({n} >= 64u ? 0u : (uint)({v} >> {n}))"
                else:
                    ref = f"({n} >= 64u ? 0u : (uint)(({v} << {n}) >> 32))"
                yield f"SHF right {right} max {maxs} wrap {wrap}", enc(0x5cf8 if right else 0x5bf8, (maxs << 37) | wrap << 50, 3), ref
    for amt in (0, 5, 31, 32, 40, 63):  # immediate: 6 bits, the max shift field above it is not part of the amount
        yield f"SHF.R.U64 imm {amt}", (0x38f8 << 48) | 9 | (1 << 8) | (amt << 20) | (3 << 39) | (7 << 16) | (2 << 37), \
            f"(uint)({v} >> {amt})"

    def part(x, p):
        return {0: x, 1: f"({x} & 0xFFFFu)", 2: f"({x} >> 16)"}[p]
    for pa in (0, 1, 2):
        for pb in (0, 1, 2):
            for lrs in (0, 1, 2):
                for negs in (0, 7, 5):
                    A, B, C = part("r1", pa), part("r2", pb), part("r3", 1)
                    A, B, C = [f"(0u - {x})" if negs >> (2 - i) & 1 else x for i, x in enumerate((A, B, C))]
                    s = f"({A} + {B})"
                    if lrs == 1:  # 33-bit sum (yuzu: the carry becomes bit 16)
                        s = f"(uint)(((uint64_t)(uint){A} + (uint64_t)(uint){B}) >> 16)"
                    elif lrs == 2:
                        s = f"({s} << 16)"
                    yield f"IADD3 parts {pa} {pb} lrs {lrs} neg {negs}", \
                        enc(0x5cc0, (pa << 35) | (pb << 33) | (1 << 31) | (lrs << 37) | (negs << 49), 3), f"(uint)({s} + {C})"
    for sh in (0, 1):
        for sg in (0, 1):
            for inv in (0, 1):
                m = f"msb{'s' if sg else 'u'}({'~r2' if inv else 'r2'})"
                yield f"FLO sh {sh} signed {sg} inv {inv}", enc(0x5c30, sh << 41 | sg << 48 | inv << 40), \
                    f"({m} == 0xFFFFFFFFu ? 0xFFFFFFFFu : {m} ^ 31u)" if sh else m
    for wrap in (0, 1):
        for brev in (0, 1):
            for sg in (0, 1):
                a, n = "reverse_bits(r1)" if brev else "r1", "(r2 & 31u)" if wrap else "r2"
                ref = f"({n} < 32u ? (uint)((int){a} >> {n}) : (uint)((int){a} >> 31))" if sg else f"({n} < 32u ? {a} >> {n} : 0u)"
                yield f"SHR wrap {wrap} brev {brev} signed {sg}", enc(0x5c28, wrap << 39 | brev << 40 | sg << 48), ref
    for sa in (0, 1):
        for sb in (0, 1):
            A, B = ("(int64_t)(int)r1" if sa else "(int64_t)r1"), ("(int64_t)(int)r2" if sb else "(int64_t)r2")
            yield f"IMUL.HI signed {sa}{sb}", enc(0x5c38, bit(39) | sa << 40 | sb << 41), f"(uint)((uint64_t)({A} * {B}) >> 32)"
            A, B = ("(int64_t)(int)r1" if sa else "(int64_t)r1"), ("(int64_t)(int)0x9abcdef1u" if sb else "(int64_t)0x9abcdef1u")
            yield f"IMUL32I.HI signed {sa}{sb}", (0x1f << 56) | 9 | (1 << 8) | (0x9abcdef1 << 20) | (7 << 16) | bit(53) | sa << 54 | sb << 55, \
                f"(uint)((uint64_t)({A} * {B}) >> 32)"


def rejected_cases():
    yield "SHF reserved max shift", enc(0x5cf8, 1 << 37, 3)
    for shift in (31, 33, 35):
        yield f"IADD3 reserved half at {shift}", enc(0x5cc0, 3 << shift, 3)
    yield "IADD3 reserved shift", enc(0x5cc0, 3 << 37, 3)
    for flag in (47, 48):
        yield f"IADD3 shift with flag {flag}", enc(0x5cc0, (1 << 37) | bit(flag), 3)


def main():
    os.makedirs(OUT, exist_ok=True)
    gen = os.path.join(OUT, "gen")
    open(gen + ".c", "w").write(GEN)
    mx = os.path.join(ROOT, "runtime", "nvn", "maxwell")
    subprocess.check_call([os.environ.get("CC", "cc"), "-O1", "-w", "-I", mx, gen + ".c", os.path.join(mx, "translate.c"), "-o", gen, "-lm"])
    rejected = 0
    for name, word in rejected_cases():
        result = subprocess.run([gen, "%016x" % word], capture_output=True, text=True)
        if result.returncode != 1 or not result.stdout.startswith("FAIL "):
            print("unsupported encoding was not explicitly rejected: %s" % name)
            return 1
        rejected += 1
    print("%d unsupported encodings explicitly rejected" % rejected, flush=True)
    src = [PRELUDE, "int main() { int bad = 0;"]
    n = 0
    for name, word, ref in cases():
        expr = subprocess.run([gen, "%016x" % word], capture_output=True, text=True).stdout.strip().rstrip(";")
        if not expr or expr.startswith("FAIL"):
            print("no translation: %s (%s)" % (name, expr))
            return 1
        n += 1
        src.append(f'{{ int e = 0; for (int k = 0; k < 200000; k++) {{ uint r1 = k % 5 ? rnd() : edge[(k / 5) % 16], '
                   f'r2 = k % 3 == 0 ? edge[k % 16] : k % 3 == 1 ? rnd() & 127 : rnd(), r3 = rnd(); uint got = (uint)({expr}), '
                   f'want = (uint)({ref}); if (got != want && e++ < 2) printf("%s: r1 %08x r2 %08x r3 %08x: %08x, want %08x\\n", '
                   f'"{name}", r1, r2, r3, got, want); }} bad += e != 0; }}')
    src.append(f'printf("%d of {n} cases differ\\n", bad); return bad != 0; }}')
    open(os.path.join(OUT, "sem.cpp"), "w").write("\n".join(src))
    subprocess.check_call([os.environ.get("CXX", "c++"), "-O1", "-w", os.path.join(OUT, "sem.cpp"), "-o", os.path.join(OUT, "sem")])
    return subprocess.call([os.path.join(OUT, "sem")])


if __name__ == "__main__":
    sys.exit(main())
