// Include implementation to inspect queue ownership and cadence without a window
// or any test-only API in the renderer. Actual display cadence needs a real window.
#include "../runtime/nvn/frame_generation_display.m"
#include <assert.h>
#include <unistd.h>

static id<MTLTexture> private_image(id<MTLDevice> device) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
    d.storageMode=MTLStorageModePrivate;
    d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    return [device newTextureWithDescriptor:d];
}
// The queue fixture suppresses the window worker so overflow and retention are
// deterministic. GPU copying below still executes the production copy helper.
static void queue_fixture(void) { pending=[NSMutableArray new]; worker_ready=true; }
static void *reset_soon(void *unused) { (void)unused; usleep(10000); fg_display_reset(); return NULL; }

int main(void) {@autoreleasepool {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if(!device) { puts("SKIP: Metal device required"); return 0; }
    id<MTLCommandQueue> queue=[device newCommandQueue];
    id<MTLTexture> target=private_image(device);
    id<MTLCommandBuffer> copy;
    __weak id<MTLTexture> source_ref;
    @autoreleasepool {
        id<MTLTexture> source=private_image(device); source_ref=source;
        id<MTLCommandBuffer> cb=[queue commandBuffer];
        MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture=source; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
        rp.colorAttachments[0].storeAction=MTLStoreActionStore;
        rp.colorAttachments[0].clearColor=MTLClearColorMake(1,.25,.5,1);
        [[cb renderCommandEncoderWithDescriptor:rp] endEncoding]; [cb commit]; [cb waitUntilCompleted]; assert(!cb.error);
        copy=copy_image(queue,source,target);
    }
    assert(source_ref); // source is retained after its producing scope ends
    [copy commit]; [copy waitUntilCompleted]; assert(!copy.error);
    id<MTLBuffer> pixels=[device newBufferWithLength:256*16 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> read=[queue commandBuffer];
    id<MTLBlitCommandEncoder> blit=[read blitCommandEncoder];
    [blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(16,16,1)
                toBuffer:pixels destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256*16];
    [blit endEncoding]; [read commit]; [read waitUntilCompleted]; assert(!read.error);
    const uint8_t *bytes=pixels.contents;
    assert(abs(bytes[0]-128)<=1 && abs(bytes[1]-64)<=1 && bytes[2]==255 && bytes[3]==255);
    assert(target.storageMode==MTLStorageModePrivate);

    pthread_once(&once,queue_fixture);
    CAMetalLayer *layer=[CAMetalLayer new]; layer.device=device; layer.framebufferOnly=NO;
    uint64_t epoch=fg_display_epoch();
    assert(!fg_display_submit(layer,target,nil,0,epoch));
    assert(!fg_display_submit(layer,nil,nil,1,epoch));
    assert(!fg_display_submit(layer,target,nil,1,epoch-1));
    __weak id<MTLTexture> first_real, first_generated;
    @autoreleasepool {
        id<MTLTexture> real=private_image(device), generated=private_image(device);
        first_real=real; first_generated=generated;
        assert(fg_display_submit(layer,real,generated,1,epoch));
    }
    assert(first_real && first_generated);
    for(int i=0;i<2;i++) @autoreleasepool {
        assert(fg_display_submit(layer,private_image(device),private_image(device),1,epoch));
    }
    assert(pending.count==2 && dropped_count==1 && !first_real && !first_generated);
    fg_display_reset(); assert(fg_display_epoch()!=epoch && !pending.count);
    assert(!fg_display_submit(layer,target,nil,1,epoch));
    worker_ready=false;
    assert(!fg_display_submit(layer,target,nil,1,fg_display_epoch())); // startup failure fails closed
    worker_ready=true;
    assert(fg_display_submit(layer,target,nil,2,fg_display_epoch()));
    fg_display_reset();

    for(int mode=1;mode<=2;mode++) {
        double step=1./(mode==1?60:120), phase=100, initial=phase;
        for(int i=0;i<1000;i++) {
            double deadline=phase+step;
            phase=tick_phase(deadline,step,deadline+step*.2); // encoding overhead must not accumulate
        }
        assert(fabs(phase-(initial+1000*step))<1e-8);
        double late=phase+10*step;
        phase=tick_phase(phase+step,step,late);
        assert(fabs(phase-late)<1e-9 && phase+step>late); // a late tick rebases, no catchup burst
    }
    double start=CACurrentMediaTime();
    assert(wait_tick(fg_display_epoch(),start+.01));
    assert(CACurrentMediaTime()-start>=.009);
    pthread_t resetter; epoch=fg_display_epoch();
    assert(!pthread_create(&resetter,NULL,reset_soon,NULL));
    start=CACurrentMediaTime(); assert(!wait_tick(epoch,start+5));
    assert(CACurrentMediaTime()-start<1); pthread_join(resetter,NULL);
    uint64_t real, generated; double fps;
    fg_presentation_stats(&real,&generated,&fps);
    assert(!real && !generated && fps==0); // queued/copied work never counts as displayed
    puts("PASS: native private copy, retained inputs, bounded whole-packet drops, epochs/failure, absolute 60/120 cadence, interruptible reset, presentation-only counters");
    return 0;
}}
