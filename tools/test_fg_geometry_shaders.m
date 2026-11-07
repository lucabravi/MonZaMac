// Execute generated MSL from synthetic Maxwell fixtures, including perspective interpolation and buffer guards.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <simd/simd.h>
#define FG_GEOMETRY_METAL_TEST
#include "test_fg_geometry_shaders.c"

enum { WIDTH = 128, VERTICES = 4, GUARD_BYTES = 16, HISTORY_BYTES = VERTICES * FG_HISTORY_WORDS * 4, TOTAL_BYTES = HISTORY_BYTES + GUARD_BYTES * 2 };
static const uint32_t guard = 0xdeadbeef;
static simd_double2 pixel(simd_float4 p) {
    return (simd_double2){WIDTH * (0.5 + 0.5 * p.x / p.w), WIDTH * (0.5 - 0.5 * p.y / p.w)};
}
static double cross2(simd_double2 a, simd_double2 b) { return a.x * b.y - a.y * b.x; }
static bool barycentric(simd_double2 p, simd_double2 a, simd_double2 b, simd_double2 c, double *l) {
    double d = cross2(b - a, c - a); l[1] = cross2(p - a, c - a) / d;
    l[2] = cross2(b - a, p - a) / d; l[0] = 1 - l[1] - l[2];
    return fmin(l[0], fmin(l[1], l[2])) > 0.02;
}
static bool guards_ok(id<MTLBuffer> buffer) {
    const uint32_t *u = buffer.contents;
    for (unsigned i = 0; i < 4; ++i) if (u[i] != guard || u[4 + HISTORY_BYTES / 4 + i] != guard) return false;
    return true;
}
int main(void) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
    printf("geometry shader GPU=%s\n", device.name.UTF8String);
    id<MTLFunction> vs = nil, fs = nil, plain_vs = nil;
    for (unsigned enabled = 0; enabled < 2; ++enabled) for (int stage = STAGE_VERTEX; stage <= STAGE_FRAGMENT; ++stage) {
        ShaderKey key = {0}; if (enabled) enable_motion(&key);
        key.flip_x = key.flip_y = key.depth_minus_one = true;
        ShaderInfo *s = fixture(stage, &key, false); assert(s->msl);
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:@(s->msl) options:nil error:&error];
        if (!library) { fprintf(stderr, "%s\n", error.description.UTF8String); return 1; }
        id<MTLFunction> fn = [library newFunctionWithName:@"main0"]; assert(fn);
        if(!enabled && stage==STAGE_VERTEX)plain_vs=fn;
        if (enabled) { if (stage == STAGE_VERTEX) vs = fn; else fs = fn; }
        maxwell_free(s);
    }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = vs; pd.fragmentFunction = fs;
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm; pd.colorAttachments[7].pixelFormat = MTLPixelFormatRG16Float;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat4; vd.attributes[0].bufferIndex = 0;
    vd.layouts[0].stride = sizeof(simd_float4); pd.vertexDescriptor = vd;
    NSError *error = nil; id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];
    if (!pipeline) { fprintf(stderr, "%s\n", error.description.UTF8String); return 1; }
    id<MTLTexture> textures[2];
    for (unsigned i = 0; i < 2; ++i) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:i ? MTLPixelFormatRG16Float : MTLPixelFormatRGBA8Unorm
                                                                                  width:WIDTH height:WIDTH mipmapped:NO];
        td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageRenderTarget;
        textures[i] = [device newTextureWithDescriptor:td]; assert(textures[i]);
    }
    id<MTLBuffer> history[2], small[2];
    for (unsigned i = 0; i < 2; ++i) {
        history[i] = [device newBufferWithLength:TOTAL_BYTES options:MTLResourceStorageModeShared];
        small[i] = [device newBufferWithLength:GUARD_BYTES options:MTLResourceStorageModeShared];
        for (unsigned k = 0; k < TOTAL_BYTES / 4; ++k) ((uint32_t *)history[i].contents)[k] = guard;
        for (unsigned k = 0; k < GUARD_BYTES / 4; ++k) ((uint32_t *)small[i].contents)[k] = guard;
    }
    const uint16_t indices[] = {0, 1, 2, 2, 1, 3};
    id<MTLBuffer> ib = [device newBufferWithBytes:indices length:sizeof indices options:MTLResourceStorageModeShared];
    simd_float4 canonical[3][VERTICES], raw[3][VERTICES];
    for (unsigned v = 0; v < VERTICES; ++v) {
        float x = v & 1 ? 0.9f : -0.9f, y = v & 2 ? 0.9f : -0.9f, z = x * 0.15f + y * 0.2f;
        canonical[0][v] = (simd_float4){x, y, 0.5f * (2 + z), 2 + z};
        float rx = cosf(0.32f) * x - sinf(0.32f) * y + 0.12f, ry = sinf(0.32f) * x + cosf(0.32f) * y + 0.06f;
        canonical[1][v] = (simd_float4){rx, ry, 0.5f * (2 + z), 2 + z}; canonical[2][v] = canonical[1][v];
        if (v == 3) canonical[2][v] += (simd_float4){0.38f, -0.24f, 0.15f, 0.3f};
        for (unsigned f = 0; f < 3; ++f) {
            raw[f][v] = canonical[f][v]; raw[f][v].x = -raw[f][v].x; raw[f][v].y = -raw[f][v].y;
            raw[f][v].z = 2 * raw[f][v].z - raw[f][v].w;
        }
    }
    id<MTLCommandQueue> queue = [device newCommandQueue];
    for (unsigned frame = 0; frame < 6; ++frame) {
        bool guard_case = frame == 3, stale_case = frame >= 4; unsigned f = frame >= 3 ? 2 : frame;
        id<MTLBuffer> current = guard_case ? small[0] : history[f & 1], previous = guard_case ? small[1] : history[(f & 1) ^ 1];
        if (!guard_case) for (unsigned k = 4; k < 4 + HISTORY_BYTES / 4; ++k) ((uint32_t *)current.contents)[k] = guard;
        if(frame==5) {
            uint32_t *words=(uint32_t *)((char *)previous.contents+GUARD_BYTES);
            for(unsigned v=0;v<VERTICES;v++) { words[v*FG_HISTORY_WORDS+4]=v==1?0:frame;words[v*FG_HISTORY_WORDS+5]=0; }
        }
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        for (unsigned i = 0; i < 2; ++i) {
            MTLRenderPassColorAttachmentDescriptor *a = rp.colorAttachments[i ? 7 : 0]; a.texture = textures[i];
            a.loadAction = MTLLoadActionClear; a.storeAction = MTLStoreActionStore;
            a.clearColor = i ? MTLClearColorMake(65504, 65504, 0, 0) : MTLClearColorMake(0, 0, 0, 0);
        }
        MTLCommandBufferDescriptor *cd = [MTLCommandBufferDescriptor new]; cd.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus;
        id<MTLCommandBuffer> cb = [queue commandBufferWithDescriptor:cd];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:pipeline]; [enc setViewport:(MTLViewport){0, 0, WIDTH, WIDTH, 0, 1}];
        [enc setVertexBytes:raw[f] length:sizeof raw[f] atIndex:0];
        [enc setVertexBuffer:current offset:guard_case ? 0 : GUARD_BYTES atIndex:FG_CURRENT_BUFFER_INDEX];
        [enc setVertexBuffer:previous offset:guard_case ? 0 : GUARD_BYTES atIndex:FG_PREVIOUS_BUFFER_INDEX];
        simd_uint4 params = {guard_case ? 0 : VERTICES, frame != 0, frame + 1, 0}; simd_float2 size = {WIDTH, WIDTH}; simd_float4 tint[2] = {0};
        [enc setVertexBytes:&params length:sizeof params atIndex:FG_PARAMS_BUFFER_INDEX];
        [enc setFragmentBytes:&size length:sizeof size atIndex:FG_PARAMS_BUFFER_INDEX];
        [enc setFragmentBytes:tint length:sizeof tint atIndex:19];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0];
        [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) { fprintf(stderr, "%s\n", cb.error.description.UTF8String); return 1; }
        if (guard_case) {
            for (unsigned k = 0; k < 4; ++k) assert(((uint32_t *)current.contents)[k] == guard && ((uint32_t *)previous.contents)[k] == guard);
        } else {
            const uint32_t *words=(const uint32_t *)((char *)current.contents + GUARD_BYTES);
            for(unsigned v=0;v<VERTICES;v++) {
                assert(!memcmp(words+v*FG_HISTORY_WORDS,&canonical[f][v],16));
                assert(words[v*FG_HISTORY_WORDS+4]==frame+1 && words[v*FG_HISTORY_WORDS+5]==0);
            }
            assert(guards_ok(current) && guards_ok(previous));
        }
        uint8_t color[WIDTH * WIDTH * 4]; _Float16 motion[WIDTH * WIDTH * 2];
        [textures[0] getBytes:color bytesPerRow:WIDTH * 4 fromRegion:MTLRegionMake2D(0, 0, WIDTH, WIDTH) mipmapLevel:0];
        [textures[1] getBytes:motion bytesPerRow:WIDTH * 4 fromRegion:MTLRegionMake2D(0, 0, WIDTH, WIDTH) mipmapLevel:0];
        unsigned covered = 0, checked = 0, camera_only_wrong = 0; double max_error = 0;
        for (unsigned y = 0; y < WIDTH; ++y) for (unsigned x = 0; x < WIDTH; ++x) {
            unsigned j = y * WIDTH + x; bool drawn = color[j * 4 + 3] != 0; covered += drawn;
            double mx = motion[j * 2], my = motion[j * 2 + 1];
            if (drawn) assert(color[j * 4] == 32 && color[j * 4 + 1] == 128 && color[j * 4 + 2] == 223 && color[j * 4 + 3] == 255);
            if (!drawn || !frame || guard_case || stale_case) { assert(mx == 65504 && my == 65504); continue; }
            if (x < 32 || x >= 96 || y < 32 || y >= 96) continue;
            simd_double2 p = {x + 0.5, y + 0.5};
            for (unsigned t = 0; t < 2; ++t) {
                const uint16_t *ids = indices + t * 3; double l[3];
                if (!barycentric(p, pixel(canonical[f][ids[0]]), pixel(canonical[f][ids[1]]), pixel(canonical[f][ids[2]]), l)) continue;
                simd_double4 prev = {0};
                for (unsigned k = 0; k < 3; ++k) prev += __builtin_convertvector(canonical[f - 1][ids[k]], simd_double4) * (l[k] / canonical[f][ids[k]].w);
                simd_double2 expected = {WIDTH * (0.5 + 0.5 * prev.x / prev.w) - p.x, WIDTH * (0.5 - 0.5 * prev.y / prev.w) - p.y};
                double e = fmax(fabs(mx - expected.x), fabs(my - expected.y)); assert(isfinite(e) && e <= 0.15);
                max_error = fmax(max_error, e); camera_only_wrong += simd_length(expected) > 0.15; ++checked; break;
            }
        }
        assert(covered > 1500 && (!frame || guard_case || stale_case || (checked > 1000 && camera_only_wrong > 100)));
        printf("PASS generated MSL %s covered=%u checked=%u max_error_px=%.6f camera_only_wrong=%u exact_history=1 guards=1 colors=1\n",
               guard_case ? "zero-count guard" : stale_case ? "stale-index history" : frame == 0 ? "seed" : frame == 1 ? "rigid" : "deformation", covered, checked, max_error, camera_only_wrong);
    }
    // An ordinary foreground shader must invalidate old motion wherever it draws.
    ShaderKey invalidate={.fg_motion=2};ShaderInfo *invalidating=fixture(STAGE_FRAGMENT,&invalidate,false);
    assert(invalidating->msl && !strstr(invalidating->msl,"fgPreviousClip"));
    id<MTLLibrary> library=[device newLibraryWithSource:@(invalidating->msl) options:nil error:&error];assert(library);
    maxwell_free(invalidating);pd.vertexFunction=plain_vs;pd.fragmentFunction=[library newFunctionWithName:@"main0"];
    pipeline=[device newRenderPipelineStateWithDescriptor:pd error:&error];assert(pipeline);
    _Float16 old_motion[WIDTH*WIDTH*2];for(unsigned i=0;i<WIDTH*WIDTH*2;i++)old_motion[i]=7;
    [textures[1] replaceRegion:MTLRegionMake2D(0,0,WIDTH,WIDTH) mipmapLevel:0 withBytes:old_motion bytesPerRow:WIDTH*4];
    MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture=textures[0];rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;
    rp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
    rp.colorAttachments[7].texture=textures[1];rp.colorAttachments[7].loadAction=MTLLoadActionLoad;rp.colorAttachments[7].storeAction=MTLStoreActionStore;
    id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:rp];
    simd_float4 tint[2]={0};[e setRenderPipelineState:pipeline];[e setVertexBytes:raw[2] length:sizeof raw[2] atIndex:0];
    [e setFragmentBytes:tint length:sizeof tint atIndex:19];
    [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0];
    [e endEncoding];[cb commit];[cb waitUntilCompleted];assert(!cb.error);
    uint8_t color[WIDTH*WIDTH*4];[textures[0] getBytes:color bytesPerRow:WIDTH*4 fromRegion:MTLRegionMake2D(0,0,WIDTH,WIDTH) mipmapLevel:0];
    [textures[1] getBytes:old_motion bytesPerRow:WIDTH*4 fromRegion:MTLRegionMake2D(0,0,WIDTH,WIDTH) mipmapLevel:0];
    unsigned invalidated=0;
    for(unsigned i=0;i<WIDTH*WIDTH;i++)if(color[i*4+3]) { assert(old_motion[i*2]==65504 && old_motion[i*2+1]==65504);invalidated++; }
    assert(invalidated>1500);puts("PASS: ordinary foreground invalidates covered motion without vertex history");
    return 0;
} }
