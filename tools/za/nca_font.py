# Extracts the Switch system fonts (.bfttf) from a firmware dump (a folder of NCAs, e.g. Ryujinx's firmware) using
# the user's own prod.keys. Needs pycryptodome. usage: python nca_font.py <firmware dir> <prod.keys> <out dir>
# Writes nintendo_ext_003.bfttf, nintendo_udsg-r_std_003.bfttf, ... (what runtime/hle/pl.c looks for in fonts/).
import os, struct, sys
from Crypto.Cipher import AES
from Crypto.Util import Counter

FONT_TITLES = {0x0100000000000810, 0x0100000000000811, 0x0100000000000812, 0x0100000000000813, 0x0100000000000814}

def load_keys(path):
    keys = {}
    for line in open(path, encoding='utf-8', errors='replace'):
        if '=' in line:
            k, v = line.split('=', 1)
            try: keys[k.strip()] = bytes.fromhex(v.strip())
            except ValueError: pass
    return keys

def xts_decrypt(data, key, sector0=0, sector_size=0x200):
    # Nintendo's AES-XTS: the tweak is the sector number, big-endian
    k1, k2 = AES.new(key[:16], AES.MODE_ECB), AES.new(key[16:], AES.MODE_ECB)
    out = bytearray()
    for s in range(len(data) // sector_size):
        t = bytearray(k2.encrypt((sector0 + s).to_bytes(16, 'big')))
        blk = data[s * sector_size:(s + 1) * sector_size]
        for i in range(0, sector_size, 16):
            x = bytes(a ^ b for a, b in zip(blk[i:i + 16], t))
            out += bytes(a ^ b for a, b in zip(k1.decrypt(x), t))
            carry = 0
            for j in range(16):  # tweak *= x (GF(2^128), little-endian)
                nc = t[j] >> 7
                t[j] = ((t[j] << 1) | carry) & 0xFF
                carry = nc
            if carry: t[0] ^= 0x87
    return bytes(out)

def main():
    fw, keyfile, out = sys.argv[1:4]
    keys = load_keys(keyfile)
    hk = keys['header_key']
    os.makedirs(out, exist_ok=True)
    for name in sorted(os.listdir(fw)):
        if not name.endswith('.nca') or name.endswith('.cnmt.nca'): continue
        path = os.path.join(fw, name)
        if os.path.isdir(path): path = os.path.join(path, '00')  # (split NCA folders)
        f = open(path, 'rb')
        hdr = xts_decrypt(f.read(0xC00), hk)
        if hdr[0x200:0x204] != b'NCA3': continue
        tid = struct.unpack_from('<Q', hdr, 0x210)[0]
        if tid not in FONT_TITLES: continue
        gen = max(hdr[0x206], hdr[0x220])
        mk = max(gen - 1, 0)
        kak_name = ['key_area_key_application', 'key_area_key_ocean', 'key_area_key_system'][hdr[0x207]] + '_%02x' % mk
        kak = AES.new(keys[kak_name], AES.MODE_ECB)
        ctr_key = kak.decrypt(hdr[0x300 + 0x20:0x300 + 0x30])
        start, end = struct.unpack_from('<II', hdr, 0x240)
        fsh = hdr[0x400:0x600]
        sec_off = start * 0x200
        ctr_hi = fsh[0x140:0x148][::-1]

        def read(off, size):  # section-relative, AES-CTR
            a = off & ~0xF
            f.seek(sec_off + a)
            raw = f.read(size + (off - a) + 16)
            c = Counter.new(64, prefix=ctr_hi, initial_value=(sec_off + a) >> 4)
            return AES.new(ctr_key, AES.MODE_CTR, counter=c).decrypt(raw)[off - a:off - a + size]

        assert fsh[0x8:0xC] == b'IVFC', 'not a RomFS section'
        lvl_off, lvl_size = struct.unpack_from('<QQ', fsh, 0x8 + 0x10 + 5 * 0x18)
        rh = read(lvl_off, 0x50)
        fields = struct.unpack_from('<10Q', rh)
        fmeta_off, fmeta_size, data_off = fields[7], fields[8], fields[9]
        meta = read(lvl_off + fmeta_off, fmeta_size)
        p = 0
        while p < len(meta):
            _, _, doff, dsize, _, nlen = struct.unpack_from('<IIQQII', meta, p)
            fname = meta[p + 0x20:p + 0x20 + nlen].decode()
            open(os.path.join(out, fname), 'wb').write(read(lvl_off + data_off + doff, dsize))
            print('%016x %s -> %s (%d bytes)' % (tid, name, fname, dsize))
            p += (0x20 + nlen + 3) & ~3

main()
