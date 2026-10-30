"""NSO loader: decompress segments, build the memory image, parse MOD0/dynamic info."""
import hashlib
import struct
import sys
import lz4.block

DT_NULL, DT_NEEDED, DT_PLTRELSZ, DT_HASH, DT_STRTAB, DT_SYMTAB, DT_RELA, DT_RELASZ = 0, 1, 2, 4, 5, 6, 7, 8
DT_STRSZ, DT_JMPREL, DT_RELACOUNT = 10, 23, 0x6FFFFFF9
DT_INIT, DT_FINI, DT_INIT_ARRAY, DT_FINI_ARRAY, DT_INIT_ARRAYSZ, DT_FINI_ARRAYSZ = 12, 13, 25, 26, 27, 28
DT_RELRSZ, DT_RELR = 35, 36
R_AARCH64_ABS64, R_AARCH64_GLOB_DAT, R_AARCH64_JUMP_SLOT, R_AARCH64_RELATIVE = 257, 1025, 1026, 1027
# Bound parser allocations; the runtime also enforces each module's smaller
# address window (128 MiB for main, up to the HLE region for sdk).
MAX_IMAGE_SIZE = 0x80000000


class Nso:
    def __init__(self, path):
        with open(path, 'rb') as f:
            raw = f.read()
        if len(raw) < 0x100 or raw[:4] != b'NSO0':
            raise ValueError(f'{path}: invalid or truncated NSO header')
        flags = struct.unpack_from('<I', raw, 0xC)[0]
        self.build_id = raw[0x40:0x60].rstrip(b'\0').hex()
        headers = []
        for i in range(3):
            file_off, mem_off, dec_size = struct.unpack_from('<III', raw, 0x10 + i * 0x10)
            stored_size = struct.unpack_from('<I', raw, 0x60 + i * 4)[0] if flags & (1 << i) else dec_size
            if file_off > len(raw) or stored_size > len(raw) - file_off:
                raise ValueError(f'{path}: truncated NSO segment {i}')
            if headers and mem_off < headers[-1][1] + headers[-1][2]:
                raise ValueError(f'{path}: NSO segment {i} overlaps the previous segment')
            if flags & (1 << i) and dec_size > stored_size * 255:
                raise ValueError(f'{path}: impossible decompressed size for NSO segment {i}')
            headers.append((file_off, mem_off, dec_size, stored_size))
        self.bss_size = struct.unpack_from('<I', raw, 0x3C)[0]
        self.text, self.rodata, self.data = [(h[1], h[2]) for h in headers]
        end = self.data[0] + self.data[1] + self.bss_size
        if end > MAX_IMAGE_SIZE:
            raise ValueError(f'{path}: NSO image exceeds the supported size')
        self.size = (end + 0xFFF) & ~0xFFF
        img = bytearray(self.size)
        for i, (file_off, mem_off, dec_size, stored_size) in enumerate(headers):
            data = raw[file_off:file_off + stored_size]
            if flags & (1 << i):
                try:
                    data = lz4.block.decompress(data, uncompressed_size=dec_size)
                except lz4.block.LZ4BlockError as e:
                    raise ValueError(f'{path}: invalid compressed NSO segment {i}') from e
            if len(data) != dec_size:
                raise ValueError(f'{path}: NSO segment {i} decompressed size does not match its header')
            if flags & (1 << (3 + i)):
                expected = raw[0xA0 + i * 32:0xC0 + i * 32]
                if hashlib.sha256(data).digest() != expected:
                    raise ValueError(f'{path}: NSO segment {i} hash mismatch')
            img[mem_off:mem_off + dec_size] = data
        self.image = img
        self._parse_mod0()

    def _range(self, off, size, what):
        if off < 0 or size < 0 or off > len(self.image) or size > len(self.image) - off:
            raise ValueError(f'NSO {what} is outside the module image')

    def u32(self, off):
        self._range(off, 4, 'word')
        return struct.unpack_from('<I', self.image, off)[0]

    def u64(self, off):
        self._range(off, 8, 'word')
        return struct.unpack_from('<Q', self.image, off)[0]

    def _parse_mod0(self):
        mod0 = self.u32(4)
        self._range(mod0, 28, 'MOD0 header')
        if self.image[mod0:mod0 + 4] != b'MOD0':
            raise ValueError('invalid NSO MOD0 header')
        rel = lambda i: mod0 + struct.unpack_from('<i', self.image, mod0 + 4 + i * 4)[0]
        self.dynamic, self.bss_start, self.bss_end = rel(0), rel(1), rel(2)
        self.eh_start, self.eh_end, self.module_obj = rel(3), rel(4), rel(5)
        dyn = {}
        needed = []
        off = self.dynamic
        while True:
            self._range(off, 16, 'dynamic table')
            tag, val = self.u64(off), self.u64(off + 8)
            off += 16
            if tag == DT_NULL:
                break
            if tag == DT_NEEDED:
                needed.append(val)
            dyn.setdefault(tag, val)
        self.dyn = dyn
        for tag in (DT_INIT, DT_FINI):
            addr = dyn.get(tag, 0)
            if addr and (addr % 4 or not self.text[0] <= addr <= self.text[0] + self.text[1] - 4):
                raise ValueError('NSO constructor entry is outside text')
        for addr_tag, size_tag in ((DT_INIT_ARRAY, DT_INIT_ARRAYSZ), (DT_FINI_ARRAY, DT_FINI_ARRAYSZ)):
            addr, size = dyn.get(addr_tag, 0), dyn.get(size_tag, 0)
            if addr % 8 or size % 8 or (size and addr_tag not in dyn):
                raise ValueError('invalid NSO constructor array')
            self._range(addr, size, 'constructor array')
        strtab = dyn.get(DT_STRTAB, 0)
        self.strtab = strtab
        self._range(strtab, dyn.get(DT_STRSZ, 0), 'string table')
        self.strtab_end = strtab + dyn[DT_STRSZ] if DT_STRSZ in dyn else len(self.image)
        self.needed = [self.cstr(strtab + n) for n in needed]
        # dynsym count from DT_HASH nchain
        self.syms = []
        if DT_HASH in dyn and DT_SYMTAB in dyn:
            self._range(dyn[DT_HASH], 8, 'hash table')
            nchain = self.u32(dyn[DT_HASH] + 4)
            st = dyn[DT_SYMTAB]
            self._range(st, nchain * 24, 'symbol table')
            for i in range(nchain):
                o = st + i * 24
                name, info, other, shndx = struct.unpack_from('<IBBH', self.image, o)
                value, size = struct.unpack_from('<QQ', self.image, o + 8)
                self.syms.append((self.cstr(strtab + name), info, shndx, value, size))
        self.relocs = []
        # RELR (newer SDKs): packed relative relocations, listed as RELATIVE with the word's own value as addend
        relr, relr_size, where = dyn.get(DT_RELR, 0), dyn.get(DT_RELRSZ, 0), None
        if relr_size % 8 or (relr_size and DT_RELR not in dyn):
            raise ValueError('invalid NSO RELR table size')
        self._range(relr, relr_size, 'RELR table')
        relr_n = relr_size // 8
        for i in range(relr_n):
            e = self.u64(relr + i * 8)
            if not e & 1:
                self.relocs.append((e, R_AARCH64_RELATIVE, 0, self.u64(e)))
                where = e + 8
                continue
            if where is None:
                raise ValueError('NSO RELR bitmap precedes its base address')
            for b in range(1, 64):
                if (e >> b) & 1:
                    a = where + (b - 1) * 8
                    self.relocs.append((a, R_AARCH64_RELATIVE, 0, self.u64(a)))
            where += 63 * 8
        for base_tag, size_tag in ((DT_RELA, DT_RELASZ), (DT_JMPREL, DT_PLTRELSZ)):
            if dyn.get(size_tag, 0) and base_tag not in dyn:
                raise ValueError('NSO RELA table has no address')
            if base_tag in dyn:
                b, size = dyn[base_tag], dyn.get(size_tag, 0)
                if size % 24:
                    raise ValueError('invalid NSO RELA table size')
                self._range(b, size, 'RELA table')
                n = size // 24
                for i in range(n):
                    r_off, r_info, r_add = struct.unpack_from('<QQq', self.image, b + i * 24)
                    self._range(r_off, 8, 'relocation target')
                    self.relocs.append((r_off, r_info & 0xFFFFFFFF, r_info >> 32, r_add))

    def cstr(self, off):
        self._range(off, 1, 'string')
        if off < self.strtab or off >= self.strtab_end:
            raise ValueError('NSO string is outside the string table')
        end = self.image.find(b'\0', off, self.strtab_end)
        if end < 0:
            raise ValueError('unterminated NSO string')
        return self.image[off:end].decode('utf-8', 'replace')

    def imports(self):
        return [s for s in self.syms if s[0] and s[2] == 0]

    def exports(self):
        return [s for s in self.syms if s[0] and s[2] != 0]


if __name__ == '__main__':
    from collections import Counter
    for p in sys.argv[1:]:
        n = Nso(p)
        print(f'== {p}  build {n.build_id[:16]}  image 0x{n.size:x}')
        print(f'  text 0x{n.text[0]:x}+0x{n.text[1]:x}  ro 0x{n.rodata[0]:x}+0x{n.rodata[1]:x}  '
              f'data 0x{n.data[0]:x}+0x{n.data[1]:x}  bss 0x{n.bss_size:x}')
        print(f'  needed {n.needed}  syms {len(n.syms)}  imports {len(n.imports())}  exports {len(n.exports())}')
        print(f'  relocs {dict(Counter(r[1] for r in n.relocs))}')
