"""Reporting must fail when a differential harness fails or omits results.

The compiler/native-process boundaries return synthetic records; the real
drivers select instructions, generate cases, and compare/report those records.
No game files or native AArch64/macOS runtime are needed.
"""
import contextlib
import io
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import test_lift
import test_simd


class LiftResultGate(unittest.TestCase):
    LINE = ' '.join(['0'] * 34 + ['0' * 32] + ['0'] * 32) + '\n'

    def run_driver(self, stdout, status=0):
        # One synthetic MOV, three oracle records. Isolate reporting from the
        # macOS-only native harness and the NSO parser, tested independently.
        nso = SimpleNamespace(text=(0, 4), image=bytearray(struct.pack('<I', 0xd2800020) + bytes(4092)))
        oracle = ([0] * 31, 0, 0, [0] * 32, 0x100004, '0' * 32)
        proc = subprocess.CompletedProcess([], status, stdout, b'synthetic harness failure')
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()), \
                patch.object(test_lift, 'ROOT', tmp), patch.object(test_lift, 'Nso', return_value=nso), \
                patch.object(test_lift, 'run_unicorn', return_value=oracle), \
                patch.object(test_lift.subprocess, 'check_call'), \
                patch.object(test_lift.subprocess, 'run', return_value=proc), \
                patch.object(sys, 'argv', ['test_lift.py', 'synthetic', '0x100000', '1', '1']):
            return test_lift.main() or 0

    def test_complete_matching_output_passes(self):
        self.assertEqual(self.run_driver((self.LINE * 3).encode()), 0)

    def test_register_mismatch_fails(self):
        self.assertEqual(self.run_driver(('1' + self.LINE[1:] + self.LINE * 2).encode()), 1)

    def test_native_process_failure_fails(self):
        self.assertEqual(self.run_driver((self.LINE * 3).encode(), status=9), 1)

    def test_missing_or_extra_results_fail(self):
        for count in (0, 1, 2, 4):
            with self.subTest(records=count):
                self.assertEqual(self.run_driver((self.LINE * count).encode()), 1)

    def test_truncated_record_fails(self):
        self.assertEqual(self.run_driver((self.LINE * 2 + '0 0\n').encode()), 1)


class SimdResultGate(unittest.TestCase):
    RECORD = bytes(test_simd.OUT_SIZE)

    def run_driver(self, data, status=0):
        def harness(args, **kwargs):
            Path(args[-1]).write_bytes(data)
            return subprocess.CompletedProcess(args, status, b'', b'synthetic harness failure')

        # FMOV D0,D1 with all-zero registers has an all-zero output record.
        state = (0, [0] * 31, 0, 0, [0] * 32)
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()), \
                patch.object(test_simd, 'ROOT', tmp), \
                patch.object(test_simd, 'candidates', return_value=[0x1e604020]), \
                patch.object(test_simd, 'make_case', return_value=state), \
                patch.object(test_simd, 'compile_tests', return_value='synthetic-harness'), \
                patch.object(test_simd.subprocess, 'run', side_effect=harness), \
                patch.object(sys, 'argv', ['test_simd.py', '--encodings', '1', '--cases', '2', '--no-validity']):
            return test_simd.main()

    def test_complete_matching_output_passes(self):
        self.assertEqual(self.run_driver(self.RECORD * 2), 0)

    def test_register_mismatch_fails(self):
        self.assertEqual(self.run_driver(b'\x01' + (self.RECORD * 2)[1:]), 1)

    def test_native_process_failure_fails(self):
        self.assertEqual(self.run_driver(self.RECORD * 2, status=9), 1)

    def test_missing_or_extra_results_fail(self):
        for count in (0, 1, 3):
            with self.subTest(records=count):
                self.assertEqual(self.run_driver(self.RECORD * count), 1)

    def test_partial_record_fails(self):
        self.assertEqual(self.run_driver(self.RECORD * 2 + b'\0'), 1)


if __name__ == '__main__':
    unittest.main()
