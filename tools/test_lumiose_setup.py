"""setup_online.py's update decision, with the network, the status and the preparation replaced (nothing runs)."""
from pathlib import Path
import hashlib
import io
import json
import math
from unittest.mock import Mock, patch
import importlib.util
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/lumiose'))
spec = importlib.util.spec_from_file_location('setup_online', ROOT / 'tools/lumiose/setup_online.py')
so = importlib.util.module_from_spec(spec); spec.loader.exec_module(so)
sys.path.insert(0, str(ROOT / 'tools'))
from activate import online_status, write_state  # noqa: E402
from test_nso import fixture  # noqa: E402

OFFICIAL = fixture(compressed=True, hashes=True)
REPLACEMENT = OFFICIAL[:-1] + bytes([OFFICIAL[-1] ^ 1])  # same NSO header and build ID, different contents
LATEST = hashlib.sha256(OFFICIAL).hexdigest()


class UpdateTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name).resolve()
        self.root = self.tmp / 'versions'; self.root.mkdir()
        self.game = self.tmp / 'game'; self.game.mkdir()
        self.mods = self.tmp / 'modules'; self.mods.mkdir()
        self.cache = self.mods / ('subsdk9-' + LATEST[:16])
        self.game_id = b'current-game-id\n'
        (self.game / 'lasgame.dylib.id').write_bytes(self.game_id)
        (self.root / 'server.txt').write_text('127.0.0.1:27777')

    def prepare_folder(self, version, module, active=False):
        identity = hashlib.sha256(version.encode()).hexdigest()
        folder = self.root / (version + '-' + identity[:16])
        folder.mkdir()
        outputs = {'subsdk9': module, 'lasgame.dylib.id': self.game_id,
                   'lumiose.dylib': b'fake library', 'lasgame.dylib': b'fake game library'}
        for name, data in outputs.items():
            (folder / name).write_bytes(data)
        (folder / 'ready.json').write_text(json.dumps({'identity': identity, 'version': version,
            'inputs': {'module': LATEST},  # claiming the correct source digest must not authenticate a replacement
            'outputs': {name: hashlib.sha256(data).hexdigest() for name, data in outputs.items()}}))
        if active:
            write_state(self.root, {'active': folder.name, 'previous': None})
        return folder

    def run_main(self, prepare=None, lookup=None, download=None, extra=()):
        self.prepare = Mock(side_effect=prepare, return_value=(False, '', 'stop'))
        self.download = Mock(side_effect=download or OSError('download failed'))
        self.reports = Mock()
        argv = ['setup_online.py', '--runtime', 'rt', '--game', str(self.game), '--root', str(self.root),
                '--modules', str(self.mods), *extra]
        with patch.multiple(so, latest_sha256=lookup or (lambda: LATEST), status_info=online_status,
                            fetch=self.download, run_stage=self.prepare, report=self.reports), \
                patch.object(sys, 'argv', argv):
            return so.main()

    def assert_ready(self, folder, version):
        self.reports.assert_called_with(1.0, 'Ready', 'ready', dir=str(folder), version=version,
                                        endpoint='127.0.0.1:27777')

    def test_reuses_only_the_published_version(self):
        folder = self.prepare_folder('1.0.0', OFFICIAL, active=True)
        self.assertEqual(self.run_main(), 0)
        self.prepare.assert_not_called()
        self.download.assert_not_called()
        self.assert_ready(folder, '1.0.0')

    def test_unavailable_checksum_does_not_fall_back_to_local_files(self):
        def unavailable():
            raise OSError('offline')
        self.prepare_folder('1.0.0', OFFICIAL, active=True)
        self.cache.write_bytes(OFFICIAL)
        self.assertEqual(self.run_main(lookup=unavailable), 1)
        self.prepare.assert_not_called()
        self.download.assert_not_called()
        self.assertEqual(self.reports.call_args.args[2], 'error')

    def test_rejects_replaced_active_and_cached_modules_even_with_matching_names_and_manifest(self):
        self.prepare_folder('1.0.0', REPLACEMENT, active=True)
        self.assertEqual(online_status(self.root)['state'], 'ready')  # manifest is internally consistent
        self.cache.write_bytes(REPLACEMENT)
        self.assertEqual(self.run_main(), 1)
        self.download.assert_called_once_with(so.DEFAULT_URL, self.mods, sha256=LATEST)
        self.prepare.assert_not_called()

    def test_replaces_unapproved_active_version_with_verified_download(self):
        old = self.prepare_folder('1.0.0', REPLACEMENT, active=True)
        new = self.prepare_folder('2.0.0', OFFICIAL)

        def download(url, out, *, sha256):
            self.assertEqual(sha256, LATEST)
            self.cache.write_bytes(OFFICIAL)
            return self.cache, LATEST, '2.0.0'

        def stage(argv, *args):
            if '--module' in argv:
                snapshot = Path(argv[argv.index('--module') + 1])
                self.cache.write_bytes(REPLACEMENT)
                self.assertEqual(snapshot.read_bytes(), OFFICIAL)
                return True, str(new), ''
            self.assertIn(new.name, argv)
            write_state(self.root, {'active': new.name, 'previous': old.name})
            return True, '', ''

        self.assertEqual(self.run_main(prepare=stage, download=download), 0)
        self.assertEqual(self.prepare.call_count, 2)
        self.assert_ready(new, '2.0.0')

    def test_unapproved_preparation_is_not_smoke_tested(self):
        self.cache.write_bytes(OFFICIAL)
        folder = self.prepare_folder('2.0.0', REPLACEMENT)
        self.assertEqual(self.run_main(prepare=lambda *a: (True, str(folder), '')), 1)
        self.download.assert_not_called()
        self.assertEqual(self.prepare.call_count, 1)
        self.assertEqual(self.reports.call_args.args[2], 'error')

    def test_manual_module_and_save_sd_card_options_are_refused(self):
        for option in ('--module', '--downloaded'):
            with self.subTest(option=option), patch('sys.stderr', new_callable=io.StringIO):
                with self.assertRaises(SystemExit) as result:
                    self.run_main(extra=(option, 'subsdk9'))
                self.assertEqual(result.exception.code, 2)
                self.prepare.assert_not_called()
                self.download.assert_not_called()

    def test_a_version_prepared_for_another_game_code_is_prepared_again(self):
        with tempfile.TemporaryDirectory() as tmp:
            old, game = Path(tmp) / 'old', Path(tmp) / 'game'
            old.mkdir(); game.mkdir()
            (old / 'lasgame.dylib.id').write_text('aaaa\n')
            (game / 'lasgame.dylib.id').write_text('bbbb\n')
            self.assertFalse(so.built_for_this_game(old, game))
            (game / 'lasgame.dylib.id').write_text('aaaa\n')
            self.assertTrue(so.built_for_this_game(old, game))
            (game / 'lasgame.dylib.id').unlink()
            self.assertFalse(so.built_for_this_game(old, game))

    def test_malformed_helper_status_fails_closed(self):
        from subprocess import CompletedProcess
        with patch.object(so, 'tool', return_value=['dummy']), patch.object(so.subprocess, 'run',
                   return_value=CompletedProcess(['dummy'], 0, 'STATUS not json\nSTATUS []\n', '')):
            self.assertEqual(so.status_info('/tmp/nonexistent'), {})

    def test_malformed_progress_does_not_propagate_nan_or_crash(self):
        class FakeProcess:
            stdout = io.StringIO('PROGRESS []\nPROGRESS {"state":"running","fraction": "NaN"}\n'
                                 'PROGRESS {"state":"running","fraction": {}}\n'
                                 'PROGRESS {"state":"running","fraction": 3}\n'
                                 'PROGRESS {"state":"ready","dir":"/out"}\n')
            def wait(self): return 0
        values = []
        with patch.object(so.subprocess, 'Popen', return_value=FakeProcess()), \
                patch.object(so, 'report', side_effect=lambda fraction, *args: values.append(fraction)):
            ok, folder, _ = so.run_stage(['dummy'], 0.2, 0.8, 'Preparing')
        self.assertTrue(ok)
        self.assertEqual(folder, '/out')
        self.assertTrue(all(math.isfinite(value) and 0.2 <= value <= 0.8 for value in values))
        self.assertEqual(values[-1], 0.8)

    def test_activation_requires_successful_exit_not_progress_marker(self):
        class FakeProcess:
            stdout = io.StringIO('')
            def wait(self): return 0
        with patch.object(so.subprocess, 'Popen', return_value=FakeProcess()):
            self.assertEqual(so.run_stage(['dummy'], 0, 1, 'Activating', False)[0], True)
        with patch.object(so.subprocess, 'Popen', return_value=FakeProcess()):
            self.assertEqual(so.run_stage(['dummy'], 0, 1, 'Preparing')[0], False)


if __name__ == '__main__':
    unittest.main()
