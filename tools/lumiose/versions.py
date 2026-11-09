"""What preparation reads from the module itself. Any module build goes through this: no list of known builds, so a new
build of the mod needs no MonZaMac release as long as it keeps working the same way (the start-up check decides)."""
import re
import struct

GAME_PREFIX = 'b1f12fd919eae86a'
RECOMP_PLATFORM = 2  # (the mod's own number for its PC build; the Switch build of the same mod is another)


def full_build_id(build_id):
    """The 32-byte build id as 64 hex digits. tools/nso.py trims the zero padding of the id, the runtime's
    identity check (identity.c) uses all 32 bytes."""
    return build_id.ljust(64, '0')


def version_name(build_id):
    return 'build-' + build_id[:8]


def module_info(log):
    """((major, minor, patch, build), platform) a module printed about itself when it started, or None."""
    found = re.search(r'\[update\] this build is (\d+)\.(\d+)\.(\d+) build (\d+) \(platform (\d+),', log)
    return (tuple(int(x) for x in found.groups()[:4]), int(found.group(5))) if found else None


def _adrp(word, pc):
    imm = (((word >> 5) & 0x7ffff) << 2 | (word >> 29) & 3) << 12
    return (pc & ~0xfff) + (imm - (1 << 33) if imm & (1 << 32) else imm)


def _is_stop(word):
    return word & 0xfc000000 in (0x14000000, 0x94000000) or word & 0xfe000000 == 0xd6000000  # b, bl, br/blr/ret


def _cmp_limit(word, reg):
    """The bound of `cmp w/x<reg>, #imm`, or None."""
    if word & 0x7f80001f == 0x7100001f and not word >> 22 & 1 and (word >> 5) & 31 == reg:
        return (word >> 10) & 0xfff
    return None


def jump_tables(nso):
    """[(image offset, entries, 'h'|'b', base address)] of the compiler's switch tables in the module's code:
    ldrh/ldrb wV, [xT, wI...] ; adr xB, base ; add xJ, xB, wV, sxth/sxtb #2 ; br xJ, bounded by cmp wI, #N and a branch.
    Code that only such a table reaches has no other way to be found: its targets are entry points for the generator.
    A site whose table or bound cannot be read is left out; the start-up check is what says the version works."""
    start, size = nso.text
    end = start + size
    ro_start, ro_size = nso.rodata
    words = struct.unpack_from('<%dI' % (size // 4), nso.image, start)
    word = lambda pc: words[(pc - start) // 4]
    guards = {}  # where a b.ls / b.lo lands -> the branch (a table block reached by a taken branch)
    for i, w in enumerate(words):
        if w & 0xff000010 == 0x54000000 and w & 15 in (9, 3):
            imm = (w >> 5) & 0x7ffff
            guards.setdefault(start + i * 4 + (imm - (1 << 19) if imm & (1 << 18) else imm) * 4, start + i * 4)
    found = []
    for adr_pc in range(start + 4, end - 8, 4):
        adr, add, br = word(adr_pc), word(adr_pc + 4), word(adr_pc + 8)
        if adr & 0x9f000000 != 0x10000000 or add & 0xffe00000 != 0x8b200000 or br & 0xfffffc1f != 0xd61f0000:
            continue
        if (add >> 5) & 31 != adr & 31 or (add >> 10) & 7 != 2 or (add >> 13) & 7 not in (4, 5) or (br >> 5) & 31 != add & 31:
            continue
        kind = 'b' if (add >> 13) & 7 == 4 else 'h'
        value = (add >> 16) & 31
        load_pc = next((p for p in range(adr_pc - 4, max(start, adr_pc - 20) - 4, -4)
                        if word(p) & 0xffe00c00 == (0x38600800 if kind == 'b' else 0x78600800) and word(p) & 31 == value), None)
        if load_pc is None:
            continue
        table_reg, index = (word(load_pc) >> 5) & 31, (word(load_pc) >> 16) & 31
        table = None
        for p in range(load_pc - 4, max(start, load_pc - 0x4000) - 4, -4):  # (the table's address is often made far earlier)
            w = word(p)
            if w & 0xff800000 == 0x91000000 and w & 31 == table_reg and not w >> 22 & 1:
                source = (w >> 5) & 31
                for q in range(p - 4, max(start, p - 0x100) - 4, -4):
                    if word(q) & 0x9f00001f == 0x90000000 | source:
                        table = _adrp(word(q), q) + ((w >> 10) & 0xfff)
                        break
                break
        if table is None or not ro_start <= table < ro_start + ro_size:
            continue
        count = None
        p = load_pc - 4
        while p >= start and load_pc - p <= 64 and not _is_stop(word(p)):
            w = word(p)
            if w & 0xff000010 == 0x54000000 and w & 15 in (8, 2):  # the guard falls through to the table: b.hi / b.hs
                for c in range(p - 4, max(start, p - 32) - 4, -4):
                    limit = _cmp_limit(word(c), index)
                    if limit is not None:
                        count = limit + 1 if w & 15 == 8 else limit
                        break
                break
            p -= 4
        else:
            guard = guards.get(p + 4)  # the block starts after the jump above it: b.ls / b.lo lands on it
            if guard is not None:
                for c in range(guard - 4, max(start, guard - 32) - 4, -4):
                    limit = _cmp_limit(word(c), index)
                    if limit is not None:
                        count = limit + 1 if word(guard) & 15 == 9 else limit
                        break
        if not count or count > 4096:
            continue
        size_of = 1 if kind == 'b' else 2
        if table + count * size_of > ro_start + ro_size:
            continue
        imm = (adr >> 5) & 0x7ffff
        base = adr_pc + (((imm << 2 | (adr >> 29) & 3) - (1 << 21)) if imm & (1 << 18) else (imm << 2 | (adr >> 29) & 3))
        values = struct.unpack_from('<%d%s' % (count, kind), nso.image, table)
        if all(start <= base + v * 4 < end for v in values):
            found.append((table, count, kind, base))
    return found
