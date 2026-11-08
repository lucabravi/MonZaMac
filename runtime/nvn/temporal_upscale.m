#import "temporal_upscale.h"
#import "../devlog.h"
#import <Foundation/Foundation.h>
#import <MetalFX/MetalFX.h>
#import <simd/simd.h>
#include <math.h>
#include <stdlib.h>

#include "../settings.h"
#include "../ui/menu.h"
static float min_scale=1,max_scale=2;
bool temporal_supported(void) {
    static bool supported;static dispatch_once_t once;
    dispatch_once(&once,^{if(@available(macOS 13.0,*)){
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();supported=[MTLFXTemporalScalerDescriptor supportsDevice:device];
        if(@available(macOS 14.0,*)){
            min_scale=[MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:device];
            max_scale=[MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:device];
        }
    }});
    return supported;
}
bool ts_enabled(void) { return settings_temporal_upscale(); }
static unsigned output_width,output_height;
static bool raster_active;
static uint64_t input_frame=UINT64_MAX,raster_frame=UINT64_MAX;
static bool scale_allowed(unsigned iw,unsigned ih,unsigned ow,unsigned oh){
    if(!iw || !ih || !ow || !oh)return false;
    float x=(float)ow/iw,y=(float)oh/ih;
    return x>=min_scale && x<=max_scale && y>=min_scale && y<=max_scale;
}
void ts_output_extent(unsigned width,unsigned height){output_width=width;output_height=height;}
bool ts_geometry_extent(unsigned width,unsigned height,uint64_t frame){
    raster_frame=frame;
    raster_active=ts_enabled() && !menu_is_open() && input_frame!=UINT64_MAX && input_frame+1==frame &&
        scale_allowed(width,height,output_width,output_height);
    return raster_active;
}
bool ts_raster_active(void){return ts_enabled() && raster_active && !menu_is_open();}
static float halton(unsigned n,unsigned b) {
    float v=0,f=1;for(;n;n/=b){f/=b;v+=f*(n%b);}return v;
}
void ts_jitter(uint64_t frame,float out[2]) {
    const char *e=getenv("LARECOMP_TEMPORAL_JITTER");
    unsigned n=(unsigned)(frame%8)+1;
    out[0]=e && !atoi(e)?0:halton(n,2)-.5f;
    out[1]=e && !atoi(e)?0:halton(n,3)-.5f;
}
void ts_camera_jitter(float m[96],const float j[2],float width,float height,bool flip_y) {
    float dx=2*j[0]/width,dy=(flip_y?2:-2)*j[1]/height;
    for(unsigned b=0;b<2;b++) {
        float *v=m+(b?32:0);
        for(unsigned col=0;col<4;col++){v[col*4]+=dx*v[col*4+3];v[col*4+1]+=dy*v[col*4+3];}
        v=m+(b?80:48);
        for(unsigned row=0;row<4;row++)v[12+row]-=dx*v[row]+dy*v[4+row];
    }
}

@interface TsFrame:NSObject {
@public
    id<MTLTexture> color,depth,motion,scaled,composite;
    unsigned readers;
}
@end
@implementation TsFrame
@end
@interface TsState:NSObject {
@public
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLFXTemporalScaler> effect;
    id<MTLComputePipelineState> prepare_float,prepare_depth,compose;
    NSMutableArray<TsFrame *> *ring;
    unsigned iw,ih,ow,oh;
    FgCamera previous;
    uint64_t last;
    bool valid;
}
@end
@implementation TsState
@end
static TsState *state;
void ts_reset(void){@synchronized([TsState class]){state=nil;input_frame=UINT64_MAX;raster_active=false;}}

