# Pokémon Z-A's game files, read-only: the ONEPACK file system (arc/data.trpfs: packs of Oodle-compressed files,
# flatbuffers), SARC archives (the UI layouts) and BNTX texture containers. Oodle through ooz built as a library
# (https://github.com/powzix/ooz, a C export `int ooz_decompress(src, src_len, dst, dst_len)`; see
# prompt_textures.py's header). Used by tools/za/prompt_textures.py.
import ctypes, mmap, os, struct


class Oodle:
    def __init__(self, path):
        self.lib = ctypes.CDLL(os.path.abspath(path))
        self.lib.ooz_decompress.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]

    def unpack(self, comp, size, raw):
        if comp == 0xFF or size == len(raw): return bytes(raw)
        out = ctypes.create_string_buffer(size + 64)
        if self.lib.ooz_decompress(bytes(raw), len(raw), out, size) != size: raise ValueError('ooz')
        return out.raw[:size]


class FB:  # flatbuffers, just what the tables here need
    def __init__(s, m): s.m = m
    def u32(s, p): return struct.unpack_from('<I', s.m, p)[0]
    def u64(s, p): return struct.unpack_from('<Q', s.m, p)[0]
    def table(s, p):
        vt = p - struct.unpack_from('<i', s.m, p)[0]
        n = (struct.unpack_from('<H', s.m, vt)[0] - 4) // 2
        return [(p + o) if (o := struct.unpack_from('<H', s.m, vt + 4 + 2 * i)[0]) else None for i in range(n)]
    def vec(s, fp):
        v = fp + s.u32(fp)
        return s.u32(v), v + 4


def pack_files(path, oodle, max_size=64 << 20):
    """every file in data.trpfs, decompressed: yields (pack index, file hash, bytes)"""
    f = open(path, 'rb')
    m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    fb = FB(m)
    assert m[:8] == b'ONEPACK\0', 'not a ONEPACK file'
    root = fb.u64(8)
    n, op = fb.vec(fb.table(root + fb.u32(root))[1])
    for i in range(n):
        off = fb.u64(op + 8 * i)
        t = fb.table(off + fb.u32(off))
        nh, hp = fb.vec(t[0])
        nf, fp = fb.vec(t[1])
        for j in range(nf):
            e = fp + 4 * j
            ft = fb.table(e + fb.u32(e))
            comp = m[ft[1]] if len(ft) > 1 and ft[1] else 0xFF
            size = fb.u64(ft[3]) if len(ft) > 3 and ft[3] else 0
            dn, dp = fb.vec(ft[4])
            if size > max_size: continue
            try:
                yield i, fb.u64(hp + 8 * j), oodle.unpack(comp, size, m[dp:dp + dn])
            except ValueError:
                continue


def sarc_files(d):
    """(name, bytes) of each file in a SARC archive"""
    sfat = struct.unpack_from('<H', d, 4)[0]
    doff = struct.unpack_from('<I', d, 0x0C)[0]
    n = struct.unpack_from('<H', d, sfat + 6)[0]
    names = sfat + 0xC + 0x10 * n + 8
    for i in range(n):
        _, attr, s, e = struct.unpack_from('<IIII', d, sfat + 0xC + 0x10 * i)
        name = ''
        if attr & 0x01000000:
            q = names + (attr & 0xFFFF) * 4
            name = d[q:d.index(b'\0', q)].decode('latin1')
        yield name, d[doff + s:doff + e]


class Tex:
    def __init__(s, **k): s.__dict__.update(k)


def bntx_textures(d):
    """the textures of a BNTX file: name, format, size, mip count, array layers, depth, block height (log2) and their
    data (every mip level, as stored: what the game hands the GPU)"""
    cnt = struct.unpack_from('<I', d, 0x24)[0]
    infos = struct.unpack_from('<Q', d, 0x28)[0]
    for i in range(cnt):
        t = struct.unpack_from('<Q', d, infos + 8 * i)[0]
        if d[t:t + 4] != b'BRTI': continue
        mips = struct.unpack_from('<H', d, t + 0x16)[0]
        fmt = struct.unpack_from('<I', d, t + 0x1C)[0]
        w, h, depth, layers, bh = struct.unpack_from('<IIIII', d, t + 0x24)
        size = struct.unpack_from('<I', d, t + 0x50)[0]
        no = struct.unpack_from('<Q', d, t + 0x60)[0]
        m0 = struct.unpack_from('<Q', d, struct.unpack_from('<Q', d, t + 0x70)[0])[0]
        name = d[no + 2:no + 2 + struct.unpack_from('<H', d, no)[0]].decode('latin1')
        yield Tex(name=name, fmt=fmt, w=w, h=h, mips=mips, depth=depth, layers=layers, bh=bh, data=d[m0:m0 + size])


def all_textures(romfs, oodle, mods=None):
    """every texture of the game (packs: standalone BNTX files and the UI's SARC archives), then the mods' UI archives
    and BNTX files: yields (where, Tex)"""
    for pi, fh, d in pack_files(os.path.join(romfs, 'arc', 'data.trpfs'), oodle):
        if d[:4] == b'BNTX':
            for t in bntx_textures(d): yield 'pack%d' % pi, t
        elif d[:4] == b'SARC':
            for name, f in sarc_files(d):
                if f[:4] == b'BNTX':
                    for t in bntx_textures(f): yield 'pack%d/%s' % (pi, name), t
    for root, _, names in os.walk(mods) if mods and os.path.isdir(mods) else ():
        for nm in names:
            p = os.path.join(root, nm)
            with open(p, 'rb') as f: d = f.read()
            if d[:4] == b'BNTX':
                for t in bntx_textures(d): yield p, t
            elif d[:4] == b'SARC':
                for name, f2 in sarc_files(d):
                    if f2[:4] == b'BNTX':
                        for t in bntx_textures(f2): yield p, t
