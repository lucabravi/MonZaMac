"""Selective generation using the existing lifter; all output stays on the user's machine."""
from pathlib import Path
import sys,struct,json,re,bisect,hashlib
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'tools'))
import gen
from nso import Nso
import argparse, shlex
ap=argparse.ArgumentParser(description='Prepare selectively patched game sources from local snapshots')
for name in ['source','build','generated','capture','module-table','out']:
 ap.add_argument('--'+name,required=True,type=Path)
a=ap.parse_args()
SOURCE=a.source; BUILD=a.build; GENERATED=a.generated; CAPTURE=a.capture; MOD_TABLE=a.module_table; OUT=a.out
OUT.mkdir(parents=True,exist_ok=True)
index=json.loads((OUT/'source-index.json').read_text());hooks=json.loads((OUT/'hooks.json').read_text());scan=json.loads((OUT/'scan.json').read_text())
(OUT/'stage').mkdir(exist_ok=True);(OUT/'src').mkdir(exist_ok=True)
manifest={'generation_id':(BUILD/'lasgame.dylib.id').read_text().strip(),'sources':{},'compile':[],'object_replacements':{}}
known_mod={int(x,16) for x in re.findall(r'void f_([0-9a-f]+)\(Cpu \*c\);',MOD_TABLE.read_text())}
for name,base in [('main',0x7000000000),('sdk',0x7008000000)]:
 original=SOURCE/'extracted/exefs'/name;n=Nso(original);raw=original.read_bytes();image=(CAPTURE/(name+'.image')).read_bytes();lo,size=n.text
 header=bytearray(raw[:0x100]);struct.pack_into('<I',header,0xc,struct.unpack_from('<I',header,0xc)[0]&~7);payload=bytearray(header)
 for i in range(3):
  _,mem,length=struct.unpack_from('<III',header,0x10+16*i);segment=image[mem:mem+length] if i==0 else bytes(n.image[mem:mem+length])
  struct.pack_into('<I',payload,0x10+16*i,len(payload));struct.pack_into('<I',payload,0x60+4*i,length);payload[0xa0+32*i:0xc0+32*i]=hashlib.sha256(segment).digest();payload.extend(segment)
 staged=OUT/'stage'/name;staged.write_bytes(payload)
 m=gen.Module(name,str(staged),base,simd='asm',flag_fusion=True)
 gen.PATCHES.clear()
 if name=='main':gen.PATCHES.update(gen.za_patches(n.build_id[:16]))
 collisions=set(gen.PATCHES)&{h['entry'] for h in hooks[name]};assert not collisions,('mod/builtin patch conflict',collisions)
 table=(GENERATED/name/(name+'_table.c')).read_text();known={int(x,16) for x in re.findall(r'void f_([0-9a-f]+)\(Cpu \*c\);',table)};ordered=sorted(known)
 for h in hooks[name]:assert h['target'] in known_mod,('missing mod hook',hex(h['target']))
 new={int(x,16) for x in scan[name]['new_entry_candidates']}-known
 parents={h['parent'] for h in hooks[name]};entry_hooks={h['entry'] for h in hooks[name] if h['entry']==h['parent']}
 functions={};refs_by_fn={};pending=parents|new
 while pending:
  a=min(pending);pending.remove(a)
  if a in functions:continue
  end=a+4 if a in entry_hooks else (ordered[bisect.bisect_right(ordered,a)] if bisect.bisect_right(ordered,a)<len(ordered) else m.hi)
  labels,ext,tables=m.scan(a,end);lines=m.emit_function(a,end,labels,tables,{})
  functions[a]='\n'.join(lines);refs_by_fn[a]=set(m._refs)
  for target in m._refs:
   if m.in_text(target) and target not in known and target not in functions:pending.add(target);new.add(target)
 source_dir=OUT/'src'/name;source_dir.mkdir(exist_ok=True)
 chunks=index[name]['chunks'];starts=[x[0] for x in chunks];by_file={}
 for a in parents:
  path=chunks[bisect.bisect_right(starts,a)-1][1];by_file.setdefault(path,set()).add(a)
 for path,addresses in by_file.items():
  original_c=Path(path);text=original_c.read_text();extra_refs=set()
  for a in addresses:
   pattern=re.compile(r'void f_'+format(a,'x')+r'\(Cpu \*c\) \{.*?\n\}',re.S);matches=list(pattern.finditer(text));assert len(matches)==1,(path,hex(a))
   match=matches[0];text=text[:match.start()]+functions[a]+text[match.end():];extra_refs|=refs_by_fn[a]
  declarations={int(x,16) for x in re.findall(r'void f_([0-9a-f]+)\(Cpu \*c\);',text)}
  text=''.join('void f_%x(Cpu *c);\n'%r for r in sorted(extra_refs-declarations))+text
  # cpu.h must precede any new forward declarations.
  if extra_refs-declarations:text='#include "cpu.h"\n'+text
  output=source_dir/original_c.name;output.write_text(text);target=OUT/'obj'/name/(original_c.stem+'.o')
  manifest['compile'].append([str(output),str(target)]);manifest['object_replacements']['build/za202/obj/'+name+'/'+original_c.stem+'.o']=str(target)
 # Additional original-return entries are independently translated from the captured code.
 batches=[];batch=[];chars=0
 for a in sorted(new):
  body=functions[a]
  if batch and (chars+len(body)>150000 or len(batch)>=16):batches.append(batch);batch=[];chars=0
  batch.append(a);chars+=len(body)
 if batch:batches.append(batch)
 extras=[]
 for number,addresses in enumerate(batches):
  refs=set().union(*(refs_by_fn[a] for a in addresses));text='#include "cpu.h"\n'+''.join('void f_%x(Cpu *c);\n'%r for r in sorted(refs))+'\n'+'\n'.join(functions[a] for a in addresses)+'\n'
  output=source_dir/('%s_returns_%03d.c'%(name,number));output.write_text(text);target=OUT/'obj'/name/(output.stem+'.o');manifest['compile'].append([str(output),str(target)]);extras.append(str(target))
 all_addresses=sorted(known|new);text='#include "cpu.h"\n'+''.join('void f_%x(Cpu *c);\n'%a for a in all_addresses)
 text+='const uint64_t %s_fn_addrs[] = {\n'%name+',\n'.join('0x%xull'%a for a in all_addresses)+'\n};\n'
 text+='const GuestFn %s_fn_ptrs[] = {\n'%name+',\n'.join('f_%x'%a for a in all_addresses)+'\n};\nconst uint64_t %s_fn_count = %d;\n'%(name,len(all_addresses))
 output=source_dir/(name+'_table.c');output.write_text(text);target=OUT/'obj'/name/(name+'_table.o');manifest['compile'].append([str(output),str(target)]);manifest['object_replacements']['build/za202/obj/'+name+'/'+name+'_table.o']=str(target)
 manifest['sources'][name]={'hooked_functions':len(parents),'new_returns':len(new),'changed_chunks':len(by_file),'extra_objects':extras,'largest_generated_function':max(map(len,functions.values())),'input_sha256':hashlib.sha256(raw).hexdigest(),'capture_text_sha256':hashlib.sha256(image[lo:lo+size]).hexdigest()}
 print(name,'hooks',len(parents),'return entries',len(new),'changed chunks',len(by_file),'largest function bytes',manifest['sources'][name]['largest_generated_function'],flush=True)
 del m
objects=[]
for old in shlex.split((BUILD/'lasgame.dylib.rsp').read_text()):
 original=Path(old)
 if not original.is_absolute():original=SOURCE/original
 rel=original.relative_to(BUILD).as_posix()
 key='build/za202/'+rel
 objects.append(manifest['object_replacements'].get(key,str(original)))
for value in manifest['sources'].values():objects+=value['extra_objects']
manifest['objects']=objects;manifest['reuse_count']=len(objects)-len(manifest['compile'])
(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2))
print('Compile objects',len(manifest['compile']),'reuse',manifest['reuse_count'],flush=True)
