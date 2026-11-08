"""Choose which prepared Lumiose version runs, with a way back (M4 step 2). Local only: it never downloads anything.

A version is a folder of tools/lumiose/prepare.py output (<version>-<identity>/ with ready.json). `state.json` in the
versions folder records the active one and the one before it:

  list                          the prepared versions and whether each still verifies
  status                        one `STATUS {json}` line for a screen: ready (a version is active and verifies), none
                                (nothing prepared yet), or invalid (the active one no longer verifies), plus the version
  activate <folder> [--smoke]   verify it (hashes, name), optionally start it hidden and offline to see that it comes
                                up, then make it the active one; the old one becomes `previous`
  rollback                      make `previous` the active one again (verified first)
  set-server <host:port>        another relay than the default (kept in server.txt), or `clear-server` to use the default again
  launch                        print the command that starts the active version: online to the server (the name is looked up
                                now and the runtime is given that one IPv4 address), `--offline` for offline

A version that fails verification or the start-up check never becomes active, and the state file is replaced only as a
whole, so a failure leaves the previous choice as it was.
"""
import argparse
import importlib.util
import json
import os
import shlex
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # (prepare.py imports its neighbours)
spec = importlib.util.spec_from_file_location('lumiose_prepare', HERE / 'prepare.py')
prep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prep)

STATE = 'state.json'
SERVER = 'server.txt'
# The Lumiose Online team's relay, the same machine as its site (its own launcher passes this address too). The name is
# looked up when starting; the runtime is only ever given the resulting IPv4 address and may reach nothing else.
DEFAULT_SERVER = 'lumioseonline.site:27777'
UP_MARKER = '[ui] installed'  # the module's UI came up: its initialization ran through
BAD_MARKERS = ('FATAL', '[crash]', 'no function at')


def read_state(root):
    try:
        state = json.loads((root / STATE).read_text())
        if isinstance(state, dict) and all(state.get(k) is None or isinstance(state.get(k), str) for k in ('active', 'previous')):
            return {'active': state.get('active'), 'previous': state.get('previous')}
    except (OSError, ValueError):
        pass
    return {'active': None, 'previous': None}


def write_state(root, state):
    tmp = root / (STATE + '.tmp')
    tmp.write_text(json.dumps(state, indent=2) + '\n')
    os.replace(tmp, root / STATE)


def verify(root, name):
    """The folder `name` of the versions folder, if it is a complete, matching and unchanged preparation."""
    if not name or Path(name).name != name:
        raise ValueError('a version is a folder name inside the versions folder')
    directory = root / name
    try:
        ready = json.loads((directory / 'ready.json').read_text())
        identity, version = ready['identity'], ready['version']
    except (OSError, ValueError, KeyError):
        raise ValueError(f'{name}: not a prepared version (no usable ready.json)') from None
    if name != f'{version}-{identity[:16]}' or not prep.valid_result(directory, identity):
        raise ValueError(f'{name}: the files do not match their manifest; prepare it again')
    return directory


def online_status(root):
    """What a screen needs to show the online entry: {'state': ready|none|invalid, 'active', 'version', 'dir' (of the
    active version, when it verifies), 'server' (host:port in use: the default or the one set), 'custom' (it was set),
    'endpoint' (that server's IPv4:port as looked up now, '' when it could not be)}."""
    active = read_state(root)['active']
    custom = read_server(root)
    server = custom or DEFAULT_SERVER
    try: endpoint = resolve_endpoint(server)
    except OSError: endpoint = ''
    info = {'state': 'none', 'active': None, 'version': None, 'server': server, 'custom': custom is not None, 'endpoint': endpoint}
    if not active:
        return info
    try:
        directory = verify(root, active)
        info.update(state='ready', active=active, dir=str(directory),
                    version=json.loads((directory / 'ready.json').read_text())['version'])
    except ValueError:
        info.update(state='invalid', active=active)
    return info


