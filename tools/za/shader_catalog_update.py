"""Explicit metadata-only updates from the project's official GitHub releases."""
import hashlib,json,os,subprocess,tempfile
from pathlib import Path
from .shader_catalog import MAX_FILE,prepare,validate_catalog,catalog_with_local_recipes

RELEASES='https://api.github.com/repos/lucabravi/MonZaMac/releases?per_page=20'
ASSETS='https://api.github.com/repos/lucabravi/MonZaMac/releases/assets/'

class NoCatalog(ValueError):pass

def _fetch(url,limit,accept):
    # Use the OS TLS trust store, not a developer-machine Python certificate path.
    curl=Path('/usr/bin/curl')
    with tempfile.TemporaryDirectory(prefix='monzamac-catalog-download-') as temp:
        path=Path(temp)/'download'
        try:
            subprocess.run([str(curl),'--fail','--silent','--show-error','--location',
                '--proto','=https','--proto-redir','=https','--connect-timeout','10','--max-time','25',
                '--max-filesize',str(limit),'--header','Accept: '+accept,'--user-agent','MonZaMac-catalog',
                '--output',str(path),url],check=True,timeout=30,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        except (OSError,subprocess.SubprocessError) as e:
            raise ValueError('Could not download the official catalog; previous catalog kept') from e
        if path.stat().st_size>limit:raise ValueError('catalog download exceeds size limit')
        return path.read_bytes()

def latest_catalog_asset():
    payload=_fetch(RELEASES,2<<20,'application/vnd.github+json')
    if len(payload)>2<<20:raise ValueError('release list exceeds size limit')
    releases=json.loads(payload)
    if not isinstance(releases,list) or len(releases)>20:raise ValueError('invalid release list')
    asset=None
    for release in releases:
        if not isinstance(release,dict) or release.get('draft') is not False or release.get('prerelease') is not False:continue
        assets=release.get('assets',[])
        if not isinstance(assets,list):raise ValueError('invalid release assets')
        matching=[a for a in assets if isinstance(a,dict) and a.get('name')=='shader-catalog.json']
        if len(matching)>1:raise ValueError('ambiguous catalog assets')
        if matching:asset=matching[0];break
    if asset is None:raise NoCatalog('No published shader catalog is available yet')
    ident,size,digest=asset.get('id'),asset.get('size'),asset.get('digest')
    if type(ident) is not int or not 0<ident<1<<63 or type(size) is not int or not 0<size<=MAX_FILE:
        raise ValueError('invalid catalog asset metadata')
    if not isinstance(digest,str) or len(digest)!=71 or not digest.startswith('sha256:') or any(c not in '0123456789abcdef' for c in digest[7:]):
        raise ValueError('official asset must have a SHA-256 digest')
    return asset

def catalog_status(installed):
    asset=latest_catalog_asset()
    path=Path(installed)
    if path.is_symlink() or not path.is_file() or path.stat().st_size!=asset["size"]:return "available"
    if path.stat().st_size>MAX_FILE:return "available"
    return "current" if hashlib.sha256(path.read_bytes()).hexdigest()==asset["digest"][7:] else "available"

def update_catalog(game,output,decoder=None,recipes=None):
    output=Path(output)
    # The app's cache root and immediate destination must not redirect writes.
    if any(p.is_symlink() for p in (output,output.parent,output.parent.parent)):
        raise ValueError('catalog destination must not contain symlinks')
    asset=latest_catalog_asset()
    ident,size,digest=asset["id"],asset["size"],asset["digest"]
    body=_fetch(ASSETS+str(ident),MAX_FILE,'application/octet-stream')
    if len(body)!=size or hashlib.sha256(body).hexdigest()!=digest[7:]:raise ValueError('catalog asset digest/size mismatch')
    catalog=validate_catalog(json.loads(body))
    if catalog['version']!=2:raise ValueError('downloaded catalog must use minimized schema v2')
    output.parent.mkdir(parents=True,exist_ok=True)
    # Verify source identities, decode only the player's files, and reconstruct
    # every input before replacing the catalog. Existing generations stay intact.
    prepare(game,catalog_with_local_recipes(catalog,recipes),output.parent,decoder)
    with tempfile.NamedTemporaryFile(prefix='.catalog-',dir=output.parent,delete=False) as f:
        temporary=Path(f.name);f.write(body);f.flush();os.fsync(f.fileno())
    try:temporary.replace(output)
    finally:temporary.unlink(missing_ok=True)
    return catalog
