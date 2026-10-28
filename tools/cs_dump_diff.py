#!/usr/bin/env python3
"""Which words of a compute dispatch's buffers depend on the internal resolution. Needs a run with LARECOMP_CS_DUMP=1 and
"trace 3" captures at two scales (runtime/nvn/renderer.m cs_audit): the game log (for its "[scale] frame N ... render
scale S" lines) and build/csdump. Words that differ between two frames of the same scale are ignored (time, jitter).

usage: tools/cs_dump_diff.py play.log build/csdump
"""
import collections
import os
import re
import struct
import sys


def main():
    log, d = sys.argv[1], sys.argv[2]
    scales = sorted((int(m[0]), m[1]) for m in re.findall(r"\[scale\] frame (\d+) .*render scale ([\d.]+)x", open(log, errors="replace").read()))

    def scale_of(frame):
        s = None
        for f, v in scales:
            if f <= frame:
                s = v
        return s

    groups = collections.defaultdict(lambda: collections.defaultdict(list))  # (cs, buf) -> scale -> [(frame, bytes)]
    for name in sorted(os.listdir(d)):
        m = re.fullmatch(r"f(\d+)_([0-9a-f]+)_([su]\d+)\.bin", name)
        if m:
            frame = int(m[1])
            groups[(m[2], m[3])][scale_of(frame)].append((frame, open(os.path.join(d, name), "rb").read()))
    for (cs, buf), by in sorted(groups.items()):
        if len(by) < 2:
            continue
        sc = sorted(by, key=lambda s: float(s or 0))
        a, b = by[sc[0]], by[sc[-1]]
        n = min(len(a[-1][1]), len(b[-1][1])) // 4
        w = lambda blob: struct.unpack("<%dI" % n, blob[:n * 4])
        noisy = set()
        for grp in (a, b):
            for (_, x), (_, y) in zip(grp, grp[1:]):
                noisy |= {i for i, (p, q) in enumerate(zip(w(x), w(y))) if p != q}
        wa, wb = w(a[-1][1]), w(b[-1][1])
        diff = [i for i in range(n) if wa[i] != wb[i] and i not in noisy]
        if diff:
            print("cs=%s %s: %d of %d words differ at scale %s vs %s (%d changing every frame ignored)" % (cs, buf, len(diff), n, sc[0], sc[-1], len(noisy)))
            for i in diff[:12]:
                print("  +%#x  %08x (%g)  ->  %08x (%g)" % (i * 4, wa[i], struct.unpack("<f", struct.pack("<I", wa[i]))[0], wb[i], struct.unpack("<f", struct.pack("<I", wb[i]))[0]))


main()
