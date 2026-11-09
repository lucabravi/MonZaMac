"""Synthetic jump-table discovery regressions; no game files or native compiler needed."""
from collections import Counter
import struct
from types import SimpleNamespace
import unittest

from gen import Module
from lifter import Lifter


BASE = 0x100000


class JumpTables(unittest.TestCase):
    def module(self, form, index):
        # Each table contains offsets 0 and 8 from its first case. X1-X3 hold
        # the table address, loaded offset and branch target respectively.
        load = 0xb8a05822 | (index << 16)  # ldrsw x2, [x1, wIndex, uxtw #2]
        tail = [0x52800160, 0xd65f03c0, 0x528002c0, 0xd65f03c0]
        if form == 'fallthrough':
            words = [0x7100041f | (index << 5),  # cmp wIndex, #1
                     0x54000148,  # b.hi default
                     0x10007fc1, load, 0x10000063,  # adr x1, table; ldrsw; adr x3, case0
                     0x8b020063, 0xd61f0060]  # add x3, x3, x2; br x3
            br, first = 0x18, 0x1c
            words += tail + [0x52800420, 0xd65f03c0]
        elif form == 'taken':
            words = [0x7100081f | (index << 5),  # cmp wIndex, #2
                     0x54000043, 0xd65f03c0,  # b.lo lookup; ret
                     0x10007fa1, load, 0x10000063,
                     0x8b020063, 0xd61f0060] + tail
            br, first = 0x1c, 0x20
        else:
            words = [0x12000000 | index,  # and wIndex, w0, #1
                     0x10007fe1, load, 0x10000063,
                     0x8b020063, 0xd61f0060] + tail
            br, first = 0x14, 0x18
        image = bytearray(0x2000)
        struct.pack_into(f'<{len(words)}I', image, 0, *words)
        struct.pack_into('<ii', image, 0x1000, 0, 8)
        m = Module.__new__(Module)
        m.base, m.lo, m.hi = BASE, BASE, BASE + 4 * len(words)
        m.nso = SimpleNamespace(image=image)
        m.words, m.lifter = words, Lifter(BASE)
        m.cache, m.stats, m.mu = {}, Counter(), None
        return m, BASE + br, [BASE + first, BASE + first + 8]

    def test_index_registers_include_frame_and_link_registers(self):
        for form in ('fallthrough', 'taken', 'masked'):
            for index in (4, 29, 30):
                with self.subTest(form=form, index=index):
                    m, br, expected = self.module(form, index)
                    self.assertEqual(m.jump_table(br, m.lo, m.hi), expected)


if __name__ == '__main__':
    unittest.main()
