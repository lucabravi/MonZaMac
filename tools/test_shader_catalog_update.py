"""Synthetic official-catalog updates: no network or game material."""
import hashlib,json,sys,unittest
from pathlib import Path
from unittest import mock
sys.path.insert(0,str(Path(__file__).parent))
import test_shader_catalog as fixtures
recipe,m=fixtures.recipe,fixtures.m
from za import shader_catalog_update as u

class Update(unittest.TestCase):
    def setUp(self):
        self.fixture=fixtures.Catalog();self.fixture.setUp();self.addCleanup(self.fixture.doCleanups)
        self.game=self.fixture.game;self.out=self.fixture.root/'cache/shader-preparation/catalog.json'
        self.out.parent.mkdir(parents=True);self.out.write_bytes(b'previous catalog')
        c=m.export_catalog([recipe(self.fixture.digest)],self.fixture.index,False)
        self.body=m.encoded(c);self.release=[dict(draft=False,prerelease=False,assets=[dict(name='shader-catalog.json',id=12,size=len(self.body),digest='sha256:'+hashlib.sha256(self.body).hexdigest())])]
        self.urls=[];self.local=None
    def fetch(self,url,limit,accept):
        self.urls.append(url)
        return json.dumps(self.release).encode() if url==u.RELEASES else self.body
    def run_update(self):
        with mock.patch.object(u,'_fetch',side_effect=self.fetch):return u.update_catalog(self.game,self.out,recipes=self.local)
    def test_verified_update_and_fixed_official_urls(self):
        self.run_update();self.assertEqual(self.out.read_bytes(),self.body)
        self.assertEqual(self.urls,[u.RELEASES,u.ASSETS+'12'])
        self.assertTrue((self.out.parent/'current.json').is_file())
        self.assertEqual(self.out.stat().st_mode&0o777,0o600)
    def test_local_discoveries_are_merged_and_unknowns_preserved(self):
        extra=recipe(self.fixture.digest);extra['pipeline']['state'][3]=1
        pending=recipe('0'*64)
        self.local=self.fixture.root/'local.jsonl'
        journal=m.encoded(extra)+m.encoded(pending);self.local.write_bytes(journal)
        self.run_update()
        current=json.loads((self.out.parent/'current.json').read_bytes())
        merged=self.out.parent/current['catalog']/'recipes.jsonl'
        self.assertEqual(len(merged.read_text().splitlines()),2)
        self.assertEqual(self.local.read_bytes(),journal)
        self.assertEqual(self.out.read_bytes(),self.body) # official base remains separate
    def test_bad_local_journal_does_not_disable_official_update(self):
        self.local=self.fixture.root/'local.jsonl';self.local.write_bytes(b'{')
        self.run_update();self.assertEqual(self.out.read_bytes(),self.body)
        self.assertEqual(self.local.read_bytes(),b'{')
    def test_status_current_and_available_without_downloading_or_writing(self):
        with mock.patch.object(u,'_fetch',side_effect=self.fetch):
            self.assertEqual(u.catalog_status(self.out),'available')
            self.out.write_bytes(self.body)
            self.assertEqual(u.catalog_status(self.out),'current')
        self.assertEqual(self.urls,[u.RELEASES,u.RELEASES])
        self.assertFalse((self.out.parent/'current.json').exists())
    def test_status_failure_is_not_reported_as_current(self):
        self.release[0]['assets']=[]
        with mock.patch.object(u,'_fetch',side_effect=self.fetch):
            with self.assertRaises(u.NoCatalog):u.catalog_status(self.out)
        self.assertEqual(self.out.read_bytes(),b'previous catalog')
    def test_absent_asset_preserves_previous(self):
        self.release[0]['assets']=[]
        with self.assertRaises(u.NoCatalog):self.run_update()
        self.assertEqual(self.out.read_bytes(),b'previous catalog')
    def test_digest_mismatch_preserves_previous(self):
        self.release[0]['assets'][0]['digest']='sha256:'+'0'*64
        with self.assertRaises(ValueError):self.run_update()
        self.assertEqual(self.out.read_bytes(),b'previous catalog')
    def test_incompatible_game_preserves_previous(self):
        (self.game/'romfs/arc/data.trpfs').write_bytes(b'incompatible game')
        with self.assertRaises(ValueError):self.run_update()
        self.assertEqual(self.out.read_bytes(),b'previous catalog')
    def test_unknown_code_fields_rejected(self):
        c=json.loads(self.body);c['shader_code']='not permitted';self.body=m.encoded(c)
        self.release[0]['assets'][0].update(size=len(self.body),digest='sha256:'+hashlib.sha256(self.body).hexdigest())
        with self.assertRaises(ValueError):self.run_update()
        self.assertEqual(self.out.read_bytes(),b'previous catalog')
    def test_unsafe_asset_and_symlink_destination(self):
        self.release[0]['assets'][0]['id']='https://untrusted.invalid'
        with self.assertRaises(ValueError):self.run_update()
        self.release[0]['assets'][0]['id']=12
        self.out.unlink();self.out.symlink_to(self.fixture.root/'untouched')
        with self.assertRaises(ValueError):self.run_update()
        self.assertFalse((self.fixture.root/'untouched').exists())
    def test_drafts_and_prereleases_ignored(self):
        self.release[0]['prerelease']=True
        with self.assertRaises(u.NoCatalog):self.run_update()
    def test_oversized_payload_rejected(self):
        self.release[0]['assets'][0]['size']=u.MAX_FILE+1
        with self.assertRaises(ValueError):self.run_update()
        self.assertEqual(self.out.read_bytes(),b'previous catalog')

if __name__=='__main__':unittest.main()
