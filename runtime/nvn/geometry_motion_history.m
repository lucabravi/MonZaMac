#import "geometry_motion_history.h"
#import <Foundation/Foundation.h>
#include <string.h>
#include "maxwell/shader.h"

@interface FgGeometryEntry : NSObject {
@public
    id<MTLBuffer> buffers[2];
    uint64_t frame, signature;
    uint32_t vertices;
    unsigned current;
    bool has_previous, signature_set, ambiguous, captured;
}
@end
@implementation FgGeometryEntry
@end
static NSMutableDictionary<NSNumber *,FgGeometryEntry *> *entries;
static id<MTLDevice> device;
static uint64_t allocated, last_frame=UINT64_MAX, invalid_frame=UINT64_MAX;
static const uint64_t budget=128ull<<20;
void fg_geometry_reset(void) {
    entries=nil;device=nil;allocated=0;last_frame=invalid_frame=UINT64_MAX;
}
bool fg_geometry_frame_valid(uint64_t frame) { return frame!=invalid_frame; }
bool fg_geometry_acquire(id<MTLDevice> d,uint64_t key,uint64_t frame,uint32_t vertices,FgGeometryBinding *out) {
    if(!out)return false;memset(out,0,sizeof *out);
    if(!d || !key || !vertices || vertices>262144 || frame==UINT64_MAX)return false;
    if(device!=d || (last_frame!=UINT64_MAX && frame<last_frame))fg_geometry_reset();
    if(!entries){entries=[NSMutableDictionary new];device=d;}
    if(frame!=last_frame) {
        for(NSNumber *k in entries.allKeys) {
            FgGeometryEntry *e=entries[k];
            if(e->frame<frame && frame-e->frame>2) {allocated-=(uint64_t)e->vertices*(FG_HISTORY_WORDS*8ull);[entries removeObjectForKey:k];}
        }
        last_frame=frame;
    }
    FgGeometryEntry *e=entries[@(key)];
    if(e && e->vertices!=vertices) {allocated-=(uint64_t)e->vertices*(FG_HISTORY_WORDS*8ull);[entries removeObjectForKey:@(key)];e=nil;}
    if(!e) {
        uint64_t bytes=(uint64_t)vertices*(FG_HISTORY_WORDS*8ull);if(bytes>budget-allocated)return false;
        e=[FgGeometryEntry new];e->vertices=vertices;e->frame=UINT64_MAX;
        for(int i=0;i<2;i++) {
            e->buffers[i]=[d newBufferWithLength:vertices*(FG_HISTORY_WORDS*4ull) options:MTLResourceStorageModeShared];
            if(!e->buffers[i])return false;
            // Unreferenced indexed vertices must never look like a captured frame.
            memset(e->buffers[i].contents,0,e->buffers[i].length);
        }
        allocated+=bytes;entries[@(key)]=e;
    }
    if(e->frame!=frame) {
        e->has_previous=e->frame!=UINT64_MAX && e->frame+1==frame && e->captured && !e->ambiguous;
        if(e->frame!=UINT64_MAX)e->current^=1;
        e->frame=frame;e->signature_set=false;e->ambiguous=false;e->captured=false;
    }
    out->current=e->buffers[e->current];out->previous=e->buffers[e->current^1];
    out->vertex_count=vertices;out->has_previous=e->has_previous&&!e->ambiguous;
    return true;
}
bool fg_geometry_model(uint64_t key,uint64_t frame,uint64_t signature) {
    FgGeometryEntry *e=entries[@(key)];if(!e || e->frame!=frame)return false;
    if(e->signature_set && e->signature!=signature){e->ambiguous=true;invalid_frame=frame;return false;}
    e->signature=signature;e->signature_set=true;return !e->ambiguous;
}

void fg_geometry_written(uint64_t key,uint64_t frame) {
    FgGeometryEntry *e=entries[@(key)];if(e && e->frame==frame)e->captured=true;
}
