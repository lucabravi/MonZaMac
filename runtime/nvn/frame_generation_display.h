#pragma once
#include <stdint.h>
#include <stdbool.h>
#ifdef __OBJC__
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#endif
#ifdef __cplusplus
extern "C" {
#endif
uint64_t fg_display_epoch(void);
// Call before changing mode, drawable size, or boot; cancels queued/uncommitted images.
void fg_display_reset(void);
#ifdef __OBJC__
// Submit only after source GPU completion. Images must be immutable, window-sized
// BGRA8Unorm. The layer must allow blits (framebufferOnly=NO). Stale epochs drop.
// False means invalid/stale input or worker/queue initialization failure.
bool fg_display_submit(CAMetalLayer *layer, id<MTLTexture> real,
                       id<MTLTexture> generated, int mode, uint64_t epoch);
#endif
#ifdef __cplusplus
}
#endif
