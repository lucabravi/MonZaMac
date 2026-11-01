"""Summarize private shader-trace metadata; never reads/dumps shader code.

Usage: python tools/za/shader_trace_report.py <trace-directory> [--game extracted]
Archive names are candidates from recent reads, not proof of shader origin.
"""
import argparse
import collections
import json
import mmap
from pathlib import Path


def records(path):
    with path.open() as f:
        for n, line in enumerate(f, 1):
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                print(f'Warning: incomplete/invalid event at line {n}; skipped')
                continue
            if isinstance(row, dict):
                yield row


def archive_ranges(game):
    import trinity
    root = game / 'romfs' / 'arc'
    data = (root / 'data.trpfd').read_bytes()
    fb = trinity.FB(data)
    n, p = fb.vec(fb.table(fb.u32(0))[1])
    names = {}
    for i in range(n):
        e = p + 4*i
        s = e + fb.u32(e)
        name = data[s+4:s+4+fb.u32(s)].decode()
        h = 0xCBF29CE484222645
        for c in name.encode():
            h = ((h ^ c) * 0x100000001b3) & ((1 << 64)-1)
        names[h] = name
    spans = []
    with (root / 'data.trpfs').open('rb') as f:
        with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as data:
            if data[:8] != b'ONEPACK\0':
                raise ValueError('not a Trinity ONEPACK archive')
            fb = trinity.FB(data)
            p = fb.u64(8)
            t = fb.table(p + fb.u32(p))
            nh, hp = fb.vec(t[0])
            np, op = fb.vec(t[1])
            for i in range(min(nh, np)):
                pack = names.get(fb.u64(hp+8*i), '<unknown pack>')
                p = fb.u64(op+8*i)
                t = fb.table(p + fb.u32(p))
                nf, fp = fb.vec(t[1])
                for j in range(nf):
                    e = fp + 4*j
                    ft = fb.table(e + fb.u32(e))
                    length, start = fb.vec(ft[4])
                    spans.append((start, start+length, pack))
    spans.sort()
    return spans


def overlapping_packs(spans, first, size):
    """Shared/overlapping payloads must all be retained; offsets are half-open."""
    if size <= 0:
        return set()
    end = first + size
    touched = set()
    for start, stop, pack in spans:
        if start >= end:
            break
        if stop > first:
            touched.add(pack)
    return touched


def summarize(path, game=None):
    rows = list(records(path / 'events.jsonl'))
    stages = [r for r in rows if r.get('kind') == 'shader']
    compiles = [r for r in rows if r.get('kind') == 'compile']
    counts = collections.Counter(r['operation'] for r in compiles)
    times = collections.defaultdict(float)
    for r in compiles:
        times[r['operation']] += r['ms']
    print(f'{len(stages)} distinct shader inputs; {len(compiles)} compilation/archive events')
    for kind, n in counts.items():
        print(f'  {kind}: {n}, {times[kind]:.3f} ms aggregate wall latency')
    spans = archive_ranges(game) if game else []
    for r in stages:
        print(f"\nStage {r['stage']}, hash {r['hash']}, frame {r['frame']}, {r['size']} bytes")
        for c in r['callers'][:8]:
            symbol = c['symbol']
            suffix = f" nearest exported symbol {symbol}+{c['symbol_offset']}" if symbol != '?' else ''
            print(f"  caller {c['pc']}{suffix}")
        print(f"  {len(r['read_candidates'])} address-range candidates; {len(r['recent_reads'])} recent reads")
        first_build = next((e for e in compiles if e['operation'] == 'program' and
                            e.get('epoch') == r.get('epoch') and e['ns'] >= r['ns'] and
                            r['code_address'] in (e['vs'], e['fs'])), None)
        if first_build:
            print(f"  registration -> first program completion: {(first_build['ns']-r['ns'])/1e6:.3f} ms "
                  f"(frame {r['frame']} -> {first_build['frame']})")
        candidates = collections.Counter()
        for read in r['recent_reads']:
            if read['path'] != 'arc/data.trpfs' or not spans:
                continue
            touched = overlapping_packs(spans, read['offset'], read['size'])
            candidates.update(touched)
        shader_candidates = [(name, n) for name, n in candidates.most_common() if any(x in name.lower() for x in ("shader", ".arc.", ".ptcl."))]
        ordered = shader_candidates[:8] + [(name, n) for name, n in candidates.most_common(4) if (name, n) not in shader_candidates[:8]]
        for name, n in ordered:
            print(f'  recent archive candidate ({n} read overlaps): {name}')
    return dict(shaders=len(stages), compile_counts=dict(counts), compile_ms=dict(times))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('trace', type=Path)
    p.add_argument('--game', type=Path)
    a = p.parse_args()
    summarize(a.trace, a.game)


if __name__ == '__main__':
    main()