static NSString *const source=@
"#include <metal_stdlib>\nusing namespace metal;\n"
"float3 linear_rgb(float3 c){return select(c/12.92f,pow((c+.055f)/1.055f,float3(2.4f)),c>.04045f); }\n"
"struct P { float4x4 inverse,previous; uint4 rect; float2 jitter; uint has_geometry; };\n"
"void prepare(float z,uint2 p,constant P& c,texture2d<float> scene,texture2d<half,access::read> geometry,texture2d<half,access::write> color,texture2d<float,access::write> depth,texture2d<half,access::write> motion) {\n"
" float2 size=float2(color.get_width(),color.get_height());float2 uv=(float2(p)+.5)/size;float2 plain=uv-c.jitter/size;\n"
" float4 rgb=scene.read(p);color.write(half4(half3(linear_rgb(rgb.rgb)),half(rgb.a)),p);depth.write(float4(z),p);float4 world=c.inverse*float4(plain.x*2-1,1-plain.y*2,z,1);float4 prev=c.previous*world;float2 mv=0;\n"
" if(all(isfinite(prev))&&prev.w>1e-6){float2 n=prev.xy/prev.w;mv=(float2(n.x*.5+.5,.5-n.y*.5)-plain)*size;}\n"
" if(c.has_geometry){half2 g=geometry.read(c.rect.xy+p).xy;if(all((as_type<ushort2>(g)&ushort2(0x7fff))<ushort2(0x7bff)))mv=float2(g);}\n"
" if(any((as_type<uint2>(mv)&uint2(0x7fffffff))>=uint2(0x7f800000)))mv=0;mv=clamp(mv,-size,size);motion.write(half4(half2(mv),0,0),p);}\n"
"kernel void float_input(texture2d<float> scene[[texture(0)]],texture2d<float> z[[texture(1)]],texture2d<half,access::read> geometry[[texture(2)]],texture2d<half,access::write> color[[texture(3)]],texture2d<float,access::write> depth[[texture(4)]],texture2d<half,access::write> motion[[texture(5)]],constant P& c[[buffer(0)]],uint2 p[[thread_position_in_grid]]){if(p.x<color.get_width()&&p.y<color.get_height())prepare(z.read(c.rect.xy+p).x,p,c,scene,geometry,color,depth,motion);}\n"
"kernel void depth_input(texture2d<float> scene[[texture(0)]],depth2d<float> z[[texture(1)]],texture2d<half,access::read> geometry[[texture(2)]],texture2d<half,access::write> color[[texture(3)]],texture2d<float,access::write> depth[[texture(4)]],texture2d<half,access::write> motion[[texture(5)]],constant P& c[[buffer(0)]],uint2 p[[thread_position_in_grid]]){constexpr sampler q(coord::pixel,filter::nearest);if(p.x<color.get_width()&&p.y<color.get_height())prepare(z.sample(q,float2(c.rect.xy+p)+.5),p,c,scene,geometry,color,depth,motion);}\n"
// Conservative spike-only HUD isolation: differing current-frame pixels use spatial sampling.
"kernel void composite(texture2d<float> scene[[texture(0)]],texture2d<float> ui[[texture(1)]],texture2d<float> scaled[[texture(2)]],texture2d<half,access::write> out[[texture(3)]],constant uint4& r[[buffer(0)]],uint2 p[[thread_position_in_grid]]){if(p.x>=out.get_width()||p.y>=out.get_height())return;constexpr sampler q(coord::normalized,filter::linear);float2 uv=(float2(p)+.5)/float2(out.get_width(),out.get_height());float4 s=scene.sample(q,uv);float4 u=ui.sample(q,(float2(r.xy)+uv*float2(r.zw))/float2(ui.get_width(),ui.get_height()));float delta=max(max(abs(s.r-u.r),abs(s.g-u.g)),abs(s.b-u.b));out.write(half4(delta>1.f/255.f?float4(linear_rgb(u.rgb),u.a):scaled.read(p)),p);}\n";

