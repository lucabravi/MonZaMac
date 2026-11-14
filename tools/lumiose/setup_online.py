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
import math
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
from prepare import report  # noqa: E402
from fetch import LIMIT, fetch_latest, latest_sha256  # noqa: E402
from commands import tool  # noqa: E402
from nso import Nso  # noqa: E402
from versions import module_info  # noqa: E402



def find_module(*folders):
    """Newest plausible NSO: ignore notes, partial downloads and files above the download limit."""
    found = []
    for folder in folders:
        for path in Path(folder).glob('*'):
            if path.name.startswith('.') or path.name.endswith(('.part', '.tmp')):
                continue
            try:
                stat = path.stat()
                if not path.is_file() or not 0x100 <= stat.st_size <= LIMIT:
                    continue
                with path.open('rb') as source:
                    if source.read(4) == b'NSO0':
                        found.append((stat.st_mtime_ns, path))
            except OSError:
                continue
    return max(found, key=lambda item: item[0])[1] if found else None


def status_info(root):
    """Read the helper's verified status, treating missing tools and malformed output as unavailable."""
    try:
        proc = subprocess.run([*tool('activate'), '--root', str(root), 'status'],
                              capture_output=True, text=True)
        if proc.returncode:
            return {}
        for line in proc.stdout.splitlines():
            if not line.startswith('STATUS '):
                continue
            try:
                info = json.loads(line[7:])
            except ValueError:
                continue
            if isinstance(info, dict):
                return info
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return {}


def active_module(root):
    """(folder, SHA-256 of the module it was prepared from) when the prepared version verifies, else None."""
    info = status_info(root)
    if info.get('state') != 'ready':
        return None
    try:
        directory = Path(info['dir'])
        return directory, json.loads((directory / 'ready.json').read_text())['inputs']['module']
    except (OSError, ValueError, KeyError, TypeError):
        return None


def built_for_this_game(directory, game):
    """False when an app update changed the game code since this version was prepared: the runtime refuses its library."""
    try:
        return (Path(directory) / 'lasgame.dylib.id').read_text().strip() == (Path(game) / 'lasgame.dylib.id').read_text().strip()
    except OSError:
        return False  # Missing build identities cannot establish that the prepared binary is compatible.


def sha256_of(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def cached_module(downloads, expected):
    """A cached download is trusted only if its *complete* SHA-256 still matches the published one."""
    for path in Path(downloads).glob('subsdk9-' + expected[:16]):
        try:
            if path.is_file() and 0 < path.stat().st_size <= LIMIT and sha256_of(path) == expected:
                return path
        except OSError:
            continue
    return None


def skipped(root):
    try:
        return set(Path(root, 'skipped-modules').read_text().split())
    except OSError:
        return set()


def skip(root, sha):
    Path(root).mkdir(parents=True, exist_ok=True)
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
        if not path or not active or not Path(path).is_file() or Path(path).stat().st_size > LIMIT:
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


def run_stage(argv, low, high, label, require_ready=True):
    """Run a script; map its PROGRESS fractions into low..high without trusting their shape."""
    try:
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    except OSError as exc:
        return False, '', str(exc)
    ready_dir, message = '', ''
    for line in proc.stdout:
        if line.startswith('PROGRESS '):
            try:
                info = json.loads(line[9:])
            except ValueError:
                continue
            if not isinstance(info, dict):
                continue
            state = info.get('state')
            if state == 'running':
                try:
                    fraction = float(info.get('fraction', 0))
                except (TypeError, ValueError):
                    fraction = 0.0
                if not math.isfinite(fraction):
                    fraction = 0.0
                step = info.get('step')
                report(low + (high - low) * max(0.0, min(1.0, fraction)),
                       step if isinstance(step, str) and step else label)
            elif state == 'ready' and isinstance(info.get('dir'), str):
                ready_dir = info['dir']
            elif state == 'error' and isinstance(info.get('message'), str):
                message = info['message']
        elif not message and line.strip():
            message = line.strip()[:200]
    code = proc.wait()
    return code == 0 and (bool(ready_dir) or not require_ready), ready_dir, message


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
            module = cached_module(downloads, latest)
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
    # (a version prepared before for this game: only the module is built again, much quicker than a first preparation)
    report(0.01, 'Updating the online version' if active else 'Preparing the online version')
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
                                '--runtime', str(args.runtime), '--game', str(args.game)], 0.90, 0.99, 'Checking', False)
    # (activate.py prints no PROGRESS lines: success is its exit code, read from the status afterwards)
    state = status_info(args.root)
    if ok and state.get('active') == name and state.get('state') == 'ready' and state.get('dir'):
        report(1.0, 'Ready', 'ready', dir=state['dir'])
        return 0
    if from_mod: skip(args.root, sha256_of(from_mod))
    report(0.0, 'The online version did not start', 'error', message=message or 'The prepared version did not come up; it was not activated.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
