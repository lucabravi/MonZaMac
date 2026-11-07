// Hand-written Maxwell instructions; no game shader bytes.
#include "runtime/nvn/maxwell/shader.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned char blob[4096];
static size_t n;
static void op(uint64_t w) {
    if (!(n % 4)) n++;
    memcpy(blob + 0x80 + n++ * 8, &w, 8);
}
static uint64_t ldc(unsigned d, unsigned a, unsigned bank, unsigned off, unsigned size) {
    return 0xef90000000000000ull | (uint64_t)size << 48 | (uint64_t)bank << 36 |
           (uint64_t)off << 20 | 7ull << 16 | a << 8 | d;
}
static ShaderInfo *translate(unsigned reg, int mutation, int stage, int glsl) {
    memset(blob, 0, sizeof blob); n=0;
    for (unsigned i=0;i<3;i++)
        op(0x4bb0000000000000ull | 7ull << 39 | 3ull << 34 | (uint64_t)(0x850/4+i+(mutation==1)) << 20 |
           7ull << 16 | 1ull << 8 | 7);
    op(0x3848000000000000ull | (uint64_t)(mutation==2 ? 5 : 6) << 20 | 7ull << 16 | 2ull << 8 | reg);
    for(unsigned i=0;i<8;i++) op(ldc(40+i*2,reg,6,i*8,5));
    size_t bypass = 0;
    if(mutation==10) { if(!(n%4)) n++;bypass=n;op(0xe240000000070000ull); }
    if(mutation!=8) op(0xdf48000000000000ull | 3ull<<31 | 1ull<<22 | 7ull<<16 | 255ull<<8 | 80);
    for(unsigned i=0;i<2;i++) op(0x5cb8000000000000ull | (uint64_t)(80+i)<<20 | 7ull<<16 | 2ull<<10 | 80+i);
    op(ldc(reg+1,3,3,mutation==3 ? 2456 : 2452,4));
    if(mutation==5) op(0x0100000000000000ull | 7ull<<16 | reg+1); // clobbered radius
    if(mutation==6) op(0xdf48000000000000ull | 3ull<<31 | 1ull<<22 | 7ull<<16 | 255ull<<8 | reg); // multi-output clobber
    if(mutation==7) op(0xe240000000000000ull | 7ull<<16); // skip into the product block
    if(bypass) {
        size_t target=n+(n%4==0); uint64_t w=0xe240000000070000ull | (uint64_t)((target-bypass-1)*8)<<20;
        memcpy(blob+0x80+bypass*8,&w,8);
    }
    for(unsigned i=0;i<2;i++) {
        unsigned axis=mutation==9 ? 1-i : i;
        op(0x5080000000000000ull | 4ull << 20 | 7ull << 16 | (uint64_t)(80+axis) << 8 | (80+axis));
        op(0x5c68000000000000ull | (uint64_t)(reg+1) << 20 | 7ull << 16 | (uint64_t)(80+axis) << 8 | (mutation==4 && i==1 ? reg+1 : 80+axis));
    }
    op(0xe30000000007000full);
    ShaderKey key={0};key.glsl=glsl;
    // Compute lacks the graphics headers and must never get the game-specific filter.
    return maxwell_translate(stage==STAGE_COMPUTE ? blob+0x80 : blob,
                             stage==STAGE_COMPUTE ? n*8 : 0x80+n*8,stage,&key);
}
int main(int argc, char **argv) {
    unsigned cases=0;
    for(unsigned reg=18;reg<=26;reg+=8) for(int mutation=0;mutation<11;mutation++) for(int glsl=0;glsl<2;glsl++) {
        ShaderInfo *s=translate(reg,mutation,STAGE_FRAGMENT,glsl);
        assert(s && s->msl);
        bool patched=strstr(s->msl,"shadow_radius_scale = shadow_cascade_ratio")!=NULL;
        if(patched != ((!mutation || mutation==4 || mutation==9) && !glsl)) fprintf(stderr,"case reg=%u mutation=%d glsl=%d patched=%d\n",reg,mutation,glsl,patched);
        assert(patched == ((!mutation || mutation==4 || mutation==9) && !glsl));
        if(patched) {
            assert(strstr(s->msl,"shadow_radius_scale.x"));
            assert(strstr(s->msl,"shadow_radius_scale.y"));
            assert(strstr(s->msl,"r80 = as_type<uint>(as_type<float>(r80) * shadow_radius_scale.x)"));
            if(mutation!=4) assert(strstr(s->msl,"r81 = as_type<uint>(as_type<float>(r81) * shadow_radius_scale.y)"));
        }
        if(patched && argc>1) { FILE *f=fopen(argv[1],"w");assert(f);fputs(s->msl,f);fclose(f); }
        maxwell_free(s);cases++;
    }
    setenv("LARECOMP_SHADOW_CASCADE_FILTER","0",1);
    ShaderInfo *s=translate(18,0,STAGE_FRAGMENT,0);assert(s && s->msl);
    assert(!strstr(s->msl,"shadow_cascade_ratio"));maxwell_free(s);
    printf("PASS: %u cascade signatures, changed registers, negative guards, dialect and opt-out\n",cases+1);
}
