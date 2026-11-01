"""Portable catalogs contain references/state only; all shader bytes here are synthetic."""
import hashlib, importlib.util, json
from pathlib import Path
import tempfile, unittest
spec = importlib.util.spec_from_file_location('catalog', Path(__file__).parent/'za/shader_catalog.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def recipe(vs):
    key = dict(attr=[0]*32, rt=[0]*8, xfb_count=[0]*4, xfb_stride=[0]*4, params=[0]*11)
    return dict(version=1, program=dict(vs=vs, fs='', vkey=key, fkey=key),
                pipeline=dict(state=[0,0,1,0,1,0], colors=[[0]*9 for _ in range(8)],
                              attrs=[[0]*3 for _ in range(31)], layouts=[[0]*3 for _ in range(31)]))

class Catalog(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name); self.game=self.root/'game'; (self.game/'romfs/arc').mkdir(parents=True)
        self.code=bytes(range(64)); self.digest=hashlib.sha256(self.code).hexdigest()
        self.raw=b'prefix'+self.code+b'trailer'; (self.game/'romfs/arc/data.trpfs').write_bytes(self.raw)
        self.entry=dict(stage=0,size=64,const_offset=64,const_size=0,origin=dict(kind='trinity',path='arc/data.trpfs',
            offset=0,stored_size=len(self.raw),decoded_size=len(self.raw),codec=255,decoded_offset=6,
            source_sha256=hashlib.sha256(self.raw).hexdigest(),pack='private filename',entry='0011223344556677'))
        self.index=dict(version=1,sources={},shaders={self.digest:self.entry})
    def test_first_install_reconstructs_without_recordings_or_shader_cache(self):
        catalog=m.export_catalog([recipe(self.digest)],self.index,False)
        self.assertNotIn('private filename',json.dumps(catalog))
        installed=m.prepare(self.game,catalog,self.root/'cache',None)
        self.assertEqual((installed/'inputs'/f'{self.digest}.bin').read_bytes(),self.code)
        self.assertEqual(len((installed/'recipes.jsonl').read_text().splitlines()),1)
        self.assertEqual(m.prepare(self.game,catalog,self.root/'cache',None),installed)
    def test_partial_coverage_is_explicit(self):
        with self.assertRaises(ValueError):m.export_catalog([recipe('f'*64)],self.index,False)
        catalog=m.export_catalog([recipe(self.digest),recipe('f'*64)],self.index,True)
        self.assertEqual(catalog['omitted_recipes'],1)
        self.assertEqual(len(catalog['recipes']),1)
    def test_unknown_strings_and_source_paths_are_rejected(self):
        r=recipe(self.digest);r['code']='unwanted payload'
        with self.assertRaises(ValueError):m.export_catalog([r],self.index,False)
        self.entry['origin']['path']='../../outside'
        with self.assertRaises(ValueError):m.export_catalog([recipe(self.digest)],self.index,False)
    def test_mismatch_does_not_publish_and_never_uses_cached_game_bytes(self):
        catalog=m.export_catalog([recipe(self.digest)],self.index,False)
        (self.game/'romfs/arc/data.trpfs').write_bytes(b'x'*len(self.raw))
        with self.assertRaises(ValueError):m.prepare(self.game,catalog,self.root/'cache',None)
        self.assertFalse((self.root/'cache/current.json').exists())
    def test_resume_rejects_modified_source_and_cached_recipes(self):
        catalog=m.export_catalog([recipe(self.digest)],self.index,False)
        installed=m.prepare(self.game,catalog,self.root/'cache',None)
        (installed/'recipes.jsonl').write_text('{}')
        with self.assertRaises(ValueError):m.prepare(self.game,catalog,self.root/'cache',None)
        (installed/'recipes.jsonl').write_bytes(b''.join(m.encoded(r) for r in m.expand_catalog(catalog)['recipes']))
        (self.game/'romfs/arc/data.trpfs').write_bytes(b'x'*len(self.raw))
        with self.assertRaises(ValueError):m.prepare(self.game,catalog,self.root/'cache',None)

    def test_cached_index_is_verified_and_nso_requires_source_identity(self):
        catalog=m.export_catalog([recipe(self.digest)],self.index,False)
        installed=m.prepare(self.game,catalog,self.root/'cache',None)
        (installed/'inputs/index.json').write_text('{}')
        with self.assertRaises(ValueError):m.prepare(self.game,catalog,self.root/'cache',None)
        self.entry['origin']=dict(kind='nso',path='exefs/main',decoded_offset=0,source_sha256='f'*64)
        with self.assertRaises(ValueError):m.export_catalog([recipe(self.digest)],self.index,False)
        self.index['sources']={'exefs/main':'e'*64}
        with self.assertRaises(ValueError):m.export_catalog([recipe(self.digest)],self.index,False)

    def test_catalog_rejects_code_fields_and_unbounded_numbers(self):
        catalog=m.export_catalog([recipe(self.digest)],self.index,False)
        catalog['inputs'][self.digest]['code']='unwanted payload'
        with self.assertRaises(ValueError):m.validate_catalog(catalog)
        catalog=m.export_catalog([recipe(self.digest)],self.index,False)
        catalog['inputs'][self.digest]['origin']['decoded_size']=1<<40
        with self.assertRaises(ValueError):m.validate_catalog(catalog)

class Profiles(unittest.TestCase):
    setUp = Catalog.setUp
    def test_shared_profiles_expand_without_losing_recipe_information(self):
        r=recipe(self.digest);r2=json.loads(json.dumps(r));r2['pipeline']['state'][3]=1
        c=m.export_catalog([r,r2],self.index,False)
        self.assertEqual(c['version'],2)
        self.assertEqual(len(c['profiles']['vertex_keys']),1)
        self.assertEqual(len(c['profiles']['fragment_keys']),1)
        self.assertEqual(len(c['profiles']['descriptors']),2)
        expanded=m.expand_catalog(c)
        self.assertEqual({m.encoded(x) for x in expanded['recipes']},{m.encoded(m.recipe(x)) for x in (r,r2)})
    def test_inactive_blending_is_normalized_but_active_state_stays_distinct(self):
        a=recipe(self.digest);a['pipeline']['colors'][0]=[25,15,0,1,0,1,0,0,0]
        b=json.loads(json.dumps(a));b['pipeline']['colors'][0][3]=4
        c=m.export_catalog([a,b],self.index,False)
        self.assertEqual(len(c['recipes']),1)
        a['pipeline']['colors'][0][2]=b['pipeline']['colors'][0][2]=1
        self.assertEqual(len(m.export_catalog([a,b],self.index,False)['recipes']),2)
    def test_profile_references_and_unknown_payloads_are_rejected(self):
        c=m.export_catalog([recipe(self.digest)],self.index,False)
        c['recipes'][0]['vertex_key']=9999
        with self.assertRaises(ValueError):m.validate_catalog(c)
        c=m.export_catalog([recipe(self.digest)],self.index,False)
        c['profiles']['vertex_keys'][0]['msl']='unwanted payload'
        with self.assertRaises(ValueError):m.validate_catalog(c)
        c=m.export_catalog([recipe(self.digest)],self.index,False)
        c['profiles']['vertex_keys'].append(c['profiles']['vertex_keys'][0])
        with self.assertRaises(ValueError):m.validate_catalog(c)
    def test_legacy_local_catalog_can_still_be_read(self):
        c=m.expand_catalog(m.export_catalog([recipe(self.digest)],self.index,False))
        self.assertEqual(c['version'],1)
        self.assertIs(m.validate_catalog(c),c)
        installed=m.prepare(self.game,c,self.root/'legacy',None)
        self.assertTrue((installed/'recipes.jsonl').is_file())

class Contributions(unittest.TestCase):
    setUp = Catalog.setUp
    def test_metadata_contribution_deduplicates_and_rejects_unknown_fields(self):
        r=recipe(self.digest);doc=m.contribution_document([r,r])
        self.assertEqual(len(m.contribution_recipes(doc)),1)
        self.assertNotIn('inputs',doc)
        doc['shader_code']='unwanted payload'
        with self.assertRaises(ValueError):m.contribution_recipes(doc)
    def test_invalid_local_recipe_file_does_not_disable_base_preparation(self):
        catalog=self.root/'catalog.json';catalog.write_bytes(m.encoded(m.export_catalog([recipe(self.digest)],self.index,False)))
        bad=self.root/'invalid-local.jsonl';bad.write_bytes(b'\xff')
        self.assertEqual(m.main(['prepare',str(self.game),str(catalog),str(self.root/'prepared-base'),'--recipes',str(bad)]),0)
        self.assertTrue((self.root/'prepared-base/current.json').exists())
    def test_invalid_export_preserves_destination(self):
        src=self.root/'recipes.jsonl';src.write_text('{"code":"unwanted"}\n')
        dest=self.root/'out.json';dest.write_text('keep')
        self.assertEqual(m.main(['contribute',str(src),str(dest)]),1)
        self.assertEqual(dest.read_text(),'keep')
    def test_catalog_has_no_recipe_count_limit(self):
        hashes=['%064x'%i for i in range(1500)]
        index=dict(version=1,sources={},shaders={h:self.entry for h in hashes})
        c=m.export_catalog([recipe(h) for h in hashes],index);m.validate_catalog(c)
        self.assertEqual(len(m.expand_catalog(c)['recipes']),1500)

    def test_contribution_has_no_recipe_count_limit(self):
        rows=[recipe('%064x'%i) for i in range(5000)]
        self.assertEqual(len(m.contribution_recipes(m.contribution_document(rows))),5000)

    def test_contribution_can_be_reimported_and_local_variants_prepared(self):
        r=recipe(self.digest);base=m.export_catalog([r],self.index,False)
        other=json.loads(json.dumps(r));other['pipeline']['state'][3]=1
        doc=m.contribution_document([other]);path=self.root/'contribution.json';path.write_bytes(m.encoded(doc))
        rows=m.load_recipes(path)
        self.assertEqual(rows,[m.recipe(other)])
        merged=m.merge_local_recipes(base,rows+[recipe('f'*64)])
        self.assertEqual(len(merged['recipes']),2)
        self.assertEqual(len(merged['inputs']),1)
        installed=m.prepare(self.game,merged,self.root/'prepared',None)
        self.assertEqual(len((installed/'recipes.jsonl').read_text().splitlines()),2)

if __name__=='__main__':unittest.main()
