# Makes fonts/nintendo_ext_003_keyboard.ttf from your NintendoExt / Standard font dumps (tools/za/nca_font.py): the
# Switch button glyphs (A B X Y L R ZL ZR + -, outline U+E0A0.. and filled U+E0E0..) redrawn as keyboard keys - a
# rounded box with the bound key's name, lettered with the Standard font. The names come from the settings file's
# bind_key_* lines (else the defaults, runtime/hle/bindings.c); rerun after rebinding. runtime/hle/pl.c loads it when
# the prompts are the keyboard's (prompts = keyboard, or auto with no controller). Needs fonttools.
# usage (from the repository root): python tools/za/keyboard_font.py [settings.ini]
import io, sys
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.reverseContourPen import ReverseContourPen

KEY = bytes([0x49, 0x62, 0x18, 0x06])
DEFAULTS = {'a': 'K', 'b': 'J', 'x': 'L', 'y': 'I', 'l': 'Q', 'r': 'E', 'zl': '1', 'zr': '3', 'plus': 'Return', 'minus': 'Backspace'}
SHORT = {'Return': 'Enter', 'Backspace': 'Bksp', 'Space': 'Space', 'Escape': 'Esc', 'Left Shift': 'Shift', 'Tab': 'Tab',
         'Left Ctrl': 'Ctrl', 'Keypad 0': 'Num0'}
# button -> (outline codepoint, filled codepoint)
GLYPHS = {'a': (0xE0A0, 0xE0E0), 'b': (0xE0A1, 0xE0E1), 'x': (0xE0A2, 0xE0E2), 'y': (0xE0A3, 0xE0E3),
          'l': (0xE0A4, 0xE0E4), 'r': (0xE0A5, 0xE0E5), 'zl': (0xE0A6, 0xE0E6), 'zr': (0xE0A7, 0xE0E7),
          'plus': (0xE0B3, 0xE0EF), 'minus': (0xE0B4, 0xE0F0)}


def bfttf(path):
    d = open(path, 'rb').read()
    size = int.from_bytes(bytes(a ^ b for a, b in zip(d[4:8], KEY)), 'big')
    return TTFont(io.BytesIO(bytes(d[8 + i] ^ KEY[i % 4] for i in range(size))))


binds = dict(DEFAULTS)
if len(sys.argv) > 1:
    for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
        k, _, v = line.partition('=')
        k, v = k.strip(), v.strip()
        if k.startswith('bind_key_') and v and k[9:] in binds:
            binds[k[9:]] = v
labels = {b: SHORT.get(v, v) for b, v in binds.items()}
print('labels:', labels)

ext = bfttf('fonts/nintendo_ext_003.bfttf')
std = bfttf('fonts/nintendo_udsg-r_std_003.bfttf')
ecmap, scmap = ext.getBestCmap(), std.getBestCmap()
egs, sgs = ext.getGlyphSet(), std.getGlyphSet()
scale_e = ext['head'].unitsPerEm / std['head'].unitsPerEm


def text_width(s):
    return sum(std['hmtx'][scmap[ord(ch)]][0] for ch in s if ord(ch) in scmap) * scale_e


def rect(pen, x0, y0, x1, y1, r, ccw=False):
    pts = [(x0 + r, y0), (x1 - r, y0), (x1, y0 + r), (x1, y1 - r), (x1 - r, y1), (x0 + r, y1), (x0, y1 - r), (x0, y0 + r)]
    if ccw:
        pts = pts[::-1]
    pen.moveTo(pts[0])
    for p in pts[1:]:
        pen.lineTo(p)
    pen.closePath()


glyf, hmtx = ext['glyf'], ext['hmtx']
for button, cps in GLYPHS.items():
    label = labels[button]
    for filled, cp in zip((False, True), cps):
        name = ecmap.get(cp)
        if not name:
            continue
        old = glyf[name]
        adv, lsb = hmtx[name]
        y0, y1 = (old.yMin, old.yMax) if hasattr(old, 'yMin') else (-100, 800)
        h = y1 - y0
        size = h * (0.62 if len(label) <= 2 else 0.5)  # letter height
        tscale = scale_e * size / (std['head'].unitsPerEm * 0.75)
        tw = text_width(label) * tscale / scale_e
        pad, stroke = h * 0.18, h * 0.08
        w = max(h, tw + 2 * pad)
        pen = TTGlyphPen(None)
        x0 = lsb if lsb > 0 else h * 0.05
        rect(pen, x0, y0, x0 + w, y1, h * 0.2, ccw=True)  # the key (outer edge: clockwise, as TrueType wants)
        if not filled:
            rect(pen, x0 + stroke, y0 + stroke, x0 + w - stroke, y1 - stroke, h * 0.14)  # hollow (counter-clockwise)
        # the label, centred: dark holes in a filled key, solid letters in a hollow one
        tx = x0 + (w - tw) / 2
        ty = y0 + (h - size) / 2 + size * 0.12
        dst = ReverseContourPen(pen) if filled else pen
        for ch in label:
            g = scmap.get(ord(ch))
            if not g:
                continue
            sgs[g].draw(TransformPen(dst, (tscale, 0, 0, tscale, tx, ty)))
            tx += std['hmtx'][g][0] * tscale
        glyf[name] = pen.glyph()
        hmtx[name] = (int(x0 * 2 + w), int(x0))
ext['hhea'].advanceWidthMax = max(m[0] for m in hmtx.metrics.values())
ext.save('fonts/nintendo_ext_003_keyboard.ttf')
print('wrote fonts/nintendo_ext_003_keyboard.ttf')
