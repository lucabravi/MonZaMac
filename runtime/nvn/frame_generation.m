// Optional ordinary-Metal MetalFX interpolation. No guest simulation work happens here.
#import "frame_generation.h"
#import <Foundation/Foundation.h>
#import <MetalFX/MetalFX.h>
#import <simd/simd.h>
#include <math.h>

#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000

API_AVAILABLE(macos(26.0))
@interface FgFrame : NSObject {
@public
    id<MTLTexture> color, depth, motion, ui;
    NSUInteger readers;
}
@end
@implementation FgFrame
@end

API_AVAILABLE(macos(26.0))
@interface FgState : NSObject {
@public
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLFXFrameInterpolator> effect;
    id<MTLComputePipelineState> copy_color, depth_float, depth_native;
    NSMutableArray<FgFrame *> *ring;
    FgFrame *previous;
    FgCamera camera;
    double time;
    NSUInteger width, height;
    MTLPixelFormat scene_format, depth_format, ui_format;
    int mode;
    BOOL has_ui;
    NSUInteger warmup;
}
@end
@implementation FgState
@end

static FgState *state API_AVAILABLE(macos(26.0));

// MetalFX expects backward motion in pixels. Reconstruct using the same raw
// [0,1] depth as the supplied inverse VP; reversed Z needs no extra inversion.
static NSString *const shader_source =
@"#include <metal_stdlib>\nusing namespace metal;\n"
"struct Camera { float4x4 inverse; float4x4 previous; };\n"
"kernel void color_copy(texture2d<float,access::read> s [[texture(0)]], texture2d<half,access::write> d [[texture(1)]], uint2 p [[thread_position_in_grid]]) { if(p.x<d.get_width()&&p.y<d.get_height()) d.write(half4(s.read(p)),p); }\n"
"void project(float z, uint2 p, constant Camera& c, texture2d<float,access::write> d, texture2d<half,access::write> m) {\n"
" float2 size=float2(d.get_width(),d.get_height()); float2 uv=(float2(p)+.5)/size;\n"
" float4 world=c.inverse*float4(uv.x*2-1,1-uv.y*2,z,1);\n"
" float4 prev=c.previous*world; float2 motion=0;\n"
" if(all(isfinite(prev))&&prev.w>1e-6) { float2 ndc=prev.xy/prev.w; float2 previousUV=float2(ndc.x*.5+.5,.5-ndc.y*.5); motion=(previousUV-uv)*size; }\n"
" if(!all(isfinite(motion)))motion=0;\n"
" d.write(float4(z),p); m.write(half4(half2(clamp(motion,-size,size)),0,0),p); }\n"
"kernel void float_depth(texture2d<float,access::read> s [[texture(0)]],texture2d<float,access::write> d [[texture(1)]],texture2d<half,access::write> m [[texture(2)]],constant Camera& c [[buffer(0)]],uint2 p [[thread_position_in_grid]]) { if(p.x<d.get_width()&&p.y<d.get_height())project(s.read(p).x,p,c,d,m); }\n"
"kernel void native_depth(depth2d<float> s [[texture(0)]],texture2d<float,access::write> d [[texture(1)]],texture2d<half,access::write> m [[texture(2)]],constant Camera& c [[buffer(0)]],uint2 p [[thread_position_in_grid]]) { constexpr sampler q(coord::pixel,filter::nearest); if(p.x<d.get_width()&&p.y<d.get_height())project(s.sample(q,float2(p)+.5),p,c,d,m); }\n";

