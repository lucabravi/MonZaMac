"""Copy selected files from a RomFS image into a host folder.

Usage: python tools/za/romfs_extract.py <romfs.bin> <out folder> [prefix, default arc/]
The image is an input file, not a source of trusted host paths or lengths.
"""
import os
from pathlib import Path
import struct
import sys

MAX_META = 256 << 20


def _table(f, off, size, length, label):
    if off > length or size > length - off or size > MAX_META:
        raise ValueError(f'invalid RomFS {label} bounds')
    f.seek(off)
    data = f.read(size)
    if len(data) != size:
        raise ValueError(f'truncated RomFS {label}')
    return data


def _directory_path(meta, offset):
    parts, visited = [], set()
    while offset:
        if offset in visited or offset > len(meta) or len(meta) - offset < 0x18:
            raise ValueError('invalid RomFS directory parent chain')
        visited.add(offset)
        parent, = struct.unpack_from('<I', meta, offset)
        name_len, = struct.unpack_from('<I', meta, offset + 0x14)
        if name_len > len(meta) - offset - 0x18:
            raise ValueError('truncated RomFS directory name')
        name = meta[offset + 0x18:offset + 0x18 + name_len].decode('utf-8')
        if not name or name in ('.', '..') or '/' in name or '\\' in name:
            raise ValueError('unsafe RomFS directory name')
        parts.append(name)
        offset = parent
    return '/'.join(reversed(parts))


def extract(image, output, prefix='arc/'):
    """Extract the matching files; reject malformed layouts and paths before writing."""
    root = Path(output).resolve()
    with open(image, 'rb') as f:
        length = os.fstat(f.fileno()).st_size
        if length < 0x50:
            raise ValueError('truncated RomFS header')
        h = struct.unpack('<10Q', f.read(0x50))
        directory = _table(f, h[3], h[4], length, 'directory metadata')
        files = _table(f, h[7], h[8], length, 'file metadata')
        data_start = h[9]
        if data_start > length:
            raise ValueError('invalid RomFS data offset')
        offset = 0
        while offset < len(files):
            if len(files) - offset < 0x20:
                raise ValueError('truncated RomFS file entry')
            parent, _, file_off, size, _, name_len = struct.unpack_from('<IIQQII', files, offset)
            if name_len > len(files) - offset - 0x20:
                raise ValueError('truncated RomFS file name')
            name = files[offset + 0x20:offset + 0x20 + name_len].decode('utf-8')
            offset += 0x20 + ((name_len + 3) & ~3)
            if offset > len(files):
                raise ValueError('truncated RomFS file entry padding')
            if not name or name in ('.', '..') or '/' in name or '\\' in name:
                raise ValueError('unsafe RomFS file name')
            directory_path = _directory_path(directory, parent)
            rel = (directory_path + '/' if directory_path else '') + name
            if not rel.startswith(prefix):
                continue
            # Neither malformed names nor an existing symlink under the output may redirect a write.
            target = (root / rel).resolve()
            if not target.is_relative_to(root):
                raise ValueError('RomFS output path leaves the destination directory')
            if file_off > length - data_start or size > length - data_start - file_off:
                raise ValueError(f'truncated RomFS file data: {rel}')
            target.parent.mkdir(parents=True, exist_ok=True)
            f.seek(data_start + file_off)
            try:
                with target.open('wb') as dest:
                    left = size
                    while left:
                        chunk = f.read(min(left, 64 << 20))
                        if not chunk:
                            raise ValueError(f'truncated RomFS file data: {rel}')
                        dest.write(chunk)
                        left -= len(chunk)
            except BaseException:
                target.unlink(missing_ok=True)
                raise
            print(rel, size)


if __name__ == '__main__':
    if len(sys.argv) not in (3, 4):
        sys.exit('usage: romfs_extract.py <romfs.bin> <out folder> [path prefix]')
    try:
        extract(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else 'arc/')
    except (OSError, ValueError, struct.error) as error:
        sys.exit(f'RomFS extraction failed: {error}')
