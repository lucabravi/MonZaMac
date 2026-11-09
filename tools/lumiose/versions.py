"""Studied module builds: reference offsets only, never module code or assets."""
PROFILES = {
    '96f2b142853fa1515ebce682e770e1241f9081fb000000000000000000000000':
        ('1.3.9', [(0x57fdc8, 91, 'h', 0x136c44), (0x194b40, 123, 'h', 0x364cc),
                   (0x212290, 14, 'b', 0xc1d74)]),
    'b6337aed498a1480cadf6026cc04865acbfc59a2000000000000000000000000':
        ('1.4.3-build2', [(0x5b1878, 91, 'h', 0x1553c4), (0x1bbcf0, 123, 'h', 0x38f2c),
                          (0x243ca0, 14, 'b', 0xd9794)]),
    'fe5753d3596288a6df601ed723c3e081a697b3ec000000000000000000000000':
        ('latest-2026-11', [(0x5c02c8, 91, 'h', 0x160244), (0x1ca160, 123, 'h', 0x3bf6c),
                            (0x252100, 14, 'b', 0xe3414)]),
}
GAME_PREFIX = 'b1f12fd919eae86a'

def full_build_id(build_id):
    """The 32-byte build id as 64 hex digits. tools/nso.py trims the zero padding of the id, the profiles and the runtime's
    identity check (identity.c) use all 32 bytes."""
    return build_id.ljust(64, '0')


def profile(build_id):
    try:
        return PROFILES[full_build_id(build_id)]
    except KeyError:
        raise ValueError('Unsupported Lumiose build; preparation needs a compatibility update') from None
