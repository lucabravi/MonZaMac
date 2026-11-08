#!/usr/bin/env python3
"""Prepare local Lumiose libraries. Requires an existing compatible game/object cache.

No module, game bytes or generated output belongs in source control. This command never enables networking.
"""
from pathlib import Path
import argparse
import concurrent.futures
import fcntl
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from nso import Nso
from versions import GAME_PREFIX, full_build_id, profile

BASES = {'main': 0x7000000000, 'sdk': 0x7008000000, 'lumiose': 0x7006200000}
REVISION = 1


def report(fraction, step, state='running', **extra):
    """One status line for a screen that runs this: `PROGRESS {json}` (state running/ready/error, fraction 0..1, the step).
    Always printed, one line, flushed; the human lines around it are not part of the protocol."""
    print('PROGRESS ' + json.dumps({'state': state, 'fraction': round(fraction, 4), 'step': step, **extra}), flush=True)


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def write_json(path, value):
    path = Path(path)
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(value, indent=2) + '\n')
    tmp.replace(path)


def valid_result(directory, key):
    try:
        m = json.loads((directory / 'ready.json').read_text())
        outputs = m['outputs']
        return (m['identity'] == key and isinstance(outputs, dict) and
                set(outputs) == {'subsdk9', 'lumiose.dylib', 'lasgame.dylib', 'lasgame.dylib.id'} and
                all(digest(directory / name) == value for name, value in outputs.items()))
    except (OSError, ValueError, KeyError, TypeError):
        return False


def stage_text(original, image, destination):
    """Keep original metadata/RO/data; only compile the captured executable text."""
    nso = Nso(original)
    if len(image) < len(nso.image):
        raise ValueError('Truncated module snapshot')
    raw = Path(original).read_bytes()
    payload = bytearray(raw[:0x100])
    flags = struct.unpack_from('<I', payload, 12)[0]
    struct.pack_into('<I', payload, 12, flags & ~7)
    for i in range(3):
        _, offset, size = struct.unpack_from('<III', raw, 0x10 + 16 * i)
        data = image[offset:offset + size] if i == 0 else nso.image[offset:offset + size]
        struct.pack_into('<I', payload, 0x10 + 16 * i, len(payload))
        struct.pack_into('<I', payload, 0x60 + 4 * i, size)
        payload[0xa0 + 32 * i:0xc0 + 32 * i] = hashlib.sha256(data).digest()
        payload.extend(data)
    Path(destination).write_bytes(payload)


def entries_from_capture(nso, image):
    lo, size = nso.text
    base = BASES['lumiose']
    entries = set()
    for off in range(0, len(image) - 7, 4):
        value = struct.unpack_from('<Q', image, off)[0]
        if base + lo <= value < base + lo + size and not value & 3:
            pos = value - base
            if image[pos:pos + 64] != nso.image[pos:pos + 64]:
                entries.add(pos)
    for off in range(lo, lo + size, 4):
        word = struct.unpack_from('<I', image, off)[0]
        if word == struct.unpack_from('<I', nso.image, off)[0] or word & 0x7c000000 != 0x14000000:
            continue
        imm = word & 0x3ffffff
        target = off + (imm - (1 << 26) if imm & (1 << 25) else imm) * 4
        if lo <= target < lo + size:
            entries.add(target)
    return entries


def branch_targets(image, base, text):
    lo, size = text
    for off in range(lo, lo + size, 4):
        word = struct.unpack_from('<I', image, off)[0]
        if word & 0x7c000000 == 0x14000000:
            imm = word & 0x3ffffff
            yield base + off + (imm - (1 << 26) if imm & (1 << 25) else imm) * 4


