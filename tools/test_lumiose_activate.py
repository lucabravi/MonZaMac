"""Version choice and rollback of the prepared Lumiose versions, with synthetic folders only."""
from pathlib import Path
import importlib.util
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('activation', ROOT / 'tools/lumiose/activate.py')
act = importlib.util.module_from_spec(spec); spec.loader.exec_module(act)
prep = act.prep
NAMES = ['subsdk9', 'lumiose.dylib', 'lasgame.dylib', 'lasgame.dylib.id']


def make_version(root, version, identity):
    directory = root / f'{version}-{identity[:16]}'
    directory.mkdir()
    for name in NAMES: (directory / name).write_text(version + name)
    prep.write_json(directory / 'ready.json', {'identity': identity, 'version': version,
                                              'outputs': {n: prep.digest(directory / n) for n in NAMES}})
    return directory.name


class ActivationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        self.a = make_version(self.root, '1.3.9', 'a' * 64)
        self.b = make_version(self.root, '1.4.3-build2', 'b' * 64)

    def tearDown(self): self.tmp.cleanup()

    def test_activate_keeps_the_previous_and_rollback_swaps(self):
        self.assertEqual(act.activate(self.root, self.a), {'active': self.a, 'previous': None})
        self.assertEqual(act.activate(self.root, self.b), {'active': self.b, 'previous': self.a})
        self.assertEqual(act.activate(self.root, self.b), {'active': self.b, 'previous': self.a})  # (again: no change)
        self.assertEqual(act.rollback(self.root), {'active': self.a, 'previous': self.b})
        self.assertEqual(act.read_state(self.root)['active'], self.a)

    def test_a_changed_or_foreign_folder_is_never_activated(self):
        act.activate(self.root, self.a)
        (self.root / self.b / 'lasgame.dylib').write_text('changed')
        with self.assertRaises(ValueError): act.activate(self.root, self.b)
        for bad in ['../x', '', 'missing', self.a + '/..']:
            with self.assertRaises(ValueError): act.activate(self.root, bad)
        self.assertEqual(act.read_state(self.root), {'active': self.a, 'previous': None})

    def test_a_failed_start_check_leaves_the_choice(self):
        act.activate(self.root, self.a)
        with self.assertRaises(RuntimeError): act.activate(self.root, self.b, lambda d: (False, 'did not come up'))
        self.assertEqual(act.read_state(self.root), {'active': self.a, 'previous': None})
        act.activate(self.root, self.b, lambda d: (True, 'ok'))
        self.assertEqual(act.read_state(self.root)['active'], self.b)

    def test_rollback_needs_a_previous_that_still_verifies(self):
        act.activate(self.root, self.a)
        with self.assertRaises(RuntimeError): act.rollback(self.root)
        act.activate(self.root, self.b)
        (self.root / self.a / 'subsdk9').write_text('changed')
        with self.assertRaises(ValueError): act.rollback(self.root)
        self.assertEqual(act.read_state(self.root)['active'], self.b)

    def test_status_for_a_screen(self):
        def lookup(host, port, family, kind): return [(family, kind, 17, '', ('203.0.113.9', port))]
        real = act.socket.getaddrinfo; act.socket.getaddrinfo = lookup  # (no network in a test)
        try:
            self.assertEqual(act.online_status(self.root), {'state': 'none', 'active': None, 'version': None, 'server': act.DEFAULT_SERVER,
                                                            'custom': False, 'endpoint': '203.0.113.9:27777'})
            act.activate(self.root, self.b); act.write_server(self.root, '203.0.113.5:1')
            self.assertEqual(act.online_status(self.root), {'state': 'ready', 'active': self.b, 'version': '1.4.3-build2', 'server': '203.0.113.5:1',
                                                            'custom': True, 'endpoint': '203.0.113.5:1', 'dir': str(self.root / self.b)})
            (self.root / self.b / 'subsdk9').write_text('changed')
            self.assertEqual(act.online_status(self.root)['state'], 'invalid')
            self.assertEqual(act.online_status(self.root)['active'], self.b)
        finally:
            act.socket.getaddrinfo = real

    def test_a_name_that_does_not_resolve_leaves_no_endpoint(self):
        def fail(*args): raise OSError('no such host')
        real = act.socket.getaddrinfo; act.socket.getaddrinfo = fail
        try:
            self.assertEqual(act.online_status(self.root)['endpoint'], '')
            self.assertEqual(act.online_status(self.root)['server'], act.DEFAULT_SERVER)
        finally:
            act.socket.getaddrinfo = real

    def test_damaged_state_is_read_as_empty(self):
        (self.root / 'state.json').write_text('{"active": 3}')
        self.assertEqual(act.read_state(self.root), {'active': None, 'previous': None})
        (self.root / 'state.json').write_text('not json')
        self.assertEqual(act.read_state(self.root), {'active': None, 'previous': None})

    def test_command_is_offline_without_a_server(self):
        env, argv = act.command(Path('/v'), Path('/rt'), Path('/g'))
        self.assertNotIn('LUMIOSE_TEST_NETWORK', env)
        self.assertNotIn('LUMIOSE_TEST_SERVER', env)
        self.assertEqual(argv, ['/rt', '/g', '--play'])
        env = act.command(Path('/v'), Path('/rt'), Path('/g'), '203.0.113.5:27777')[0]
        self.assertEqual((env['LUMIOSE_TEST_NETWORK'], env['LUMIOSE_TEST_SERVER']), ('1', '203.0.113.5:27777'))

    def test_a_server_is_an_ipv4_address_or_a_name_with_a_port(self):
        self.assertEqual(act.parse_server(' 203.0.113.005:27777 '), '203.0.113.5:27777')
        self.assertEqual(act.parse_server('Example.ORG:27777'), 'example.org:27777')
        for bad in ['', 'localhost:1', 'example.org', 'example.org:0', 'example.org:70000', '1.2.3:5', '1.2.3.4', '1.2.3.4:0',
                    '256.1.1.1:5', '1.2.3.4:x', '1.2.3.4:5; rm', 'exa mple.org:5', '-a.org:5', 'a..org:5', 'http://a.org:5']:
            with self.assertRaises(ValueError, msg=bad): act.parse_server(bad)

    def test_a_name_is_looked_up_for_ipv4_only(self):
        seen = []
        def lookup(host, port, family, kind):
            seen.append((host, port, family))
            return [(act.socket.AF_INET6, kind, 17, '', ('::1', port, 0, 0)), (family, kind, 17, '', ('198.51.100.7', port))]
        self.assertEqual(act.resolve_endpoint('Example.org:27777', lookup), '198.51.100.7:27777')
        self.assertEqual(seen, [('example.org', 27777, act.socket.AF_INET)])
        self.assertEqual(act.resolve_endpoint('203.0.113.5:1', lambda *a: self.fail('an address is not looked up')), '203.0.113.5:1')
        with self.assertRaises(OSError): act.resolve_endpoint('example.org:1', lambda *a: [])

    def test_the_server_is_kept_in_a_file_and_a_bad_one_changes_nothing(self):
        self.assertIsNone(act.read_server(self.root))
        act.write_server(self.root, ' 203.0.113.005:27777 ')
        self.assertEqual(act.read_server(self.root), '203.0.113.5:27777')
        act.write_server(self.root, 'Example.org:1')
        self.assertEqual(act.read_server(self.root), 'example.org:1')
        for bad in ['', 'example.org', '1.2.3.4:0', 'a b.org:5']:
            with self.assertRaises(ValueError): act.write_server(self.root, bad)
        self.assertEqual(act.read_server(self.root), 'example.org:1')  # (a bad one changes nothing)
        (self.root / 'server.txt').write_text('garbage')
        self.assertIsNone(act.read_server(self.root))


class SmokeTests(unittest.TestCase):
    def run_fake(self, body, **kw):
        with tempfile.TemporaryDirectory() as tmp:
            runtime = Path(tmp) / 'runtime.sh'
            runtime.write_text('#!/bin/sh\n' + body + '\n'); runtime.chmod(0o755)
            return act.smoke(Path(tmp), runtime, Path(tmp), **kw)

    def test_comes_up_and_stays(self):
        ok, _ = self.run_fake('echo "[guest] [ui] installed: x"; sleep 30', seconds=20, settle=2)
        self.assertTrue(ok)

    def test_crash_after_the_start_fails(self):
        ok, why = self.run_fake('echo "[ui] installed"; sleep 1; echo "[crash] boom"; sleep 30', seconds=20, settle=5)
        self.assertFalse(ok); self.assertIn('error', why)

    def test_exit_before_or_after_the_start_fails(self):
        self.assertFalse(self.run_fake('exit 0', seconds=10, settle=2)[0])
        self.assertFalse(self.run_fake('echo "[ui] installed"; sleep 1', seconds=10, settle=5)[0])
        self.assertFalse(self.run_fake('sleep 30', seconds=3, settle=1)[0])


if __name__ == '__main__':
    unittest.main()
