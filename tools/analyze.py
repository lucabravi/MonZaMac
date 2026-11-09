"""Function discovery and instruction census for an NSO module."""
import struct
import sys
from collections import Counter

import capstone
from nso import Nso, R_AARCH64_RELATIVE


def encoded_format(enc):
    fmt = {0x0B: '<i', 0x03: '<I', 0x0C: '<q', 0x04: '<Q'}.get(enc & 0x0F)
    if fmt is None or enc & 0x80 or (enc & 0x70) not in (0, 0x10, 0x30):
        raise ValueError(f'unsupported encoding {enc:#x}')
    return fmt, struct.calcsize(fmt)


def read_encoded(img, off, enc, pc_base, end=None):
    fmt, size = encoded_format(enc)
    end = len(img) if end is None else end
    if off < 0 or off + size > end or end > len(img):
        raise ValueError('encoded value is outside .eh_frame_hdr')
    v = struct.unpack_from(fmt, img, off)[0]
    app = enc & 0x70
    if app == 0x10:
        v += off
    elif app == 0x30:
        v += pc_base
    return v, size


def eh_frame_functions(n):
    """Function start addresses from .eh_frame_hdr's binary search table."""
    img, hdr, end = n.image, n.eh_start, n.eh_end
    if hdr < 0 or end < hdr or end > len(img):
        raise ValueError('.eh_frame_hdr is outside the module image')
    if hdr == end:
        return []
    if end - hdr < 4:
        raise ValueError('truncated .eh_frame_hdr')
    ver, ptr_enc, cnt_enc, tbl_enc = img[hdr:hdr + 4]
    if ver != 1:
        raise ValueError(f'unsupported .eh_frame_hdr version {ver}')
    off = hdr + 4
    _, sz = read_encoded(img, off, ptr_enc, hdr, end)
    off += sz
    count, sz = read_encoded(img, off, cnt_enc, hdr, end)
    off += sz
    if count:
        _, sz = encoded_format(tbl_enc)
        if count < 0 or count > (end - off) // (2 * sz):
            raise ValueError('.eh_frame_hdr table count exceeds its declared range')
    starts = []
    for _ in range(count):
        loc, sz = read_encoded(img, off, tbl_enc, hdr, end)
        off += sz
        _, sz = read_encoded(img, off, tbl_enc, hdr, end)
        off += sz
        starts.append(loc)
    return starts


def discover(n):
    text_lo, text_hi = n.text[0], n.text[0] + n.text[1]
    in_text = lambda a: text_lo <= a < text_hi and a % 4 == 0
    funcs = {}
    for a in eh_frame_functions(n):
        if in_text(a):
            funcs[a] = 'eh'
    for name, info, shndx, value, size in n.syms:
        if shndx and in_text(value) and (info & 0xF) == 2:
            funcs.setdefault(value, 'sym')
    # Code pointers stored in data (vtables, callbacks)
    ptr_targets = set()
    for off, typ, sym, add in n.relocs:
        if typ == R_AARCH64_RELATIVE and in_text(add):
            ptr_targets.add(add)
    for a in ptr_targets:
        funcs.setdefault(a, 'ptr')
    # BL targets
    code = bytes(n.image[text_lo:text_hi])
    words = struct.unpack(f'<{len(code) // 4}I', code)
    for i, w in enumerate(words):
        if (w & 0xFC000000) == 0x94000000:
            imm = w & 0x03FFFFFF
            if imm & 0x02000000:
                imm -= 0x04000000
            t = text_lo + i * 4 + imm * 4
            if in_text(t):
                funcs.setdefault(t, 'bl')
    return funcs, words


def census(n, words):
    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
    c = Counter()
    bad = 0
    code = struct.pack(f'<{len(words)}I', *words)
    off = 0
    while off < len(code):
        got = False
        for ins in md.disasm_lite(code[off:], n.text[0] + off):
            c[ins[2]] += 1
            off += 4
            got = True
        if off < len(code):   # undecodable word: skip it
            bad += 1
            off += 4
    return c, bad


if __name__ == '__main__':
    n = Nso(sys.argv[1])
    funcs, words = discover(n)
    print(f'functions: {len(funcs)}  by source: {dict(Counter(funcs.values()))}')
    if '--census' in sys.argv:
        c, bad = census(n, words)
        print(f'instructions: {sum(c.values())}  undecodable words: {bad}  distinct mnemonics: {len(c)}')
        print(' '.join(f'{m}:{k}' for m, k in c.most_common()))
