"""Index shaders from the user's files into a PRIVATE input cache, never a release asset.

Usage: tools/venv/bin/python tools/za/shader_inputs.py extracted build/shader-inputs [--ooz /path/to/libooz.dylib]
The optional external decoder is the same interface used by trinity.py; it is not bundled with the app.
Only executable BNSH containers are indexed without it. No shader code is printed.
"""
import argparse
import hashlib
import json
import mmap
from pathlib import Path
import struct
import subprocess
import tempfile
import sys

LIMIT = 16 << 20


def shader_spans(data):
    """Validated (stage, decoded offset, length, constant offset, constant size)."""
    pos = 0
    while True:
        base = data.find(b'BNSH\0\0\0\0', pos)
        if base < 0:
            return
        pos = base + 8
        if base + 0x20 > len(data) or data[base + 0xC:base + 0xE] != b'\xff\xfe':
            continue
        size = struct.unpack_from('<I', data, base + 0x1C)[0]
        first = struct.unpack_from('<H', data, base + 0x16)[0]
        if size < 0x40 or size > len(data) - base or first + 0x28 > size:
            continue
        if data[base + first:base + first + 4] != b'grsc':
            continue
        nvar = struct.unpack_from('<I', data, base + first + 0x1C)[0]
        pvar = struct.unpack_from('<Q', data, base + first + 0x20)[0]
        if pvar > size or nvar > min(100000, (size - pvar) // 0x40):
            continue
        for variant in range(nvar):
            program = struct.unpack_from('<Q', data, base + pvar + variant * 0x40 + 0x10)[0]
            if not program or program + 0x38 > size:
                continue
            for slot in range(6):
                section = struct.unpack_from('<Q', data, base + program + 8 + 8 * slot)[0]
                if not section or section + 0x20 > size:
                    continue
                control, code, code_size = struct.unpack_from('<QQI', data, base + section + 8)
                if control + 0x750 > size or code > size or code_size > size - code:
                    continue
                cs, co = struct.unpack_from('<II', data, base + control + 0x6FC)
                if co < 16 or co > code_size or cs > code_size - co or co + cs > LIMIT:
                    continue
                magic = struct.unpack_from('<I', data, base + code)[0]
                header = struct.unpack_from('<I', data, base + code + 0x30)[0] if co >= 0x34 else 0
                stage = {1: 0, 5: 1, 4: 2, 2: 3, 3: 4}.get((header >> 10) & 15, 5) if magic == 0x12345678 else 5
                yield stage, base + code, co + cs, co, cs


def index_container(data, origin, out, shaders):
    for stage, offset, length, co, cs in shader_spans(data):
        code = data[offset:offset + length]
        digest = hashlib.sha256(code).hexdigest()
        if digest in shaders:
            continue
        path = out / (digest + '.bin')
        if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            tmp = path.with_suffix('.tmp')
            tmp.write_bytes(code)
            tmp.replace(path)
        shaders[digest] = dict(stage=stage, size=length, const_offset=co, const_size=cs,
                               origin=dict(origin, decoded_offset=offset))


def trinity_entries(root, decoder):
    import trinity
    metadata = (root / 'arc/data.trpfd').read_bytes()
    fb = trinity.FB(metadata)
    n, p = fb.vec(fb.table(fb.u32(0))[1])
    names = {}
    for i in range(n):
        e = p + 4 * i
        s = e + fb.u32(e)
        name = metadata[s + 4:s + 4 + fb.u32(s)].decode()
        if 'shader' not in name.lower():
            continue
        h = 0xCBF29CE484222645  # Trinity's path hash seed
        for c in name.encode():
            h = ((h ^ c) * 0x100000001B3) & ((1 << 64) - 1)
        names[h] = name
    with (root / 'arc/data.trpfs').open('rb') as source:
        with mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as data:
            fb = trinity.FB(data)
            if data[:8] != b'ONEPACK\0':
                raise ValueError('not a Trinity ONEPACK archive')
            p = fb.u64(8)
            table = fb.table(p + fb.u32(p))
            nh, hp = fb.vec(table[0])
            np, op = fb.vec(table[1])
            for i in range(min(nh, np)):
                pack = fb.u64(hp + 8 * i)
                if pack not in names:
                    continue
                off = fb.u64(op + 8 * i)
                entries = fb.table(off + fb.u32(off))
                nf, fp = fb.vec(entries[1])
                _, hashes = fb.vec(entries[0])
                for j in range(nf):
                    e = fp + 4 * j
                    ft = fb.table(e + fb.u32(e))
                    comp = data[ft[1]] if len(ft) > 1 and ft[1] else 255
                    size = fb.u64(ft[3]) if len(ft) > 3 and ft[3] else 0
                    stored, start = fb.vec(ft[4])
                    if size > 128 << 20:
                        continue
                    raw = data[start:start + stored]
                    decoded = decoder.unpack(comp, size, raw)
                    yield decoded, dict(kind='trinity', path='arc/data.trpfs', pack=names[pack],
                                        entry=f'{fb.u64(hashes + 8 * j):016x}', offset=start, stored_size=stored,
                                        decoded_size=len(decoded), codec=comp,
                                        source_sha256=hashlib.sha256(raw).hexdigest())


class ExternalDecoder:
    """Developer-only oozdec protocol: little-endian output length + compressed input."""
    def __init__(self, executable):
        self.executable = str(Path(executable).resolve())

    def unpack(self, comp, size, raw):
        if comp == 255 or size == len(raw):
            return bytes(raw)
        with tempfile.TemporaryDirectory(prefix='monzamac-shader-input-') as tmp:
            source, dest = Path(tmp) / 'input', Path(tmp) / 'output'
            source.write_bytes(struct.pack('<Q', size) + raw)
            subprocess.run([self.executable, str(source), str(dest)], check=True, timeout=30,
                           stdout=subprocess.DEVNULL)
            data = dest.read_bytes()
            if len(data) != size:
                raise ValueError('decoder output length mismatch')
            return data


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('game', type=Path)
    ap.add_argument('output', type=Path)
    decoder = ap.add_mutually_exclusive_group()
    decoder.add_argument('--ooz', help='optional external Oodle library (trinity.py interface)')
    decoder.add_argument('--ooz-exe', help='optional external oozdec executable (8-byte size-prefix protocol)')
    args = ap.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from nso import Nso
    shaders = {}
    sources = {}
    for module in ('main', 'sdk'):
        path = args.game / 'exefs' / module
        sources['exefs/' + module] = hashlib.sha256(path.read_bytes()).hexdigest()
        index_container(Nso(str(path)).image, dict(kind='nso', path='exefs/' + module,
                                                 source_sha256=sources['exefs/' + module]), args.output, shaders)
    embedded = len(shaders)
    if args.ooz or args.ooz_exe:
        import trinity
        decoder = trinity.Oodle(args.ooz) if args.ooz else ExternalDecoder(args.ooz_exe)
        for data, origin in trinity_entries(args.game / 'romfs', decoder):
            index_container(data, origin, args.output, shaders)
    index = dict(version=1, sources=sources, shaders=shaders)
    tmp = args.output / 'index.json.tmp'
    tmp.write_text(json.dumps(index, sort_keys=True, indent=2) + '\n')
    tmp.replace(args.output / 'index.json')
    print(f'Indexed {len(shaders)} unique shader inputs ({embedded} executable, {len(shaders)-embedded} archive); private cache only.')


if __name__ == '__main__':
    main()