def parse_server(value):
    """'host:port' with an IPv4 address or a host name and a port, or ValueError. Returns it normalized (IPv4 octets
    without leading zeros, name in lower case)."""
    host, sep, port = value.strip().rpartition(':')
    if not sep or not port.isdigit() or not 0 < int(port) < 65536 or not host:
        raise ValueError('the server is host:port, like 203.0.113.5:27777 or example.org:27777')
    octets = host.split('.')
    if len(octets) == 4 and all(o.isdigit() for o in octets):
        if not all(len(o) <= 3 and int(o) <= 255 for o in octets):
            raise ValueError('the server is host:port, like 203.0.113.5:27777 or example.org:27777')
        host = '.'.join(str(int(o)) for o in octets)
    elif not re.fullmatch(r'(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}', host.lower()):
        raise ValueError('the server is host:port, like 203.0.113.5:27777 or example.org:27777')
    return f'{host.lower()}:{int(port)}'


def resolve_endpoint(server, resolver=None):
    """The IPv4:port of a server (host:port) as the runtime pins it; OSError when a name has no IPv4 address."""
    host, _, port = parse_server(server).rpartition(':')
    if re.fullmatch(r'\d+\.\d+\.\d+\.\d+', host):
        return f'{host}:{port}'
    for family, _, _, _, address in (resolver or socket.getaddrinfo)(host, int(port), socket.AF_INET, socket.SOCK_DGRAM):
        if family == socket.AF_INET:
            return f'{address[0]}:{port}'
    raise OSError(f'{host} has no IPv4 address')


def read_server(root):
    try:
        return parse_server((root / SERVER).read_text())
    except (OSError, ValueError):
        return None


def write_server(root, value):
    tmp = root / (SERVER + '.tmp')
    tmp.write_text(parse_server(value) + '\n')
    os.replace(tmp, root / SERVER)


def command(directory, runtime, game, server=None):
    env = {'LUMIOSE_TEST_MODULE': str(directory / 'subsdk9'), 'LUMIOSE_TEST_LIBRARY': str(directory / 'lumiose.dylib'),
           'LARECOMP_GAME_LIB': str(directory / 'lasgame.dylib')}
    if server:  # only this exact IPv4:port is reachable (runtime/hle/lumiose_net.c); without it the network stays off
        env['LUMIOSE_TEST_NETWORK'] = '1'
        env['LUMIOSE_TEST_SERVER'] = resolve_endpoint(server)  # (an IPv4 address stays as it is)
    return env, [str(runtime), str(game), '--play']


