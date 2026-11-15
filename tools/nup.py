"""Minimal NUP container reader (SPEC.md v1): unencrypted NX dumps, no keys.

Only what the setup needs: package records, the file tree and per-file extents. Every offset is
bounds-checked before use, the TOC hash is verified before the TOC is trusted (SPEC §6.1), and each file's
content is checked against its SHA-256 as it is written.
zstd is imported only when a file is actually compressed, so a raw-only container needs no wheel.
"""
import hashlib
import struct

MAGIC = b'NUP\x01'
TOC_MAGIC = b'TOC\x01'
HEADER_SIZE = 0x80
NO_DIR = 0xFFFFFFFF
KIND_BASE, KIND_UPDATE, KIND_ADDON = 0, 1, 2
CODEC_RAW, CODEC_ZSTD = 0, 1

_SUPER = struct.Struct('<4sHHQQ32sQQII16s32s')  # 0x80
_TOC = struct.Struct('<4sIQQQQQ')               # 0x30
_PKG = struct.Struct('<QIIIIBBHIQI20x')         # 0x40
_DIR = struct.Struct('<IIIIQ')                  # 0x18
_FILE = struct.Struct('<IIQQQ32sBBH12x')        # 0x50


class NupError(ValueError):
    pass


class Package:
    __slots__ = ('title_id', 'root_dir', 'exefs_dir', 'romfs_dir', 'version', 'kind', 'flags')

    def __init__(self, title_id, root_dir, exefs_dir, romfs_dir, version, kind, flags):
        self.title_id, self.root_dir, self.exefs_dir, self.romfs_dir = title_id, root_dir, exefs_dir, romfs_dir
        self.version, self.kind, self.flags = version, kind, flags


