"""Download the Lumiose module (subsdk9) for tools/lumiose/prepare.py, on the user's explicit request. Local only.

  fetch.py [--url URL] [--out DIR]

The default URL is the file in the Lumiose Online repository's branch, so it follows what the authors publish there. That
file can be older than what the module installs for itself on first use, and it can move; preparation fails closed for a
build it does not know. The file is checked before it is kept: https only, a size limit, an NSO header, a build this
tooling knows. It is written under its own hash and the path is printed, to be given to prepare.py as --module.
Nothing is downloaded unless this command is run.
"""
import argparse
import hashlib
import os
import sys
import tempfile
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
from versions import profile  # noqa: E402
from nso import Nso  # noqa: E402

DEFAULT_URL = ('https://raw.githubusercontent.com/TheMagnumChad/PokeZ-ARecomp-Online/refs/heads/pokemon-za/'
               'lumiose/subsdk9')
LIMIT = 16 << 20  # the module is about 4 MB


def fetch(url, out, opener=urllib.request.urlopen, allow_http=False, limit=LIMIT):
    """Download url into the folder `out`; returns (path, sha256, version). ValueError for anything not acceptable."""
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
            nso = Nso(part)  # raises ValueError for anything that is not a well-formed NSO
            version = profile(nso.build_id)[0]  # raises ValueError for a build this tooling does not know
            sha = digest.hexdigest()
            path = out / f'subsdk9-{sha[:16]}'
            os.replace(part, path)
            return path, sha, version
        except BaseException:
            part.unlink(missing_ok=True)
            raise


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--url', default=DEFAULT_URL)
    ap.add_argument('--out', type=Path, default=Path('build/lumiose-modules'))
    args = ap.parse_args()
    print(f'Downloading {args.url}')
    try:
        path, sha, version = fetch(args.url, args.out)
    except (ValueError, OSError) as e:
        print(f'Not kept: {e}', file=sys.stderr)
        sys.exit(1)
    print(f'Kept {path} (sha256 {sha}, module {version}); next: prepare.py --module {path}')


if __name__ == '__main__':
    main()