static BOOL native_depth_format(MTLPixelFormat f) {
    return f==MTLPixelFormatDepth16Unorm || f==MTLPixelFormatDepth32Float || f==MTLPixelFormatDepth32Float_Stencil8;
}
static BOOL color_format(MTLPixelFormat f) {
    switch(f) {
        case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB:
        case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB:
        case MTLPixelFormatRGBA16Float: case MTLPixelFormatRGBA32Float:
        case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatRG11B10Float: return YES;
        default: return NO;
    }
}
static BOOL usable(id<MTLTexture> t, id<MTLDevice> d, NSUInteger w, NSUInteger h) {
    return t && t.device==d && t.width==w && t.height==h && t.textureType==MTLTextureType2D &&
        t.sampleCount==1 && !t.framebufferOnly && t.storageMode!=MTLStorageModeMemoryless &&
        (t.usage&MTLTextureUsageShaderRead) && t.hazardTrackingMode!=MTLHazardTrackingModeUntracked;
}
static BOOL camera_valid(const FgCamera *c) {
    if(!c || !isfinite(c->near_plane) || !isfinite(c->far_plane) || c->near_plane<=0 || c->far_plane<=c->near_plane ||
       !isfinite(c->vertical_fov) || c->vertical_fov<=0 || c->vertical_fov>=180 || !isfinite(c->aspect) || c->aspect<=0)return NO;
    for(unsigned i=0;i<16;i++)if(!isfinite(c->view_projection[i]) || !isfinite(c->inverse_view_projection[i]))return NO;
    matrix_float4x4 vp, inv;
    memcpy(&vp,c->view_projection,sizeof vp); memcpy(&inv,c->inverse_view_projection,sizeof inv);
    matrix_float4x4 product=simd_mul(vp,inv);
    for(unsigned col=0;col<4;col++)for(unsigned row=0;row<4;row++)
        if(!isfinite(product.columns[col][row]) || fabsf(product.columns[col][row]-(col==row?1.f:0.f))>.02f)return NO;
    return YES;
}
static BOOL camera_cut(const FgCamera *old, const FgCamera *c) {
    if(old->reversed_depth!=c->reversed_depth || fabsf(old->vertical_fov-c->vertical_fov)>2.f ||
       fabsf(old->aspect/c->aspect-1.f)>.01f || fabsf(old->near_plane/c->near_plane-1.f)>.01f ||
       fabsf(old->far_plane/c->far_plane-1.f)>.01f)return YES;
    matrix_float4x4 vp,inv;
    memcpy(&vp,old->view_projection,sizeof vp); memcpy(&inv,c->inverse_view_projection,sizeof inv);
    matrix_float4x4 reprojection=simd_mul(vp,inv);
    // A large screen-space camera jump is treated as a cut. The caller also
    // resets explicitly for menus, loading, or cuts below this conservative limit.
    for(unsigned i=0;i<2;i++) {
        float z=i?.99f:.95f;
        vector_float4 p={0,0,c->reversed_depth?1.f-z:z,1};
        vector_float4 q=simd_mul(reprojection,p);
        if(!isfinite(q.w) || q.w<=1e-6 || fabsf(q.x/q.w)>.6f || fabsf(q.y/q.w)>.6f)return YES;
    }
    return NO;
}
API_AVAILABLE(macos(26.0))
static id<MTLTexture> texture(FgState *s, MTLPixelFormat f, MTLTextureUsage usage) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:s->width height:s->height mipmapped:NO];
    d.storageMode=MTLStorageModePrivate; d.usage=usage;
    return [s->device newTextureWithDescriptor:d];
}
API_AVAILABLE(macos(26.0))
static FgState *make_state(id<MTLCommandBuffer> cb, id<MTLTexture> scene, id<MTLTexture> ui, id<MTLTexture> depth, int mode) {
    FgState *s=[FgState new]; s->device=cb.device; s->queue=cb.commandQueue;
    s->width=scene.width; s->height=scene.height; s->mode=mode; s->has_ui=ui!=nil;
    s->scene_format=scene.pixelFormat; s->depth_format=depth.pixelFormat; s->ui_format=ui.pixelFormat;
    MTLFXFrameInterpolatorDescriptor *d=[MTLFXFrameInterpolatorDescriptor new];
    d.inputWidth=d.outputWidth=s->width; d.inputHeight=d.outputHeight=s->height;
    d.colorTextureFormat=MTLPixelFormatRGBA16Float;
    // Match the game's 8-bit canvas directly; avoids a full-frame FP16→8-bit pass.
    const char *fp16=getenv("LARECOMP_FG_OUTPUT_FP16");
    bool native8=(!fp16 || !atoi(fp16)) &&
        (scene.pixelFormat==MTLPixelFormatRGBA8Unorm || scene.pixelFormat==MTLPixelFormatBGRA8Unorm);
    d.outputTextureFormat=native8?scene.pixelFormat:MTLPixelFormatRGBA16Float;
    d.depthTextureFormat=MTLPixelFormatR32Float; d.motionTextureFormat=MTLPixelFormatRG16Float;
    d.uiTextureFormat=MTLPixelFormatRGBA16Float;
    s->effect=[d newFrameInterpolatorWithDevice:s->device];
    if(!s->effect && native8) {
        d.outputTextureFormat=MTLPixelFormatRGBA16Float;
        s->effect=[d newFrameInterpolatorWithDevice:s->device];
    }
    NSError *error=nil;
    id<MTLLibrary> lib=[s->device newLibraryWithSource:shader_source options:nil error:&error];
    if(!lib || !s->effect)return nil;
    s->copy_color=[s->device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"color_copy"] error:&error];
    s->depth_float=[s->device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"float_depth"] error:&error];
    s->depth_native=[s->device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"native_depth"] error:&error];
    if(!s->effect || !s->copy_color || !s->depth_float || !s->depth_native)return nil;
    s->ring=[NSMutableArray new];
    return s;
}
API_AVAILABLE(macos(26.0))
static FgFrame *acquire_frame(FgState *s) {
    for(FgFrame *f in s->ring)if(f!=s->previous && f->readers==0)return f;
    FgFrame *f=[FgFrame new];
    f->color=texture(s,MTLPixelFormatRGBA16Float,s->effect.colorTextureUsage|MTLTextureUsageShaderWrite);
    f->depth=texture(s,MTLPixelFormatR32Float,s->effect.depthTextureUsage|MTLTextureUsageShaderWrite);
    f->motion=texture(s,MTLPixelFormatRG16Float,s->effect.motionTextureUsage|MTLTextureUsageShaderWrite);
    if(s->has_ui)f->ui=texture(s,MTLPixelFormatRGBA16Float,s->effect.uiTextureUsage|MTLTextureUsageShaderWrite);
    if(!f->color || !f->depth || !f->motion || (s->has_ui && !f->ui))return nil;
    [s->ring addObject:f];
    return f;
}
#endif

