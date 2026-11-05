#import "frame_generation_display.h"
#include "frame_generation_present.h"
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <math.h>
#include <stdio.h>

@interface FgDisplayPacket : NSObject {
@public
    CAMetalLayer *layer;
    id<MTLTexture> real, generated;
    id<MTLCommandQueue> queue;
    int mode;
    uint64_t epoch;
}
@end
@implementation FgDisplayPacket
@end

static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t submit_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed=PTHREAD_COND_INITIALIZER;
static pthread_once_t once=PTHREAD_ONCE_INIT;
static _Atomic uint64_t current_epoch=1;
static NSMutableArray<FgDisplayPacket *> *pending;
static id<MTLCommandQueue> display_queue;
static bool worker_ready;
static uint64_t real_count, generated_count, dropped_count;
static double last_presented, last_generated, display_period;

uint64_t fg_display_epoch(void) { return atomic_load(&current_epoch); }
void fg_display_reset(void) {
    pthread_mutex_lock(&submit_lock);
    pthread_mutex_lock(&lock);
    atomic_fetch_add(&current_epoch,1);
    [pending removeAllObjects];
    last_presented=last_generated=display_period=0;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
    pthread_mutex_unlock(&submit_lock);
}
bool fg_presentation_active(double *fps) {
    pthread_mutex_lock(&lock);
    bool active=last_generated>0 && CACurrentMediaTime()-last_generated<.25 && display_period>0;
    if(fps)*fps=active?1./display_period:0;
    pthread_mutex_unlock(&lock);
    return active;
}
void fg_presentation_stats(uint64_t *real, uint64_t *generated, double *fps) {
    pthread_mutex_lock(&lock);
    if(real)*real=real_count;
    if(generated)*generated=generated_count;
    if(fps)*fps=display_period>0?1./display_period:0;
    pthread_mutex_unlock(&lock);
}

