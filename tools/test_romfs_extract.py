"""Asset-free RomFS extractor tests: valid data, malformed metadata, path confinement, truncated data."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('romfs_extract', ROOT / 'tools/za/romfs_extract.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def image(file_name='test.bin', data=b'good', *, declared_size=None, parent=0x18, cycle=False):
    directory = bytearray(0x18 + 0x18 + 4)
    struct.pack_into('<I', directory, 0x18, 0x18 if cycle else 0)
    struct.pack_into('<I', directory, 0x18 + 0x14, 3)
    directory[0x18 + 0x18:0x18 + 0x1B] = b'arc'
    name = file_name.encode()
    file_meta = bytearray(0x20 + ((len(name) + 3) & ~3))
    struct.pack_into('<IIQQII', file_meta, 0, parent, 0xffffffff, 0,
                     len(data) if declared_size is None else declared_size, 0xffffffff, len(name))
    file_meta[0x20:0x20 + len(name)] = name
    doff = 0x50
    foff = doff + len(directory)
    data_off = foff + len(file_meta)
    header = struct.pack('<10Q', 0x50, 0, 0, doff, len(directory), 0, 0, foff, len(file_meta), data_off)
    return header + directory + file_meta + data


class RomfsExtractionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.src = self.root / 'romfs.bin'
        self.out = self.root / 'dest'

    def run_image(self, content):
        self.src.write_bytes(content)
        return module.extract(self.src, self.out)

    def test_valid_file(self):
        self.run_image(image())
        self.assertEqual((self.out / 'arc/test.bin').read_bytes(), b'good')

    def test_rejects_parent_traversal(self):
        with self.assertRaisesRegex(ValueError, 'unsafe RomFS file name'):
            self.run_image(image('../../escaped'))
        self.assertFalse((self.root / 'escaped').exists())

    def test_rejects_absolute_path_component(self):
        with self.assertRaisesRegex(ValueError, 'unsafe RomFS file name'):
            self.run_image(image('/tmp/escaped'))

    def test_rejects_truncated_data_before_writing(self):
        with self.assertRaisesRegex(ValueError, 'truncated RomFS file data'):
            self.run_image(image(declared_size=100))
        self.assertFalse((self.out / 'arc/test.bin').exists())

    def test_rejects_parent_cycle(self):
        with self.assertRaisesRegex(ValueError, 'parent chain'):
            self.run_image(image(cycle=True))

    def test_rejects_out_of_bounds_file_name(self):
        damaged = bytearray(image())
        entry = 0x50 + (0x18 + 0x18 + 4)
        struct.pack_into('<I', damaged, entry + 0x1c, 65535)
        with self.assertRaisesRegex(ValueError, 'truncated RomFS file name'):
            self.run_image(bytes(damaged))

    def test_rejects_output_symlink(self):
        self.out.mkdir()
        outside = self.root / 'outside'
        outside.mkdir()
        (self.out / 'arc').symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'leaves the destination directory'):
            self.run_image(image())
        self.assertFalse((outside / 'test.bin').exists())


if __name__ == '__main__':
    unittest.main()
