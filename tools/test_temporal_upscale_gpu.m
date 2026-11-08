#include <stdbool.h>
bool settings_temporal_upscale(void);
#include "../runtime/nvn/temporal_upscale.m"
#import <Foundation/Foundation.h>
#import <simd/simd.h>
#include <assert.h>
#include <math.h>
#include <stdarg.h>
static bool selected=true,menu_open;
bool menu_is_open(void){return menu_open;}
bool settings_temporal_upscale(void){return selected;}
void devlog(const char *subject,const char *fmt,...) {(void)subject;(void)fmt;}
static id<MTLTexture> input(id<MTLDevice> dev,MTLPixelFormat f) {
 MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:1920 height:1080 mipmapped:NO];
 d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;return [dev newTextureWithDescriptor:d];
}
int main(void){@autoreleasepool {
 unsigned checks=0;
 for(unsigned flip=0;flip<2;flip++)for(unsigned frame=0;frame<8;frame++){
  float j[2],m[96];ts_jitter(frame,j);matrix_float4x4 identity=matrix_identity_float4x4;
  matrix_float4x4 projection={.columns={{2,0,0,0},{0,3,0,0},{0,0,-1.001f,-1},{0,0,-.1001f,0}}};
  matrix_float4x4 inv=simd_inverse(projection);memcpy(m,&projection,64);memcpy(m+16,&identity,64);memcpy(m+32,&projection,64);
  memcpy(m+48,&inv,64);memcpy(m+64,&identity,64);memcpy(m+80,&inv,64);ts_camera_jitter(m,j,1920,1080,flip);
  matrix_float4x4 vp,vi,p,pi;memcpy(&vp,m,64);memcpy(&p,m+32,64);memcpy(&vi,m+48,64);memcpy(&pi,m+80,64);
  matrix_float4x4 a=simd_mul(vp,vi),b=simd_mul(p,pi);
  for(unsigned c=0;c<4;c++)for(unsigned r=0;r<4;r++){assert(fabsf(a.columns[c][r]-(c==r))<1e-5);assert(fabsf(b.columns[c][r]-(c==r))<1e-5);checks+=2;}
  vector_float4 point={.2f,.1f,-2,1},old=simd_mul(projection,point),shifted=simd_mul(vp,point);
  assert(fabsf((shifted.x/shifted.w-old.x/old.w)*960-j[0])<1e-4);
  assert(fabsf((shifted.y/shifted.w-old.y/old.w)*(flip?540:-540)-j[1])<1e-4);checks+=2;
 }
 setenv("LARECOMP_TEMPORAL_SPIKE","1",1);assert(ts_enabled());ts_output_extent(2880,1620);assert(!ts_geometry_extent(1920,1080,0));
 id<MTLDevice> dev=MTLCreateSystemDefaultDevice();id<MTLCommandQueue> q=[dev newCommandQueue];
 id<MTLTexture> scene=input(dev,MTLPixelFormatRGBA8Unorm),ui=input(dev,MTLPixelFormatRGBA8Unorm);
 FgCamera cam={.near_plane=.1f,.far_plane=100,.vertical_fov=60,.aspect=16.f/9};matrix_float4x4 identity=matrix_identity_float4x4;
 memcpy(cam.view_projection,&identity,64);memcpy(cam.inverse_view_projection,&identity,64);FgRect rect={0,0,1920,1080};
 id<MTLTexture> last_depth=nil;
 for(unsigned type=0;type<2;type++){
  id<MTLTexture> depth=input(dev,type?MTLPixelFormatDepth32Float:MTLPixelFormatR32Float);last_depth=depth;ts_reset();
  id<MTLCommandBuffer> cb=[q commandBuffer];
  for(id<MTLTexture> t in @[scene,ui,depth]){
   MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
   if(t.pixelFormat==MTLPixelFormatDepth32Float){rp.depthAttachment.texture=t;rp.depthAttachment.clearDepth=.5;rp.depthAttachment.loadAction=MTLLoadActionClear;rp.depthAttachment.storeAction=MTLStoreActionStore;}
   else{rp.colorAttachments[0].texture=t;rp.colorAttachments[0].clearColor=MTLClearColorMake(.3,.2,.1,1);rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;}
   [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
  }
  [cb commit];[cb waitUntilCompleted];assert(!cb.error);
  for(unsigned frame=0;frame<5;frame++){
   ts_geometry_extent(1920,1080,frame==3?7:frame);
   cb=[q commandBuffer];unsigned w=frame==4?2560:2880,h=frame==4?1440:1620;
   id<MTLTexture> out=ts_encode(cb,scene,ui,depth,nil,&cam,&rect,w,h,frame==3?7:frame,NULL);
   assert(out && out.width==w && out.height==h);[cb commit];[cb waitUntilCompleted];assert(!cb.error);checks++;
  }
 }
 assert(ts_geometry_extent(1920,1080,5));
 menu_open=true;assert(!ts_geometry_extent(1920,1080,5));assert(!ts_raster_active());menu_open=false;
 assert(!ts_geometry_extent(480,270,5));checks+=4;
 id<MTLCommandBuffer> bad=[q commandBuffer];FgRect badrect={UINT32_MAX,0,1920,1080};
 assert(!ts_encode(bad,scene,ui,last_depth,nil,&cam,&badrect,2880,1620,9,NULL));assert(!state);checks+=2;
 // Differing physical pixel aspect is valid: camera projection still supplies the right rays.
 FgCamera stretched=cam;stretched.aspect=1.6f;ts_output_extent(2880,1800);
 id<MTLCommandBuffer> tall=[q commandBuffer];TemporalOutput tall_out={0};
 assert(ts_encode(tall,scene,ui,last_depth,nil,&stretched,&rect,2880,1800,10,&tall_out));
 assert(tall_out.prepared.reset && tall_out.prepared.depth.width==1920 && tall_out.scene.width==2880);
 [tall commit];[tall waitUntilCompleted];assert(!tall.error);checks+=2;
 // Six queued generations must retain distinct resources through a reset.
 ts_reset();ts_output_extent(2880,1620);
 NSMutableArray *pending=[NSMutableArray new],*outputs=[NSMutableArray new];
 for(unsigned i=0;i<6;i++){
  id<MTLCommandBuffer> cb=[q commandBuffer];ts_geometry_extent(1920,1080,20+i);
  id<MTLTexture> out=ts_encode(cb,scene,ui,last_depth,nil,&cam,&rect,2880,1620,20+i,NULL);
  assert(out && ![outputs containsObject:out]);[outputs addObject:out];[pending addObject:cb];checks++;
 }
 id<MTLCommandBuffer> extra=[q commandBuffer];assert(!ts_encode(extra,scene,ui,last_depth,nil,&cam,&rect,2880,1620,26,NULL));checks++;
 ts_reset();
 for(id<MTLCommandBuffer> cb in pending){[cb commit];[cb waitUntilCompleted];assert(!cb.error);checks++;}
 selected=false;assert(!ts_raster_active());selected=true;
 assert(!ts_geometry_extent(4096,2160,9));assert(!ts_raster_active());checks+=3;
 printf("PASS %u matrix, coordinate, native/float depth, history-gap and resize checks\n",checks);return 0;
}}