static id<MTLTexture> texture(TsState *s,MTLPixelFormat f,unsigned w,unsigned h,MTLTextureUsage usage) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    d.storageMode=MTLStorageModePrivate;d.usage=usage;return [s->device newTextureWithDescriptor:d];
}
static TsState *make_state(id<MTLCommandBuffer> cb,unsigned iw,unsigned ih,unsigned ow,unsigned oh) {
    TsState *s=[TsState new];s->device=cb.device;s->queue=cb.commandQueue;s->iw=iw;s->ih=ih;s->ow=ow;s->oh=oh;
    MTLFXTemporalScalerDescriptor *d=[MTLFXTemporalScalerDescriptor new];
    d.inputWidth=iw;d.inputHeight=ih;d.outputWidth=ow;d.outputHeight=oh;
    d.colorTextureFormat=d.outputTextureFormat=MTLPixelFormatRGBA16Float;
    d.depthTextureFormat=MTLPixelFormatR32Float;d.motionTextureFormat=MTLPixelFormatRG16Float;d.autoExposureEnabled=YES;
    s->effect=[d newTemporalScalerWithDevice:s->device];if(!s->effect)return nil;
    NSError *error=nil;id<MTLLibrary> lib=[s->device newLibraryWithSource:source options:nil error:&error];
    if(!lib){devlog("temporal","prepare compiler: %s",error.localizedDescription.UTF8String);return nil;}
    s->prepare_float=[s->device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"float_input"] error:&error];
    s->prepare_depth=[s->device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"depth_input"] error:&error];
    s->compose=[s->device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"composite"] error:&error];
    if(!s->prepare_float || !s->prepare_depth || !s->compose)return nil;
    s->ring=[NSMutableArray new];return s;
}
static TsFrame *acquire(TsState *s) {
    @synchronized([TsState class]){
        for(TsFrame *f in s->ring)if(!f->readers){f->readers++;return f;}
        if(s->ring.count>=6)return nil;
        TsFrame *f=[TsFrame new];
        f->color=texture(s,MTLPixelFormatRGBA16Float,s->iw,s->ih,s->effect.colorTextureUsage|MTLTextureUsageShaderWrite);
        f->depth=texture(s,MTLPixelFormatR32Float,s->iw,s->ih,s->effect.depthTextureUsage|MTLTextureUsageShaderWrite);
        f->motion=texture(s,MTLPixelFormatRG16Float,s->iw,s->ih,s->effect.motionTextureUsage|MTLTextureUsageShaderWrite);
        f->scaled=texture(s,MTLPixelFormatRGBA16Float,s->ow,s->oh,s->effect.outputTextureUsage|MTLTextureUsageShaderRead);
        f->composite=texture(s,MTLPixelFormatRGBA16Float,s->ow,s->oh,MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite);
        if(!f->color || !f->depth || !f->motion || !f->scaled || !f->composite)return nil;
        f->readers=1;[s->ring addObject:f];return f;
    }
}
static bool cut(const FgCamera *a,const FgCamera *b) {
    if(a->reversed_depth!=b->reversed_depth || fabsf(a->vertical_fov-b->vertical_fov)>2 || fabsf(a->aspect/b->aspect-1)>.01f)return true;
    matrix_float4x4 vp,inv;memcpy(&vp,a->view_projection,sizeof vp);memcpy(&inv,b->inverse_view_projection,sizeof inv);
    matrix_float4x4 transform=simd_mul(vp,inv);
    for(unsigned i=0;i<2;i++){
        float z=i?.99f:.95f;vector_float4 p={0,0,b->reversed_depth?1-z:z,1};p=simd_mul(transform,p);
        if(!isfinite(p.w)||p.w<=1e-6||fabsf(p.x/p.w)>.6f||fabsf(p.y/p.w)>.6f)return true;
    }
    return false;
}
static bool rect_fits(const FgRect *r,id<MTLTexture> t) {
    return r && t && r->width && r->height && r->x<t.width && r->y<t.height &&
        r->width<=t.width-r->x && r->height<=t.height-r->y;
}
static bool readable(id<MTLTexture> t,id<MTLDevice> d) {
    return t && t.device==d && t.textureType==MTLTextureType2D && t.sampleCount==1 && !t.framebufferOnly &&
        t.storageMode!=MTLStorageModeMemoryless && t.hazardTrackingMode!=MTLHazardTrackingModeUntracked && (t.usage&MTLTextureUsageShaderRead);
}
id<MTLTexture> ts_encode(id<MTLCommandBuffer> cb,id<MTLTexture> scene,id<MTLTexture> ui,
    id<MTLTexture> depth,id<MTLTexture> geometry,const FgCamera *camera,const FgRect *rect,
    unsigned width,unsigned height,uint64_t frame,TemporalOutput *output) {
    @synchronized([TsState class]) {
    if(output)*output=(TemporalOutput){0};
    if(!ts_enabled() || menu_is_open() || !cb || cb.status>=MTLCommandBufferStatusCommitted || !scene || !depth || !ui || !camera || !rect || !width || !height || width>16384 || height>16384 || !scale_allowed((unsigned)scene.width,(unsigned)scene.height,width,height) ||
       rect->width!=scene.width || rect->height!=scene.height || !rect_fits(rect,depth) || !rect_fits(rect,ui) ||
       !readable(scene,cb.device) || !readable(depth,cb.device) || !readable(ui,cb.device) ||
       (scene.pixelFormat!=MTLPixelFormatRGBA8Unorm && scene.pixelFormat!=MTLPixelFormatBGRA8Unorm) ||
       (ui.pixelFormat!=MTLPixelFormatRGBA8Unorm && ui.pixelFormat!=MTLPixelFormatBGRA8Unorm) ||
       (depth.pixelFormat!=MTLPixelFormatR32Float && depth.pixelFormat!=MTLPixelFormatR16Float && depth.pixelFormat!=MTLPixelFormatR16Unorm &&
        depth.pixelFormat!=MTLPixelFormatDepth16Unorm && depth.pixelFormat!=MTLPixelFormatDepth32Float && depth.pixelFormat!=MTLPixelFormatDepth32Float_Stencil8) ||
       (geometry && (!readable(geometry,cb.device) || geometry.width!=depth.width || geometry.height!=depth.height || geometry.pixelFormat!=MTLPixelFormatRG16Float)) ||
       !isfinite(camera->aspect) || camera->aspect<=0 ||
       !isfinite(camera->near_plane) || !isfinite(camera->far_plane) || camera->near_plane<=0 || camera->far_plane<=camera->near_plane){ts_reset();return nil;}
    TsState *s=state;
    if(!s || s->device!=cb.device || s->queue!=cb.commandQueue || s->iw!=scene.width || s->ih!=scene.height || s->ow!=width || s->oh!=height)
        state=s=make_state(cb,(unsigned)scene.width,(unsigned)scene.height,width,height);
    if(!s)return nil;
    TsFrame *f=acquire(s);if(!f){s->valid=false;return nil;}
    bool reset=!s->valid || frame!=s->last+1 || cut(&s->previous,camera);
    struct { matrix_float4x4 inverse,previous;vector_uint4 rect;vector_float2 jitter;uint32_t has_geometry; } p={0};
    memcpy(&p.inverse,camera->inverse_view_projection,sizeof p.inverse);
    memcpy(&p.previous,reset?camera->view_projection:s->previous.view_projection,sizeof p.previous);
    p.rect=(vector_uint4){rect->x,rect->y,rect->width,rect->height};if(ts_raster_active() && raster_frame==frame)ts_jitter(frame,(float *)&p.jitter);
    p.has_geometry=geometry && geometry.width==depth.width && geometry.height==depth.height && geometry.pixelFormat==MTLPixelFormatRG16Float;
    id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];
    bool native=depth.pixelFormat==MTLPixelFormatDepth16Unorm || depth.pixelFormat==MTLPixelFormatDepth32Float || depth.pixelFormat==MTLPixelFormatDepth32Float_Stencil8;
    [e setComputePipelineState:native?s->prepare_depth:s->prepare_float];
    [e setTexture:scene atIndex:0];[e setTexture:depth atIndex:1];[e setTexture:p.has_geometry?geometry:scene atIndex:2];
    [e setTexture:f->color atIndex:3];[e setTexture:f->depth atIndex:4];[e setTexture:f->motion atIndex:5];
    [e setBytes:&p length:sizeof p atIndex:0];[e dispatchThreads:MTLSizeMake(s->iw,s->ih,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[e endEncoding];
    id<MTLFXTemporalScaler> effect=s->effect;
    effect.colorTexture=f->color;effect.depthTexture=f->depth;effect.motionTexture=f->motion;effect.outputTexture=f->scaled;
    effect.inputContentWidth=s->iw;effect.inputContentHeight=s->ih;effect.reset=reset;effect.depthReversed=camera->reversed_depth;
    effect.preExposure=1;effect.motionVectorScaleX=effect.motionVectorScaleY=1;effect.jitterOffsetX=p.jitter.x;effect.jitterOffsetY=p.jitter.y;
    [effect encodeToCommandBuffer:cb];
    e=[cb computeCommandEncoder];[e setComputePipelineState:s->compose];
    [e setTexture:scene atIndex:0];[e setTexture:ui atIndex:1];[e setTexture:f->scaled atIndex:2];[e setTexture:f->composite atIndex:3];
    [e setBytes:&p.rect length:sizeof p.rect atIndex:0];[e dispatchThreads:MTLSizeMake(width,height,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[e endEncoding];
    s->last=frame;s->previous=*camera;s->valid=true;input_frame=frame;
    NSArray *inputs=@[scene,depth,ui,geometry?:scene];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done){(void)inputs;@synchronized([TsState class]){f->readers--;if(done.error && state==s)ts_reset();}}];
    if(frame%120==0)devlog("temporal","frame %llu %ux%u -> %ux%u geometry %u reset %d jitter %.3f,%.3f",(unsigned long long)frame,s->iw,s->ih,width,height,p.has_geometry,reset,p.jitter.x,p.jitter.y);
    if(output){
        output->scene=f->scaled;output->composited=f->composite;
        output->prepared=(FgPreparedInputs){.depth=f->depth,.motion=f->motion,.scaler=s->effect,.reset=reset};
        output->prepared.jitter[0]=p.jitter.x;output->prepared.jitter[1]=p.jitter.y;
    }
    return f->composite;
    }
}
