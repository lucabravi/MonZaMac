// Partial uploads preserve all texels outside the rectangle, including GOB padding boundaries.
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "../runtime/nvn/tegra.h"

int main(void) {
    for (unsigned bpb=1;bpb<=16;bpb*=2) for(unsigned bh=0;bh<=4;bh++) {
        unsigned w=73,h=139,x=13,y=7,rw=53,rh=123;
        size_t bytes=(size_t)w*h*bpb, storage=((w*bpb+63)/64)*512ull*(1u<<bh)*((h+(8u<<bh)-1)/(8u<<bh));
        unsigned char *linear=malloc(bytes), *expect=malloc(bytes), *tiled=calloc(1,storage), *got=malloc(bytes), *patch=malloc((size_t)rw*rh*bpb);
        for(size_t i=0;i<bytes;i++) linear[i]=(unsigned char)(i*17+3);
        for(size_t i=0;i<(size_t)rw*rh*bpb;i++) patch[i]=(unsigned char)(i*29+7);
        memcpy(expect,linear,bytes);
        for(unsigned row=0;row<rh;row++) memcpy(expect+((size_t)(y+row)*w+x)*bpb,patch+(size_t)row*rw*bpb,(size_t)rw*bpb);
        tegra_swizzle(linear,tiled,w,h,1,bpb,bh,0);
        assert(tegra_swizzle_rect(patch,tiled,w,h,x,y,rw,rh,bpb,bh));
        tegra_deswizzle(tiled,got,w,h,1,bpb,bh,0); assert(!memcmp(expect,got,bytes));
        assert(!tegra_swizzle_rect(patch,tiled,w,h,w,y,1,rh,bpb,bh));
        assert(!tegra_swizzle_rect(patch,tiled,w,h,x,y,w,rh,bpb,bh));
        assert(!tegra_swizzle_rect(patch,tiled,w,h,x,h,1,1,bpb,bh));
        tegra_deswizzle(tiled,got,w,h,1,bpb,bh,0);assert(!memcmp(expect,got,bytes));
        free(linear);free(expect);free(tiled);free(got);free(patch);
    }
    puts("PASS partial texture uploads across sectors/GOBs preserve neighbors and reject bounds");
}
