#pragma once
#include <stdbool.h>
#include <stdint.h>
#ifdef __OBJC__
#import <Metal/Metal.h>
#endif
#ifdef __cplusplus
extern "C" {
#endif
#ifdef __OBJC__
// Renderer-thread only; the registry owns buffers until reset/eviction. Encoders retain bindings.
typedef struct {
    __unsafe_unretained id<MTLBuffer> current, previous;
    uint32_t vertex_count;
    bool has_previous;
} FgGeometryBinding;
bool fg_geometry_acquire(id<MTLDevice>, uint64_t key, uint64_t frame, uint32_t vertices, FgGeometryBinding *out);
bool fg_geometry_model(uint64_t key, uint64_t frame, uint64_t signature);
void fg_geometry_written(uint64_t key, uint64_t frame);
#endif
void fg_geometry_reset(void);
bool fg_geometry_frame_valid(uint64_t frame);
#ifdef __cplusplus
}
#endif
