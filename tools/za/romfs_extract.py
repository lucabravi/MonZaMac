# Copies files out of a RomFS image (romfs.bin) into a folder: by default arc/ (Pokémon Z-A's packs and their list,
# what tools/za/prompt_textures.py reads).
# usage: python tools/za/romfs_extract.py <romfs.bin> <out folder> [path prefix, default arc/]
import os, struct, sys

img, out = sys.argv[1], sys.argv[2]
prefix = sys.argv[3] if len(sys.argv) > 3 else 'arc/'
f = open(img, 'rb')
h = struct.unpack('<10Q', f.read(0x50))
doff, dsz, foff, fsz, data = h[3], h[4], h[7], h[8], h[9]
f.seek(doff); dm = f.read(dsz)
f.seek(foff); fm = f.read(fsz)


def dir_path(d):
    parts = []
    while d:
        parent, = struct.unpack_from('<I', dm, d)
        nl, = struct.unpack_from('<I', dm, d + 0x14)
        parts.append(dm[d + 0x18:d + 0x18 + nl].decode())
        d = parent
    return '/'.join(reversed(parts))


o = 0
while o + 0x20 <= fsz:
    parent, _, off, size, _, nl = struct.unpack_from('<IIQQII', fm, o)
    name = fm[o + 0x20:o + 0x20 + nl].decode()
    path = (dir_path(parent) + '/' if parent else '') + name
    o += 0x20 + ((nl + 3) & ~3)
    if not path.startswith(prefix): continue
    dst = os.path.join(out, path)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    f.seek(data + off)
    with open(dst, 'wb') as w:
        left = size
        while left:
            chunk = f.read(min(left, 64 << 20))
            w.write(chunk)
            left -= len(chunk)
    print(path, size)
