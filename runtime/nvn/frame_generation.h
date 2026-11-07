#ifndef NVN_FRAME_GENERATION_H
#define NVN_FRAME_GENERATION_H

#include <stdbool.h>

// Metal clip depth [0,1]; matrices are column-major, without temporal jitter.
typedef struct {
    float view_projection[16];
    float inverse_view_projection[16];
    float near_plane, far_plane;
    float vertical_fov; // degrees
    float aspect;
    bool reversed_depth;
} FgCamera;

#ifdef __OBJC__
#import <Metal/Metal.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif
bool fg_supported(void);
// Developer-only, call after committing the encoded frame and before encoding another.
bool fg_debug_dump(const char *directory);
void fg_reset(void);
#ifdef __OBJC__
// End active encoders first. Calls and commits must follow frame order on one queue.
// Inputs must be shader-readable, tracked, single-sample 2D textures of equal size.
// max_width: 0 keeps native resolution; a lower width affects only generated frames.
// mode: 0=off, 1=30->60, 2=60->120. First two frames after reset and invalid frames return nil.
// Returned private texture matches an 8-bit canvas when supported, otherwise RGBA16Float.
// It can be retained by the presenter and is never recycled.
// Camera-only motion cannot describe independently moving objects or particles.
// Optional geometry motion is backward RG16Float displacement in scene pixels.
// Any component at +/-65504 or nonfinite falls back to camera motion for that pixel.
id<MTLTexture> fg_encode(id<MTLCommandBuffer> command_buffer,
                         id<MTLTexture> scene, id<MTLTexture> composited_ui,
                         id<MTLTexture> depth, id<MTLTexture> geometry_motion, const FgCamera *camera,
                         int mode, unsigned max_width, double now_seconds);
#endif
#ifdef __cplusplus
}
#endif
#endif
