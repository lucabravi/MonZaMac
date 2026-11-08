"""Everything the start screen's "set up online" does, as one job with one progress: find the module, prepare it, check
that it starts, make it the active version. Prints PROGRESS lines (see prepare.py report()) and ends with state ready or
error. The module is a file the user has put in lumiose-module/ (any name) or that fetch.py kept in build/lumiose-modules/; with
none, the newest live one is downloaded (fetch.py: the authors' fixed link, checked against their published SHA-256). The
player has agreed before this runs: it is the only thing here that uses the network.

  setup_online.py --runtime monzamac --game extracted [--root build/lumiose-prepared] [--module FILE]
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
from prepare import report  # noqa: E402
from fetch import fetch_latest  # noqa: E402

FOLDERS = ('lumiose-module', 'build/lumiose-modules')


def find_module(base):
    """The newest regular file in the module folders under `base`, or None."""
    found = [p for folder in FOLDERS for p in (base / folder).glob('*') if p.is_file() and not p.name.startswith('.')]
    return max(found, key=lambda p: p.stat().st_mtime) if found else None


def run_stage(argv, low, high, label):
    """Run a script; its PROGRESS fractions are mapped into low..high. Returns (ok, last ready dir, last message)."""
    p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, cwd=ROOT)
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
    args = ap.parse_args()
    py = sys.executable
    module = args.module or find_module(Path.cwd()) or find_module(ROOT)
    if not module:
        report(0.0, 'Downloading the module')
        try:
            module = fetch_latest(ROOT / 'build/lumiose-modules')[0]
        except (ValueError, OSError) as e:
            report(0.0, 'Download failed', 'error', message=f'Could not download the Lumiose module: {e}')
            return 1
    report(0.01, 'Preparing the online version')
    ok, directory, message = run_stage([py, str(HERE / 'prepare.py'), '--module', str(module), '--runtime', str(args.runtime),
                                        '--source', str(args.source), '--out', str(args.root)], 0.01, 0.90, 'Preparing')
    if not ok:
        report(0.0, 'Preparation failed', 'error', message=message or 'Preparation failed.')
        return 1
    report(0.90, 'Checking that it starts')
    name = Path(directory).name
    ok, _, message = run_stage([py, str(HERE / 'activate.py'), '--root', str(args.root), 'activate', name, '--smoke',
                                '--runtime', str(args.runtime), '--game', str(args.game)], 0.90, 0.99, 'Checking')
    # (activate.py prints no PROGRESS lines: success is its exit code, read from the status afterwards)
    status = subprocess.run([py, str(HERE / 'activate.py'), '--root', str(args.root), 'status'], capture_output=True, text=True, cwd=ROOT)
    state = {}
    for line in status.stdout.splitlines():
        if line.startswith('STATUS '): state = json.loads(line[7:])
    if state.get('active') == name and state.get('state') == 'ready':
        report(1.0, 'Ready', 'ready', dir=state['dir'])
        return 0
    report(0.0, 'The online version did not start', 'error', message=message or 'The prepared version did not come up; it was not activated.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
