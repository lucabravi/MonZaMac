"""The run helper must trust make's exit status before touching test/game state."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RunBuild(unittest.TestCase):
    def run_helper(self, status, message):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / 'tools').mkdir(); (root / 'bin').mkdir()
        shutil.copyfile(ROOT / 'tools/run.sh', root / 'tools/run.sh')
        # Stop at the next real boundary: no game process or player save is used.
        marker = root / 'slot-entered'
        (root / 'tools/game_slot.sh').write_text(': > "$SLOT_PROBE"\nexit 0\n')
        make = root / 'bin/make'
        make.write_text('#!/bin/sh\nprintf "%s\\n" "$MAKE_MESSAGE" >&2\nexit "$MAKE_STATUS"\n')
        make.chmod(0o700)
        env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'],
                   REALSAVE='1', MAKE_MESSAGE=message, MAKE_STATUS=str(status), SLOT_PROBE=str(marker))
        result = subprocess.run(['bash', str(root / 'tools/run.sh')], cwd=root, env=env,
                                capture_output=True, text=True, timeout=10)
        return result, marker.exists()

    def test_make_failure_without_word_error_stops_before_launch(self):
        result, entered = self.run_helper(2, 'make: *** No rule to make target missing. Stop.')
        self.assertFalse(entered, 'a failed build reached the game launch path')
        self.assertEqual(result.returncode, 2)
        self.assertIn('No rule to make target', result.stdout + result.stderr)

    def test_successful_make_output_is_not_mistaken_for_failure(self):
        result, entered = self.run_helper(0, '0 errors generated.')
        self.assertTrue(entered, 'successful make output containing error blocked the run')
        self.assertEqual(result.returncode, 0)


if __name__ == '__main__': unittest.main()