class Nup:
    """Read a .nup in place. File contents are streamed out, never held whole in memory."""

    def __init__(self, path):
        self.path = path
        self.f = open(path, 'rb')
        try:
            self._read(path)
        except BaseException:
            self.f.close()
            raise

    def close(self):
        self.f.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def _read(self, path):
        f = self.f
        f.seek(0, 2)
        actual = f.tell()
        f.seek(0)
        head = f.read(HEADER_SIZE)
        if len(head) != HEADER_SIZE:
            raise NupError('short header')
        (magic, header_size, header_version, toc_off, toc_size, toc_hash, blob_off, file_size,
         pkg_count, flags, _uuid, _reserved) = _SUPER.unpack(head)
        if magic != MAGIC or header_version != 1 or header_size < HEADER_SIZE:
            raise NupError('not a NUP v1 container')
        if flags != 0 or file_size != actual or pkg_count < 1:
            raise NupError('inconsistent superblock')
        if toc_off != header_size or blob_off % 16 or blob_off < toc_off + toc_size:
            raise NupError('inconsistent regions')
        if toc_size > (64 << 20):
            raise NupError('TOC too large')
        f.seek(toc_off)
        toc = f.read(toc_size)
        if len(toc) != toc_size or hashlib.sha256(toc).digest() != toc_hash:
            raise NupError('TOC hash mismatch')
        magic, count, dir_count, file_count, pool_off, pool_size, _ = _TOC.unpack_from(toc)
        if magic != TOC_MAGIC or count != pkg_count:
            raise NupError('bad TOC')
        fixed = _TOC.size + count * _PKG.size + dir_count * _DIR.size + file_count * _FILE.size
        if fixed > toc_size or pool_off < fixed or pool_off + pool_size > toc_size:
            raise NupError('TOC bounds')
        if dir_count > 1 << 20 or file_count > 1 << 22:
            raise NupError('TOC counts')
        pos = _TOC.size
        self.packages = []
        for _ in range(count):
            title, root, exefs, romfs, version, kind, pflags, _r, _r2, _mo, _ms = _PKG.unpack_from(toc, pos)
            pos += _PKG.size
            self.packages.append(Package(title, root, exefs, romfs, version, kind, pflags))
        self.dirs = []
        for _ in range(dir_count):
            name_off, name_len, first, n, _r = _DIR.unpack_from(toc, pos)
            pos += _DIR.size
            self.dirs.append((name_off, name_len, first, n))
        self.files = []
        for _ in range(file_count):
            name_off, name_len, size, ext_off, ext_size, sha, codec, _cf, _r = _FILE.unpack_from(toc, pos)
            pos += _FILE.size
            if codec not in (CODEC_RAW, CODEC_ZSTD) or (codec == CODEC_RAW and ext_size != size):
                raise NupError('file record')
            if size and (ext_off < blob_off or ext_off + ext_size > file_size):
                raise NupError('extent bounds')
            self.files.append((name_off, name_len, size, ext_off, ext_size, sha, codec))
        self.children = struct.unpack_from('<%dI' % ((pool_off - fixed) // 4), toc, pos)
        self.pool = toc[pool_off:pool_off + pool_size]
        for name_off, name_len, _f, _n in self.dirs:
            self._name(name_off, name_len, allow_empty=True)
        for name_off, name_len, *_ in self.files:
            self._name(name_off, name_len)
        for p in self.packages:
            for d in (p.root_dir, p.exefs_dir, p.romfs_dir):
                if d != NO_DIR and d >= dir_count:
                    raise NupError('package dir')
        for _o, _l, first, n in self.dirs:
            if first + n > len(self.children):
                raise NupError('children bounds')
        for c in self.children:
            if c >= dir_count + file_count:
                raise NupError('child id')

    def _name(self, off, size, allow_empty=False):
        if off + size > len(self.pool) or (not size and not allow_empty):
            raise NupError('name bounds')
        try:
            name = self.pool[off:off + size].decode('utf-8')
        except UnicodeError:
            raise NupError('name encoding') from None
        if name in ('.', '..') or '/' in name or '\\' in name or '\0' in name:
            raise NupError('name')
        return name

    def children_of(self, dir_index):
        _o, _l, first, n = self.dirs[dir_index]
        out = []
        for slot in range(first, first + n):
            cid = self.children[slot]
            out.append((cid < len(self.dirs), cid if cid < len(self.dirs) else cid - len(self.dirs)))
        return out

    def extract(self, dir_index, dest):
        """Write one package subtree under dest, creating parents; later calls overwrite."""
        import os
        seen = set()
        stack = [(dir_index, str(dest))]
        while stack:
            di, dpath = stack.pop()
            if di in seen:
                continue
            seen.add(di)
            os.makedirs(dpath, exist_ok=True)
            for is_dir, idx in self.children_of(di):
                if is_dir:
                    name = self._name(*self.dirs[idx][:2], allow_empty=True)
                    stack.append((idx, os.path.join(dpath, name)))
                else:
                    rec = self.files[idx]
                    path = os.path.join(dpath, self._name(rec[0], rec[1]))
                    with open(path, 'wb') as out:
                        self._copy_file(rec, out)

    def _copy_file(self, rec, out):
        _no, _nl, size, ext_off, ext_size, sha, codec = rec
        digest = hashlib.sha256()  # (of the content as written: a damaged container must not become a damaged game)
        written = 0
        if size:
            reader = _Slice(self.f, ext_off, ext_size)
            if codec == CODEC_ZSTD:
                try:
                    import zstandard
                except ImportError:
                    raise NupError('zstd support is missing') from None
                reader = zstandard.ZstdDecompressor().stream_reader(reader, read_size=1 << 20)
            while True:
                try:
                    chunk = reader.read(8 << 20)
                except Exception as e:  # (zstandard.ZstdError: a broken frame)
                    if isinstance(e, OSError): raise
                    raise NupError('compressed data') from None
                if not chunk:
                    break
                written += len(chunk)
                if written > size:
                    raise NupError('file size mismatch')
                digest.update(chunk)
                out.write(chunk)
        if written != size:
            raise NupError('file size mismatch')
        if digest.digest() != sha:
            raise NupError('file hash mismatch')


class _Slice:
    """A bounded read-only view of the container, the frame's extent."""

    def __init__(self, f, off, size):
        self.f, self.off, self.left = f, off, size

    def read(self, n=-1):
        if self.left <= 0:
            return b''
        if n is None or n < 0:
            n = self.left
        n = min(n, self.left)
        self.f.seek(self.off)
        data = self.f.read(n)
        self.off += len(data)
        self.left -= len(data)
        return data

    def readable(self):
        return True
