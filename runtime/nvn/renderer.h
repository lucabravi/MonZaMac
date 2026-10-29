// Interface between the NVN executor (renderer.m) and the Metal plumbing (metal.m).
#pragma once
#include <stdbool.h>
#include <stdint.h>
#ifdef __OBJC__
#import <Metal/Metal.h>
void renderer_init(id<MTLDevice> dev);
id<MTLCommandQueue> renderer_queue(void);
id<MTLTexture> renderer_texture(NvnTexture *t, id<MTLBlitCommandEncoder> blit, bool for_render);
MTLPixelFormat renderer_pixel_format(uint32_t nvn_format);
bool renderer_format_alpha_one(uint32_t nvn_format);
extern id<MTLBuffer> g_guest_buffer;
extern uint64_t g_guest_buffer_base;
extern uint64_t g_gwin_base, g_gwin_max;  // guest memory window g_guest_buffer wraps (see backend_gwin_pick)
void backend_gwin_pick(void);
#endif
#include <SDL3/SDL_events.h>

typedef struct RendererGpuTimingToken RendererGpuTimingToken;
double renderer_host_time_seconds(void);
bool renderer_gpu_timing_trace(void);  // LARECOMP_GPU_TIMING_TRACE, read once
RendererGpuTimingToken *renderer_gpu_timing_submit(uint64_t frame, const char *kind);
void renderer_gpu_timing_mark_commit(RendererGpuTimingToken *token);
void renderer_gpu_timing_complete(RendererGpuTimingToken *token, double gpu_start, double gpu_end);
double renderer_gpu_timing_present(uint64_t frame, double *present_time, double *frame_ms, unsigned *samples);
void renderer_gpu_timing_reset(void);

// Opt-in live diagnostics; the boundary is after all work for a presented frame has been submitted.
void renderer_debug_frame_boundary(uint64_t frame);
void renderer_profile_pass_end(const char *reason);
bool renderer_profile_active(void);
void renderer_present_submit(void);

bool renderer_is_gpu_owned(NvnTexture *t);
void renderer_flush(void);  // finish all recorded GPU work
void renderer_save_pipeline_archive(void);  // write cache/pipelines.bin now (also done at exit)
bool renderer_origin_lower_left(void);
const char *renderer_stats(void);
bool renderer_format_is_depth(uint32_t f);
bool renderer_format_has_stencil(uint32_t f);
bool renderer_format_is_uint(uint32_t f);
bool renderer_format_is_sint(uint32_t f);
void renderer_mark_gpu_owned(NvnTexture *t);
void input_handle_event(const SDL_Event *e);
void input_mouse_update(SDL_Window *w);  // runtime/hle/input.c
bool input_user_blocked(const SDL_Event *e);
