// Optional MetalFX temporal reconstruction. Settings preserve the saved spatial/AA choices.
#pragma once
#include "frame_generation.h"
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
bool temporal_supported(void);
bool ts_enabled(void);
bool ts_geometry_extent(unsigned width,unsigned height,uint64_t frame);
void ts_output_extent(unsigned width,unsigned height);
bool ts_raster_active(void);
void ts_jitter(uint64_t frame, float out[2]);
void ts_camera_jitter(float matrices[96], const float jitter[2], float width, float height, bool flip_y);
#ifdef __OBJC__
// Returned images are linear RGBA16F; presentation must encode sRGB.
// Prepared fields are valid for this command buffer; FG copies previous color before recycling.
typedef struct {
    id<MTLTexture> scene, composited;
    FgPreparedInputs prepared;
} TemporalOutput;
id<MTLTexture> ts_encode(id<MTLCommandBuffer> cb, id<MTLTexture> scene, id<MTLTexture> ui,
    id<MTLTexture> depth, id<MTLTexture> geometry, const FgCamera *camera, const FgRect *rect,
    unsigned width, unsigned height, uint64_t frame, TemporalOutput *output);
void ts_reset(void);
#endif

#ifdef __cplusplus
}
#endif
