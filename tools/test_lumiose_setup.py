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
LATEST = 'ab' * 32


class UpdateTests(unittest.TestCase):
    def run_main(self, latest, active, downloads=()):
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
            so.run_stage = lambda argv, *a: (stages.append(argv), (False, '', 'stop'))[1]
            so.report = lambda f, step, state='running', **kw: reports.append((state, step, kw))
            sys.argv = ['setup_online.py', '--runtime', 'rt', '--game', 'g', '--root', tmp, '--modules', str(mods)]
            code = so.main()
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


if __name__ == '__main__':
    unittest.main()
