"""Local package preparation for the launcher. Never prints tool output or key material."""
import argparse
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile

from nup import Nup, NupError, KIND_BASE, KIND_UPDATE, KIND_ADDON, NO_DIR

APP_ID = 0x0100F43008C44000


class ImportFailure(Exception):
    def __init__(self, code, field=''):
        super().__init__(code)
        self.code = code
        self.field = field


def in_field(field, action, *args):
    try:
        return action(*args)
    except ImportFailure as exc:
        if not exc.field and exc.code != 'decrypt': exc.field = field
        raise
    except (OSError, ValueError):
        raise ImportFailure('io', field) from None


class Package:
    """Read bounded PFS0/HFS0 members; extract only selected content, never container paths."""
    def __init__(self, path):
        self.path = Path(path).resolve(strict=True)
        size = self.path.stat().st_size
        with self.path.open('rb') as f:
            magic = f.read(4)
            if magic == b'7z\xbc\xaf':
                raise ImportFailure('archive-7z-nsp' if self.path.suffix.lower() == '.nsp' else 'archive-7z')
            if magic == b'PK\x03\x04' or magic[:2] == b'\x1f\x8b':
                raise ImportFailure('archive')
            if magic == b'PFS0':
                self.entries = self._entries(f, 0, size, b'PFS0')
            else:
                f.seek(0x100)
                if f.read(4) != b'HEAD': raise ImportFailure('package')
                f.seek(0x130); raw = f.read(8)
                if len(raw) != 8: raise ImportFailure('package')
                root = self._entries(f, struct.unpack('<Q', raw)[0], size, b'HFS0')
                if 'secure' not in root: raise ImportFailure('package')
                off, length = root['secure']
                self.entries = self._entries(f, off, off + length, b'HFS0')

    @staticmethod
    def _entries(f, base, end, magic):
        if base < 0 or base + 16 > end: raise ImportFailure('package')
        f.seek(base); header = f.read(16)
        if len(header) != 16: raise ImportFailure('package')
        got, count, names_size, _ = struct.unpack('<4sIII', header)
        entry_size = 24 if magic == b'PFS0' else 64
        data_start = base + 16 + count * entry_size + names_size
        if got != magic or count > 65536 or names_size > 16 << 20 or data_start > end:
            raise ImportFailure('package')
        table = f.read(count * entry_size); names = f.read(names_size)
        result = {}; ranges = []
        for i in range(count):
            off, size, name_off = struct.unpack_from('<QQI', table, i * entry_size)
            if name_off >= len(names): raise ImportFailure('package')
            nul = names.find(b'\0', name_off)
            if nul < 0: raise ImportFailure('package')
            try: name = names[name_off:nul].decode('ascii')
            except UnicodeError: raise ImportFailure('package') from None
            if not name or name in ('.', '..') or any(c in name for c in '/\\:') or name in result:
                raise ImportFailure('package')
            start = data_start + off
            if start + size > end: raise ImportFailure('package')
            result[name] = (start, size)
            if size: ranges.append((start, start + size))
        ranges.sort()
        if any(b[0] < a[1] for a, b in zip(ranges, ranges[1:])): raise ImportFailure('package')
        return result

    def copy(self, name, dest):
        if name not in self.entries: raise ImportFailure('package')
        off, size = self.entries[name]
        with self.path.open('rb') as src, Path(dest).open('xb') as out:
            src.seek(off)
            while size:
                chunk = src.read(min(size, 8 << 20))
                if not chunk: raise ImportFailure('package')
                out.write(chunk); size -= len(chunk)


def program_content(data, patch):
    if len(data) < 32: raise ImportFailure('package')
    title, _, kind, extended, count = struct.unpack_from('<QIBxHH', data)
    if title != APP_ID + (0x800 if patch else 0) or kind != (0x81 if patch else 0x80):
        raise ImportFailure('game')
    off = 32 + extended
    if count > 4096 or off + count * 56 > len(data): raise ImportFailure('package')
    programs = [data[p + 32:p + 48].hex() + '.nca' for p in range(off, off + count * 56, 56)
                if data[p + 54] == 1 and data[p + 55] == 0]
    if len(programs) != 1: raise ImportFailure('package')
    if patch and extended >= 8 and struct.unpack_from('<Q', data, 32)[0] != APP_ID:
        raise ImportFailure('game')
    return programs[0]


