"""Collect original notices for the decoder's actual Cargo build, offline.

Reads dep-info rather than including every optional/dev crate in Cargo.lock.
No crate source or local build paths are copied into the release notice bundle.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import tomllib
import tarfile
import re

GENERATOR='monzamac-shader-decoder-notices'
SUPPORTED={'MIT','MIT OR Apache-2.0','Apache-2.0 OR MIT','Zlib OR Apache-2.0 OR MIT','Unlicense OR MIT','(MIT OR Apache-2.0) AND Unicode-3.0'}

def packages(deps,own):
    roots=set();cache={}
    for file in Path(deps).glob('*.d'):
        for token in shlex.split(file.read_text().replace('\\\n',' ')):
            p=Path(token.rstrip(':'))
            if not p.is_absolute() or p.suffix!='.rs' or not p.is_file():continue
            parent=p.parent
            if parent not in cache:
                cache[parent]=next((d for d in (parent,*parent.parents) if (d/'Cargo.toml').is_file()),None)
            root=cache[parent]
            if root and root.resolve()!=Path(own).resolve():roots.add(root)
    if not roots:raise ValueError('no compiled registry dependencies found; build the decoder first')
    return sorted(roots)

def verify_package(crate,expected,files):
    archive=crate.parents[2]/'cache'/crate.parent.name/(crate.name+'.crate')
    if not archive.is_file():raise ValueError(f'{crate.name}: original Cargo package archive unavailable')
    h=hashlib.sha256()
    with archive.open('rb') as f:
        for block in iter(lambda:f.read(1<<20),b''):h.update(block)
    if h.hexdigest()!=expected:raise ValueError(f'{crate.name}: archive checksum mismatch')
    with tarfile.open(archive,'r:gz') as tar:
        prefix=crate.name+'/'
        expected_notices={m.name[len(prefix):] for m in tar.getmembers() if m.isfile() and m.name.startswith(prefix)
                          and '/' not in m.name[len(prefix):] and notice_name(m.name[len(prefix):])}
        if expected_notices!={f.name for f in files}:raise ValueError(f'{crate.name}: upstream notice set is missing or modified')
        for file in [crate/'Cargo.toml',*files]:
            member=tar.extractfile(f'{crate.name}/{file.name}')
            if member is None or member.read()!=file.read_bytes():
                raise ValueError(f'{crate.name}: modified package manifest/notice')

def notice_name(name):
    return any(x in name.lower() for x in ('license','licence','copying','notice','copyright'))

def notice_files(crate):
    return sorted(p for p in crate.iterdir() if p.is_file() and notice_name(p.name))

def generate(deps,lockfile,own,rust_docs,output):
    locked={(p['name'],p['version']):p for p in tomllib.loads(Path(lockfile).read_text())['package']}
    output=Path(output);rust_docs=Path(rust_docs)
    if output.is_symlink():raise ValueError('notice output must not be a symlink')
    if output.exists():
        marker=output/'inventory.json'
        if not marker.is_file() or json.loads(marker.read_text()).get('generator')!=GENERATOR:
            raise ValueError('refusing to replace an unowned directory')
        verify(output)
    output.parent.mkdir(parents=True,exist_ok=True)
    stage=Path(tempfile.mkdtemp(prefix='.decoder-notices-',dir=output.parent))
    rows=[]
    try:
        for crate in packages(deps,own):
            p=tomllib.loads((crate/'Cargo.toml').read_text())['package']
            name,version,license=p['name'],p['version'],p.get('license')
            if not re.fullmatch(r'[A-Za-z0-9_-]+',name) or not re.fullmatch(r'[A-Za-z0-9.+_-]+',version):raise ValueError('invalid package identity')
            entry=locked.get((name,version))
            if not entry or not entry.get('source','').startswith('registry+'):
                raise ValueError(f'{name}: dependency is not a checksummed registry package in Cargo.lock')
            checksum=entry.get('checksum')
            if not checksum:raise ValueError(f'{name}: missing package checksum')
            if license not in SUPPORTED:raise ValueError(f'{name}: review unsupported license expression {license!r}')
            files=notice_files(crate)
            verify_package(crate,checksum,files)
            if not files and (name,version,license)==('oozextract','0.5.7','MIT'):
                files=[Path(__file__).parent/'shader_decode/licenses/oozextract-MIT.txt']
            if not files:raise ValueError(f'{name}: no license/notice files supplied')
            contents='\n'.join(f.read_text() for f in files)
            mit='Permission is hereby granted, free of charge' in contents
            zlib='origin of this software must not' in contents
            if not (mit or ('Zlib' in license and zlib)):
                raise ValueError(f'{name}: expected MIT/Zlib permission text is missing')
            if 'AND Unicode-3.0' in license and not any('unicode' in f.name.lower() for f in files):
                raise ValueError(f'{name}: mandatory Unicode notice missing')
            dest=stage/'crates'/f'{name}-{version}';dest.mkdir(parents=True)
            listed=[]
            for file in files:
                shutil.copy2(file,dest/file.name)
                listed.append(dict(file=f'crates/{name}-{version}/{file.name}',sha256=hashlib.sha256(file.read_bytes()).hexdigest()))
            rows.append(dict(name=name,version=version,license=license,package_sha256=checksum,notices=listed))
        if not (rust_docs/'COPYRIGHT-library.html').is_file() or not (rust_docs/'licenses').is_dir():
            raise ValueError('Rust standard-library copyright/licenses unavailable; install the rust-docs component')
        (stage/'rust').mkdir()
        shutil.copy2(rust_docs/'COPYRIGHT-library.html',stage/'rust/COPYRIGHT-library.html')
        shutil.copytree(rust_docs/'licenses',stage/'rust/licenses')
        inventory=dict(version=1,generator=GENERATOR,packages=sorted(rows,key=lambda x:(x['name'],x['version'])),
                       rust_notices='rust/COPYRIGHT-library.html',
                       rust_files={str(p.relative_to(stage)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (stage/'rust').rglob('*') if p.is_file()})
        (stage/'inventory.json').write_text(json.dumps(inventory,indent=2)+'\n')
        (stage/'README.txt').write_text('MonZaMac shader decoder: third-party notices\n\n'
            'Original notices for the checksummed crates used by this build are under crates/.\n'
            'Rust standard-library copyright/attribution information and referenced license texts are under rust/.\n'
            'inventory.json records package versions, declared license expressions and notice hashes.\n'
            'oozextract declares MIT; its attribution file records that no separate copyright notice was supplied.\n'
            'These notices concern the decoder software, not Nintendo game content or the metadata catalog.\n')
        verify(stage)
        old=None
        if output.exists():
            old=Path(tempfile.mkdtemp(prefix='.old-decoder-notices-',dir=output.parent));old.rmdir();output.rename(old)
        try:stage.rename(output)
        except BaseException:
            if old is not None:old.rename(output)
            raise
        if old is not None:shutil.rmtree(old)
        return inventory
    finally:
        if stage.exists():shutil.rmtree(stage)

def verify(output):
    output=Path(output)
    if output.is_symlink():raise ValueError('notice package must not be a symlink')
    output=output.resolve()
    if any(p.is_symlink() for p in output.rglob('*')):raise ValueError('symlinks are not allowed in notice packages')
    inventory=json.loads((output/'inventory.json').read_text())
    if inventory.get('generator')!=GENERATOR or inventory.get('version')!=1:raise ValueError('unknown notice inventory')
    files=dict(inventory['rust_files'])
    for package in inventory['packages']:
        for notice in package['notices']:files[notice['file']]=notice['sha256']
    if not inventory['packages'] or not files:raise ValueError('empty notice inventory')
    for relative,expected in files.items():
        p=output/relative
        if p.is_symlink() or not p.resolve().is_relative_to(output) or not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=expected:
            raise ValueError(f'notice missing or modified: {relative}')
    actual={str(p.relative_to(output)) for p in output.rglob('*') if p.is_file()}
    if actual!=set(files)|{'inventory.json','README.txt'}:raise ValueError('unexpected files in notice package')
    return inventory

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--verify',type=Path)
    ap.add_argument('--deps',type=Path);ap.add_argument('--lock',type=Path)
    ap.add_argument('--manifest',type=Path);ap.add_argument('--output',type=Path)
    ap.add_argument('--rust-docs',type=Path)
    a=ap.parse_args()
    try:
        if a.verify:
            result=verify(a.verify);print(f'Verified decoder notices for {len(result["packages"])} compiled crates');return 0
        if not all((a.deps,a.lock,a.manifest,a.output)):raise ValueError('generation requires --deps, --lock, --manifest and --output')
        docs=a.rust_docs
        if docs is None:
            sysroot=subprocess.check_output([os.environ.get('RUSTC','rustc'),'--print','sysroot'],text=True).strip()
            docs=Path(sysroot)/'share/doc/rust'
        result=generate(a.deps,a.lock,a.manifest.parent,docs,a.output)
        print(f'Packaged decoder notices for {len(result["packages"])} compiled crates and the Rust standard library')
        return 0
    except (ValueError,OSError,KeyError,subprocess.CalledProcessError) as e:
        print(f'Decoder notice packaging failed: {e}');return 1
if __name__=='__main__':raise SystemExit(main())
