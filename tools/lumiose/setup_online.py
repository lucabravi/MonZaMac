"""Prepare and activate the module published by Lumiose Online for the launcher's Play online button.

Each launch checks the team's published SHA-256. A cached download or prepared version can be reused if its module
matches. Files from the save's SD card and manually supplied modules are never considered here; prepare.py is the
separate tool for local development.

  setup_online.py --runtime monzamac --game extracted [--root build/lumiose-prepared]
                  [--modules DIR] [--cache DIR --include DIR --cc "zig cc"]   (the app's layout: see prepare.py)
"""
import argparse
import hashlib
import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
from prepare import report  # noqa: E402
from fetch import DEFAULT_URL, LIMIT, fetch, latest_sha256  # noqa: E402
from commands import tool  # noqa: E402


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


def built_for_this_game(directory, game):
    """False when an app update changed the game code since this version was prepared: the runtime refuses its library."""
    try:
        return (Path(directory) / 'lasgame.dylib.id').read_text().strip() == (Path(game) / 'lasgame.dylib.id').read_text().strip()
    except OSError:
        return False  # Missing build identities cannot establish that the prepared binary is compatible.


def checked_module(path, expected):
    """The exact bytes accepted for this launch, or None for a missing or unapproved module."""
    try:
        if not path.is_file():
            return None
        with path.open('rb') as source:
            data = source.read(LIMIT + 1)
        if 0x100 <= len(data) <= LIMIT and hashlib.sha256(data).hexdigest() == expected:
            return data
    except OSError:
        pass
    return None


def ready(status, game, expected):
    """A manifest alone only checks consistency. Also check the real module against the team's digest."""
    if (status.get('state') != 'ready' or not status.get('dir') or
            not all(isinstance(status.get(k), str) for k in ('dir', 'version', 'endpoint'))):
        return False
    directory = Path(status['dir'])
    return built_for_this_game(directory, game) and checked_module(directory / 'subsdk9', expected) is not None


def report_ready(status):
    # The launcher consumes this exact result; it must not select a version from state.json again.
    report(1.0, 'Ready', 'ready', **{k: status[k] for k in ('dir', 'version', 'endpoint')})


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
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
                                 allow_abbrev=False)
    ap.add_argument('--runtime', required=True, type=Path)
    ap.add_argument('--game', required=True, type=Path)
    ap.add_argument('--root', type=Path, default=Path('build/lumiose-prepared'))
    ap.add_argument('--source', type=Path, default=ROOT)
    ap.add_argument('--modules', type=Path, help='Where downloaded modules are kept (default build/lumiose-modules)')
    ap.add_argument('--cache', type=Path)
    ap.add_argument('--include', type=Path)
    ap.add_argument('--cc')
    args = ap.parse_args()
    downloads = args.modules or ROOT / 'build/lumiose-modules'
    report(0.0, 'Checking for updates')
    try:
        expected = latest_sha256()
    except (ValueError, OSError):
        report(0.0, 'Verification failed', 'error',
               message='Could not verify the Lumiose Online module. Check your connection and try again.')
        return 1
    active = status_info(args.root)
    if ready(active, args.game, expected):
        report_ready(active)
        return 0

    data = checked_module(downloads / ('subsdk9-' + expected[:16]), expected)
    if data is None:
        report(0.0, 'Downloading the module')
        try:
            path, _, _ = fetch(DEFAULT_URL, downloads, sha256=expected)
            data = checked_module(path, expected)
            if data is None:
                raise ValueError('the module does not match the published SHA-256')
        except (ValueError, OSError) as e:
            report(0.0, 'Download failed', 'error', message=f'Could not download the Lumiose module: {e}')
            return 1

    report(0.01, 'Updating the online version' if active.get('state') == 'ready' else 'Preparing the online version')
    extra = [x for flag, value in [('--cache', args.cache), ('--include', args.include), ('--cc', args.cc)] if value
             for x in (flag, str(value))]
    # Prepare from the verified bytes, rather than reopening the user-writable download cache during the build.
    with tempfile.TemporaryDirectory(prefix='lumiose-verified-') as scratch:
        module = Path(scratch) / 'subsdk9'
        module.write_bytes(data)
        ok, directory, message = run_stage([*tool('prepare'), '--module', str(module), '--runtime', str(args.runtime),
                                            '--game', str(args.game), '--source', str(args.source), '--out', str(args.root),
                                            *extra], 0.01, 0.90, 'Preparing')
    prepared = Path(directory)
    if not ok or prepared.parent != args.root.resolve() or checked_module(prepared / 'subsdk9', expected) is None:
        report(0.0, 'Preparation failed', 'error', message=message or 'The prepared module could not be verified.')
        return 1
    report(0.90, 'Checking that it starts')
    ok, _, message = run_stage([*tool('activate'), '--root', str(args.root), 'activate', prepared.name, '--smoke',
                                '--runtime', str(args.runtime), '--game', str(args.game)], 0.90, 0.99, 'Checking', False)
    # (activate.py prints no PROGRESS lines: success is its exit code, read from the status afterwards)
    state = status_info(args.root)
    if ok and state.get('dir') == directory and ready(state, args.game, expected):
        report_ready(state)
        return 0
    report(0.0, 'The online version did not start', 'error', message=message or 'The prepared version did not come up; it was not activated.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