def run_tool(tool, args):
    # nstool diagnostics can contain cryptographic material. They are never forwarded to the app log.
    result = subprocess.run([str(tool), *map(str, args)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode: raise ImportFailure('decrypt')


def emit(phase):
    print('import: ' + phase, flush=True)


def validate_extracted(output, build_id):
    output = Path(output)
    if any(not (output / 'exefs' / n).is_file() for n in ('main', 'main.npdm', 'rtld', 'sdk')):
        raise ImportFailure('files')
    with (output / 'exefs/main').open('rb') as f:
        f.seek(0x40)
        if f.read(len(build_id)) != build_id: raise ImportFailure('version')
    if not (output / 'romfs/arc/data.trpfd').is_file(): raise ImportFailure('files')


def select_program(package, work, tool, keys, patch):
    work.mkdir()
    tickets = []
    for name in package.entries:
        if re.fullmatch(r'[0-9a-fA-F]{32}\.tik', name):
            path = work / name; package.copy(name, path); tickets += ['--tik', path]
    metas = [n for n in package.entries if re.fullmatch(r'[0-9a-fA-F]{32}\.cnmt\.nca', n)]
    if not metas: raise ImportFailure('package')
    for i, name in enumerate(metas):
        meta = work / name; package.copy(name, meta)
        out = work / ('meta-' + str(i)); out.mkdir()
        run_tool(tool, ['-k', keys, *tickets, '-x', '/0', out, meta])
        for cnmt in out.glob('*.cnmt'):
            if cnmt.stat().st_size > 4 << 20: raise ImportFailure('package')
            try: name = program_content(cnmt.read_bytes(), patch)
            except ImportFailure as e:
                if e.code == 'game': continue
                raise
            path = work / name; package.copy(name, path)
            return path, tickets
    raise ImportFailure('game')


def addon_content(data):
    """(title, data NCA name) of an AddOnContent cnmt (kind 0x82), or None for any other meta."""
    if len(data) < 32: raise ImportFailure('package')
    title, _, kind, extended, count = struct.unpack_from('<QIBxHH', data)
    if kind != 0x82: return None
    off = 32 + extended
    if count > 4096 or off + count * 56 > len(data): raise ImportFailure('package')
    ncas = [data[p + 32:p + 48].hex() + '.nca' for p in range(off, off + count * 56, 56) if data[p + 54] != 0]
    if len(ncas) != 1: raise ImportFailure('package')
    return title, ncas[0]


def extract_dlc(dlc, keys, output, tool):
    """Optional add-on package: its data partition goes to output/aoc-tree/<titleid>/ (packed to aoc/<id>.bin later)."""
    keys = Path(keys).resolve(strict=True)
    output = Path(output).resolve(strict=True)
    package = in_field('dlc', Package, dlc)
    with tempfile.TemporaryDirectory(prefix='.dlc-', dir=output) as tmp:
        work = Path(tmp)
        tickets = []
        for name in package.entries:
            if re.fullmatch(r'[0-9a-fA-F]{32}\.tik', name):
                path = work / name; package.copy(name, path); tickets += ['--tik', path]
        found = None
        for i, name in enumerate(n for n in package.entries if re.fullmatch(r'[0-9a-fA-F]{32}\.cnmt\.nca', n)):
            meta = work / name; package.copy(name, meta)
            out = work / ('meta-' + str(i)); out.mkdir()
            run_tool(tool, ['-k', keys, *tickets, '-x', '/0', out, meta])
            for cnmt in out.glob('*.cnmt'):
                if cnmt.stat().st_size > 4 << 20: raise ImportFailure('package')
                found = found or addon_content(cnmt.read_bytes())
        if not found or found[0] >> 13 != APP_ID >> 13: raise ImportFailure('dlc', 'dlc')
        title, nca = found
        path = work / nca; package.copy(nca, path)
        dest = output / 'aoc-tree' / ('%016x' % title)
        if dest.exists(): shutil.rmtree(dest)
        dest.parent.mkdir(exist_ok=True)
        run_tool(tool, ['-k', keys, *tickets, '-x', '/0', dest, path])
        return title


def extract(base, update, keys, output, tool, build_id):
    keys = in_field('keys', Path(keys).resolve, True)
    output = Path(output).resolve(strict=True)
    if not keys.is_file() or not 0 < keys.stat().st_size <= 8 << 20: raise ImportFailure('keys', 'keys')
    if not output.is_dir() or any((output / n).exists() for n in ('exefs', 'romfs')):
        raise ImportFailure('output')
    emit('checking')
    base = in_field('base', Package, base)
    update = in_field('update', Package, update)
    if base.path == update.path: raise ImportFailure('input')
    # Include both copied NCAs, the merged tree, the ROMFS image and build scratch space.
    sizes = (base.path.stat().st_size, update.path.stat().st_size)
    need = max(25 << 30, sum(sizes) + 2 * max(sizes) + (3 << 30))
    if shutil.disk_usage(output).free < need:
        print('import: space ' + str(need), flush=True)
        raise ImportFailure('space')
    try:
        with tempfile.TemporaryDirectory(prefix='.extract-', dir=output) as tmp:
            work = Path(tmp)
            emit('base'); bnca, btickets = in_field('base', select_program, base, work / 'base', tool, keys, False)
            emit('update'); unca, utickets = in_field('update', select_program, update, work / 'update', tool, keys, True)
            emit('extracting')
            run_tool(tool, ['-k', keys, *btickets, *utickets, '--basenca', bnca,
                            '-x', '/0', output / 'exefs', '-x', '/1', output / 'romfs', unca])
            validate_extracted(output, build_id)
        emit('ready')
    except BaseException:
        for name in ('exefs', 'romfs'):
            p = output / name
            if p.is_dir() and not p.is_symlink(): shutil.rmtree(p)
        raise


def extract_nup(nup_path, output, build_id):
    """Switch 2 Edition .nup: base, update and add-ons in one unencrypted container (no keys, no nstool)."""
    output = Path(output).resolve(strict=True)
    if not output.is_dir() or any((output / n).exists() for n in ('exefs', 'romfs')):
        raise ImportFailure('output')
    emit('checking')
    try:
        container = Nup(nup_path)
    except NupError:
        raise ImportFailure('nup', 'base') from None
    except OSError:
        raise ImportFailure('io', 'base') from None
    with container:
        base = next((p for p in container.packages if p.kind == KIND_BASE), None)
        if not base or base.title_id != APP_ID or base.exefs_dir == NO_DIR or base.romfs_dir == NO_DIR:
            raise ImportFailure('game')
        update = max((p for p in container.packages if p.kind == KIND_UPDATE and p.title_id == APP_ID),
                     key=lambda p: p.version, default=None)
        addons = [p for p in container.packages if p.kind == KIND_ADDON and p.romfs_dir != NO_DIR]
        # The unpacked tree and the data image are each about the container's size (the game's own packs are
        # already compressed), plus room for the game code build.
        size = Path(nup_path).stat().st_size
        need = max(25 << 30, 2 * size + (3 << 30))
        if shutil.disk_usage(output).free < need:
            print('import: space ' + str(need), flush=True)
            raise ImportFailure('space')
        try:
            emit('base')
            container.extract(base.exefs_dir, output / 'exefs')
            container.extract(base.romfs_dir, output / 'romfs')
            if update:
                emit('update')
                if update.exefs_dir != NO_DIR: container.extract(update.exefs_dir, output / 'exefs')
                if update.romfs_dir != NO_DIR: container.extract(update.romfs_dir, output / 'romfs')
            emit('extracting')
            validate_extracted(output, build_id)
            for p in addons:
                container.extract(p.romfs_dir, output / 'aoc-tree' / ('%016x' % p.title_id))
            emit('ready')
        except BaseException as e:
            for name in ('exefs', 'romfs', 'aoc-tree'):
                p = output / name
                if p.is_dir() and not p.is_symlink(): shutil.rmtree(p)
            if isinstance(e, NupError):
                raise ImportFailure('nup', 'base') from None
            raise


def main(argv=None):
    parser = argparse.ArgumentParser(description='Prepare your own game packages locally.')
    for name in ('base', 'update', 'keys', 'output', 'nstool', 'build-id'):
        parser.add_argument('--' + name)
    parser.add_argument('--nup')  # Switch 2 Edition container: base, update and add-ons, no keys
    parser.add_argument('--dlc')  # optional add-on NSP; a bad one never fails the base import
    parser.add_argument('--dlc-only', action='store_true')  # add the DLC to an installed game: no base, update or build id
    args = parser.parse_args(argv)
    try:
        if args.dlc_only:
            if not (args.dlc and args.keys and args.output and args.nstool): raise ImportFailure('input')
            extract_dlc(args.dlc, args.keys, args.output, args.nstool)
            emit('dlc ready')
            return 0
        if args.nup:
            if not (args.output and args.build_id): raise ImportFailure('input')
            build_id = bytes.fromhex(args.build_id)
            if len(build_id) != 8: raise ImportFailure('input')
            extract_nup(args.nup, args.output, build_id)
            return 0
        if not all((args.base, args.update, args.keys, args.output, args.nstool, args.build_id)): raise ImportFailure('input')
        build_id = bytes.fromhex(args.build_id)
        if len(build_id) != 8: raise ImportFailure('input')
        extract(args.base, args.update, args.keys, args.output, args.nstool, build_id)
        if args.dlc:
            try: extract_dlc(args.dlc, args.keys, args.output, args.nstool); emit('dlc ready')
            except (ImportFailure, OSError, ValueError): emit('dlc skipped')
        return 0
    except ImportFailure as e:
        emit('error ' + (e.field or 'none') + ' ' + e.code)
    except (OSError, ValueError):
        emit('error none io')
    except Exception:
        emit('error none extract')
    return 1


if __name__ == '__main__': sys.exit(main())
