"""Build/run synthetic shader trace checks; no GPU or game files."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='monzamac-trace-test-') as tmp:
    tmp = Path(tmp)
    exe = tmp / 'test'
    subprocess.run(['clang', '-O1', '-fobjc-arc', '-I'+str(root/'runtime'), '-framework', 'Foundation',
                    str(root/'tools/test_shader_trace.m'), '-o', str(exe)], check=True)
    for mode in ('disabled', 'enabled', 'dump', 'filtered', 'invalid-target', 'timing'):
        subprocess.run([str(exe), str(tmp/mode), mode], check=True)
        print('PASS', mode)
        if mode == 'enabled':
            import sys
            sys.path.insert(0, str(root/'tools/za'))
            from shader_trace_report import summarize, overlapping_packs
            spans = [(100, 200, "shared-A"), (100, 200, "shared-B"), (150, 160, "short")]
            assert overlapping_packs(spans, 170, 10) == {"shared-A", "shared-B"}
            assert overlapping_packs(spans, 200, 1) == set()
            assert overlapping_packs(spans, 170, 0) == set()
            summary = summarize(tmp/mode)
            assert summary['shaders'] == 1 and summary['compile_counts'] == {'pipeline': 1}
