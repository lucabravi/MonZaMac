#!/usr/bin/env python3
"""Count the Maxwell encodings whose translation is known to differ from Ryujinx / yuzu (or that the references
disagree on) in dumped game shaders, so the open cases can be ranked by how often the game really uses them.

usage: tools/maxwell_audit.py [build/shaders/*_code.bin build/cs_*.bin ...]
Dumps: LARECOMP_DUMP_SHADERS=1 (graphics programs: build/shaders/<addr>_s<stage>_code.bin) and the compute programs
the renderer saves on first dispatch (build/cs_<n>.bin). Stage 5 / cs_* are compute (no SPH).
"""
import glob
import os
import struct
import sys
from collections import Counter, defaultdict


def bits(w, lo, n):
    return (w >> lo) & ((1 << n) - 1)


def op(w, val, mask):
    return (w & mask) == val


def is_(w, *pairs):
    return any(op(w, v << 48, m << 48) for v, m in pairs)


# (name, test) - the test sees one instruction word. "fixed" = handled since fix/maxwell-decode-audit.
CHECKS = [
    # fixed
    ("fixed: SHF .U64/.S64 (64-bit funnel shift)", lambda w: is_(w, (0x5cf8, 0xfff8), (0x5bf8, 0xfff8), (0x38f8, 0xfef8),
                                                                    (0x36f8, 0xfef8)) and bits(w, 37, 2) >= 2),
    ("fixed: SHF clamp with a register amount", lambda w: is_(w, (0x5cf8, 0xfff8), (0x5bf8, 0xfff8))
     and bits(w, 37, 2) != 1 and not bits(w, 50, 1)),
    ("rejected: SHF unsupported max shift 1", lambda w: is_(w, (0x5cf8, 0xfff8), (0x5bf8, 0xfff8),
                                                           (0x38f8, 0xfef8), (0x36f8, 0xfef8)) and bits(w, 37, 2) == 1),
    ("fixed: IADD3 half select / .LS / .RS", lambda w: is_(w, (0x5cc0, 0xfff0)) and bits(w, 31, 8) != 0
     and not any(bits(w, p, 2) == 3 for p in (31, 33, 35, 37)) and not (bits(w, 37, 2) and bits(w, 47, 2))),
    ("fixed: LOP3 register form writing a predicate", lambda w: is_(w, (0x5be0, 0xfff8)) and bits(w, 48, 3) != 7),
    ("fixed: FLO .SH / inverted source", lambda w: is_(w, (0x5c30, 0xfff8), (0x4c30, 0xfff8), (0x3830, 0xfef8)) and bits(w, 40, 2)),
    ("fixed: SHR .W / .BREV", lambda w: is_(w, (0x5c28, 0xfff8), (0x4c28, 0xfff8), (0x3828, 0xfef8)) and bits(w, 39, 2)),
    ("fixed: IMUL32I .HI same signedness", lambda w: is_(w, (0x1f00, 0xff00)) and bits(w, 53, 1)
     and bits(w, 54, 1) == bits(w, 55, 1)),
    ("rejected: IMUL32I .HI mixed signedness", lambda w: is_(w, (0x1f00, 0xff00)) and bits(w, 53, 1)
     and bits(w, 54, 1) != bits(w, 55, 1)),
    ("rejected: IADD3 reserved half / shift", lambda w: is_(w, (0x5cc0, 0xfff0))
     and any(bits(w, p, 2) == 3 for p in (31, 33, 35, 37))),
    ("rejected: IADD3 shift with .CC / .X", lambda w: is_(w, (0x5cc0, 0xfff0))
     and bits(w, 37, 2) != 0 and bits(w, 47, 2) != 0),
    ("rejected: IMUL .HI mixed signedness", lambda w: is_(w, (0x5c38, 0xfff8), (0x4c38, 0xfff8), (0x3838, 0xfef8))
     and bits(w, 39, 1) and bits(w, 40, 1) != bits(w, 41, 1)),
    # open
    ("open: SHF .CC / .HI / .X", lambda w: is_(w, (0x5cf8, 0xfff8), (0x5bf8, 0xfff8),
                                                        (0x38f8, 0xfef8), (0x36f8, 0xfef8)) and bits(w, 47, 3) != 0),
    ("open: TEXS 2D.LL.DC (Ryujinx: dref Rb, lod Rb+1; yuzu and the port: the reverse)",
     lambda w: op(w, 0xd000 << 48, 0xf600 << 48) and bits(w, 53, 4) == 5),
    ("open: ISETP / ISET .X (64-bit compare, the port compares the high word only)",
     lambda w: is_(w, (0x5b60, 0xfff0), (0x4b60, 0xfff0), (0x3660, 0xfef0), (0x5b50, 0xfff0), (0x4b50, 0xfff0),
                   (0x3650, 0xfef0)) and bits(w, 43, 1)),
    ("open: IADD / ISCADD .PO (both negate bits: the port negates A and B)",
     lambda w: is_(w, (0x5c10, 0xfff8), (0x4c10, 0xfff8), (0x3810, 0xfef8), (0x5c18, 0xfff8), (0x4c18, 0xfff8),
                   (0x3818, 0xfef8)) and bits(w, 48, 2) == 3),
    ("open: IADD32I negated immediate / .PO (bit 55, ignored)", lambda w: is_(w, (0x1c00, 0xfe00)) and bits(w, 55, 1)),
    ("open: IADD / IADD32I .SAT (ignored)", lambda w: (is_(w, (0x5c10, 0xfff8), (0x4c10, 0xfff8), (0x3810, 0xfef8)) and bits(w, 50, 1))
     or (is_(w, (0x1c00, 0xfe00)) and bits(w, 54, 1))),
    ("open: XMAD .X (C dropped, as Ryujinx; yuzu: unimplemented)",
     lambda w: (is_(w, (0x5b00, 0xffc0), (0x3600, 0xfec0)) and bits(w, 38, 1))
     or (is_(w, (0x4e00, 0xfe00), (0x5100, 0xff80)) and bits(w, 54, 1))),
    ("open: LDC sub-word size or address mode (read as a whole word)",
     lambda w: is_(w, (0xef90, 0xfff8)) and (bits(w, 48, 3) < 4 or bits(w, 44, 2) != 0)),
    ("open: ALD / AST .O / .P or attribute >= 0x400 (ignored)",
     lambda w: is_(w, (0xefd8, 0xfff8), (0xeff0, 0xfff8)) and (bits(w, 31, 2) or bits(w, 30, 1))),
    ("open: TXQ dimension reading z (depth / layers: the port returns 1)",
     lambda w: is_(w, (0xdf48, 0xfff8)) and bits(w, 22, 6) == 1 and bits(w, 31, 4) & 4),
    ("open: TEX .AOFFI on a 1D / 3D / cube target (2D offsets only)",
     lambda w: op(w, 0xc038 << 48, 0xfc38 << 48) and bits(w, 54, 1) and bits(w, 29, 2) != 1),
    ("open: PRMT immediate selector with sign replicate (bit 3 of a nibble, ignored)",
     lambda w: is_(w, (0x36c0, 0xfef0)) and any(bits(w, 20 + 4 * i, 4) & 8 for i in range(4))),
    ("open: I2I .SAT to/from 32 bits (clamped as signed)",
     lambda w: is_(w, (0x5ce0, 0xfff8), (0x4ce0, 0xfff8), (0x38e0, 0xfef8)) and bits(w, 50, 1)
     and (bits(w, 8, 2) == 2 or bits(w, 10, 2) == 2)),
    ("open: F2I / I2F / F2F with a 64-bit format",
     lambda w: is_(w, (0x5cb0, 0xfff8), (0x4cb0, 0xfff8), (0x38b0, 0xfef8), (0x5cb8, 0xfff8), (0x4cb8, 0xfff8),
                   (0x38b8, 0xfef8), (0x5ca8, 0xfff8), (0x4ca8, 0xfff8), (0x38a8, 0xfef8))
     and (bits(w, 8, 2) == 3 or bits(w, 10, 2) == 3)),
]