def print_launch(directory, runtime, game):
    print('Offline launch (network is opt-in):')
    print(shlex.join(['env', 'LUMIOSE_TEST_MODULE=' + str(directory / 'subsdk9'),
                      'LUMIOSE_TEST_LIBRARY=' + str(directory / 'lumiose.dylib'),
                      'LARECOMP_GAME_LIB=' + str(directory / 'lasgame.dylib'),
                      str(runtime), str(game), '--play']))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--module', required=True, type=Path)
    ap.add_argument('--runtime', required=True, type=Path)
    ap.add_argument('--source', type=Path, default=ROOT, help='Checkout owning the compatible vanilla generated/object cache')
    ap.add_argument('--build', type=Path, default=Path('build/za202'), help='Relative to --source, or absolute')
    ap.add_argument('--generated', type=Path, default=Path('generated-202'), help='Relative to --source, or absolute')
    ap.add_argument('--out', type=Path, default=ROOT / 'build/lumiose-prepared')
    ap.add_argument('--jobs', type=int, default=min(os.cpu_count() or 1, 8))
    ap.add_argument('--timeout', type=float, default=60, help='Seconds allowed for offline initialization capture')
    ap.add_argument('--cc', default='clang')
    args = ap.parse_args()
    if not 1 <= args.jobs <= 64 or not 0 < args.timeout <= 600:
        ap.error('jobs must be 1..64 and capture timeout 0..600 seconds')
    source, runtime, module = args.source.resolve(), args.runtime.resolve(), args.module.resolve()
    build, generated = (source / args.build).resolve(), (source / args.generated).resolve()
    out = args.out.resolve()
    nso = Nso(module)
    version, tables = profile(nso.build_id)
    build_id = full_build_id(nso.build_id)  # (all 32 bytes, as the runtime compares them)
    game = source / 'extracted'
    for name in ['main', 'sdk']:
        n = Nso(game / 'exefs' / name)
        if name == 'main' and not n.build_id.startswith(GAME_PREFIX):
            raise ValueError('Lumiose preparation requires the studied v2.0.2 game')
    if not runtime.is_file():
        raise ValueError('Runtime is missing; build the runtime first')
    if out == ROOT or ROOT.is_relative_to(out) or module.is_relative_to(out):
        raise ValueError('Output must not contain the checkout or the input module')
    flags = shlex.split((build / 'gamelib-flags').read_text())
    if '-O1' not in flags:
        raise ValueError('Expected the existing -O1 game cache')
    # Cache ownership: unchanged objects must have the same generator/headers as this runtime checkout.
    required = ['runtime/cpu.h', 'runtime/simd.h', 'runtime/simd_fp.h', 'runtime/gamelib.h',
                'tools/gen.py', 'tools/lifter.py', 'tools/patches.py', 'tools/flagfuse.py',
                'tools/analyze.py', 'tools/nso.py', 'tools/passes.py', 'tools/simd_c.py',
                'tools/gamelib_entry.c', 'runtime/hle/hle_symbols.txt']
    for name in required:
        if (ROOT / name).read_bytes() != (source / name).read_bytes():
            raise ValueError('Vanilla object cache source differs: ' + name)
    objects = [p if p.is_absolute() else source / p for p in map(Path, shlex.split((build / 'lasgame.dylib.rsp').read_text()))]
    identity = {'revision': REVISION, 'module': digest(module), 'runtime': digest(runtime),
                'game': {n: digest(game / 'exefs' / n) for n in ['main', 'sdk']},
                'generation': (build / 'lasgame.dylib.id').read_text().strip(), 'flags': flags,
                'compiler': subprocess.check_output([args.cc, '--version'], text=True),
                'sources': {str(p.relative_to(ROOT)): digest(p) for p in
                            [*(ROOT / n for n in required), *sorted(Path(__file__).parent.glob('*.py')),
                             ROOT / 'tools/lumiose/identity.c', ROOT / 'tools/lumiose_test_entry.c']},
                'objects': [(str(p.relative_to(build)), p.stat().st_size, p.stat().st_mtime_ns) for p in objects]}
    key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    out.mkdir(parents=True, exist_ok=True)
    final = out / (version + '-' + key[:16])
    with (out / '.prepare.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another preparation is already running in this output folder') from None
        if valid_result(final, key):
            print('Already prepared:', final)
            report(1.0, 'Already prepared', 'ready', dir=str(final))
            print_launch(final, runtime, game)
            return
        if final.exists():
            raise ValueError('Prepared output failed verification; choose another output directory')
        with tempfile.TemporaryDirectory(prefix='.preparing-', dir=out) as tmp:
            work = Path(tmp)
            log = (work / 'prepare.log').open('wb')
            def run(command, env=None):
                subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            def compile_all(sources, target_dir, cflags):
                target_dir.mkdir(exist_ok=True)
                def compile_one(src):
                    obj = target_dir / (src.stem + '.o')
                    run([args.cc, *cflags, '-c', str(src), '-o', str(obj)])
                    return obj
                with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
                    return list(pool.map(compile_one, sources))
            try:
                shutil.copy2(module, work / 'subsdk9')
                stage = work / 'stage'; stage.mkdir()
                shutil.copy2(module, stage / 'subsdk9')
                (stage / 'main').symlink_to(game / 'exefs/main')
                seeds = set()
                for off, count, fmt, start in tables:
                    for value in struct.unpack_from('<' + str(count) + fmt, nso.image, off):
                        target = start + value * 4
                        if not nso.text[0] <= target < sum(nso.text):
                            raise ValueError('Module jump table does not match its compatibility profile')
                        seeds.add(target)
                gen_dir = work / 'module-gen'
                identity_source = ROOT / 'tools/lumiose/identity.c'
                modflags = ['-O1', '-fno-strict-aliasing', '-Wno-return-type', '-Wno-unused-label',
                            '-fvisibility=hidden', '-Iruntime', '-include', 'runtime/lumiose_cpu.h',
                            '-DLUMIOSE_BUILD_ID="' + build_id + '"']
                def build_module():
                    if gen_dir.exists(): shutil.rmtree(gen_dir)
                    env = os.environ.copy()
                    env['LUMIOSE_TEST_ENTRIES_LUMIOSE'] = ','.join(hex(x) for x in sorted(seeds))
                    run([sys.executable, 'tools/gen.py', 'lumiose', str(stage / 'subsdk9'),
                         hex(BASES['lumiose']), str(gen_dir)], env)
                    objs = compile_all([*sorted(gen_dir.glob('*.c')), ROOT / 'tools/lumiose_test_entry.c', identity_source],
                                       work / 'module-obj', modflags)
                    run([args.cc, '-dynamiclib', '-undefined', 'dynamic_lookup', '-o', str(work / 'lumiose.dylib'), *map(str, objs)])
                print('Preparing module bootstrap...', flush=True)
                report(0.02, 'Preparing the module')
                build_module()
                capture = work / 'capture'; capture.mkdir()
                data = work / 'data'; data.mkdir()
                (data / 'larecomp.ini').write_text('resolution=1x\nfps60=0\nframe_generation=0\nupscaler=bilinear\n'
                                                'game_smooth_anim=0\ngpu_overlap=0\nxfb_barrier=0\nprepare_shaders=0\n')
                env = {k: v for k, v in os.environ.items() if not k.startswith(('LARECOMP_', 'LUMIOSE_'))}
                env.update(LARECOMP_DATA_ROOT=str(data), LARECOMP_SAVE_DIR=str(work / 'save'),
                           LARECOMP_NO_LAUNCHER='1', LARECOMP_NO_UPDATE_CHECK='1', LARECOMP_HIDDEN='1',
                           LARECOMP_GAME_LIB=str(build / 'lasgame.dylib'), LUMIOSE_TEST_MODULE=str(work / 'subsdk9'),
                           LUMIOSE_TEST_LIBRARY=str(work / 'lumiose.dylib'), LUMIOSE_TEST_DUMP=str(capture),
                           LUMIOSE_TEST_CAPTURE_ONLY='1')
                print('Capturing hooks offline...', flush=True)
                report(0.12, 'Starting the module once, offline')
                with (work / 'capture.log').open('wb') as capture_log:
                    process = subprocess.Popen([str(runtime), str(game), '--play'], cwd=ROOT, env=env,
                                               stdout=capture_log, stderr=subprocess.STDOUT, start_new_session=True)
                    try:
                        if process.wait(timeout=args.timeout):
                            raise ValueError('Offline capture failed; see the retained failure log')
                    finally:
                        if process.poll() is None:
                            os.killpg(process.pid, signal.SIGTERM)
                            try:
                                process.wait(timeout=3)
                            except subprocess.TimeoutExpired:
                                os.killpg(process.pid, signal.SIGKILL); process.wait()
                images = {name: (capture / (name + '.image')).read_bytes() for name in ['main', 'sdk', 'subsdk9']}
                stage_text(work / 'subsdk9', images['subsdk9'], stage / 'subsdk9')
                seeds |= entries_from_capture(nso, images['subsdk9'])
                patched = work / 'game'; patched.mkdir()
                hooks, scans, index = {}, {}, {}
                import bisect
                mod_targets = list(branch_targets(images['subsdk9'], BASES['lumiose'], nso.text))
                for name in ['main', 'sdk']:
                    base = BASES[name]; original = Nso(game / 'exefs' / name)
                    known = {int(x, 16) for x in re.findall(r'void f_([0-9a-f]+)\(Cpu \*c\);',
                              (generated / name / (name + '_table.c')).read_text())}
                    ordered = sorted(known); changes = []
                    image = images[name]
                    if len(image) < len(original.image):
                        raise ValueError('Truncated ' + name + ' snapshot')
                    for off in range(original.text[0], sum(original.text), 4):
                        before = struct.unpack_from('<I', original.image, off)[0]
                        word = struct.unpack_from('<I', image, off)[0]
                        if before == word: continue
                        if word & 0xfc000000 != 0x14000000:
                            raise ValueError('Unsupported non-branch hook in ' + name)
                        target = next(branch_targets(image[off:off+4], base + off, (0, 4)))
                        if not BASES['lumiose'] <= target < BASES['lumiose'] + sum(nso.text):
                            raise ValueError('Hook target is outside the module')
                        pos = bisect.bisect_right(ordered, base + off) - 1
                        if pos < 0: raise ValueError('Hook has no known original function')
                        changes.append(dict(entry=base + off, parent=ordered[pos], target=target))
                        seeds.add(target - BASES['lumiose'])
                    if not changes: raise ValueError('No captured hooks installed in ' + name)
                    returns = {v for v in mod_targets if base + original.text[0] <= v < base + sum(original.text) and v not in known}
                    hooks[name] = changes
                    scans[name] = {'new_entry_candidates': [hex(x) for x in sorted(returns)]}
                    chunks = []
                    for file in sorted((generated / name).glob('*.c')):
                        addresses = [int(x, 16) for x in re.findall(r'^void f_([0-9a-f]+)\(Cpu \*c\) \{', file.read_text(), re.M)]
                        if addresses: chunks.append([min(addresses), str(file)])
                    index[name] = {'chunks': sorted(chunks)}
                write_json(patched / 'hooks.json', hooks); write_json(patched / 'scan.json', scans)
                write_json(patched / 'source-index.json', index)
                print('Translating captured module and patched game...', flush=True)
                report(0.22, 'Translating the module and the patched game code')
                build_module()
                run([sys.executable, 'tools/lumiose/prepare_game.py', '--source', str(source), '--build', str(build),
                     '--generated', str(generated), '--capture', str(capture), '--module-table', str(gen_dir / 'lumiose_table.c'),
                     '--out', str(patched)])
                m = json.loads((patched / 'manifest.json').read_text())
                pairs = [(Path(a), Path(b)) for a, b in m['compile']]
                done = [0]; count_lock = threading.Lock()
                report(0.32, f'Compiling {len(pairs)} changed game files' if pairs else 'Nothing to compile')
                def compile_game(item):
                    src, obj = item; obj.parent.mkdir(exist_ok=True, parents=True)
                    run([args.cc, *flags, '-c', str(src), '-o', str(obj)])
                    with count_lock:
                        done[0] += 1
                        if done[0] == len(pairs) or done[0] % max(1, len(pairs) // 40) == 0:
                            report(0.32 + 0.60 * done[0] / len(pairs), f'Compiled {done[0]} of {len(pairs)} game files')
                with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
                    list(pool.map(compile_game, pairs))
                report(0.94, 'Linking')
                id_obj = compile_all([identity_source], work / 'identity-obj',
                                     ['-O1', '-Iruntime', '-DLUMIOSE_BUILD_ID="' + build_id + '"'])
                rsp = work / 'link.rsp'; rsp.write_text('\n'.join(shlex.quote(x) for x in [*m['objects'], *map(str, id_obj)]))
                run([args.cc, '-dynamiclib', '-undefined', 'dynamic_lookup', '-o', str(work / 'lasgame.dylib'), '@' + str(rsp)])
                (work / 'lasgame.dylib.id').write_text(identity['generation'] + '\n')
                log.close()
                result = {'identity': key, 'module_build': build_id, 'version': version,
                          'inputs': identity, 'compiled': len(pairs), 'reused': m['reuse_count'],
                          'outputs': {name: digest(work / name) for name in
                                      ['subsdk9', 'lumiose.dylib', 'lasgame.dylib', 'lasgame.dylib.id']}}
                # Keep diagnostics private, but do not retain snapshots/generated C in the completed version.
                for name in ['stage', 'module-gen', 'module-obj', 'capture', 'data', 'save', 'game', 'identity-obj']:
                    shutil.rmtree(work / name, ignore_errors=True)
                rsp.unlink()
                write_json(work / 'ready.json', result)
                work.rename(final)
            except BaseException:
                log.close()
                for name in ['prepare.log', 'capture.log']:
                    if (work / name).exists(): shutil.copy2(work / name, out / ('failed-' + name))
                raise
    print('Prepared:', final)
    report(1.0, 'Prepared', 'ready', dir=str(final))
    print_launch(final, runtime, game)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        report(0.0, 'Preparation failed', 'error', message=str(error))
        raise SystemExit(str(error))