static bool wait_tick(uint64_t epoch, double deadline) {
    pthread_mutex_lock(&lock);
    double remaining;
    while(fg_display_epoch()==epoch && (remaining=deadline-CACurrentMediaTime())>0) {
        struct timespec duration={(time_t)remaining,(long)((remaining-floor(remaining))*1e9)};
        pthread_cond_timedwait_relative_np(&changed,&lock,&duration);
    }
    bool valid=fg_display_epoch()==epoch;
    pthread_mutex_unlock(&lock);
    return valid;
}
static double tick_phase(double deadline, double step, double now) {
    // Preserve absolute cadence across encoding overhead; rebase a stalled
    // worker so it never bursts through an old backlog of missed ticks.
    return now-deadline>step*.5?now:deadline;
}
static id<MTLCommandBuffer> copy_image(id<MTLCommandQueue> queue, id<MTLTexture> image, id<MTLTexture> target) {
    id<MTLCommandBuffer> cb=[queue commandBuffer];
    id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
    if(!cb || !blit)return nil;
    [blit copyFromTexture:image toTexture:target]; [blit endEncoding];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        (void)completed; (void)image; // retain immutable source through the copy
    }];
    return cb;
}
static bool present_image(FgDisplayPacket *p, id<MTLCommandQueue> queue,
                          id<MTLTexture> image, bool synthetic, double *phase, double step) {
    double deadline=*phase+step;
    if(!wait_tick(p->epoch,deadline))return false;
    id<CAMetalDrawable> drawable=[p->layer nextDrawable];
    if(!drawable || fg_display_epoch()!=p->epoch || drawable.texture.framebufferOnly ||
       drawable.texture.width!=image.width || drawable.texture.height!=image.height ||
       drawable.texture.pixelFormat!=image.pixelFormat)return false;
    id<MTLCommandBuffer> cb=copy_image(queue,image,drawable.texture);
    if(!cb)return false;
    uint64_t epoch=p->epoch;
    [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
        double now=shown.presentedTime;
        pthread_mutex_lock(&lock);
        if(fg_display_epoch()==epoch && now>0) {
            if(synthetic) { generated_count++;last_generated=now; } else real_count++;
            double delta=now-last_presented;
            if(delta>.001 && delta<.2)display_period=display_period?display_period*.9+delta*.1:delta;
            last_presented=fmax(now,last_presented);
            if((real_count+generated_count)%120==0)
                fprintf(stderr,"[framegen-present] real %llu generated %llu display %.1f fps dropped %llu\n",
                        (unsigned long long)real_count,(unsigned long long)generated_count,display_period>0?1./display_period:0,(unsigned long long)dropped_count);
        }
        pthread_mutex_unlock(&lock);
    }];
    // Serialize the final epoch check with reset. Already committed drawables
    // cannot be recalled, but reset prevents any later stale submission.
    pthread_mutex_lock(&submit_lock);
    bool valid=fg_display_epoch()==epoch;
    if(valid) {
        [cb presentDrawable:drawable]; [cb commit];
        double now=CACurrentMediaTime();
        *phase=tick_phase(deadline,step,now);
    }
    pthread_mutex_unlock(&submit_lock);
    return valid;
}
static void *display_worker(void *unused) {
    (void)unused; pthread_setname_np("MetalFX display");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);
    double last_tick=0; uint64_t epoch=0;
    for(;;) @autoreleasepool {
        pthread_mutex_lock(&lock);
        while(!pending.count)pthread_cond_wait(&changed,&lock);
        FgDisplayPacket *p=pending[0]; [pending removeObjectAtIndex:0];
        pthread_mutex_unlock(&lock);
        if(fg_display_epoch()!=p->epoch)continue;
        if(epoch!=p->epoch) { epoch=p->epoch; last_tick=0; }
        double period=1./(p->mode==1?30:60), step=p->generated?period*.5:period;
        if(p->generated) {
            if(!present_image(p,p->queue,p->generated,true,&last_tick,step))continue;
        }
        present_image(p,p->queue,p->real,false,&last_tick,step);
    }
    return NULL;
}
static void start_worker(void) {
    pthread_mutex_lock(&lock); pending=[NSMutableArray new]; pthread_mutex_unlock(&lock);
    pthread_t worker;
    worker_ready=pthread_create(&worker,NULL,display_worker,NULL)==0;
    if(worker_ready)pthread_detach(worker);
}
bool fg_display_submit(CAMetalLayer *layer, id<MTLTexture> real,
                       id<MTLTexture> generated, int mode, uint64_t epoch) {
    if(!layer || !real || (mode!=1 && mode!=2) || fg_display_epoch()!=epoch ||
       real.device!=layer.device || real.pixelFormat!=MTLPixelFormatBGRA8Unorm ||
       real.textureType!=MTLTextureType2D || real.sampleCount!=1 || real.framebufferOnly ||
       (generated && (generated.device!=real.device || generated.pixelFormat!=real.pixelFormat ||
        generated.width!=real.width || generated.height!=real.height || generated.textureType!=MTLTextureType2D ||
        generated.sampleCount!=1 || generated.framebufferOnly)))return false;
    FgDisplayPacket *p=[FgDisplayPacket new];
    p->layer=layer; p->real=real; p->generated=generated; p->mode=mode; p->epoch=epoch;
    pthread_once(&once,start_worker);
    pthread_mutex_lock(&lock);
    bool accepted=worker_ready && fg_display_epoch()==epoch;
    if(accepted && (!display_queue || display_queue.device!=layer.device))display_queue=[layer.device newCommandQueue];
    accepted=accepted && display_queue!=nil;
    if(accepted) {
        p->queue=display_queue;
        if(pending.count>=2) { [pending removeObjectAtIndex:0]; dropped_count++; }
        [pending addObject:p]; pthread_cond_signal(&changed);
    }
    pthread_mutex_unlock(&lock);
    return accepted;
}
