"""Download the Lumiose module (subsdk9) for tools/lumiose/prepare.py, on the user's explicit request.

  fetch.py [--url URL [--sha256 HEX]] [--out DIR]

The default is the fixed link the Lumiose Online team keeps on its site for the newest live module, with the SHA-256 they
publish next to it (<url>.sha256): the download is kept only if it matches. The file is checked before it is kept: https
only, a size limit, that hash, an NSO header, a build this tooling knows (preparation fails closed for any other). It is
written under its own hash and the path is printed, to be given to prepare.py as --module. With --url another file can be
fetched; give its --sha256 to have it checked, else it is only checked as above.
Nothing is downloaded unless this command (or the setup that calls it, after the player's consent) is run.
"""
import argparse
import hashlib
import os
import re
import sys
import tempfile
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
from versions import profile  # noqa: E402
from nso import Nso  # noqa: E402

DEFAULT_URL = 'https://lumioseonline.site/downloads/latest/subsdk9'  # (its hash: DEFAULT_URL + '.sha256')
LIMIT = 16 << 20  # the module is about 4 MB


def parse_sha256(text):
    """The digest in a `sha256sum` line ("<64 hex>  <name>") or a bare digest; ValueError if there is none."""
    m = re.match(r'\s*([0-9a-fA-F]{64})(\s|$)', text)
    if not m:
        raise ValueError('the published SHA-256 is not a 64-digit hash')
    return m.group(1).lower()


def fetch(url, out, opener=urllib.request.urlopen, allow_http=False, limit=LIMIT, sha256=None):
    """Download url into the folder `out`; returns (path, sha256, version). ValueError for anything not acceptable,
    including a download that does not match `sha256` when one is given."""
    if not (url.startswith('https://') or (allow_http and url.startswith('http://'))):
        raise ValueError('the module is downloaded over https only')
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=out, prefix='download-', suffix='.part', delete=False) as tmp:
        part = Path(tmp.name)
        try:
            with opener(url, timeout=60) as response:
                final = getattr(response, 'url', url)
                if not (final.startswith('https://') or (allow_http and final.startswith('http://'))):
                    raise ValueError('the download was redirected away from https')
                digest, size = hashlib.sha256(), 0
                while True:
                    block = response.read(1 << 16)
                    if not block: break
                    size += len(block)
                    if size > limit: raise ValueError('the download is larger than a module can be')
                    digest.update(block); tmp.write(block)
            tmp.flush()
            if size < 0x100:
                raise ValueError('the download is too small to be a module')
            sha = digest.hexdigest()
            if sha256 and sha != sha256.lower():
                raise ValueError('the download does not match the SHA-256 the authors publish for it')
            nso = Nso(part)  # raises ValueError for anything that is not a well-formed NSO
            version = profile(nso.build_id)[0]  # raises ValueError for a build this tooling does not know
            path = out / f'subsdk9-{sha[:16]}'
            os.replace(part, path)
            return path, sha, version
        except BaseException:
            part.unlink(missing_ok=True)
            raise


def fetch_latest(out, url=DEFAULT_URL, opener=urllib.request.urlopen, allow_http=False):
    """The newest live module under its published SHA-256 (<url>.sha256); same results as fetch()."""
    scheme_ok = url.startswith('https://') or (allow_http and url.startswith('http://'))
    if not scheme_ok:
        raise ValueError('the module is downloaded over https only')
    with opener(url + '.sha256', timeout=60) as response:
        expected = parse_sha256(response.read(1024).decode('ascii', 'replace'))
    return fetch(url, out, opener=opener, allow_http=allow_http, sha256=expected)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--url')
    ap.add_argument('--sha256', help='the hash to check a --url download against')
    ap.add_argument('--out', type=Path, default=Path('build/lumiose-modules'))
    args = ap.parse_args()
    url = args.url or DEFAULT_URL
    print(f'Downloading {url}')
    try:
        if args.url:
            if not args.sha256:
                print('Note: no --sha256 given, the download is not checked against a published hash.', file=sys.stderr)
            path, sha, version = fetch(url, args.out, sha256=args.sha256)
        else:
            path, sha, version = fetch_latest(args.out)
    except (ValueError, OSError) as e:
        print(f'Not kept: {e}', file=sys.stderr)
        sys.exit(1)
    print(f'Kept {path} (sha256 {sha}, module {version}); next: prepare.py --module {path}')


if __name__ == '__main__':
    main()
