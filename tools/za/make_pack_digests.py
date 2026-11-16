#!/usr/bin/env python3
"""runtime/gamecheck_table.h: a 4-byte digest of each pack of arc/data.trpfs, from a copy of the game known to be clean.

Usage: make_pack_digests.py <version>=<path to data.trpfs> ... > runtime/gamecheck_table.h

The start screen (runtime/gamecheck.c) hashes the packs of the player's data.trpfs the same way and names the ones that
differ: a damaged download of the update crashes the game when it loads the damaged model. The table holds digests only,
no game data. A version's entry is picked by the file's size.
"""
import hashlib, mmap, struct, sys


def packs(m):
    """[(pack hash, start, end)] in the file's own order (data.trpfs: a flatbuffer after the 'ONEPACK' magic)"""
    u32 = lambda p: struct.unpack_from('<I', m, p)[0]
    u64 = lambda p: struct.unpack_from('<Q', m, p)[0]
    if m[:8] != b'ONEPACK\0': raise ValueError('not a ONEPACK file')
    root = u64(8)
    t = root + u32(root)
    vt = t - struct.unpack_from('<i', m, t)[0]
    f_hash, f_off = struct.unpack_from('<HH', m, vt + 4)
    hv = t + f_hash + u32(t + f_hash)
    ov = t + f_off + u32(t + f_off)
    n = u32(hv)
    offs = [u64(ov + 4 + 8 * i) for i in range(n)]
    ends = sorted(set(offs)) + [root if root > max(offs) else len(m)]
    nxt = {o: ends[k + 1] for k, o in enumerate(ends[:-1])}
    return [(u64(hv + 4 + 8 * i), offs[i], nxt[offs[i]]) for i in range(n)]


def digests(m):
    return [int.from_bytes(hashlib.sha256(m[a:b]).digest()[:4], 'big') for _, a, b in packs(m)]


if __name__ == '__main__':
    out = ['// Made by tools/za/make_pack_digests.py from a clean copy of each version: the first 4 bytes of the SHA-256 of',
           '// every pack of arc/data.trpfs, in the file\'s order. Digests only, no game data.', '']
    names = []
    for a in sys.argv[1:]:
        ver, path = a.split('=', 1)
        with open(path, 'rb') as f:
            m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
            d = digests(m)
            size = len(m)
        tag = ver.replace('.', '_')
        out.append(f'static const uint32_t gc_digests_{tag}[] = {{')
        for k in range(0, len(d), 8): out.append('    ' + ' '.join(f'0x{x:08x},' for x in d[k:k + 8]))
        out += ['};', '']
        names.append((size, ver, tag, len(d)))
        print(ver, size, len(d), 'packs', file=sys.stderr)
    out.append('static const struct { uint64_t size; const char *version; const uint32_t *digests; unsigned count; } gc_versions[] = {')
    for size, ver, tag, n in names: out.append(f'    {{{size}ull, "{ver}", gc_digests_{tag}, {n}}},')
    out.append('};')
    sys.stdout.write('\n'.join(out) + '\n')
