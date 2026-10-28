#!/usr/bin/env python3
"""Compare two game logs holding "[cs-out]" lines (the "trace n" live command, runtime/nvn/renderer.m cs_audit) taken in
the same still scene at different internal resolutions. Prints the compute dispatches whose storage-buffer contents
differ between the logs while each log is stable by itself: the ones whose output depends on the resolution.

usage: tools/cs_diff.py a.log b.log
"""
import collections
import sys


def load(path):
    frames = collections.OrderedDict()
    for line in open(path, errors="replace"):
        if not line.startswith("[cs-out]"):
            continue
        d = dict(t.split("=", 1) for t in line.split()[1:] if "=" in t)
        frames.setdefault(d["f"], []).append(d)
    return list(frames.values())


def outputs(frames, i):  # the distinct storage-buffer hashes of dispatch i over the traced frames
    return {tuple(sorted((k, v) for k, v in fr[i].items() if k[0] == "s" and k[1:].isdigit())) for fr in frames if i < len(fr)}


def main():
    a, b = load(sys.argv[1]), load(sys.argv[2])
    if not a or not b:
        sys.exit("no [cs-out] lines (send 'trace 3' to build/dbgcmd while the game runs)")
    na, nb = collections.Counter(map(len, a)), collections.Counter(map(len, b))
    print("dispatches per frame: a %s, b %s" % (dict(na), dict(nb)))
    n = min(max(na), max(nb))
    found = 0
    for i in range(n):
        da, db = a[-1][i], b[-1][i]
        if da["cs"] != db["cs"]:
            print("dispatch %d: different shader (%s / %s), the frames are not aligned from here" % (i, da["cs"], db["cs"]))
            break
        oa, ob = outputs(a, i), outputs(b, i)
        if oa.isdisjoint(ob) and len(oa) <= 2 and len(ob) <= 2 and any(oa) and any(ob):
            found += 1
            tex = " ".join(k + "=" + v for k, v in sorted(db.items()) if k[0] == "t" and k[1:].isdigit())
            print("dispatch %d cs=%s g=%s differs; textures (b): %s" % (i, da["cs"], da["g"], tex or "none"))
    print("%d dispatches with a stable, different output" % found)


main()