def smoke(directory, runtime, game, seconds=90, settle=20):
    """Start the version hidden and offline in a scratch profile. True if the module's UI comes up and the game then keeps
    running for `settle` more seconds with no error in the log (the first crashes seen came after the module's start)."""
    env = {k: v for k, v in os.environ.items() if not k.startswith(('LARECOMP_', 'LUMIOSE_'))}
    extra, argv = command(directory, runtime, game)
    with tempfile.TemporaryDirectory(prefix='lumiose-smoke-') as scratch:
        log = Path(scratch) / 'run.log'
        env.update(extra, LARECOMP_HIDDEN='1', LARECOMP_NO_UPDATE_CHECK='1', LARECOMP_SAVE_DIR=str(Path(scratch) / 'save'))
        with log.open('w') as f:
            p = subprocess.Popen(argv, env=env, stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                start = time.monotonic(); up = None
                while time.monotonic() - start < seconds:
                    text = log.read_text(errors='replace')
                    if any(m in text for m in BAD_MARKERS):
                        return False, 'the start-up log reports an error'
                    if p.poll() is not None:
                        return False, 'the game exited' + ('' if up else ' before the module came up')
                    if up is None and UP_MARKER in text:
                        up = time.monotonic()
                    if up is not None and time.monotonic() - up >= settle:
                        return True, f'the module came up and the game ran {settle} s more'
                    time.sleep(1)
                return False, f'the module did not come up and settle within {seconds} s'
            finally:
                if p.poll() is None:
                    os.killpg(p.pid, signal.SIGTERM)
                    try: p.wait(timeout=8)
                    except subprocess.TimeoutExpired:
                        os.killpg(p.pid, signal.SIGKILL); p.wait()


def activate(root, name, check=None):
    """Make `name` the active version. `check(directory)` -> (ok, why) runs after verification; on failure nothing changes."""
    directory = verify(root, name)
    if check:
        ok, why = check(directory)
        if not ok:
            raise RuntimeError(f'{name}: not activated, {why}')
    state = read_state(root)
    if state['active'] != name:
        state = {'active': name, 'previous': state['active']}
        write_state(root, state)
    return state


def rollback(root):
    state = read_state(root)
    if not state['previous']:
        raise RuntimeError('there is no previous version to go back to')
    verify(root, state['previous'])
    state = {'active': state['previous'], 'previous': state['active']}
    write_state(root, state)
    return state


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', type=Path, default=Path('build/lumiose-prepared'), help='the versions folder')
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('list')
    sub.add_parser('status')
    a = sub.add_parser('activate'); a.add_argument('version')
    a.add_argument('--smoke', action='store_true', help='start it hidden and offline first (needs --runtime and --game)')
    sub.add_parser('rollback')
    s = sub.add_parser('set-server'); s.add_argument('server')
    sub.add_parser('clear-server')
    for p in (a, sub.add_parser('launch')):
        p.add_argument('--runtime', type=Path); p.add_argument('--game', type=Path)
    sub.choices['launch'].add_argument('--offline', action='store_true', help='do not use the network even if a server is set')
    args = ap.parse_args()
    root = args.root.resolve()
    try:
        if args.cmd == 'list':
            state = read_state(root)
            for d in sorted(p for p in root.iterdir() if p.is_dir()) if root.is_dir() else []:
                try: verify(root, d.name); status = 'ok'
                except ValueError as e: status = str(e).split(': ', 1)[-1]
                tag = ' (active)' if d.name == state['active'] else ' (previous)' if d.name == state['previous'] else ''
                print(f'{d.name}{tag}: {status}')
        elif args.cmd == 'status':
            print('STATUS ' + json.dumps(online_status(root)))
        elif args.cmd == 'activate':
            check = None
            if args.smoke:
                if not (args.runtime and args.game): ap.error('--smoke needs --runtime and --game')
                check = lambda d: smoke(d, args.runtime.resolve(), args.game.resolve())
            state = activate(root, args.version, check)
            print(f'active: {state["active"]}' + (f', previous: {state["previous"]}' if state['previous'] else ''))
        elif args.cmd == 'rollback':
            state = rollback(root)
            print(f'active: {state["active"]}, previous: {state["previous"]}')
        elif args.cmd == 'set-server':
            write_server(root, args.server)
            print(f'server: {read_server(root)}')
        elif args.cmd == 'clear-server':
            (root / SERVER).unlink(missing_ok=True)
            print(f'server: the default, {DEFAULT_SERVER}')
        else:
            state = read_state(root)
            if not state['active']: raise RuntimeError('no version is active; run activate first')
            if not (args.runtime and args.game): ap.error('launch needs --runtime and --game')
            server = None if args.offline else read_server(root) or DEFAULT_SERVER
            env, argv = command(verify(root, state['active']), args.runtime.resolve(), args.game.resolve(), server)
            print(shlex.join(['env', *[f'{k}={v}' for k, v in env.items()], *argv]))
            print('# ' + (f'online: only {env["LUMIOSE_TEST_SERVER"]} ({server}) is reachable' if server else 'offline'), file=sys.stderr)
    except (ValueError, RuntimeError, OSError) as e:
        print(f'{e}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
