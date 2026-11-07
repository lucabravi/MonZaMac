// Synthetic Maxwell instructions only; no game shader bytes.
#include "../runtime/nvn/maxwell/shader.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void emit(uint8_t *blob, size_t *n, uint64_t word) {
    if (!(*n % 4)) ++*n;
    memcpy(blob + 0x80 + (*n)++ * 8, &word, 8);
}
static ShaderInfo *fixture(int stage, const ShaderKey *key, bool rt7) {
    uint8_t blob[256] = {0}; size_t n = 0;
    if (stage == STAGE_VERTEX) {
        emit(blob, &n, 0xefd8000000000000ull | 3ull << 47 | 0x80ull << 20 | 7ull << 16 | 255ull << 8);
        emit(blob, &n, 0xeff0000000000000ull | 3ull << 47 | 0x70ull << 20 | 7ull << 16);
        emit(blob, &n, 0xeff0000000000000ull | 3ull << 47 | 0x270ull << 20 | 7ull << 16);
    } else if (stage == STAGE_FRAGMENT) {
        uint32_t omap = rt7 ? 0xf000000fu : 0xfu;
        memcpy(blob + 0x78, &omap, 4);
        const uint32_t rgba[] = {0x3e000000, 0x3f000000, 0x3f600000, 0x3f800000};
        for (unsigned r = 0; r < 4; ++r)
            emit(blob, &n, 0x0100000000000000ull | (uint64_t)rgba[r] << 20 | 7ull << 16 | r);
    }
    emit(blob, &n, 0xe30000000007000full);
    return maxwell_translate(stage == STAGE_COMPUTE ? blob + 0x80 : blob,
                             stage == STAGE_COMPUTE ? n * 8 : 0x80 + n * 8, stage, key);
}
static void enable_motion(ShaderKey *key) { key->fg_motion = 1; }

#ifndef FG_GEOMETRY_METAL_TEST
int main(void) {
    assert(sizeof(ShaderKey) == 84 && offsetof(ShaderKey, img_uint) == 81 && offsetof(ShaderKey, fg_motion) == 82);
    ShaderKey plain = {0}, motion = {0}; enable_motion(&motion);
    const uint8_t zeros[84] = {0}; assert(!memcmp(&plain, zeros, sizeof plain));
    for (int stage = STAGE_VERTEX; stage <= STAGE_FRAGMENT; ++stage) {
        ShaderInfo *old = fixture(stage, &plain, false), *fg = fixture(stage, &motion, false);
        assert(old->msl && fg->msl && !strstr(old->msl, "fgPreviousClip"));
        assert(strstr(fg->msl, "fgPreviousClip"));
        assert(!old->uses_fg_motion && fg->uses_fg_motion);
        if (stage == STAGE_VERTEX) {
            assert(strstr(fg->msl, "device atomic_uint *fgCurrent [[buffer(23)]]"));
            assert(strstr(fg->msl, "device const uint *fgPrevious [[buffer(24)]]"));
            assert(strstr(fg->msl, "constant uint4 &fgParams [[buffer(25)]]"));
            assert(strstr(fg->msl, "if (vid < fgParams.x)"));
            assert(strstr(fg->msl, "memory_order_relaxed"));
            assert(strstr(fg->msl, "user(locn31)"));
            assert(fg->out_mask == old->out_mask && fg->attr_mask == old->attr_mask);
        } else {
            assert(strstr(fg->msl, "float4 fgMotion [[color(7)]]"));
            assert(strstr(fg->msl, "constant float4 &fgViewport [[buffer(25)]]"));
            assert(strstr(fg->msl, "65504"));
            assert(fg->out_mask == old->out_mask);
        }
        maxwell_free(old); maxwell_free(fg);
        plain.glsl = motion.glsl = 1;
        old = fixture(stage, &plain, false); fg = fixture(stage, &motion, false);
        assert(old->msl && fg->msl && !strcmp(old->msl, fg->msl));
        assert(!old->uses_fg_motion && !fg->uses_fg_motion);
        maxwell_free(old); maxwell_free(fg); plain.glsl = motion.glsl = 0;
    }
    ShaderInfo *collision = fixture(STAGE_FRAGMENT, &motion, true);
    assert(!collision->msl && strstr(collision->error, "7")); maxwell_free(collision);
    collision = fixture(STAGE_FRAGMENT, &plain, true); assert(collision->msl); maxwell_free(collision);
    motion.glsl = 1; collision = fixture(STAGE_FRAGMENT, &motion, true); assert(collision->msl); maxwell_free(collision);
    motion.glsl = 0; plain.xfb_void = motion.xfb_void = 1;
    ShaderInfo *a = fixture(STAGE_VERTEX, &plain, false), *b = fixture(STAGE_VERTEX, &motion, false);
    assert(a->msl && b->msl && !strcmp(a->msl, b->msl)); maxwell_free(a); maxwell_free(b);
    b = fixture(STAGE_COMPUTE, &motion, false); assert(b->msl && !b->uses_fg_motion && !strstr(b->msl, "fgPreviousClip")); maxwell_free(b);
    puts("PASS geometry shader key layout, opt-in/dialect, history slots, guest varyings, RT7 collision and xfb guards");
    return 0;
}
#endif
