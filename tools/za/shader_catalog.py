"""Metadata-only shader catalogs and reconstruction from the player's own files.

No code bytes, native binaries, translated MSL or arbitrary paths enter a catalog.
Generated catalogs and reconstructed inputs are PRIVATE artifacts, never Git files.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile

MAX_FILE = 16 << 20
MAX_RECIPE_FILE = 100 << 20  # local journal and contribution files: only the size limits them
MAX_BLOCK = 128 << 20
HASH = re.compile(r'[0-9a-f]{64}\Z')

def digest(data): return hashlib.sha256(data).hexdigest()
def encoded(value): return (json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode()
def fields(value, names):
    if not isinstance(value,dict) or set(value)!=set(names): raise ValueError('unexpected catalog fields')
def number(value, limit):
    if type(value) not in (int,bool) or value<0 or value>limit: raise ValueError('numeric field outside limit')
    return int(value)
def sha(value):
    if not isinstance(value,str) or not HASH.fullmatch(value): raise ValueError('invalid SHA-256')
    return value

def array(value,n,limit):
    if not isinstance(value,list) or len(value)!=n: raise ValueError('invalid array shape')
    return [number(x,limit) for x in value]

def key(value):
    fields(value,('attr','rt','xfb_count','xfb_stride','params'))
    params=array(value['params'],11,(1<<32)-1)
    if any(params[i]>1 for i in (0,1,2,8)) or params[4]!=0 or params[9]>255 or params[10]>255:
        raise ValueError('invalid specialization flags')
    return dict(attr=array(value['attr'],32,2),rt=array(value['rt'],8,2),
                xfb_count=array(value['xfb_count'],4,255),xfb_stride=array(value['xfb_stride'],4,65535),params=params)

def recipe(value):
    fields(value,('version','program','pipeline'))
    if type(value['version']) is not int or value['version']!=1: raise ValueError('unsupported recipe version')
    p=value['program'];fields(p,('vs','fs','vkey','fkey'))
    fs=sha(p['fs']) if p['fs']!='' else ''
    return dict(version=1,program=dict(vs=sha(p['vs']),fs=fs,vkey=key(p['vkey']),fkey=key(p['fkey'])),pipeline=descriptor(value['pipeline']))

def descriptor(pd):
    fields(pd,('state','colors','attrs','layouts'))
    out=dict(state=array(pd['state'],6,1024))
    for name,count,width,limit in (('colors',8,9,1024),('attrs',31,3,1<<24),('layouts',31,3,1<<24)):
        if not isinstance(pd[name],list) or len(pd[name])!=count: raise ValueError('invalid descriptor shape')
        out[name]=[array(row,width,limit) for row in pd[name]]
    for color in out['colors']:
        if color[0]==0: color[1]=color[2]=0
        if color[2]==0: color[3:]=[0]*6
    return out

def input_reference(value):
    fields(value,('stage','size','const_offset','const_size','origin'))
    stage=number(value['stage'],1);size=number(value['size'],MAX_FILE)
    co=number(value['const_offset'],size);cs=number(value['const_size'],size)
    if co<16 or co+cs!=size: raise ValueError('invalid code/constant range')
    o=value['origin']
    if not isinstance(o,dict): raise ValueError('invalid origin')
    kind=o.get('kind'); source=sha(o.get('source_sha256'))
    decoded=number(o.get('decoded_offset'),1<<31)
    if kind=='nso':
        if o.get('path') not in ('exefs/main','exefs/sdk'): raise ValueError('unsupported NSO path')
        origin=dict(kind=kind,path=o['path'],source_sha256=source,decoded_offset=decoded)
    elif kind=='trinity':
        if o.get('path')!='arc/data.trpfs': raise ValueError('unsupported Trinity path')
        origin=dict(kind=kind,path=o['path'],source_sha256=source,decoded_offset=decoded,
                    offset=number(o.get('offset'),(1<<63)-1),stored_size=number(o.get('stored_size'),MAX_BLOCK),
                    decoded_size=number(o.get('decoded_size'),MAX_BLOCK),codec=number(o.get('codec'),255))
        if not origin['stored_size'] or decoded+size>origin['decoded_size']: raise ValueError('invalid decoded span')
    else: raise ValueError('unsupported origin')
    return dict(stage=stage,size=size,const_offset=co,const_size=cs,origin=origin)

def sources(value):
    if not isinstance(value,dict) or not set(value)<= {'exefs/main','exefs/sdk'}: raise ValueError('unsupported source files')
    return {k:sha(v) for k,v in value.items()}

def _export_v1(recipes,index,allow_partial=False):
    if not isinstance(recipes,list) or not recipes: raise ValueError('expected recipes')
    if index.get('version')!=1 or not isinstance(index.get('shaders'),dict): raise ValueError('invalid input index')
    module_sources=sources(index.get('sources',{}))
    inputs={};out={};omitted=0
    for raw in recipes:
        r=recipe(raw);p=r['program']; refs=[(p['vs'],0)]+([(p['fs'],1)] if p['fs'] else [])
        if any(h not in index['shaders'] for h,_ in refs):
            if not allow_partial: raise ValueError('unresolved shader reference; use --allow-partial explicitly')
            omitted+=1;continue
        for h,stage in refs:
            ref=input_reference(index['shaders'][h])
            if ref['stage']!=stage: raise ValueError('shader stage mismatch')
            if ref['origin']['kind']=='nso' and module_sources.get(ref['origin']['path'])!=ref['origin']['source_sha256']:
                raise ValueError('NSO reference requires a matching module fingerprint')
            inputs[h]=ref
        out[digest(encoded(r))]=r
    if not out: raise ValueError('no complete pipeline recipes')
    return dict(version=1,sources=module_sources,inputs=inputs,
                recipes=[out[k] for k in sorted(out)],omitted_recipes=omitted)

def _validate_v1(c):
    fields(c,('version','sources','inputs','recipes','omitted_recipes'))
    if type(c['version']) is not int or c['version']!=1: raise ValueError('unsupported catalog version')
    number(c['omitted_recipes'],1<<31)
    if not isinstance(c['inputs'],dict) or len(c['inputs'])>2048: raise ValueError('too many input references')
    for h,ref in c['inputs'].items():
        sha(h)
        if input_reference(ref)!=ref: raise ValueError('unexpected input-origin fields')
    clean=_export_v1(c['recipes'],dict(version=1,sources=c['sources'],shaders=c['inputs']))
    if set(clean['inputs'])!=set(c['inputs']): raise ValueError('unused input references')
    return c

def export_catalog(recipes,index,allow_partial=False):
    c=_export_v1(recipes,index,allow_partial)
    profiles,rows=pack_recipe_profiles(c['recipes'])
    return dict(version=2,sources=c['sources'],inputs=c['inputs'],profiles=profiles,recipes=rows,omitted_recipes=c['omitted_recipes'])

def pack_recipe_profiles(recipes):
    selections={name:{} for name in ('vertex_keys','fragment_keys','descriptors')}
    for r in recipes:
        for name,value in (('vertex_keys',r['program']['vkey']),('fragment_keys',r['program']['fkey']),('descriptors',r['pipeline'])):
            selections[name][encoded(value)]=value
    profiles={name:[values[k] for k in sorted(values)] for name,values in selections.items()}
    ids={name:{encoded(v):i for i,v in enumerate(table)} for name,table in profiles.items()}
    rows=[]
    for r in recipes:
        p=r['program']
        rows.append(dict(vs=p['vs'],fs=p['fs'],vertex_key=ids['vertex_keys'][encoded(p['vkey'])],
                         fragment_key=ids['fragment_keys'][encoded(p['fkey'])],descriptor=ids['descriptors'][encoded(r['pipeline'])]))
    return profiles,rows

def _expand_v2(c):
    fields(c,('version','sources','inputs','profiles','recipes','omitted_recipes'))
    rows=expand_recipe_profiles(c['profiles'],c['recipes'],None)
    return dict(version=1,sources=c['sources'],inputs=c['inputs'],recipes=rows,omitted_recipes=c['omitted_recipes'])

def expand_recipe_profiles(profiles,recipes,limit):
    fields(profiles,('vertex_keys','fragment_keys','descriptors'))
    for name,table in profiles.items():
        if not isinstance(table,list) or not table or (limit is not None and len(table)>limit):raise ValueError('invalid profile table size')
        normalized=[descriptor(v) if name=='descriptors' else key(v) for v in table]
        if encoded(normalized)!=encoded(table) or len({encoded(v) for v in table})!=len(table):
            raise ValueError('profiles must be canonical and distinct')
    if not isinstance(recipes,list) or not recipes or (limit is not None and len(recipes)>limit):raise ValueError('invalid recipe count')
    refs={name:set() for name in profiles};rows=[]
    for r in recipes:
        fields(r,('vs','fs','vertex_key','fragment_key','descriptor'))
        values={}
        for field,name in (('vertex_key','vertex_keys'),('fragment_key','fragment_keys'),('descriptor','descriptors')):
            i=r[field]
            if type(i) is not int or not 0<=i<len(profiles[name]):raise ValueError('profile reference outside table')
            refs[name].add(i);values[field]=profiles[name][i]
        rows.append(dict(version=1,program=dict(vs=r['vs'],fs=r['fs'],vkey=values['vertex_key'],fkey=values['fragment_key']),pipeline=values['descriptor']))
    if any(refs[name]!=set(range(len(table))) for name,table in profiles.items()):raise ValueError('unused profile')
    return rows

def validate_catalog(c):
    if not isinstance(c,dict) or type(c.get('version')) is not int:raise ValueError('invalid catalog version')
    if c['version']==1:_validate_v1(c)
    elif c['version']==2:_validate_v1(_expand_v2(c))
    else:raise ValueError('unsupported catalog version')
    return c

def expand_catalog(c):
    validate_catalog(c)
    return _expand_v2(c) if c['version']==2 else c

def contribution_document(rows):
    if not isinstance(rows,list) or not rows:raise ValueError('expected contribution recipes')
    unique={encoded(recipe(r)):recipe(r) for r in rows}
    profiles,recipes=pack_recipe_profiles([unique[k] for k in sorted(unique)])
    return dict(type='shader-recipes',version=1,profiles=profiles,recipes=recipes)

def contribution_recipes(doc):
    fields(doc,('type','version','profiles','recipes'))
    if doc['type']!='shader-recipes' or type(doc['version']) is not int or doc['version']!=1:raise ValueError('unsupported contribution')
    return [recipe(r) for r in expand_recipe_profiles(doc['profiles'],doc['recipes'],None)]

def load_recipes(path,allow_empty=False):
    with Path(path).open('rb') as f:data=f.read(MAX_RECIPE_FILE+1)
    if len(data)>MAX_RECIPE_FILE:raise ValueError('recipe file too large')
    text=data.decode('utf-8')
    try:doc=json.loads(text)
    except json.JSONDecodeError:doc=None
    if isinstance(doc,dict) and doc.get('type')=='shader-recipes':return contribution_recipes(doc)
    rows=[recipe(json.loads(line)) for line in text.splitlines() if line.strip()]
    if not rows and not allow_empty:raise ValueError('expected recipes')
    return rows

def merge_local_recipes(catalog,local):
    base=expand_catalog(catalog);rows={encoded(recipe(r)):recipe(r) for r in base['recipes']}
    missing=added=0
    for raw in local:
        r=recipe(raw);p=r['program'];identity=encoded(r)
        if identity in rows:continue
        if any(h and h not in base['inputs'] for h in (p['vs'],p['fs'])):missing+=1;continue
        rows[identity]=r;added+=1
    c=export_catalog(list(rows.values()),dict(version=1,sources=base['sources'],shaders=base['inputs']))
    c['omitted_recipes']=catalog['omitted_recipes']
    print(f'[shader-inputs] local recipes: {added} added, {missing} awaiting source references',file=sys.stderr,flush=True)
    return c

def catalog_with_local_recipes(catalog,path):
    if path:
        try:return merge_local_recipes(catalog,load_recipes(path,allow_empty=True))
        except (ValueError,OSError,KeyError,TypeError,RecursionError):
            print('[shader-inputs] invalid local recipes ignored; using installed catalog',file=sys.stderr)
    return catalog

def read_json(path):
    with Path(path).open('rb') as f: data=f.read(MAX_FILE+1)
    if len(data)>MAX_FILE: raise ValueError('metadata file too large')
    return json.loads(data)

def file_hash(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1<<20),b''):h.update(chunk)
    return h.hexdigest()

def source_path(game,relative):
    path=(game/relative).resolve()
    if not path.is_relative_to(game): raise ValueError('source symlink escapes game folder')
    return path

def prepare(game,catalog,output,decoder):
    """Return an immutable generation; publish current.json only after verification."""
    import fcntl
    validate_catalog(catalog)
    print(f'[shader-inputs] catalog: {len(catalog["recipes"])} covered recipes, {catalog["omitted_recipes"]} uncovered recipes omitted',file=sys.stderr,flush=True)
    game=Path(game).resolve(strict=True);output=Path(output)
    if output.is_symlink(): raise ValueError('output root must not be a symlink')
    output.mkdir(parents=True,exist_ok=True)
    generation=digest(encoded(catalog));destination=output/generation
    expanded=expand_catalog(catalog)
    fd=os.open(output/'.prepare.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        for relative,h in catalog['sources'].items():
            if file_hash(source_path(game,relative))!=h: raise ValueError('game version/source fingerprint mismatch')
        if destination.exists():
            if destination.is_symlink() or (destination/'inputs').is_symlink(): raise ValueError('generation must not contain directory symlinks')
            checked=set()
            for ref in catalog['inputs'].values():
                o=ref['origin']
                if o['kind']!='trinity':continue
                block=(o['offset'],o['stored_size'],o['source_sha256'])
                if block in checked:continue
                checked.add(block)
                with source_path(game,'romfs/'+o['path']).open('rb') as f:f.seek(o['offset']);raw=f.read(o['stored_size'])
                if len(raw)!=o['stored_size'] or digest(raw)!=o['source_sha256']:raise ValueError('compressed source fingerprint mismatch')
            for name in ('catalog.json','recipes.jsonl'):
                if (destination/name).is_symlink():raise ValueError('cached metadata must not be a symlink')
            if (destination/'catalog.json').read_bytes()!=encoded(catalog): raise ValueError('cached catalog mismatch')
            if (destination/'recipes.jsonl').read_bytes()!=b''.join(encoded(r) for r in expanded['recipes']):raise ValueError('cached recipes damaged; remove this generation and retry')
            index_path=destination/'inputs/index.json'
            expected_index=encoded(dict(version=1,sources=catalog['sources'],shaders=catalog['inputs']))
            if index_path.is_symlink() or index_path.read_bytes()!=expected_index:raise ValueError('cached index damaged; remove this generation and retry')
            for h,ref in catalog['inputs'].items():
                path=destination/'inputs'/f'{h}.bin'
                if path.is_symlink() or path.stat().st_size!=ref['size'] or file_hash(path)!=h: raise ValueError('cached input damaged; remove this generation and retry')
        else:
            staging=Path(tempfile.mkdtemp(prefix='.preparing-',dir=output))
            try:
                private=staging/'inputs';private.mkdir()
                groups={}
                for h,ref in catalog['inputs'].items():
                    block={k:v for k,v in ref['origin'].items() if k!='decoded_offset'}
                    groups.setdefault(encoded(block),[]).append((h,ref))
                done=0
                for block,refs in groups.items():
                    o=json.loads(block)
                    if o['kind']=='nso':
                        path=source_path(game,o['path'])
                        if file_hash(path)!=o['source_sha256']:raise ValueError('NSO source fingerprint mismatch')
                        from nso import Nso
                        data=Nso(str(path)).image
                    else:
                        path=source_path(game,'romfs/'+o['path'])
                        with path.open('rb') as f:f.seek(o['offset']);raw=f.read(o['stored_size'])
                        if len(raw)!=o['stored_size'] or digest(raw)!=o['source_sha256']:raise ValueError('compressed source fingerprint mismatch')
                        if o['codec']==255 or o['decoded_size']==len(raw):data=raw
                        else:
                            if decoder is None:raise ValueError('native shader decoder unavailable')
                            data=decoder.unpack(o['codec'],o['decoded_size'],raw)
                        if len(data)!=o['decoded_size']:raise ValueError('decoded block size mismatch')
                    for h,ref in refs:
                        off=ref['origin']['decoded_offset'];code=data[off:off+ref['size']]
                        if len(code)!=ref['size'] or digest(code)!=h:raise ValueError('reconstructed shader hash mismatch')
                        (private/f'{h}.bin').write_bytes(code);done+=1
                    print(f'[shader-inputs] {done}/{len(catalog["inputs"])} verified',file=sys.stderr,flush=True)
                (private/'index.json').write_bytes(encoded(dict(version=1,sources=catalog['sources'],shaders=catalog['inputs'])))
                (staging/'recipes.jsonl').write_bytes(b''.join(encoded(r) for r in expanded['recipes']))
                (staging/'catalog.json').write_bytes(encoded(catalog))
                staging.rename(destination)
            finally:
                if staging.exists():shutil.rmtree(staging)
        with tempfile.NamedTemporaryFile(prefix='.current-',dir=output,delete=False) as f:
            pointer=Path(f.name);f.write(encoded(dict(version=1,catalog=generation)))
        try:pointer.replace(output/'current.json')
        finally:pointer.unlink(missing_ok=True)
    return destination

def main(argv=None):
    ap=argparse.ArgumentParser(description=__doc__);sub=ap.add_subparsers(dest='command',required=True)
    ex=sub.add_parser('export');ex.add_argument('recipes',type=Path);ex.add_argument('index',type=Path);ex.add_argument('output',type=Path)
    ex.add_argument('--allow-partial',action='store_true')
    check=sub.add_parser('check');check.add_argument('catalog',type=Path)
    check.add_argument('--for-distribution',action='store_true',help='require minimized schema v2; structural check only, not legal clearance')
    pr=sub.add_parser('prepare');pr.add_argument('game',type=Path);pr.add_argument('catalog',type=Path);pr.add_argument('output',type=Path)
    pr.add_argument('--decoder',type=Path);pr.add_argument('--recipes',type=Path)
    co=sub.add_parser('contribute');co.add_argument('recipes',type=Path);co.add_argument('output',type=Path)
    up=sub.add_parser('update');up.add_argument('game',type=Path);up.add_argument('output',type=Path);up.add_argument('--decoder',type=Path);up.add_argument('--recipes',type=Path)
    status=sub.add_parser('status');status.add_argument('installed',type=Path)
    args=ap.parse_args(argv)
    try:
        if args.command=='status':
            from za.shader_catalog_update import catalog_status,NoCatalog
            try:print(json.dumps(dict(state=catalog_status(args.installed))))
            except NoCatalog as e:print(str(e),file=sys.stderr);return 2
        elif args.command=='update':
            from za.shader_catalog_update import update_catalog,NoCatalog
            from za.shader_inputs import ExternalDecoder
            decoder=args.decoder
            if decoder is None:
                candidate=Path(sys.executable).parent/'monzamac-shader-decode'
                if candidate.is_file():decoder=candidate
            try:c=update_catalog(args.game,args.output,ExternalDecoder(decoder) if decoder else None,args.recipes)
            except NoCatalog as e:print(str(e),file=sys.stderr);return 2
            print(f'Catalog verified and installed: {len(c["recipes"])} recipes; applied at next game start.')
        elif args.command=='export':
            rows=load_recipes(args.recipes)
            c=export_catalog(rows,read_json(args.index),args.allow_partial);validate_catalog(c)
            with args.output.open('xb') as f:f.write(encoded(c))
            print(f'Exported {len(c["recipes"])} recipes, {len(c["inputs"])} references; {c["omitted_recipes"]} omitted. Metadata only; keep local pending distribution review.')
        elif args.command=='contribute':
            document=contribution_document(load_recipes(args.recipes));contribution_recipes(document)
            if len(encoded(document))>MAX_RECIPE_FILE:raise ValueError('contribution exceeds metadata size limit')
            if args.output.is_symlink():raise ValueError('export destination must not be a symlink')
            with tempfile.NamedTemporaryFile(prefix='.shader-recipes-',dir=args.output.parent,delete=False) as f:
                temp=Path(f.name);f.write(encoded(document))
            try:temp.replace(args.output)
            finally:temp.unlink(missing_ok=True)
            print(f'Exported {len(document["recipes"])} metadata recipes. No uploads performed.')
        elif args.command=='check':
            c=validate_catalog(read_json(args.catalog))
            if args.for_distribution and c['version']!=2:raise ValueError('distribution checks require minimized schema v2')
            print(f'Metadata catalog: {len(c["recipes"])} recipes, {len(c["inputs"])} references, {c["omitted_recipes"]} omitted; no code fields permitted.')
        else:
            from za.shader_inputs import ExternalDecoder
            decoder=args.decoder
            if decoder is None:
                candidate=Path(sys.executable).parent/'monzamac-shader-decode'
                if candidate.is_file():decoder=candidate
            catalog=read_json(args.catalog)
            catalog=catalog_with_local_recipes(catalog,args.recipes)
            dest=prepare(args.game,catalog,args.output,ExternalDecoder(decoder) if decoder else None)
            print(json.dumps(dict(generation=str(dest),recipes=str(dest/'recipes.jsonl'),inputs=str(dest/'inputs'))))
        return 0
    except (ValueError,OSError,KeyError,TypeError,RecursionError) as e:
        print(f'Shader preparation failed: {e}',file=sys.stderr);return 1

if __name__=='__main__':
    sys.path.insert(0,str(Path(__file__).resolve().parents[1]));sys.exit(main())
