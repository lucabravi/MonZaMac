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
// Depth of a bigger game target whose picture is only its top-left WxH (handheld: 1280x720 in 1920x1080); zero elsewhere.
static id<MTLTexture> depth_in_corner(void) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:2*W height:2*H mipmapped:NO];
    d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> t=[device newTextureWithDescriptor:d];
    float z=100.f/(.1f-100.f)*-2.f+(.1f*100.f/(.1f-100.f)); z/=2.f;
    float *pixels=calloc(4*W*H,sizeof(float));
    for(unsigned y=0;y<H;y++)for(unsigned x=0;x<W;x++)pixels[y*2*W+x]=z;
    [t replaceRegion:MTLRegionMake2D(0,0,2*W,2*H) mipmapLevel:0 withBytes:pixels bytesPerRow:2*W*sizeof(float)];
    free(pixels);
    return t;
}
static id<MTLTexture> encode_motion(id<MTLTexture> s,id<MTLTexture> ui,id<MTLTexture> z,id<MTLTexture> motion,FgCamera *c,int mode,double now) {
    id<MTLCommandBuffer> cb=[queue commandBuffer];
    id<MTLTexture> out=fg_encode(cb,s,ui,z,motion,c,mode,0,now);
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
static id<MTLTexture> encode(id<MTLTexture> s,id<MTLTexture> ui,id<MTLTexture> z,FgCamera *c,int mode,double now) {
    return encode_motion(s,ui,z,nil,c,mode,now);
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
// Pans the camera over five frames and returns the last generated image.
static NSData *sequence_last(id<MTLTexture> z,const FgRect *rect,int mode) {
    fg_reset();
    NSData *last=nil;
    for(int i=0;i<5;i++) {
        FgCamera c=camera(i*16.f/(W*(1.f/tanf(M_PI/6)/((float)W/H))),false);
        id<MTLCommandBuffer> cb=[queue commandBuffer];
        id<MTLTexture> out=fg_encode_view(cb,scene(i*4,false),nil,NULL,z,rect,nil,&c,mode,0,3.+i/(mode==1?30.:60.));
        [cb commit]; [cb waitUntilCompleted]; assert(!cb.error);
        if(i<2) assert(!out); else { assert(out); last=readback(out); }
    }
    return last;
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
static double difference(NSData *data, int shift, unsigned inset) {
    const __fp16 *p=data.bytes;
    double sum=0;
    for(unsigned y=inset;y<H-inset;y++)for(unsigned x=inset;x<W-inset;x++) {
        unsigned sx=(x+shift+W)%W, i=(y*W+x)*4;
        __fp16 expected[3]={(__fp16)(sx/255.f),(__fp16)(y/255.f),(__fp16)((((sx/24+y/24)&1)?220:25)/255.f)};
        for(unsigned k=0;k<3;k++)sum+=fabs((float)p[i+k]-(float)expected[k]);
    }
    return sum/((W-2*inset)*(H-2*inset)*3);
}
static void assert_midpoint(NSData *data, int current_shift, int mode, bool reversed, bool native) {
    // Exclude wraparound/disocclusion borders, including the retained frames' 28px shift.
    const unsigned inset=32;
    int midpoint=current_shift-2, best_shift=current_shift-4;
    double previous=difference(data,current_shift-4,inset), current=difference(data,current_shift,inset);
    double middle=difference(data,midpoint,inset), best=previous;
    for(int shift=current_shift-3;shift<=current_shift;shift++) {
        double error=difference(data,shift,inset);
        if(error<best) { best=error; best_shift=shift; }
    }
    fprintf(stderr,"phase mode%d reversed%d native%d shift%d: midpoint %.6f, previous %.6f, current %.6f, best %d (expected %d)\n",
        mode,reversed,native,current_shift,middle,previous,current,best_shift,midpoint);
    assert(middle<previous && middle<current);
    assert(abs(best_shift-midpoint)<=1);
}
static id<MTLTexture> geometry_field(bool gradient) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float width:W height:H mipmapped:NO];
    d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> t=[device newTextureWithDescriptor:d];
    const __fp16 values[8][2]={{-6,2},{65504,0},{0,65504},{-65504,0},{NAN,1},{1,INFINITY},{-INFINITY,0},{0,0}};
    __fp16 *pixels=malloc(W*H*4);
    for(unsigned y=0;y<H;y++)for(unsigned x=0;x<W;x++) {
        unsigned i=(y*W+x)*2, band=x/(W/8);
        pixels[i]=gradient?(__fp16)(1+x*.125f):values[band][0];
        pixels[i+1]=gradient?(__fp16)(-2+y*.125f):values[band][1];
    }
    [t replaceRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0 withBytes:pixels bytesPerRow:W*4];
    free(pixels);return t;
}
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
API_AVAILABLE(macos(26.0))
static void geometry_motion_test(int mode) {
    fg_reset();double now=20,dt=1./(mode==1?30:60);
    id<MTLTexture> z=depth(false,false), geometry=geometry_field(false);
    FgCamera c=camera(0,false);
    assert(!encode(scene(0,false),nil,z,&c,mode,now));
    c=camera(16.f/(W*(1.f/tanf(M_PI/6)/((float)W/H))),false);
    assert(!encode(scene(4,false),nil,z,&c,mode,now+=dt));
    c=camera(32.f/(W*(1.f/tanf(M_PI/6)/((float)W/H))),false);
    assert(encode_motion(scene(8,false),nil,z,geometry,&c,mode,now+=dt)); // nil -> geometry keeps history
    NSData *bytes=readback_pixels(state->previous->motion,4);const __fp16 *p=bytes.bytes;
    for(unsigned band=0;band<8;band++) {
        unsigned i=(H/2*W+band*(W/8)+W/16)*2;
        float x=band==0?-6:band==7?0:4,y=band==0?2:0;
        assert(fabsf((float)p[i]-x)<.01f && fabsf((float)p[i+1]-y)<.01f);
    }
    c=camera(48.f/(W*(1.f/tanf(M_PI/6)/((float)W/H))),false);
    assert(encode(scene(12,false),nil,z,&c,mode,now+=dt)); // geometry -> nil keeps history
    bytes=readback_pixels(state->previous->motion,4);p=bytes.bytes;
    unsigned center=(H/2*W+W/2)*2;
    assert(fabsf((float)p[center]-4)<.01f && fabsf((float)p[center+1])<.01f);
    for(id<MTLTexture> invalid in @[crop(geometry),scene(0,false)]) {
        assert(!encode_motion(scene(12,false),nil,z,invalid,&c,mode,now+=dt));
        assert(!state);
    }
    assert(!encode(scene(12,false),nil,z,&c,mode,now+=dt));
    assert(!encode(scene(12,false),nil,z,&c,mode,now+=dt));
    assert(encode(scene(12,false),nil,z,&c,mode,now+=dt));

    // Exercise scaled geometry selection through the real depth/motion conversion path.
    id<MTLCommandBuffer> cb=[queue commandBuffer];
    assert(!fg_encode(cb,scene(12,false),nil,z,geometry_field(true),&c,mode,W/2,now+=dt));
    [cb commit];[cb waitUntilCompleted];assert(!cb.error);
    bytes=readback_pixels(state->previous->motion,4);p=bytes.bytes;
    unsigned sample=(23*(W/2)+17)*2; // nearest source (35,47), displacement scaled by 1/2
    assert(fabsf((float)p[sample]-2.6875f)<.001f && fabsf((float)p[sample+1]-1.9375f)<.001f);

    // Reset before submission must preserve the externally supplied field through completion.
    fg_reset();id<MTLCommandBuffer> pending=[queue commandBuffer];__weak id<MTLTexture> external_ref;
    @autoreleasepool {
        id<MTLTexture> external=geometry_field(false);external_ref=external;
        assert(!fg_encode(pending,scene(0,false),nil,z,external,&c,mode,0,now+=dt));
    }
    assert(external_ref);fg_reset();[pending commit];[pending waitUntilCompleted];assert(!pending.error);
}
#endif
int main(void) {@autoreleasepool {
    device=MTLCreateSystemDefaultDevice(); queue=[device newCommandQueue];
    if(!fg_supported()){puts("SKIP: macOS 26 / supported MetalFX GPU required");return 0;}
    printf("GPU: %s\n",device.name.UTF8String);
    unsetenv("LARECOMP_FG_OUTPUT_FP16");
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if(@available(macOS 26.0,*)) {
    geometry_motion_test(1);geometry_motion_test(2);
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
            double current_difference=difference(bytes,i*4,0), previous_difference=difference(bytes,(i-1)*4,0);
            assert(current_difference>.0001 && previous_difference>.0001);
            assert_midpoint(bytes,i*4,mode,reversed,native);
            if(last)assert(![last isEqualToData:bytes]);
            last=bytes;
        }
        assert([readback(retained_output) isEqualToData:retained_data]);
        assert(!fg_encode(nil,scene(12,false),nil,z,nil,&c,mode,0,now));
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
    assert(!fg_encode(completed,scene(0,false),nil,z,nil,&c,2,0,3.));

    // More pending frames than any fixed triple buffer, followed by a reset
    // before submission, verifies the ring and completion-owned generation.
    for(int mode=1;mode<=2;mode++) {
        fg_reset();
        NSMutableArray<id<MTLCommandBuffer>> *pending=[NSMutableArray new];
        NSMutableArray<id<MTLTexture>> *outputs=[NSMutableArray new];
        for(int i=0;i<8;i++) {
            id<MTLCommandBuffer> cb=[queue commandBuffer];
            c=camera(i*16.f/(W*(1.f/tanf(M_PI/6)/((float)W/H))),false);
            id<MTLTexture> out=fg_encode(cb,scene(i*4,false),nil,z,nil,&c,mode,0,3.+i/(mode==1?30.:60.));
            if(i<2)assert(!out); else { assert(out); [outputs addObject:out]; }
            [pending addObject:cb];
        }
        assert(state->ring.count==8);
        fg_reset();
        for(id<MTLCommandBuffer> cb in pending)[cb commit];
        for(id<MTLCommandBuffer> cb in pending) { [cb waitUntilCompleted]; assert(!cb.error); }
        for(unsigned i=0;i<outputs.count;i++) {
            NSData *bytes=readback(outputs[i]);
            assert(difference(bytes,(i+2)*4,0)>.0001 && difference(bytes,(i+1)*4,0)>.0001);
            assert_midpoint(bytes,(i+2)*4,mode,false,false);
        }
    }
    for(int mode=1;mode<=2;mode++) {  // the picture is a sub-rectangle of a larger depth target: same result as a plain one
        NSData *plain=sequence_last(depth(false,false),NULL,mode), *corner=sequence_last(depth_in_corner(),&(FgRect){0,0,W,H},mode);
        assert(plain.length==corner.length);
        const __fp16 *x=plain.bytes,*y=corner.bytes;
        for(NSUInteger i=0;i<plain.length/sizeof(__fp16);i++)assert(fabsf((float)x[i]-(float)y[i])<.004f);
    }
    fg_reset();setenv("LARECOMP_FG_OUTPUT_FP16","1",1);
    { FgCamera c=camera(0,false);id<MTLTexture> z=depth(false,false);
      assert(!encode(scene(0,false),nil,z,&c,1,30.));
      assert(!encode(scene(0,false),nil,z,&c,1,30.+1./30));
      assert(encode(scene(0,false),nil,z,&c,1,30.+2./30)); }
    unsetenv("LARECOMP_FG_OUTPUT_FP16");fg_reset();
    // Change generated resolution live while scene/depth/motion remain at native size.
    {
        id<MTLTexture> source=scene(0,false),ui=scene(0,true),z=depth(false,false),geometry=geometry_field(false);
        FgCamera c=camera(0,false);
        for(unsigned i=0;i<6;i++) {
            unsigned limit=i<3?W/2:0;
            id<MTLCommandBuffer> cb=[queue commandBuffer];
            id<MTLTexture> out=fg_encode(cb,source,ui,z,geometry,&c,2,limit,40.+i/60.);
            [cb commit];[cb waitUntilCompleted];assert(!cb.error);
            assert(source.width==W && source.height==H);
            if(i%3<2)assert(!out);
            else {
                assert(out.width==(limit?W/2:W) && out.height==(limit?H/2:H));
                NSData *bytes=readback_pixels(state->previous->motion,4);
                const __fp16 *v=bytes.bytes;
                unsigned x=(unsigned)out.width/16,y=(unsigned)out.height/2;
                NSUInteger row=(out.width*4+255)&~255;
                const __fp16 *motion=(const __fp16 *)((const uint8_t *)v+y*row+x*4);
                assert(fabs((float)motion[0]-(limit?-3:-6))<.01 && fabs((float)motion[1]-(limit?1:2))<.01);
            }
        }
        fg_reset();
    }
    puts("PASS: both modes, normal/reversed native/float depth, motion scenes, 4px X/-3px Y backward motion, geometry override/sentinel/nonfinite fallback/scaling, interior midpoint within 1px, private output distinct from endpoints, reset/gap/nil/off/UI/cut/resize, in-flight retention");
    }
#endif
    return 0;
}}