def instructions(path):
    data = open(path, "rb").read()
    compute = "_s5_" in path or os.path.basename(path).startswith("cs_")
    if compute:
        start = 0x100 if data[:4] == struct.pack("<I", 0x12345679) else 0
    else:
        start = 0x80
    n = (len(data) - start) // 8
    words = struct.unpack_from("<%dQ" % n, data, start)
    seen_exit = False
    for i, w in enumerate(words):  # (same end detection as maxwell_translate)
        if i % 4 == 0:
            continue
        if (w & 0xfff0000000000000) == 0xe240000000000000 and bits(w, 20, 24) == (1 << 24) - 8 and seen_exit:
            return
        if w == 0 and i > 4:
            return
        seen_exit = True
        yield i * 8, w


def main(paths):
    if not paths:
        paths = glob.glob("build/shaders/*_code.bin") + glob.glob("build/cs_*.bin")
    hits = Counter()
    where = defaultdict(list)
    for p in paths:
        for pc, w in instructions(p):
            for name, test in CHECKS:
                if test(w):
                    hits[name] += 1
                    if len(where[name]) < 3:
                        where[name].append("%s+%#x %016x" % (os.path.basename(p), pc, w))
    print("%d shader files" % len(paths))
    for name, _ in CHECKS:
        print("%6d  %s" % (hits[name], name))
        for x in where[name]:
            print("          %s" % x)


if __name__ == "__main__":
    main(sys.argv[1:])
