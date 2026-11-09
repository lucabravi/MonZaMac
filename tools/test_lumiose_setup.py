"""setup_online.py's update decision, with the network, the status and the preparation replaced (nothing runs)."""
from pathlib import Path
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
LATEST = 'ab' * 32


class UpdateTests(unittest.TestCase):
    def run_main(self, latest, active, downloads=(), mod_file=None, prepared=None, skipped=''):
        stages, reports = [], []
        with tempfile.TemporaryDirectory() as tmp:
            mods = Path(tmp) / 'modules'; mods.mkdir()
            for name in downloads: (mods / name).write_bytes(b'x')
            def lookup():
                if latest is None: raise OSError('offline')
                return latest
            so.latest_sha256 = lookup
            so.active_module = lambda root: active
            so.fetch_latest = lambda out: (_ for _ in ()).throw(OSError('no download in a test'))
            so.run_stage = lambda argv, *a: (stages.append(argv), (bool(prepared), str(prepared or ''), 'stop'))[1]
            (Path(tmp) / 'skipped-modules').write_text(skipped)
            so.report = lambda f, step, state='running', **kw: reports.append((state, step, kw))
            sys.argv = ['setup_online.py', '--runtime', 'rt', '--game', 'g', '--root', tmp, '--modules', str(mods)]
            if mod_file:
                sys.argv += ['--downloaded', str(mod_file)]
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
