"""setup_online.py's update decision, with the network, the status and the preparation replaced (nothing runs)."""
from pathlib import Path
import hashlib
import io
import math
import os
from unittest.mock import patch
import importlib.util
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/lumiose'))
spec = importlib.util.spec_from_file_location('setup_online', ROOT / 'tools/lumiose/setup_online.py')
so = importlib.util.module_from_spec(spec); spec.loader.exec_module(so)
sys.path.insert(0, str(ROOT / 'tools'))
from test_nso import fixture  # noqa: E402
LATEST = hashlib.sha256(b'x').hexdigest()


class UpdateTests(unittest.TestCase):
    def run_main(self, latest, active, downloads=(), mod_file=None, prepared=None, skipped=''):
        stages, reports = [], []
        with tempfile.TemporaryDirectory() as tmp:
            mods = Path(tmp) / 'modules'; mods.mkdir()
            for name in downloads: (mods / name).write_bytes(b'x')
            def lookup():
                if latest is None: raise OSError('offline')
                return latest
            (Path(tmp) / 'skipped-modules').write_text(skipped)
            sys.argv = ['setup_online.py', '--runtime', 'rt', '--game', 'g', '--root', tmp, '--modules', str(mods)]
            if mod_file:
                sys.argv += ['--downloaded', str(mod_file)]
            # This helper tests the update decision, not the game build identity on fake /v/1.
            with patch.multiple(so, latest_sha256=lookup, active_module=lambda root: active,
                                fetch_latest=lambda out: (_ for _ in ()).throw(OSError('no download in a test')),
                                run_stage=lambda argv, *a: (stages.append(argv),
                                                             (bool(prepared), str(prepared or ''), 'stop'))[1],
                                report=lambda f, step, state='running', **kw: reports.append((state, step, kw))), \
                    patch.object(so, 'built_for_this_game', return_value=True), \
                    patch.object(so, 'status_info', return_value={}):
                code = so.main()
            self.skipped_after = (Path(tmp) / 'skipped-modules').read_text()
            return code, stages, reports, mods

    def test_current_version_starts_at_once(self):
        code, stages, reports, _ = self.run_main(LATEST, (Path('/v/1'), LATEST))
        self.assertEqual((code, stages), (0, []))
        self.assertEqual(reports[-1][0], 'ready')

    def test_offline_keeps_the_active_version(self):
        code, stages, _, _ = self.run_main(None, (Path('/v/1'), 'cd' * 32))
        self.assertEqual((code, stages), (0, []))

    def test_a_newer_module_is_prepared_from_the_download_with_its_hash(self):
        code, stages, _, mods = self.run_main(LATEST, (Path('/v/1'), 'cd' * 32), ['subsdk9-' + LATEST[:16], 'subsdk9-old'])
        self.assertEqual(code, 1)  # (the stubbed preparation stops)
        argv = stages[0]
        self.assertEqual(Path(argv[argv.index('--module') + 1]).name, 'subsdk9-' + LATEST[:16])

    def test_a_newer_module_not_here_is_downloaded(self):
        code, stages, reports, _ = self.run_main(LATEST, None)
        self.assertEqual((code, stages), (1, []))
        self.assertEqual(reports[-1][0], 'error')
        self.assertIn('download', reports[-1][2]['message'])

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

    def test_cached_download_must_match_full_sha256(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ('subsdk9-' + LATEST[:16])
            path.write_bytes(b'x')
            self.assertEqual(so.cached_module(tmp, LATEST), path)
            path.write_bytes(b'y')
            self.assertIsNone(so.cached_module(tmp, LATEST))

    def test_partial_download_is_not_selected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'module'
            path.write_bytes(fixture(compressed=True, hashes=True))
            partial = Path(tmp) / 'newer.part'
            partial.write_bytes(fixture(compressed=True, hashes=True))
            readme = Path(tmp) / 'README.txt'
            readme.write_bytes(b'instructions' * 100)
            newest = path.stat().st_mtime + 100
            os.utime(partial, (newest, newest))
            os.utime(readme, (newest + 10, newest + 10))
            self.assertEqual(so.find_module(tmp), path)

    def test_skipping_after_failed_preparation_creates_parent(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp) / 'missing' / 'versions'
            so.skip(folder, 'deadbeef')
            self.assertEqual((folder / 'skipped-modules').read_text(), 'deadbeef\n')

    def test_malformed_helper_status_fails_closed(self):
        from subprocess import CompletedProcess
        with patch.object(so, 'tool', return_value=['dummy']), patch.object(so.subprocess, 'run',
                   return_value=CompletedProcess(['dummy'], 0, 'STATUS not json\nSTATUS []\n', '')):
            self.assertEqual(so.status_info('/tmp/nonexistent'), {})
            self.assertIsNone(so.active_module('/tmp/nonexistent'))

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

    def module_file(self, tmp):
        path = Path(tmp) / 'subsdk9'
        path.write_bytes(fixture(compressed=True, hashes=True))
        return path, so.sha256_of(path)

    def version_folder(self, tmp, name, line):
        folder = Path(tmp) / name; folder.mkdir()
        (folder / 'capture.log').write_text(line)
        return folder

    def test_the_mods_own_download_comes_before_the_site(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, sha = self.module_file(tmp)
            code, stages, _, _ = self.run_main(LATEST, (Path('/v/1'), 'cd' * 32), mod_file=path)
        self.assertEqual(code, 1)
        argv = stages[0]
        self.assertEqual(Path(argv[argv.index('--module') + 1]).name, 'subsdk9-' + sha[:16])
        self.assertIn(sha, self.skipped_after)  # (it failed: the next press goes on without it)

    def test_the_active_module_and_a_skipped_one_are_not_prepared_again(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, sha = self.module_file(tmp)
            for active, skip in (((Path('/v/1'), sha), ''), ((Path('/v/1'), 'cd' * 32), sha + '\n')):
                code, stages, _, _ = self.run_main(None, active, mod_file=path, skipped=skip)
                self.assertEqual((code, stages), (0, []))

    def test_something_that_is_no_module_is_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'subsdk9'; path.write_bytes(b'not a module')
            code, stages, _, _ = self.run_main(None, (Path('/v/1'), 'cd' * 32), mod_file=path)
        self.assertEqual((code, stages), (0, []))

    def test_a_module_not_newer_keeps_the_active_version(self):
        line = '[guest] [update] this build is %s build 1 (platform 2, channel 0)\n'
        with tempfile.TemporaryDirectory() as tmp:
            path, sha = self.module_file(tmp)
            active = self.version_folder(tmp, 'active', line % '1.6.0')
            new = self.version_folder(tmp, 'new', line % '1.5.0')
            code, stages, reports, _ = self.run_main(LATEST, (active, 'cd' * 32), mod_file=path, prepared=new)
        self.assertEqual((code, len(stages)), (0, 1))  # (prepared, never given to activate)
        self.assertEqual(reports[-1][2]['dir'], str(active))
        self.assertIn(sha, self.skipped_after)

    def test_a_newer_module_goes_on_to_the_check(self):
        line = '[guest] [update] this build is %s build 1 (platform 2, channel 0)\n'
        with tempfile.TemporaryDirectory() as tmp:
            path, _ = self.module_file(tmp)
            active = self.version_folder(tmp, 'active', line % '1.5.0')
            new = self.version_folder(tmp, 'new', line % '1.10.0')
            _, stages, _, _ = self.run_main(LATEST, (active, 'cd' * 32), mod_file=path, prepared=new)
        self.assertEqual(len(stages), 2)
        self.assertIn('activate', stages[1])


if __name__ == '__main__':
    unittest.main()
