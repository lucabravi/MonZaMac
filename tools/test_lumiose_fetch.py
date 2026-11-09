"""The module download, against a local server and synthetic files only (nothing leaves this machine)."""
from pathlib import Path
import contextlib
import functools
import hashlib
import http.server
import importlib.util
import io
import sys
import tempfile
import threading
import unittest
from email.message import Message
from unittest.mock import patch
import urllib.request
import urllib.response

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tools/lumiose'))
spec = importlib.util.spec_from_file_location('fetch_module', ROOT / 'tools/lumiose/fetch.py')
fm = importlib.util.module_from_spec(spec); spec.loader.exec_module(fm)
from test_nso import fixture  # noqa: E402
import nso  # noqa: E402


@contextlib.contextmanager
def serve(files):
    with tempfile.TemporaryDirectory() as root:
        for name, data in files.items(): (Path(root) / name).write_bytes(data)
        class Quiet(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args): pass
        handler = functools.partial(Quiet, directory=root)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try: yield f'http://127.0.0.1:{server.server_port}/'
        finally: server.shutdown(); server.server_close()


class FetchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.out = Path(self.tmp.name) / 'out'
        self.good = fixture(compressed=True, hashes=True)

    def tearDown(self):
        self.tmp.cleanup()

    def test_https_only(self):
        for url in ['http://example.com/x', 'ftp://example.com/x', 'file:///etc/passwd', '/etc/passwd']:
            with self.assertRaises(ValueError): fm.fetch(url, self.out)
        self.assertFalse(self.out.exists() and any(self.out.iterdir()))

    def test_hash_lookups_reject_an_insecure_final_url(self):
        sha = hashlib.sha256(self.good).hexdigest()
        def redirected(url, timeout):
            response = io.BytesIO(sha.encode() if url.endswith('.sha256') else self.good)
            response.url = url.replace('https://', 'http://') if url.endswith('.sha256') else url
            return response
        with self.assertRaises(ValueError):
            fm.latest_sha256('https://example.test/subsdk9', opener=redirected)
        with self.assertRaises(ValueError):
            fm.fetch_latest(self.out, 'https://example.test/subsdk9', opener=redirected)
        self.assertFalse(self.out.exists())

    def test_default_opener_rejects_downgrade_before_contacting_http(self):
        requested = []
        class Transport(urllib.request.BaseHandler):
            # Only the transport is synthetic; the actual opener and redirect chain run.
            handler_order = 100
            def https_open(self, req):
                requested.append(req.full_url)
                headers = Message(); headers['Location'] = 'http://example.test/hash'
                response = urllib.response.addinfourl(io.BytesIO(), headers, req.full_url, 302)
                response.msg = 'Found'
                return response
            def http_open(self, req):
                requested.append(req.full_url)
                response = urllib.response.addinfourl(io.BytesIO(b'ab' * 32), Message(), req.full_url, 200)
                response.msg = 'OK'
                return response
        build = urllib.request.build_opener
        with patch.object(urllib.request, '_opener', None), patch.object(
                urllib.request, 'build_opener', side_effect=lambda *handlers: build(Transport(), *handlers)):
            with self.assertRaises(ValueError):
                fm.latest_sha256('https://example.test/subsdk9')
        self.assertEqual(requested, ['https://example.test/subsdk9.sha256'])

    def test_keeps_a_module_under_its_hash(self):
        with serve({'subsdk9': self.good}) as base:
            path, sha, version = fm.fetch(base + 'subsdk9', self.out, allow_http=True)
        self.assertEqual(path.read_bytes(), self.good)
        self.assertEqual((path.name, version), (f'subsdk9-{sha[:16]}', 'build-00010203'))
        self.assertEqual(sorted(p.name for p in self.out.iterdir()), [path.name])  # (no partial file left)

    def test_refuses_what_is_not_a_known_module_and_leaves_nothing(self):
        cases = {'text': b'<html>not found</html>' * 30, 'tiny': b'NSO0', 'big': b'x' * 5000}
        with serve(cases) as base:
            for name in cases:
                with self.assertRaises(ValueError, msg=name):
                    fm.fetch(base + name, self.out, allow_http=True, limit=4000)
        self.assertEqual(list(self.out.iterdir()), [])

    def test_a_given_sha256_must_match(self):
        sha = hashlib.sha256(self.good).hexdigest()
        with serve({'subsdk9': self.good}) as base:
            path, got, _ = fm.fetch(base + 'subsdk9', self.out, allow_http=True, sha256=sha.upper())
            self.assertEqual(got, sha)
            with self.assertRaises(ValueError):
                fm.fetch(base + 'subsdk9', self.out, allow_http=True, sha256='0' * 64)
        self.assertEqual(sorted(p.name for p in self.out.iterdir()), [path.name])  # (the mismatch left nothing)

    def test_the_hash_file_is_a_sha256sum_line_or_a_bare_digest(self):
        sha = 'ab' * 32
        self.assertEqual(fm.parse_sha256(f'{sha}  subsdk9\n'), sha)
        self.assertEqual(fm.parse_sha256(sha.upper()), sha)
        for bad in ['', 'not a hash', 'ab' * 31, 'zz' * 32, '<html>' + sha]:
            with self.assertRaises(ValueError): fm.parse_sha256(bad)

    def test_latest_is_kept_only_under_its_published_hash(self):
        sha = hashlib.sha256(self.good).hexdigest()
        with serve({'subsdk9': self.good, 'subsdk9.sha256': f'{sha}  subsdk9\n'.encode()}) as base:
            path, got, version = fm.fetch_latest(self.out, base + 'subsdk9', allow_http=True)
        self.assertEqual((got, version), (sha, 'build-00010203'))
        with serve({'subsdk9': self.good, 'subsdk9.sha256': (b'1' * 64) + b'  subsdk9\n'}) as base:
            with self.assertRaises(ValueError): fm.fetch_latest(self.out, base + 'subsdk9', allow_http=True)
        with serve({'subsdk9': self.good}) as base:  # (no hash file: no module)
            with self.assertRaises(OSError): fm.fetch_latest(self.out, base + 'subsdk9', allow_http=True)
        with self.assertRaises(ValueError): fm.fetch_latest(self.out, 'http://example.com/subsdk9')
        self.assertEqual(sorted(p.name for p in self.out.iterdir()), [path.name])

    def test_a_missing_file_is_an_error_not_a_module(self):
        with serve({}) as base:
            with self.assertRaises(OSError): fm.fetch(base + 'nothing', self.out, allow_http=True)
        self.assertEqual(list(self.out.iterdir()), [])

    def test_a_build_never_seen_is_kept(self):
        other = bytearray(self.good); other[0x40:0x44] = b'\x01\x02\x03\x04'
        with serve({'other': bytes(other)}) as base:
            path, _, version = fm.fetch(base + 'other', self.out, allow_http=True)
        self.assertTrue(path.is_file())
        self.assertEqual(version, 'build-01020304')


if __name__ == '__main__':
    unittest.main()
