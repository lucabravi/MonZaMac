"""Bounds checks for synthetic .eh_frame_hdr function-discovery tables."""
import struct
from types import SimpleNamespace
import unittest

from analyze import eh_frame_functions


def fixture(wide=False):
    image = bytearray(0x100)
    # Version 1; pcrel sdata4 frame pointer; udata4 count; datarel table.
    struct.pack_into('<BBBBiI', image, 0x40, 1, 0x1b, 3, 0x3c if wide else 0x3b, 0, 2)
    struct.pack_into('<4q' if wide else '<4i', image, 0x4c, -0x20, 0x30, -0x10, 0x38)
    return SimpleNamespace(image=image, eh_start=0x40, eh_end=0x6c if wide else 0x5c)


class EhFrameFunctions(unittest.TestCase):
    def test_valid_signed_relative_tables(self):
        for wide in (False, True):
            with self.subTest(wide=wide):
                self.assertEqual(eh_frame_functions(fixture(wide)), [0x20, 0x30])

    def test_absent_table(self):
        n = fixture()
        n.eh_start = n.eh_end = 0
        self.assertEqual(eh_frame_functions(n), [])

    def test_header_and_fields_cannot_read_past_declared_end(self):
        for end in (0x43, 0x44, 0x47, 0x4b, 0x50, 0x58):
            n = fixture()
            n.eh_end = end
            with self.subTest(end=end), self.assertRaisesRegex(ValueError, 'frame'):
                eh_frame_functions(n)

    def test_header_range_must_fit_image(self):
        for start, end in ((-4, 0x5c), (0x40, 0x3f), (0x40, 0x101), (0x100, 0x104)):
            n = fixture()
            n.eh_start, n.eh_end = start, end
            with self.subTest(start=start, end=end), self.assertRaisesRegex(ValueError, 'frame'):
                eh_frame_functions(n)

    def test_table_count_must_fit_declared_range(self):
        for count in (3, 0xffffffff):
            n = fixture()
            struct.pack_into('<I', n.image, 0x48, count)
            with self.subTest(count=count), self.assertRaisesRegex(ValueError, 'frame'):
                eh_frame_functions(n)

    def test_negative_table_count_is_invalid(self):
        n = fixture()
        n.image[0x42] = 0x0b  # sdata4 count
        struct.pack_into('<i', n.image, 0x48, -1)
        with self.assertRaisesRegex(ValueError, 'frame'):
            eh_frame_functions(n)

    def test_unsupported_version_is_not_used_for_discovery(self):
        n = fixture()
        n.image[0x40] = 2
        with self.assertRaisesRegex(ValueError, 'version'):
            eh_frame_functions(n)

    def test_unsupported_pointer_encodings_are_rejected(self):
        for encoding in (0x2b, 0xbb):  # text-relative and indirect are not implemented
            n = fixture()
            n.image[0x43] = encoding
            with self.subTest(encoding=encoding), self.assertRaisesRegex(ValueError, 'encoding'):
                eh_frame_functions(n)


if __name__ == '__main__':
    unittest.main()
