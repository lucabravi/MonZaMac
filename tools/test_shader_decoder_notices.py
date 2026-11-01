"""License packaging safety; synthetic crates/toolchain only."""
import importlib.util,json,hashlib,tempfile,unittest,tarfile
from pathlib import Path
spec=importlib.util.spec_from_file_location('notices',Path(__file__).parent/'shader_decoder_notices.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class Notices(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
  self.deps=self.root/'deps';self.deps.mkdir();self.crate=self.root/'cache with spaces/src/registry/demo-1.0.0'
  (self.crate/'src').mkdir(parents=True);(self.crate/'src/lib.rs').write_text('// synthetic')
  (self.crate/'Cargo.toml').write_text('[package]\nname="demo"\nversion="1.0.0"\nlicense="MIT"\n')
  (self.crate/'LICENSE').write_text('Copyright Demo\nPermission is hereby granted, free of charge, to any person\n')
  (self.crate/'NOTICE').write_text('Original upstream notice\n')
  path=str(self.crate/'src/lib.rs').replace(' ','\\ ')
  (self.deps/'demo.d').write_text(f'target: {path}\n')
  self.lock=self.root/'Cargo.lock';self.refresh_archive()
  self.rust=self.root/'rust';(self.rust/'licenses').mkdir(parents=True)
  (self.rust/'COPYRIGHT-library.html').write_text('Rust library notices')
  (self.rust/'licenses/MIT.txt').write_text('Rust MIT text')
 def refresh_archive(self):
  self.archive=self.crate.parents[2]/'cache/registry/demo-1.0.0.crate';self.archive.parent.mkdir(parents=True,exist_ok=True)
  with tarfile.open(self.archive,'w:gz') as tar:
   for p in self.crate.rglob('*'):
    if p.is_file():tar.add(p,arcname=str(Path(self.crate.name)/p.relative_to(self.crate)))
  checksum=hashlib.sha256(self.archive.read_bytes()).hexdigest()
  self.lock.write_text('[[package]]\nname="demo"\nversion="1.0.0"\nsource="registry+https://github.com/rust-lang/crates.io-index"\nchecksum="'+checksum+'"\n')
 def run_generate(self):return m.generate(self.deps,self.lock,self.root/'own',self.rust,self.root/'out')
 def test_exact_original_notice_and_no_local_paths_in_inventory(self):
  self.run_generate();out=self.root/'out'
  self.assertEqual((out/'crates/demo-1.0.0/LICENSE').read_text(),(self.crate/'LICENSE').read_text())
  inventory=(out/'inventory.json').read_text();self.assertNotIn(str(self.root),inventory)
  self.assertTrue((out/'rust/COPYRIGHT-library.html').is_file())
  self.run_generate();m.verify(out)
  (out/'crates/demo-1.0.0/LICENSE').write_text('changed')
  with self.assertRaises(ValueError):m.verify(out)
 def test_missing_notice_checksum_mismatch_and_empty_build_fail(self):
  (self.crate/'LICENSE').unlink()
  with self.assertRaises(ValueError):self.run_generate()
  self.assertFalse((self.root/'out').exists())
  (self.crate/'LICENSE').write_text('Permission is hereby granted, free of charge\n')
  self.archive.write_bytes(self.archive.read_bytes()+b'changed')
  with self.assertRaises(ValueError):self.run_generate()
  (self.deps/'demo.d').unlink()
  with self.assertRaises(ValueError):self.run_generate()
 def test_unicode_notice_is_mandatory_and_unowned_output_is_preserved(self):
  p=self.crate/'Cargo.toml';p.write_text(p.read_text().replace('MIT','(MIT OR Apache-2.0) AND Unicode-3.0'));self.refresh_archive()
  with self.assertRaises(ValueError):self.run_generate()
  (self.crate/'LICENSE-UNICODE').write_text('Unicode License V3');self.refresh_archive()
  self.run_generate();self.assertTrue((self.root/'out/crates/demo-1.0.0/LICENSE-UNICODE').exists())
  (self.root/'out/inventory.json').unlink()
  with self.assertRaises(ValueError):self.run_generate()
  self.assertTrue((self.root/'out/crates/demo-1.0.0/LICENSE').exists())
 def test_deleted_notice_and_tampered_output_are_not_silently_accepted(self):
  (self.crate/'NOTICE').unlink()
  with self.assertRaises(ValueError):self.run_generate()
  (self.crate/'NOTICE').write_text('Original upstream notice\n')
  self.run_generate();extra=self.root/'out/unrelated.txt';extra.write_text('keep')
  with self.assertRaises(ValueError):self.run_generate()
  self.assertEqual(extra.read_text(),'keep')
  self.archive.unlink()
  with self.assertRaises(ValueError):self.run_generate()
if __name__=='__main__':unittest.main()
