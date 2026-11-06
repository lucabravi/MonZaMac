// Synthetic textures only: this verifies GPU execution, not in-game visual quality.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "frame_generation.h"
// Include the implementation to inspect GPU motion/depth without test-only public API.
#include "../runtime/nvn/frame_generation.m"

static const unsigned W = 256, H = 192;
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;

static FgCamera camera_xy(float camera_x, float camera_y, bool reversed) {
    float n=.1f, f=100.f, ys=1.f/tanf(60.f*M_PI/360.f), xs=ys/((float)W/H);
    matrix_float4x4 p = { .columns = {
        {xs,0,0,0}, {0,ys,0,0}, {0,0,reversed?n/(f-n):f/(n-f),-1},
        {0,0,reversed?n*f/(f-n):n*f/(n-f),0}}};
    matrix_float4x4 v = matrix_identity_float4x4;
    v.columns[3].x = -camera_x; v.columns[3].y = -camera_y;
    matrix_float4x4 vp=simd_mul(p,v), inv=simd_inverse(vp);
    FgCamera c={.near_plane=n,.far_plane=f,.vertical_fov=60,.aspect=(float)W/H,.reversed_depth=reversed};
    memcpy(c.view_projection,&vp,sizeof vp);
    memcpy(c.inverse_view_projection,&inv,sizeof inv);
    return c;
}
static FgCamera camera(float x, bool reversed) { return camera_xy(x,0,reversed); }
static id<MTLTexture> scene(int shift, bool ui) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO];
    d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> t=[device newTextureWithDescriptor:d];
    uint8_t *pixels=malloc(W*H*4);
    for(unsigned y=0;y<H;y++) for(unsigned x=0;x<W;x++) {
        unsigned i=(y*W+x)*4, sx=(x+shift+W)%W;
        pixels[i]=sx; pixels[i+1]=y; pixels[i+2]=((sx/24+y/24)&1)?220:25; pixels[i+3]=255;
        if(ui && x<48 && y<20) pixels[i]=pixels[i+1]=pixels[i+2]=255;
    }
    [t replaceRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0 withBytes:pixels bytesPerRow:W*4];
    free(pixels);
    return t;
}
static id<MTLTexture> depth(bool reversed, bool native) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:native?MTLPixelFormatDepth32Float:MTLPixelFormatR32Float width:W height:H mipmapped:NO];
    d.usage=MTLTextureUsageShaderRead|(native?MTLTextureUsageRenderTarget:0);
    id<MTLTexture> t=[device newTextureWithDescriptor:d];
    float z=100.f/(.1f-100.f)*-2.f+(.1f*100.f/(.1f-100.f)); z/=2.f;
    if(reversed)z=1.f-z;
    if(native) {
        id<MTLCommandBuffer> cb=[queue commandBuffer];
        MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
        rp.depthAttachment.texture=t; rp.depthAttachment.loadAction=MTLLoadActionClear;
        rp.depthAttachment.storeAction=MTLStoreActionStore; rp.depthAttachment.clearDepth=z;
        [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        [cb commit]; [cb waitUntilCompleted]; assert(!cb.error);
    } else {
        float *pixels=malloc(W*H*sizeof(float));
        for(unsigned i=0;i<W*H;i++)pixels[i]=z;
        [t replaceRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0 withBytes:pixels bytesPerRow:W*sizeof(float)];
        free(pixels);
    }
    return t;
}
static id<MTLTexture> encode(id<MTLTexture> s,id<MTLTexture> ui,id<MTLTexture> z,FgCamera *c,int mode,double now) {
    id<MTLCommandBuffer> cb=[queue commandBuffer];
    id<MTLTexture> out=fg_encode(cb,s,ui,z,c,mode,now);
    [cb commit]; [cb waitUntilCompleted];
    if(cb.error)fprintf(stderr,"%s\n",cb.error.description.UTF8String);
    assert(!cb.error);
    if(out) {
        const char *legacy=getenv("LARECOMP_FG_OUTPUT_FP16");
        assert(out.storageMode==MTLStorageModePrivate);
        assert(out.pixelFormat==(legacy && atoi(legacy)?MTLPixelFormatRGBA16Float:MTLPixelFormatRGBA8Unorm));
    }
    return out;
}
static NSData *readback_pixels(id<MTLTexture> t, NSUInteger pixel_size) {
    NSUInteger row=(t.width*pixel_size+255)&~255;
    id<MTLBuffer> b=[device newBufferWithLength:row*t.height options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb=[queue commandBuffer];
    id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
    [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(t.width,t.height,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row*t.height];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; assert(!cb.error);
    return [NSData dataWithBytes:b.contents length:row*t.height];
}
static NSData *readback(id<MTLTexture> t) {
    if(t.pixelFormat==MTLPixelFormatRGBA16Float)return readback_pixels(t,8);
    assert(t.pixelFormat==MTLPixelFormatRGBA8Unorm);
    NSData *raw=readback_pixels(t,4);NSUInteger row=(t.width*4+255)&~255;
    NSMutableData *converted=[NSMutableData dataWithLength:t.width*t.height*8];
    __fp16 *dst=converted.mutableBytes;const uint8_t *src=raw.bytes;
    for(NSUInteger y=0;y<t.height;y++)for(NSUInteger x=0;x<t.width*4;x++)dst[y*t.width*4+x]=(__fp16)(src[y*row+x]/255.f);
    return converted;
}
static id<MTLTexture> crop(id<MTLTexture> t) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:t.pixelFormat width:W/2 height:H/2 mipmapped:NO];
    d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> out=[device newTextureWithDescriptor:d];
    void *pixels=malloc(W/2*H/2*4);
    [t getBytes:pixels bytesPerRow:W/2*4 fromRegion:MTLRegionMake2D(0,0,W/2,H/2) mipmapLevel:0];
    [out replaceRegion:MTLRegionMake2D(0,0,W/2,H/2) mipmapLevel:0 withBytes:pixels bytesPerRow:W/2*4];
    free(pixels);
    return out;
}
static double difference(NSData *data, int shift) {
    const __fp16 *p=data.bytes;
    double sum=0;
    for(unsigned y=0;y<H;y++)for(unsigned x=0;x<W;x++) {
        unsigned sx=(x+shift+W)%W, i=(y*W+x)*4;
        __fp16 expected[3]={(__fp16)(sx/255.f),(__fp16)(y/255.f),(__fp16)((((sx/24+y/24)&1)?220:25)/255.f)};
        for(unsigned k=0;k<3;k++)sum+=fabs((float)p[i+k]-(float)expected[k]);
    }
    return sum/(W*H*3);
}
int main(void) {@autoreleasepool {
    device=MTLCreateSystemDefaultDevice(); queue=[device newCommandQueue];
    if(!fg_supported()){puts("SKIP: macOS 26 / supported MetalFX GPU required");return 0;}
    printf("GPU: %s\n",device.name.UTF8String);
    unsetenv("LARECOMP_FG_OUTPUT_FP16");
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if(@available(macOS 26.0,*)) {
    for(int mode=1;mode<=2;mode++) for(int reversed=0;reversed<=1;reversed++) for(int native=0;native<=1;native++) {
        fg_reset(); double dt=mode==1?1./30:1./60, now=1.;
        id<MTLTexture> z=depth(reversed,native);
        FgCamera c=camera(0,reversed);
        assert(!encode(scene(0,false),nil,z,&c,mode,now));
        NSData *last=nil, *retained_data=nil;
        id<MTLTexture> retained_output=nil;
        for(int i=1;i<=3;i++) {
            c=camera(i*16.f/(W*(1.f/tanf(M_PI/6)/((float)W/H))),reversed);
            id<MTLTexture> out=encode(scene(i*4,false),nil,z,&c,mode,now+=dt);
            if(i==1) { assert(!out); continue; }
            assert(out);
            NSData *motion_bytes=readback_pixels(state->previous->motion,4);
            const __fp16 *motion=motion_bytes.bytes;
            unsigned center=(H/2*W+W/2)*2;
            assert(fabsf((float)motion[center]-4.f)<.01f && fabsf((float)motion[center+1])<.01f);
            NSData *depth_bytes=readback_pixels(state->previous->depth,4);
            const float *depth_pixels=depth_bytes.bytes;
            float expected_depth=(100.f/(.1f-100.f)*-2.f+(.1f*100.f/(.1f-100.f)))/2.f;
            if(reversed)expected_depth=1.f-expected_depth;
            assert(fabsf(depth_pixels[H/2*W+W/2]-expected_depth)<1e-5f);
            assert(state->effect.nearPlane==c.near_plane && state->effect.farPlane==c.far_plane);
            assert(state->effect.fieldOfView==c.vertical_fov && state->effect.isDepthReversed==reversed);
            NSData *bytes=readback(out);
            if(!retained_output) { retained_output=out; retained_data=bytes; }
            const __fp16 *p=bytes.bytes;
            for(unsigned k=0;k<W*H*4;k++)assert(isfinite((float)p[k]));
            double current_difference=difference(bytes,i*4), previous_difference=difference(bytes,(i-1)*4);
            assert(current_difference>.0001 && previous_difference>.0001);
            if(last)assert(![last isEqualToData:bytes]);
            last=bytes;
        }
        assert([readback(retained_output) isEqualToData:retained_data]);
        assert(!fg_encode(nil,scene(12,false),nil,z,&c,mode,now));
        assert(!encode(nil,nil,z,&c,mode,now+=dt));
        assert(!encode(scene(12,false),nil,z,&c,mode,now+=dt));
        assert(!encode(scene(12,false),nil,z,&c,mode,now+=dt));
        assert(encode(scene(12,false),nil,z,&c,mode,now+=dt));
        assert(!encode(scene(12,false),nil,z,&c,mode,now+=1.));
        assert(!encode(scene(12,false),nil,nil,&c,mode,now+=dt));
        assert(!encode(scene(12,false),nil,z,NULL,mode,now+=dt));
        assert(!encode(scene(12,false),nil,z,&c,0,now+=dt));
        assert(!encode(scene(12,false),nil,z,&c,mode,now+=dt));
        // UI transition clears history, then exercises composited UI with valid inputs.
        assert(!encode(scene(12,false),scene(12,true),z,&c,mode,now+=dt));
        assert(!encode(scene(12,false),scene(12,true),z,&c,mode,now+=dt));
        assert(encode(scene(12,false),scene(12,true),z,&c,mode,now+=dt));
        fg_reset();
        assert(!encode(scene(0,false),nil,z,&c,mode,now+=dt));
    }
    // Vertical reprojection checks framebuffer Y inversion independently of
    // the horizontal shifted-scene interpolation fixture above.
    for(int reversed=0;reversed<=1;reversed++) {
        fg_reset(); id<MTLTexture> z=depth(reversed,true);
        for(int i=0;i<3;i++) {
            float y=i*12.f/(H*(1.f/tanf(M_PI/6)));
            FgCamera c=camera_xy(0,y,reversed);
            encode(scene(0,false),nil,z,&c,1,1.+i/30.);
        }
        NSData *bytes=readback_pixels(state->previous->motion,4);
        const __fp16 *p=bytes.bytes; unsigned center=(H/2*W+W/2)*2;
        assert(fabsf((float)p[center])<.01f && fabsf((float)p[center+1]+3.f)<.01f);
    }
    // A cut, mode change, invalid camera, and resize each suppress stale history.
    fg_reset(); FgCamera c=camera(0,false); id<MTLTexture> z=depth(false,false);
    assert(!encode(scene(0,false),nil,z,&c,1,1.));
    assert(!encode(scene(0,false),nil,z,&c,1,1.+1./30));
    assert(encode(scene(0,false),nil,z,&c,1,1.+2./30));
    c=camera(100,false);
    assert(!encode(scene(0,false),nil,z,&c,1,1.+3./30));
    assert(!encode(scene(0,false),nil,z,&c,1,1.+4./30));
    assert(encode(scene(0,false),nil,z,&c,1,1.+5./30));
    assert(!encode(scene(0,false),nil,z,&c,2,1.+6./30));
    c.near_plane=NAN;
    assert(!encode(scene(0,false),nil,z,&c,2,1.+7./30));
    c=camera(0,false);
    assert(!encode(scene(0,false),nil,z,&c,2,1.+8./30));
    assert(!encode(scene(0,false),nil,z,&c,2,1.+9./30));
    assert(encode(scene(0,false),nil,z,&c,2,1.+10./30));
    id<MTLTexture> small_scene=crop(scene(0,false)), small_depth=crop(z);
    assert(!encode(small_scene,nil,small_depth,&c,2,2.));
    assert(!encode(small_scene,nil,small_depth,&c,2,2.+1./60));
    id<MTLTexture> small_output=encode(small_scene,nil,small_depth,&c,2,2.+2./60);
    assert(small_output.width==W/2 && small_output.height==H/2);

    id<MTLCommandBuffer> completed=[queue commandBuffer];
    [completed commit]; [completed waitUntilCompleted];
    assert(!fg_encode(completed,scene(0,false),nil,z,&c,2,3.));

    // More pending frames than any fixed triple buffer, followed by a reset
    // before submission, verifies the ring and completion-owned generation.
    fg_reset();
    NSMutableArray<id<MTLCommandBuffer>> *pending=[NSMutableArray new];
    NSMutableArray<id<MTLTexture>> *outputs=[NSMutableArray new];
    for(int i=0;i<8;i++) {
        id<MTLCommandBuffer> cb=[queue commandBuffer];
        c=camera(i*16.f/(W*(1.f/tanf(M_PI/6)/((float)W/H))),false);
        id<MTLTexture> out=fg_encode(cb,scene(i*4,false),nil,z,&c,1,3.+i/30.);
        if(i<2)assert(!out); else { assert(out); [outputs addObject:out]; }
        [pending addObject:cb];
    }
    assert(state->ring.count==8);
    fg_reset();
    for(id<MTLCommandBuffer> cb in pending)[cb commit];
    for(id<MTLCommandBuffer> cb in pending) { [cb waitUntilCompleted]; assert(!cb.error); }
    for(unsigned i=0;i<outputs.count;i++) {
        NSData *bytes=readback(outputs[i]);
        assert(difference(bytes,(i+2)*4)>.0001 && difference(bytes,(i+1)*4)>.0001);
    }
    fg_reset();setenv("LARECOMP_FG_OUTPUT_FP16","1",1);
    { FgCamera c=camera(0,false);id<MTLTexture> z=depth(false,false);
      assert(!encode(scene(0,false),nil,z,&c,1,30.));
      assert(!encode(scene(0,false),nil,z,&c,1,30.+1./30));
      assert(encode(scene(0,false),nil,z,&c,1,30.+2./30)); }
    unsetenv("LARECOMP_FG_OUTPUT_FP16");fg_reset();
    puts("PASS: both modes, normal/reversed native/float depth, motion scenes, 4px X/-3px Y backward motion, private output distinct from endpoints, reset/gap/nil/off/UI/cut/resize, in-flight retention");
    }
#endif
    return 0;
}}
