"""Everything the start screen's "set up online" does, as one job with one progress: find the module, prepare it, check
that it starts, make it the active version. Prints PROGRESS lines (see prepare.py report()) and ends with state ready or
error. The module is a file the user has put in lumiose-module/ (any name) or that fetch.py kept in build/lumiose-modules/; with
none, the newest live one is downloaded (fetch.py: the authors' fixed link, checked against their published SHA-256). The
player has agreed before this runs: it is the only thing here that uses the network.

The mod also updates itself in the game: it gets a signed file from the relay and writes it to the save's SD card folder
(--downloaded), which is what a Switch would load next. Here that file has to be prepared first, so it comes before the site,
which can be later than the relay. A module not newer than the active version is never activated; a module that was refused
is remembered (skipped-modules in the versions folder) and not tried again on every press.

  setup_online.py --runtime monzamac --game extracted [--root build/lumiose-prepared] [--module FILE]
                  [--modules DIR] [--downloaded FILE] [--cache DIR --include DIR --cc "zig cc"]   (the app's layout: see prepare.py)
"""
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
from prepare import report  # noqa: E402
from fetch import fetch_latest, latest_sha256  # noqa: E402
from commands import tool  # noqa: E402
from nso import Nso  # noqa: E402
from versions import module_info  # noqa: E402



def find_module(*folders):
    """The newest regular file in these folders, or None."""
    found = [p for folder in folders for p in Path(folder).glob('*') if p.is_file() and not p.name.startswith('.')]
    return max(found, key=lambda p: p.stat().st_mtime) if found else None


def active_module(root):
    """(folder, SHA-256 of the module it was prepared from) of the active prepared version when it verifies, else None."""
    state = subprocess.run([*tool('activate'), '--root', str(root), 'status'], capture_output=True, text=True)
    info = next((json.loads(l[7:]) for l in state.stdout.splitlines() if l.startswith('STATUS ')), {})
    if info.get('state') != 'ready':
        return None
    try:
        return Path(info['dir']), json.loads((Path(info['dir']) / 'ready.json').read_text())['inputs']['module']
    except (OSError, ValueError, KeyError, TypeError):
        return None


def built_for_this_game(directory, game):
    """False when an app update changed the game code since this version was prepared: the runtime refuses its library."""
    try:
        return (Path(directory) / 'lasgame.dylib.id').read_text().strip() == (Path(game) / 'lasgame.dylib.id').read_text().strip()
    except OSError:
        return True  # (the check of the prepared files, or the start itself, reports a missing one)