bool fg_supported(void) {
    static bool supported; static dispatch_once_t once;
    dispatch_once(&once, ^{
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
        if(@available(macOS 26.0,*)) {
            id<MTLDevice> d=MTLCreateSystemDefaultDevice();
            supported=d && [MTLFXFrameInterpolatorDescriptor supportsDevice:d];
        }
#endif
    });
    return supported;
}

void fg_reset(void) {
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if(@available(macOS 26.0,*)) @synchronized([FgState class]) {
        // Pending completion handlers retain the old generation and its resources.
        state=nil;
    }
#endif
}

id<MTLTexture> fg_encode(id<MTLCommandBuffer> cb, id<MTLTexture> scene, id<MTLTexture> ui,
                         id<MTLTexture> depth, const FgCamera *camera, int mode, double now) {
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if(@available(macOS 26.0,*)) @synchronized([FgState class]) {
        id<MTLDevice> device=cb.device;
        BOOL valid=cb && cb.status<MTLCommandBufferStatusCommitted && (mode==1 || mode==2) && isfinite(now) && camera_valid(camera) &&
            [MTLFXFrameInterpolatorDescriptor supportsDevice:device] &&
            usable(scene,device,scene.width,scene.height) && color_format(scene.pixelFormat) &&
            usable(depth,device,scene.width,scene.height) &&
            (native_depth_format(depth.pixelFormat) || depth.pixelFormat==MTLPixelFormatR32Float || depth.pixelFormat==MTLPixelFormatR16Float || depth.pixelFormat==MTLPixelFormatR16Unorm) &&
            (!ui || (usable(ui,device,scene.width,scene.height) && color_format(ui.pixelFormat))) &&
            fabsf(camera->aspect-((float)scene.width/scene.height))<.05f;
        if(!valid) { state=nil; return nil; }
        FgState *s=state;
        if(!s || s->queue!=cb.commandQueue || s->width!=scene.width || s->height!=scene.height ||
           s->mode!=mode || s->scene_format!=scene.pixelFormat || s->depth_format!=depth.pixelFormat ||
           s->has_ui!=(ui!=nil) || s->ui_format!=ui.pixelFormat) {
            state=s=make_state(cb,scene,ui,depth,mode);
            if(!s)return nil;
        }
        double delta=now-s->time;
        BOOL reset=!s->previous || !isfinite(delta) || delta<=0 || delta>.25 || camera_cut(&s->camera,camera);
        FgFrame *frame=acquire_frame(s), *previous=reset?nil:s->previous;
        id<MTLTexture> output=texture(s,s->effect.outputTextureFormat,s->effect.outputTextureUsage|MTLTextureUsageShaderRead);
        if(!frame || !output) { state=nil; return nil; }
        id<MTLComputeCommandEncoder> encoder=[cb computeCommandEncoder];
        if(!encoder) { state=nil; return nil; }
        encoder.label=@"Frame generation input conversion and camera motion";
        [encoder setComputePipelineState:s->copy_color];
        [encoder setTexture:scene atIndex:0]; [encoder setTexture:frame->color atIndex:1];
        MTLSize size=MTLSizeMake(s->width,s->height,1), group=MTLSizeMake(8,8,1);
        [encoder dispatchThreads:size threadsPerThreadgroup:group];
        if(ui) {
            [encoder setTexture:ui atIndex:0]; [encoder setTexture:frame->ui atIndex:1];
            [encoder dispatchThreads:size threadsPerThreadgroup:group];
        }
        struct { matrix_float4x4 inverse, previous; } reprojection;
        memcpy(&reprojection.inverse,camera->inverse_view_projection,sizeof reprojection.inverse);
        memcpy(&reprojection.previous,previous?s->camera.view_projection:camera->view_projection,sizeof reprojection.previous);
        [encoder setComputePipelineState:native_depth_format(depth.pixelFormat)?s->depth_native:s->depth_float];
        [encoder setTexture:depth atIndex:0]; [encoder setTexture:frame->depth atIndex:1]; [encoder setTexture:frame->motion atIndex:2];
        [encoder setBytes:&reprojection length:sizeof reprojection atIndex:0];
        [encoder dispatchThreads:size threadsPerThreadgroup:group];
        [encoder endEncoding];

        id<MTLFXFrameInterpolator> effect=s->effect;
        effect.colorTexture=frame->color; effect.prevColorTexture=previous?previous->color:frame->color;
        effect.depthTexture=frame->depth; effect.motionTexture=frame->motion; effect.outputTexture=output;
        effect.uiTexture=frame->ui; effect.uiTextureComposited=ui!=nil;
        effect.depthReversed=camera->reversed_depth;
        effect.nearPlane=camera->near_plane; effect.farPlane=camera->far_plane;
        effect.fieldOfView=camera->vertical_fov; effect.aspectRatio=camera->aspect;
        effect.motionVectorScaleX=effect.motionVectorScaleY=1.f;
        effect.jitterOffsetX=effect.jitterOffsetY=0;
        effect.deltaTime=reset?(mode==1?1.f/30:1.f/60):(float)delta;
        effect.shouldResetHistory=reset;
        if(reset)s->warmup=2;
        [effect encodeToCommandBuffer:cb];
        frame->readers++; if(previous)previous->readers++;
        s->previous=frame; s->camera=*camera; s->time=now;
        // Native encoders can retain internal scratch/history resources. Keep the
        // whole generation, inputs, and both ring slots until GPU completion.
        NSArray *resources=ui?@[scene,depth,ui,output]:@[scene,depth,output];
        [cb addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            (void)resources;
            @synchronized([FgState class]) {
                frame->readers--; if(previous)previous->readers--;
                if(completed.status==MTLCommandBufferStatusError && state==s)state=nil;
            }
        }];
        // The native effect copies current color on its first non-reset encode.
        // Suppress both seed frames so callers never count that copy as generated.
        BOOL ready=s->warmup==0;
        if(s->warmup)s->warmup--;
        return ready?output:nil;
    }
#endif
    (void)cb; (void)scene; (void)ui; (void)depth; (void)camera; (void)mode; (void)now;
    return nil;
}