def sha256_of(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def skipped(root):
    try:
        return set(Path(root, 'skipped-modules').read_text().split())
    except OSError:
        return set()


def skip(root, sha):
    with Path(root, 'skipped-modules').open('a') as f:
        f.write(sha + '\n')


def built_version(directory):
    """The (major, minor, patch, build) a prepared version's module printed when it was captured, or None."""
    try:
        info = module_info((Path(directory) / 'capture.log').read_text(errors='replace'))
    except OSError:
        return None
    return info[0] if info else None


def mod_download(path, active, root, downloads):
    """The module the mod installed by itself, kept among the downloads, when it is one to try; else None. With no active
    version the site decides: this file can be old, and there is nothing to compare it with."""
    try:
        if not path or not active or not Path(path).is_file():
            return None
        sha = sha256_of(path)
        if sha == active[1] or sha in skipped(root):
            return None
        Nso(path)  # (raises ValueError for anything that is not a well-formed NSO)
        Path(downloads).mkdir(parents=True, exist_ok=True)
        kept = Path(downloads) / ('subsdk9-' + sha[:16])
        shutil.copy2(path, kept)
        return kept
    except (OSError, ValueError):
        return None


def run_stage(argv, low, high, label):
    """Run a script; its PROGRESS fractions are mapped into low..high. Returns (ok, last ready dir, last message)."""
    p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    ready_dir, message = '', ''
    for line in p.stdout:
        if line.startswith('PROGRESS '):
            try: info = json.loads(line[9:])
            except ValueError: continue
            if info.get('state') == 'running':
                report(low + (high - low) * float(info.get('fraction', 0)), info.get('step') or label)
            elif info.get('state') == 'ready': ready_dir = info.get('dir', '')
            elif info.get('state') == 'error': message = info.get('message', '')
        elif not message and line.strip():
            message = line.strip()[:200]
    code = p.wait()
    return code == 0 and bool(ready_dir), ready_dir, message


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--runtime', required=True, type=Path)
    ap.add_argument('--game', required=True, type=Path)
    ap.add_argument('--root', type=Path, default=Path('build/lumiose-prepared'))
    ap.add_argument('--module', type=Path)
    ap.add_argument('--source', type=Path, default=ROOT)
    ap.add_argument('--modules', type=Path, help='Where downloaded modules are kept (default build/lumiose-modules)')
    ap.add_argument('--downloaded', type=Path, help="Where the mod installs its own update (in the save's SD card folder)")
    ap.add_argument('--cache', type=Path)
    ap.add_argument('--include', type=Path)
    ap.add_argument('--cc')
    args = ap.parse_args()
    downloads = args.modules or ROOT / 'build/lumiose-modules'
    module = args.module
    active = active_module(args.root)
    if active and not built_for_this_game(active[0], args.game):
        active = None  # (prepared again like a first time: the module is the same, its game library is not)
    from_mod = None if module else mod_download(args.downloaded, active, args.root, downloads)
    module = module or from_mod
    if not module:  # the newest live module: nothing to do when the active version was prepared from it
        report(0.0, 'Checking for updates')
        try:
            latest = latest_sha256()
        except (ValueError, OSError):
            latest = None  # (offline: the active version, else a module already here)
        if active and (latest is None or active[1] == latest or latest in skipped(args.root)):
            report(1.0, 'Ready', 'ready', dir=str(active[0]))
            return 0
        if latest:
            module = next((p for p in Path(downloads).glob('subsdk9-' + latest[:16]) if p.is_file()), None)
        else:
            module = find_module(args.modules) if args.modules else find_module(
                *(base / f for base in (Path.cwd(), ROOT) for f in ('lumiose-module', 'build/lumiose-modules')))
    if not module:
        report(0.0, 'Downloading the module')
        try:
            module = fetch_latest(downloads)[0]
        except (ValueError, OSError) as e:
            report(0.0, 'Download failed', 'error', message=f'Could not download the Lumiose module: {e}')
            return 1
    report(0.01, 'Preparing the online version')
    extra = [x for flag, value in [('--cache', args.cache), ('--include', args.include), ('--cc', args.cc)] if value
             for x in (flag, str(value))]
    ok, directory, message = run_stage([*tool('prepare'), '--module', str(module), '--runtime', str(args.runtime),
                                        '--game', str(args.game), '--source', str(args.source), '--out', str(args.root), *extra],
                                       0.01, 0.90, 'Preparing')
    if not ok:
        if from_mod: skip(args.root, sha256_of(from_mod))
        report(0.0, 'Preparation failed', 'error', message=message or 'Preparation failed.')
        return 1
    new, old = built_version(directory), built_version(active[0]) if active else None
    if new and old and new <= old:  # (the site can be behind the version the mod brought, or the file behind the site)
        skip(args.root, sha256_of(module))
        report(1.0, 'Ready', 'ready', dir=str(active[0]))
        return 0
    report(0.90, 'Checking that it starts')
    name = Path(directory).name
    ok, _, message = run_stage([*tool('activate'), '--root', str(args.root), 'activate', name, '--smoke',
                                '--runtime', str(args.runtime), '--game', str(args.game)], 0.90, 0.99, 'Checking')
    # (activate.py prints no PROGRESS lines: success is its exit code, read from the status afterwards)
    status = subprocess.run([*tool('activate'), '--root', str(args.root), 'status'], capture_output=True, text=True)
    state = {}
    for line in status.stdout.splitlines():
        if line.startswith('STATUS '): state = json.loads(line[7:])
    if state.get('active') == name and state.get('state') == 'ready':
        report(1.0, 'Ready', 'ready', dir=state['dir'])
        return 0
    if from_mod: skip(args.root, sha256_of(from_mod))
    report(0.0, 'The online version did not start', 'error', message=message or 'The prepared version did not come up; it was not activated.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
