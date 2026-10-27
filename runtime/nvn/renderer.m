// Executes recorded NVN command lists with Metal.
#include <pthread.h>
#include <dirent.h>
#include <unistd.h>
#import <Metal/Metal.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <float.h>
#include <math.h>
#include <sys/stat.h>
#include <SDL3/SDL_timer.h>

#include "maxwell/shader.h"
#include "nvn.h"
#include "renderer.h"
#include "../settings.h"  // (g_settings.game_drs)

static id<MTLDevice> dev;
static id<MTLCommandBuffer> cmdbuf;
static id<MTLRenderCommandEncoder> enc;
static id<MTLRenderPipelineState> clear_pipes[64];
static NSMutableDictionary<NSString *, id> *cache;
// (stats) GPU wait time by cause: 0 = guest fence (nvnSyncWait), 1 = full flush (CPU reads GPU results / ring), 2 = sync all
static uint64_t stat_wait_by[3], stat_wait_n[3];
static void dump_pending_arrays(void);
static uint64_t stat_draws, stat_skipped, stat_passes, stat_dispatches, stat_wait_ns, stat_flushes, stat_feedback_copies;
static uint64_t stat_skip_none, stat_skip_failed, stat_skip_wait;  // why a draw was dropped
static double stat_gpu_s;
static pthread_mutex_t gpu_timing_lock = PTHREAD_MUTEX_INITIALIZER;

#define GPU_TIME_WINDOW_CAP 64
#define GPU_TIME_INTERVAL_CAP 512
enum { GPU_WINDOW_FREE, GPU_WINDOW_OPEN, GPU_WINDOW_CLOSED, GPU_WINDOW_READY };
typedef struct {
    uint64_t id, frame;
    int state;
    bool overflow, discard;
    unsigned pending, buffers, nintervals;
    double start_s, end_s, frame_ms, span_sum_ms, busy_ms;
    double intervals[GPU_TIME_INTERVAL_CAP * 2];  // start/end pairs, mach-clock seconds
} GpuTimeWindow;

struct RendererGpuTimingToken {
    uint64_t sequence, frame, first_window, last_window;
    double commit_s;
    bool presentation, trace, discard;
    struct RendererGpuTimingToken *next;
};

static GpuTimeWindow gpu_time_windows[GPU_TIME_WINDOW_CAP];
static GpuTimeWindow *gpu_time_open;
static RendererGpuTimingToken *gpu_time_pending;
static uint64_t gpu_time_window_sequence, gpu_time_cb_sequence;

typedef struct { double start, end; } GpuTimeInterval;
static int compare_gpu_time_interval(const void *a, const void *b) {
    double d = ((const GpuTimeInterval *)a)->start - ((const GpuTimeInterval *)b)->start;
    return d < 0 ? -1 : d > 0 ? 1 : 0;
}

static double gpu_interval_sum_ms(const double *intervals, size_t count, double window_start, double window_end) {
    if (!intervals || !count || window_end <= window_start) return 0;
    if (count > GPU_TIME_INTERVAL_CAP) return -1;
    double total = 0;
    for (size_t i = 0; i < count; i++) {
        double start = fmax(intervals[i * 2], window_start);
        double end = fmin(intervals[i * 2 + 1], window_end);
        if (end > start) total += end - start;
    }
    return total * 1000.0;
}

static double gpu_interval_union_ms(const double *intervals, size_t count, double window_start, double window_end) {
    if (!intervals || !count || window_end <= window_start) return 0;
    if (count > 512) return -1;  // callers overflow the bounded per-window record
    GpuTimeInterval sorted[512];
    size_t n = 0;
    for (size_t i = 0; i < count; i++) {
        double start = fmax(intervals[i * 2], window_start);
        double end = fmin(intervals[i * 2 + 1], window_end);
        if (end > start) sorted[n++] = (GpuTimeInterval){start, end};
    }
    if (!n) return 0;
    qsort(sorted, n, sizeof *sorted, compare_gpu_time_interval);
    double total = 0, start = sorted[0].start, end = sorted[0].end;
    for (size_t i = 1; i < n; i++) {
        if (sorted[i].start > end) { total += end - start; start = sorted[i].start; end = sorted[i].end; }
        else if (sorted[i].end > end) end = sorted[i].end;
    }
    return (total + end - start) * 1000.0;
}

static GpuTimeWindow *gpu_time_window(uint64_t id) {
    GpuTimeWindow *w = &gpu_time_windows[id % GPU_TIME_WINDOW_CAP];
    return w->state != GPU_WINDOW_FREE && w->id == id ? w : NULL;
}

static void gpu_time_finalize(GpuTimeWindow *w) {
    if (w->state != GPU_WINDOW_CLOSED || w->pending) return;
    bool valid = !w->overflow && w->frame_ms > 0 && w->frame_ms <= 250;
    w->span_sum_ms = valid ? gpu_interval_sum_ms(w->intervals, w->nintervals, w->start_s, w->end_s) : -1;
    w->busy_ms = valid ? gpu_interval_union_ms(w->intervals, w->nintervals, w->start_s, w->end_s) : -1;
    if (w->busy_ms >= 0) stat_gpu_s += w->busy_ms / 1000.0;
    w->state = GPU_WINDOW_READY;
    if (getenv("LARECOMP_GPU_TIMING_TRACE"))
        LOG("[gpu-window] frame %llu elapsed %.3fms spans-sum %.3fms gpu-union %.3fms buffers %u intervals %u%s\n",
            (unsigned long long)w->frame, w->frame_ms, w->span_sum_ms, w->busy_ms, w->buffers, w->nintervals,
            w->overflow ? " overflow" : "");
}

static GpuTimeWindow *gpu_time_open_window(double start_s, uint64_t frame) {
    for (unsigned attempt = 0; attempt < GPU_TIME_WINDOW_CAP; attempt++) {
        uint64_t id = ++gpu_time_window_sequence;
        GpuTimeWindow *w = &gpu_time_windows[id % GPU_TIME_WINDOW_CAP];
        if (w->state != GPU_WINDOW_FREE) continue;
        memset(w, 0, sizeof *w);
        w->id = id;
        w->frame = frame;
        w->start_s = start_s;
        w->state = GPU_WINDOW_OPEN;
        gpu_time_open = w;
        for (RendererGpuTimingToken *cb = gpu_time_pending; cb; cb = cb->next) {
            if (cb->discard || cb->last_window >= id) continue;
            if (!cb->first_window) cb->first_window = id;
            cb->last_window = id;
            w->pending++;
            w->buffers++;
        }
        return w;
    }
    gpu_time_open = NULL;
    return NULL;
}

RendererGpuTimingToken *renderer_gpu_timing_submit(uint64_t frame, bool presentation) {
    RendererGpuTimingToken *cb = calloc(1, sizeof *cb);
    if (!cb) return NULL;
    pthread_mutex_lock(&gpu_timing_lock);
    cb->sequence = ++gpu_time_cb_sequence;
    cb->frame = frame;
    cb->presentation = presentation;
    cb->trace = getenv("LARECOMP_GPU_TIMING_TRACE") != NULL;
    double submit_s = renderer_host_time_seconds();
    if (!gpu_time_open) gpu_time_open_window(submit_s, frame);
    if (gpu_time_open) {
        cb->first_window = cb->last_window = gpu_time_open->id;
        gpu_time_open->pending++;
        gpu_time_open->buffers++;
    }
    cb->next = gpu_time_pending;
    gpu_time_pending = cb;
    pthread_mutex_unlock(&gpu_timing_lock);
    return cb;
}

void renderer_gpu_timing_mark_commit(RendererGpuTimingToken *cb) {
    if (!cb) return;
    double now = renderer_host_time_seconds();
    pthread_mutex_lock(&gpu_timing_lock);
    cb->commit_s = now;
    pthread_mutex_unlock(&gpu_timing_lock);
}

void renderer_gpu_timing_complete(RendererGpuTimingToken *cb, double gpu_start, double gpu_end) {
    if (!cb) return;
    double completed = renderer_host_time_seconds();
    pthread_mutex_lock(&gpu_timing_lock);
    if (!cb->discard && cb->first_window) {
        for (uint64_t id = cb->first_window; id <= cb->last_window; id++) {
            GpuTimeWindow *w = gpu_time_window(id);
            if (!w || w->state == GPU_WINDOW_READY) continue;
            if (gpu_end > gpu_start) {
                if (w->nintervals < GPU_TIME_INTERVAL_CAP) {
                    w->intervals[w->nintervals * 2] = gpu_start;
                    w->intervals[w->nintervals * 2 + 1] = gpu_end;
                    w->nintervals++;
                } else w->overflow = true;
            }
            if (w->pending) w->pending--;
            gpu_time_finalize(w);
        }
    }
    RendererGpuTimingToken **link = &gpu_time_pending;
    while (*link && *link != cb) link = &(*link)->next;
    if (*link) *link = cb->next;
    pthread_mutex_unlock(&gpu_timing_lock);
    if (cb->trace)
        LOG("[gpu-cb] frame %llu cb %llu kind %s commit %.6f start %.6f end %.6f complete %.6f queue %.3fms span %.3fms callback %.3fms\n",
            (unsigned long long)cb->frame, (unsigned long long)cb->sequence, cb->presentation ? "present" : "renderer",
            cb->commit_s, gpu_start, gpu_end, completed,
            cb->commit_s > 0 && gpu_start > 0 ? (gpu_start - cb->commit_s) * 1000.0 : -1.0,
            (gpu_end - gpu_start) * 1000.0, gpu_end > 0 ? (completed - gpu_end) * 1000.0 : -1.0);
    free(cb);
}

double renderer_gpu_timing_present(uint64_t frame, double *present_time, double *frame_ms, unsigned *samples) {
    double sum_gpu = 0, sum_frame = 0;
    unsigned n = 0;
    pthread_mutex_lock(&gpu_timing_lock);
    double now = renderer_host_time_seconds();
    if (present_time) *present_time = now;
    if (gpu_time_open) {
        GpuTimeWindow *w = gpu_time_open;
        gpu_time_open = NULL;
        w->frame = frame;
        w->end_s = now;
        w->frame_ms = (now - w->start_s) * 1000.0;
        w->state = GPU_WINDOW_CLOSED;
        gpu_time_finalize(w);
    }
    for (unsigned i = 0; i < GPU_TIME_WINDOW_CAP; i++) {
        GpuTimeWindow *w = &gpu_time_windows[i];
        if (w->state != GPU_WINDOW_READY) continue;
        if (w->busy_ms >= 0 && w->frame_ms > 0 && w->frame_ms <= 250) {
            sum_gpu += w->busy_ms;
            sum_frame += w->frame_ms;
            n++;
        }
        memset(w, 0, sizeof *w);
    }
    gpu_time_open_window(now, frame + 1);
    pthread_mutex_unlock(&gpu_timing_lock);
    if (frame_ms) *frame_ms = n ? sum_frame / n : -1;
    if (samples) *samples = n;
    return n ? sum_gpu / n : -1;
}

void renderer_gpu_timing_reset(void) {
    pthread_mutex_lock(&gpu_timing_lock);
    memset(gpu_time_windows, 0, sizeof gpu_time_windows);
    gpu_time_open = NULL;
    stat_gpu_s = 0;
    for (RendererGpuTimingToken *cb = gpu_time_pending; cb; cb = cb->next) {
        cb->discard = true;
        cb->first_window = cb->last_window = 0;
    }
    pthread_mutex_unlock(&gpu_timing_lock);
}

// (forward: texture-lifetime cleanup and stats, defined further down)
static int g_views_live;
static void views_forget(void *base);
static NSMutableDictionary *g_snap_copies;
static NvnTexture *snap_tex[8];
static bool snap_ok[8];
static NvnTexture *feedback_tex[4];
static id<MTLTexture> feedback_copy[4];
static int nfeedback;
static uint64_t op_counts[CMD_COUNT];
bool g_debug_frame;
void renderer_save_texture(id<MTLTexture> tex, const char *path);
void renderer_save_texture_alpha(id<MTLTexture> tex, const char *path);
static char stats_text[320];

// ------------------------------------------------------------------ state
typedef struct {
    NvnTexture *color[8];
    NvnTextureView cview[8];
    uint8_t has_cview[8];
    int ncolor;
    NvnTexture *depth;
    NvnTextureView dview;
    uint8_t has_dview;
} RtState;

typedef struct { uint64_t addr, size; } Range;

static struct {
    RtState rt;
    bool rt_dirty;
    NvnProgram *program;
    uint8_t blend[8][8];
    uint32_t channel_mask;
    uint8_t color_state[4], ds[8], ms[0x18], poly[4];
    float poly_offset[3];  // factor, units, clamp (nvnCommandBufferSetPolygonOffsetClamp)
    uint8_t depth_clamp;   // nvnCommandBufferSetDepthClamp
    uint32_t attrib[16];
    int nattrib;
    uint32_t stream[16][2];
    int nstream;
    Range vbuf[16], ubuf[6][18], sbuf[6][16];
    uint64_t tex[6][32], img[6][8];
    NvnDescPool *tpool, *spool;
    float viewport[16][4];
    int32_t scissor[16][4];
    float depth_range[16][2];
    float blend_color[4];
    uint32_t stencil_ref[2], stencil_mask[2], stencil_vmask[2];
    bool prim_restart;
    uint32_t restart_index;
    uint64_t copy_row_stride, copy_image_stride;
} st;

extern uint32_t g_window_origin_lower_left_hack;
uint32_t nvn_window_origin(void);
bool renderer_origin_lower_left(void) { return nvn_window_origin() == 0; }

static double stat_compile_ms;  // time spent building shaders/pipelines (first-use stutter)
static int stat_compiles;
static inline double now_ms(void) { return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }
#define TIMED_COMPILE(expr) ({ double t0_ = now_ms(); __auto_type r_ = (expr); stat_compile_ms += now_ms() - t0_; stat_compiles++; r_; })

static uint64_t hmix(uint64_t h, const void *p, size_t n) {
    const uint8_t *b = p;
    for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 0x100000001B3ull; }
    return h;
}

const char *renderer_stats(void) {
    static int dumps;
    if (dumps++ < 3) {
        LOG("[metal] command counts:");
        for (int i = 0; i < CMD_COUNT; i++) if (op_counts[i]) LOG(" %d:%llu", i, op_counts[i]);
        LOG("\n");
    }
    extern int g_tex_live;
    extern uint64_t g_tex_live_bytes;
    struct task_vm_info vmi;
    mach_msg_type_number_t vn = TASK_VM_INFO_COUNT;
    uint64_t foot = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmi, &vn) == KERN_SUCCESS ? vmi.phys_footprint : 0;
    pthread_mutex_lock(&gpu_timing_lock);
    double gpu_s = stat_gpu_s;
    stat_gpu_s = 0;
    pthread_mutex_unlock(&gpu_timing_lock);
    snprintf(stats_text, sizeof stats_text, "%llu draws, %llu skipped (%llu no shader, %llu failed, %llu compiling), %llu passes, %llu dispatches, %llu flushes, gpu %.0fms, wait %.0fms, compile %d/%.0fms, fbcopy %llu | tex %d (%.0f MB) views %d snaps %lu mem %.0f MB | waits fence %.0fms/%llu flush %.0fms/%llu all %.0fms/%llu", stat_draws, stat_skipped,
             stat_skip_none, stat_skip_failed, stat_skip_wait,
             stat_passes, stat_dispatches, stat_flushes, gpu_s * 1000.0, (double)stat_wait_ns / 1e6 * 125.0 / 3.0, stat_compiles, stat_compile_ms, stat_feedback_copies,
             g_tex_live, g_tex_live_bytes / 1048576.0, g_views_live, (unsigned long)(g_snap_copies ? g_snap_copies.count : 0), foot / 1048576.0, stat_wait_by[0] / 24e3, (unsigned long long)stat_wait_n[0], stat_wait_by[1] / 24e3, (unsigned long long)stat_wait_n[1], stat_wait_by[2] / 24e3, (unsigned long long)stat_wait_n[2]);
    stat_compiles = 0;
    stat_feedback_copies = 0;
    stat_compile_ms = 0;
    stat_draws = stat_skipped = stat_passes = stat_dispatches = stat_flushes = stat_wait_ns = 0;
    stat_skip_none = stat_skip_failed = stat_skip_wait = 0;
    memset(stat_wait_by, 0, sizeof stat_wait_by); memset(stat_wait_n, 0, sizeof stat_wait_n);
    return stats_text;
}

static void st_defaults(void) {
    memset(&st, 0, sizeof st);
    for (int i = 0; i < 16; i++) {
        st.viewport[i][2] = 1280; st.viewport[i][3] = 720;
        st.scissor[i][2] = 16384; st.scissor[i][3] = 16384;
        st.depth_range[i][1] = 1.0f;
    }
    st.channel_mask = 0xFFFFFFFF;
    st.stencil_mask[0] = st.stencil_mask[1] = 0xFF;
    st.stencil_vmask[0] = st.stencil_vmask[1] = 0xFF;
    st.ds[1] = 1; st.ds[2] = 2;
    st.poly[1] = 1; st.poly[2] = 2;
    for (int i = 0; i < 8; i++) { st.blend[i][1] = 2; st.blend[i][2] = 1; st.blend[i][3] = 2; st.blend[i][4] = 1; st.blend[i][5] = 1; st.blend[i][6] = 1; }
}

void renderer_init(id<MTLDevice> d) {
    dev = d;
    cache = [NSMutableDictionary new];
    st_defaults();
}

static int g_passes_in_cb;  // render passes encoded into the open command buffer (chunked commits)
static id<MTLCommandBuffer> cb(void) {
    if (!cmdbuf) cmdbuf = [renderer_queue() commandBuffer];
    return cmdbuf;
}

void renderer_texture_scale(NvnTexture *t, float *sx, float *sy);
void renderer_get_scale(float *sx, float *sy);
static float pass_sx = 1, pass_sy = 1;  // allocation scale of the current pass's attachments
static NSUInteger pass_layers = 1;
static int pass_width = 16, pass_height = 16;
bool renderer_texture_presented(NvnTexture *t);
// Widescreen UI: 2D draws into the swapchain image use a centred 16:9 region (uniform scale) instead of
// the stretched wide mapping. vp_* is the mapping for the current draw: physical = guest * s + off.
static float vp_sx = 1, vp_sy = 1, vp_ox = 0, vp_oy = 0;
static float tex_sc[2][64][2];          // per bound texture slot: allocation scale (for shaders' texel math)
static uint32_t tex_wh[2][64][2];       // per bound texture slot: guest size
#define RSCALE_BUFFER_INDEX 18

static int debug_pass_no;
static int dbg_draws;  // draws encoded in the pass in flight (debug frame)
static int dbg_skips;  // draws dropped before encoding in the pass in flight (no program / not compiled)
static int dbg_enc;    // draws that reached a Metal draw call in the pass in flight (debug frame)
static NvnTexture *dbg_rt[8];  // the attachments the pass in flight began with (st.rt already names the next pass's when it ends)
static id dbg_rt_tex[8];  // (diagnostics) the exact MTL textures those attachments were encoded with
static NSString *g_last_pipe_label;  // (diagnostics) label of the pipeline bound by the last draw: the FS source hash it was built from
// (diagnostics) live overrides, set from build/dbgcmd while the game runs (see debug_live_controls)
static int g_live_cull = -1;  // -1: as the guest asks; 0/1/2: force None/Front/Back
static int g_live_nodt;       // 1: depth compare Always (like LARECOMP_NO_DEPTH_TEST, but live)
static int g_live_bias_on;    // 1: force g_live_bias_val on every draw ("bias" command)
static float g_live_bias_val[3];
static int g_ca_on;           // LARECOMP_CLEAR_ALL / "clear" command
static int g_ca_pass = -1;
static MTLClearColor g_ca_col;
static uint64_t g_live_log_rt[4];  // "rt a[,b,..]": log every draw into these color targets
static uint64_t g_live_trace_end;  // "trace n": log draws/dispatches for at most n presents, without texture dumps
static bool trace_frame(void) {
    extern uint64_t renderer_present_count(void);
    return g_live_trace_end && renderer_present_count() < g_live_trace_end;
}
static void debug_live_controls(void);
static void op_ring_dump(int back);  // (defined with the executor)
static void end_pass(void) {
    debug_live_controls();
    if (enc) {
        [enc endEncoding];
        enc = nil;
        if (g_debug_frame && dbg_rt[0] && dbg_rt[0]->backend) {
            // build/nodump: skip the per-attachment PNG dumps and the per-pass GPU wait, so several
            // consecutive frames can be sampled quickly (the dumps themselves take seconds per frame).
            static int nd_tick, nd_on;
            if (!(nd_tick++ & 63)) nd_on = access("build/nodump", F_OK) == 0;
            id<MTLCommandBuffer> c = nil;
            char path[256];
            if (!nd_on) {
                c = cmdbuf;
                cmdbuf = nil;
                [c commit];
                [c waitUntilCompleted];
                dump_pending_arrays();
            }
            for (int k = 0; k < 8 && !nd_on; k++) {
                if (dbg_rt[k]) LOG("[dbgpass] %d att %d %ux%u f%#x @%llx backend %d\n", debug_pass_no, k, dbg_rt[k]->width, dbg_rt[k]->height, dbg_rt[k]->format, (unsigned long long)dbg_rt[k]->addr, dbg_rt[k]->backend != NULL);
                if (!dbg_rt[k] || !dbg_rt[k]->backend) continue;
                id<MTLTexture> t = dbg_rt_tex[k] ? dbg_rt_tex[k] : renderer_texture(dbg_rt[k], nil, true);
                LOG("[dbgpass] %d tex %p type %lu fmt %lu %lux%lu lv %lu sl %lu parent %d\n", debug_pass_no, (__bridge void *)t,
                    (unsigned long)t.textureType, (unsigned long)t.pixelFormat, (unsigned long)t.width, (unsigned long)t.height,
                    (unsigned long)t.mipmapLevelCount, (unsigned long)t.arrayLength, t.parentTexture != nil);
                snprintf(path, sizeof path, k ? "build/pass_%03d_c%d.png" : "build/pass_%03d.png", debug_pass_no, k);
                renderer_save_texture(t, path);
                if (!k) {
                    snprintf(path, sizeof path, "build/pass_%03d_a.png", debug_pass_no);
                    renderer_save_texture_alpha(t, path);
                }
            }
            // build/passdump: passes that reach Metal with nothing drawn into them (and any pass whose attachments
            // include an RGBA16F 0x29 buffer): dump the commands that produced them.
            static int pd_on, pd_tick;
            if (!(pd_tick++ & 15)) pd_on = access("build/passdump", F_OK) == 0;
            if (pd_on) {
                bool hdr = false;
                for (int k = 0; k < 8; k++) if (dbg_rt[k] && dbg_rt[k]->format == 0x29) hdr = true;
                LOG("[passdump] %d draws %d skip %d enc %d fs %llx prog %p hdr %d pipe %s |", debug_pass_no, dbg_draws, dbg_skips, dbg_enc,
                    st.program ? (unsigned long long)st.program->stages[1].code_addr : 0, (void *)st.program, hdr,
                    g_last_pipe_label ? g_last_pipe_label.UTF8String : "-");
                for (int k = 0; k < 8 && dbg_rt[k]; k++)
                    LOG(" %d %ux%u f%#x @%llx", k, dbg_rt[k]->width, dbg_rt[k]->height, dbg_rt[k]->format,
                        (unsigned long long)dbg_rt[k]->addr);
                LOG(" | dep %llx %ux%u f%#x", st.rt.depth ? (unsigned long long)st.rt.depth->addr : 0,
                    st.rt.depth ? st.rt.depth->width : 0, st.rt.depth ? st.rt.depth->height : 0,
                    st.rt.depth ? st.rt.depth->format : 0);
                LOG(" | cv %d f%#x m%#x lv %u+%u sl %u+%u", st.rt.has_cview[0], st.rt.cview[0].format, st.rt.cview[0].setmask,
                    st.rt.cview[0].base_level, st.rt.cview[0].num_levels, st.rt.cview[0].min_layer, st.rt.cview[0].num_layers);
                LOG("\n");
                if (hdr || !dbg_draws || debug_pass_no == 50 || debug_pass_no >= 84) op_ring_dump(40);
            }
            debug_pass_no++;
        }
        // (reset here, not in begin_pass: begin_pass runs lazily inside the pass's first draw, after the
        //  counters were bumped, so resetting there hid that draw)
        dbg_draws = 0;
        dbg_skips = 0;
        dbg_enc = 0;
    }
}

static void ring_reset(void);
// Submitted work runs asynchronously; last_cb is the most recently committed command buffer (the queue
// executes in order, so waiting for it waits for everything before it). Other guest threads (nvnSyncWait)
// read last_cb, so it is guarded by cb_lock; everything else here runs on the submitting thread.
static id<MTLCommandBuffer> last_cb;
static pthread_mutex_t cb_lock = PTHREAD_MUTEX_INITIALIZER;
// Fences: each committed command buffer gets a sequence number; a fence remembers the number of the submission
// that contains it, and nvnSyncWait waits only for that one (not for everything submitted since), so the game's
// CPU work on frame N+1 overlaps the GPU's frame N as on the Switch.
#define CB_HIST 256
static uint64_t submit_seq;
static id<MTLCommandBuffer> cb_hist[CB_HIST];

double renderer_host_time_seconds(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return (double)mach_absolute_time() * (double)tb.numer / (double)tb.denom / 1e9;
}

static int g_wait_kind;
static void wait_cb(id<MTLCommandBuffer> c) {
    if (!c) return;
    uint64_t t0 = mach_absolute_time();
    [c waitUntilCompleted];
    uint64_t d = mach_absolute_time() - t0;
    stat_wait_ns += d;
    stat_wait_by[g_wait_kind] += d;
    if (d > 24000) stat_wait_n[g_wait_kind]++;  // (> ~1 ms counts as a real wait)
}

// Textures the game destroyed (any thread): their cached views and snapshot copies are dropped on the render thread.
static pthread_mutex_t gone_lock = PTHREAD_MUTEX_INITIALIZER;
static struct { void *nvn, *mtl; } gone[4096];
static int ngone;
void renderer_texture_gone(void *nvn_tex, void *mtl_tex) {
    pthread_mutex_lock(&gone_lock);
    if (ngone < 4096) { gone[ngone].nvn = nvn_tex; gone[ngone].mtl = mtl_tex; ngone++; }
    pthread_mutex_unlock(&gone_lock);
}
static void drain_gone(void) {
    pthread_mutex_lock(&gone_lock);
    int n = ngone;
    static struct { void *nvn, *mtl; } local[4096];
    memcpy(local, gone, sizeof local[0] * n);
    ngone = 0;
    pthread_mutex_unlock(&gone_lock);
    for (int i = 0; i < n; i++) {
        if (local[i].mtl) views_forget(local[i].mtl);
        if (local[i].nvn) {
            if (g_snap_copies) {
                NSValue *key = [NSValue valueWithPointer:local[i].nvn];
                id<MTLTexture> snapshot = g_snap_copies[key];
                if (snapshot) views_forget((__bridge void *)snapshot);
                [g_snap_copies removeObjectForKey:key];
            }
            for (int k = 0; k < 8; k++) if (snap_tex[k] == local[i].nvn) { snap_tex[k] = NULL; snap_ok[k] = false; }
            for (int k = 0; k < nfeedback; k++) if (feedback_tex[k] == local[i].nvn) { feedback_tex[k] = NULL; feedback_copy[k] = nil; }
        }
    }
}

// Commit recorded work without waiting.
void renderer_submit(void) {
    end_pass();
    drain_gone();
    if (cmdbuf) {
        id<MTLCommandBuffer> c = cmdbuf;
        cmdbuf = nil;
        extern uint64_t renderer_present_count(void);
        RendererGpuTimingToken *gpu_timing = renderer_gpu_timing_submit(renderer_present_count() + 1, false);
        [c addCompletedHandler:^(id<MTLCommandBuffer> done) {
            renderer_gpu_timing_complete(gpu_timing, done.GPUStartTime, done.GPUEndTime);
            if (done.error) LOG("[metal] command buffer error: %s\n", done.error.localizedDescription.UTF8String);
        }];
        renderer_gpu_timing_mark_commit(gpu_timing);
        [c commit];
        g_passes_in_cb = 0;
        pthread_mutex_lock(&cb_lock);
        last_cb = c;
        submit_seq++;
        cb_hist[submit_seq % CB_HIST] = c;
        pthread_mutex_unlock(&cb_lock);
        stat_flushes++;
    }
}

// Finish all recorded GPU work (the CPU is about to read GPU results, or reuse the ring).
void renderer_flush(void) {
    renderer_submit();
    pthread_mutex_lock(&cb_lock);
    id<MTLCommandBuffer> c = last_cb;
    pthread_mutex_unlock(&cb_lock);
    g_wait_kind = 1;
    wait_cb(c);
    g_wait_kind = 0;
    ring_reset();
}

// Wait for submitted work without committing anything new (nvnSyncWait / QueueFinish).
// Callable from any thread: everything submitted so far was committed by renderer_submit.
void renderer_sync(void) {
    pthread_mutex_lock(&cb_lock);
    id<MTLCommandBuffer> c = last_cb;
    pthread_mutex_unlock(&cb_lock);
    g_wait_kind = 2;
    wait_cb(c);
    g_wait_kind = 0;
}

// Sequence number a fence placed now belongs to: the pending (uncommitted) work's submission, else the last one.
uint64_t renderer_fence_seq(void) {
    pthread_mutex_lock(&cb_lock);
    uint64_t q = submit_seq + (cmdbuf ? 1 : 0);
    pthread_mutex_unlock(&cb_lock);
    return q;
}

// Wait until submission `seq` has completed (0 = nothing to wait for).
void renderer_wait_seq(uint64_t seq) {
    if (!seq) return;
    if (ENV("LARECOMP_LOG_FENCES")) {  // (debug) how far behind the newest submission the waited fence is
        extern uint64_t renderer_present_count(void);
        static uint64_t f0, hist[6], frames_seen;
        uint64_t f = renderer_present_count();
        uint64_t pend = submit_seq + (cmdbuf ? 1 : 0);
        uint64_t age = pend > seq ? pend - seq : 0;
        bool done_already = false;
        pthread_mutex_lock(&cb_lock);
        if (seq <= submit_seq && submit_seq - seq < CB_HIST && cb_hist[seq % CB_HIST])
            done_already = cb_hist[seq % CB_HIST].status >= MTLCommandBufferStatusCompleted;
        pthread_mutex_unlock(&cb_lock);
        hist[age > 4 ? 4 : age]++;
        if (done_already) hist[5]++;
        if (f - f0 >= 300) {
            frames_seen = f - f0;
            LOG("[fences] per %llu frames: waits by age (submissions behind newest) 0:%llu 1:%llu 2:%llu 3:%llu 4+:%llu, already done %llu; submissions now %llu\n",
                (unsigned long long)frames_seen, hist[0], hist[1], hist[2], hist[3], hist[4], hist[5], (unsigned long long)submit_seq);
            memset(hist, 0, sizeof hist);
            f0 = f;
        }
    }
    pthread_mutex_lock(&cb_lock);
    id<MTLCommandBuffer> c = nil;
    if (seq > submit_seq) c = last_cb;  // not committed yet (other thread): wait for everything committed so far
    else if (submit_seq - seq < CB_HIST) c = cb_hist[seq % CB_HIST];
    pthread_mutex_unlock(&cb_lock);
    wait_cb(c);
}

// ------------------------------------------------------------------ textures with views
// Texture view cache: views are made per bind otherwise (an allocation per draw). Keyed by the base texture and
// the view parameters; a cached view retains its base, so a key's base pointer can't be reused while cached.
#define VIEW_TAB 16384
static struct { uint64_t key; void *base; void *view; } view_tab[VIEW_TAB];

// Views keep their base texture alive: when the game frees a texture its views must go too (they piled up -
// render targets of a 32:9 window held long after the game dropped them - and a new texture at the same address
// could get a stale view). Entries are tombstoned (key ~0) so probe chains stay intact.
static void views_forget(void *base) {
    for (int i = 0; i < VIEW_TAB; i++) {
        if (!view_tab[i].view) continue;
        id<MTLTexture> texture = (__bridge id<MTLTexture>)view_tab[i].view;
        while (texture && (__bridge void *)texture != base) texture = texture.parentTexture;
        if (texture) {
            CFRelease(view_tab[i].view);
            view_tab[i].view = NULL;
            view_tab[i].base = NULL;
            view_tab[i].key = ~0ull;
            g_views_live--;
        }
    }
}

static id<MTLTexture> view_cached(id<MTLTexture> base, uint64_t params, id<MTLTexture> (^make)(void)) {
    uint64_t k = ((uint64_t)(uintptr_t)(__bridge void *)base * 0x9E3779B97F4A7C15ull) ^ (params * 0xC2B2AE3D27D4EB4Full);
    if (!k) k = 1;
    if (k == ~0ull) k = 2;
    // up to 8 probes; a miss is stored in the first free or tombstoned slot of those, else over the first one.
    // (It used to go to the slot past the 8 probes - never found again - and tombstones were never reused: on the
    // overworld, where textures stream in and out, more and more binds made a new view every time, the slowdown
    // that grew with play time until a level change - user report 2026-10-08, 32:9.)
    uint32_t start = (uint32_t)(k ^ (k >> 32)) & (VIEW_TAB - 1), slot = start;
    int free_slot = -1;
    for (int probe = 0; probe < 8; probe++, slot = (slot + 1) & (VIEW_TAB - 1)) {
        if (view_tab[slot].key == k && view_tab[slot].base == (__bridge void *)base) return (__bridge id<MTLTexture>)view_tab[slot].view;
        if (!view_tab[slot].key || view_tab[slot].key == ~0ull) {
            if (free_slot < 0) free_slot = (int)slot;
            if (!view_tab[slot].key) break;  // (end of the chain)
        }
    }
    slot = free_slot >= 0 ? (uint32_t)free_slot : start;
    id<MTLTexture> v = make();
    if (!v) return base;
    if (ENV("LARECOMP_LOG_VIEWCREATE")) {  // (debug: what keeps making new views - overworld soak, views pile up)
        extern uint64_t renderer_present_count(void);
        static int n;
        if (renderer_present_count() > (uint64_t)atol(ENV("LARECOMP_LOG_VIEWCREATE")) && n++ < 400)
            LOG("[viewnew] f%llu base %p %s %lux%lu fmt %lu type %lu params %#llx live %d\n", (unsigned long long)renderer_present_count(),
                (__bridge void *)base, base.label.UTF8String, (unsigned long)base.width, (unsigned long)base.height,
                (unsigned long)base.pixelFormat, (unsigned long)base.textureType, (unsigned long long)params, g_views_live);
    }
    if (view_tab[slot].view) { CFRelease(view_tab[slot].view); g_views_live--; }  // evict (8 probes all taken)
    g_views_live++;
    view_tab[slot].key = k;
    view_tab[slot].base = (__bridge void *)base;
    view_tab[slot].view = (void *)CFBridgingRetain(v);
    return v;
}

static NSUInteger texture_layers(id<MTLTexture> texture) {
    NSUInteger layers = texture.arrayLength;
    if (texture.textureType == MTLTextureTypeCube || texture.textureType == MTLTextureTypeCubeArray) layers *= 6;
    return layers;
}

static id<MTLTexture> view_texture(NvnTexture *t, const NvnTextureView *v, bool has_view, bool render,
                                   id<MTLBlitCommandEncoder> blit) {
    id<MTLTexture> base = renderer_texture(t, blit, render);
    if (!has_view || !v->setmask) return base;
    MTLPixelFormat pf = (v->setmask & 4) ? renderer_pixel_format(v->format) : base.pixelFormat;
    NSUInteger lv0 = (v->setmask & 1) ? v->base_level : 0;
    NSUInteger ly0 = (v->setmask & 2) ? v->min_layer : 0;
    NSUInteger slices = texture_layers(base);
    // Resizing recreates the window images smaller than a cached guest view asks for; an empty or out-of-bounds level
    // or slice range aborts inside Metal's validator (user report 2026-10-23: resizing the window on the profile).
    if (lv0 >= base.mipmapLevelCount) lv0 = base.mipmapLevelCount - 1;
    if (ly0 >= slices) ly0 = slices - 1;
    NSUInteger nlv = (v->setmask & 1) && v->num_levels ? v->num_levels : base.mipmapLevelCount - lv0;
    NSUInteger nly = (v->setmask & 2) && v->num_layers ? v->num_layers : slices - ly0;
    if (nlv > base.mipmapLevelCount - lv0) nlv = base.mipmapLevelCount - lv0;
    if (nly > slices - ly0) nly = slices - ly0;
    MTLTextureType type = base.textureType;
    // A cube view needs whole, aligned groups of six faces, including when it is sampled.
    if ((type == MTLTextureTypeCube || type == MTLTextureTypeCubeArray) && (ly0 % 6 || nly % 6))
        type = nly == 1 ? MTLTextureType2D : MTLTextureType2DArray;
    if (render && (type == MTLTextureType2DArray || type == MTLTextureTypeCube || type == MTLTextureTypeCubeArray) && nly == 1)
        type = MTLTextureType2D;
    if (pf == base.pixelFormat && lv0 == 0 && nlv == base.mipmapLevelCount && ly0 == 0 && nly == slices && type == base.textureType)
        return base;
    static int vlog;  // LARECOMP_LOG_VIEWS: texture views that change the pixel format
    if (pf != base.pixelFormat && vlog < 20 && getenv("LARECOMP_LOG_VIEWS")) {
        vlog++;
        LOG("[view] tex fmt %#x (mtl %lu) viewed as nvn %#x (mtl %lu)\n", t->format, (unsigned long)base.pixelFormat, v->format, (unsigned long)pf);
    }
    NSUInteger ns = type == MTLTextureType2D ? 1 : nly;
    uint64_t params = (uint64_t)pf | (uint64_t)type << 16 | (uint64_t)lv0 << 24 | (uint64_t)nlv << 32 | (uint64_t)ly0 << 40 | (uint64_t)ns << 52;
    id<MTLTexture> got = view_cached(base, params, ^{
        return [base newTextureViewWithPixelFormat:pf textureType:type levels:NSMakeRange(lv0, nlv) slices:NSMakeRange(ly0, ns)];
    });
    if (got == base && pf != base.pixelFormat) {
        static int nfail;
        if (nfail++ < 10) LOG("[view] FAILED %lu -> %lu (nvn %#x -> %#x)\n", (unsigned long)base.pixelFormat, (unsigned long)pf, t->format, v->format);
    }
    return got;
}

// ------------------------------------------------------------------ render passes
static __unsafe_unretained id last_bias_enc;  // encoder the depth bias was last set on

// Metal cannot pick a 3D render target's slice from the vertex shader (render_target_array_index is for array and cube
// targets): a draw whose instances fill a volume (Z-A's 32x32x32 light / fog volume: one instance per slice) is replayed one
// instance per pass, each with its slice as the attachment's depthPlane. -1: not replaying.
static int g_rt_plane = -1;

static void begin_pass(void) {
    if (enc && !st.rt_dirty) return;
    end_pass();
    st.rt_dirty = false;
    for (int i = 0; i < 8; i++) dbg_rt[i] = i < st.rt.ncolor ? st.rt.color[i] : NULL;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    int w = 0, h = 0;
    NSUInteger layers = NSUIntegerMax;
    for (int i = 0; i < st.rt.ncolor; i++) {
        NvnTexture *t = st.rt.color[i];
        if (!t) continue;
        renderer_mark_gpu_owned(t);
        id<MTLTexture> tex = view_texture(t, &st.rt.cview[i], st.rt.has_cview[i], true, nil);
        rp.colorAttachments[i].texture = tex;
        layers = MIN(layers, texture_layers(tex));
        if (g_debug_frame) dbg_rt_tex[i] = tex;
        if (g_rt_plane >= 0 && tex.textureType == MTLTextureType3D) rp.colorAttachments[i].depthPlane = (NSUInteger)g_rt_plane;
        rp.colorAttachments[i].loadAction = MTLLoadActionLoad;
        // reshaped output: areas outside the game's 16:9 drawing (interiors, fades) start black each frame
        extern bool renderer_texture_first_write(NvnTexture *t);
        extern bool renderer_texture_level_fresh(NvnTexture *t);
        extern bool renderer_texture_frame_fresh(NvnTexture *t);
        bool fresh = renderer_texture_level_fresh(t) | renderer_texture_frame_fresh(t);
        if (renderer_texture_first_write(t) || fresh) {
            rp.colorAttachments[i].loadAction = MTLLoadActionClear;
            rp.colorAttachments[i].clearColor = MTLClearColorMake(0, 0, 0, fresh ? 0 : 1);
        }
        rp.colorAttachments[i].storeAction = MTLStoreActionStore;
        {   // LARECOMP_CLEAR_ALL=<rrggbbaa hex>[:<pass>]: force a clear colour (proves which attachment reaches the window)
            static int ca_once;
            if (!ca_once) {
                ca_once = 1;
                const char *e = getenv("LARECOMP_CLEAR_ALL");
                if (e) {
                    unsigned v = 0; const char *c = strchr(e, ':');
                    if (sscanf(e, "%x", &v) == 1) {
                        g_ca_on = 1;
                        g_ca_col = MTLClearColorMake(((v >> 24) & 255) / 255.0, ((v >> 16) & 255) / 255.0, ((v >> 8) & 255) / 255.0, (v & 255) / 255.0);
                        if (c) g_ca_pass = atoi(c + 1);
                        LOG("[clear] LARECOMP_CLEAR_ALL %08x pass %d\n", v, g_ca_pass);
                    }
                }
            }
            if (g_ca_on && (g_ca_pass < 0 || g_ca_pass == debug_pass_no)) { rp.colorAttachments[i].loadAction = MTLLoadActionClear; rp.colorAttachments[i].clearColor = g_ca_col; }
        }
        if (!w) { renderer_texture_scale(t, &pass_sx, &pass_sy); w = (int)tex.width; h = (int)tex.height; }
        else { w = MIN(w, (int)tex.width); h = MIN(h, (int)tex.height); }
    }
    if (st.rt.depth) {
        renderer_mark_gpu_owned(st.rt.depth);
        id<MTLTexture> tex = view_texture(st.rt.depth, &st.rt.dview, st.rt.has_dview, true, nil);
        if (renderer_format_is_depth(st.rt.depth->format) && st.rt.depth->format != 0x31) {
            rp.depthAttachment.texture = tex;
            rp.depthAttachment.loadAction = MTLLoadActionLoad;
            rp.depthAttachment.storeAction = MTLStoreActionStore;
        }
        if (renderer_format_has_stencil(st.rt.depth->format)) {
            rp.stencilAttachment.texture = tex;
            rp.stencilAttachment.loadAction = MTLLoadActionLoad;
            rp.stencilAttachment.storeAction = MTLStoreActionStore;
        }
        if (rp.depthAttachment.texture || rp.stencilAttachment.texture) {
            layers = MIN(layers, texture_layers(tex));
            if (!w) { renderer_texture_scale(st.rt.depth, &pass_sx, &pass_sy); w = (int)tex.width; h = (int)tex.height; }
            else { w = MIN(w, (int)tex.width); h = MIN(h, (int)tex.height); }
        }
    }
    if (!w) {
        pass_sx = pass_sy = 1;
        rp.renderTargetWidth = w = 16; rp.renderTargetHeight = h = 16;
        rp.defaultRasterSampleCount = 1;
    }
    pass_width = w; pass_height = h;
    // Layer-writing vertices also require an explicit length for single-layer targets. Every attachment must
    // expose the chosen range; 3D depth planes are replayed individually and contribute one layer here.
    rp.renderTargetArrayLength = pass_layers = layers == NSUIntegerMax ? 1 : layers;
    // Commit the frame in chunks: the GPU starts on the first passes while the CPU still encodes the rest. The
    // game waits for its previous frame before it submits the next one, so with one command buffer per frame the
    // GPU sat idle during our encoding and a frame cost GPU + encoding time (5120x1440 with the GPU clocked down:
    // ~15.5 + a few ms -> missed vsync -> 30 fps). LARECOMP_CHUNK_PASSES=<n> (0 = one buffer per frame).
    static int chunk = -1;
    if (chunk < 0) { const char *e = ENV("LARECOMP_CHUNK_PASSES"); chunk = e ? atoi(e) : 8; }
    if (chunk > 0 && cmdbuf && ++g_passes_in_cb >= chunk) renderer_submit();
    enc = [cb() renderCommandEncoderWithDescriptor:rp];
    vp_sx = pass_sx; vp_sy = pass_sy; vp_ox = 0; vp_oy = 0;
    stat_passes++;
}

// Native views already include allocation rounding and mip selection. The smallest attachment bounds the pass.
static void pass_size(int *w, int *h) {
    *w = pass_width; *h = pass_height;
}

static void apply_scissor(void) {
    int w, h;
    pass_size(&w, &h);
    if (!w) return;
    int x = st.scissor[0][0], y = st.scissor[0][1], sw = st.scissor[0][2], sh = st.scissor[0][3];
    if (vp_sx != 1 || vp_sy != 1 || vp_ox != 0 || vp_oy != 0) {
        double x0 = floor(x * (double)vp_sx + vp_ox), y0 = floor(y * (double)vp_sy + vp_oy);
        double x1 = ceil(((double)x + sw) * vp_sx + vp_ox), y1 = ceil(((double)y + sh) * vp_sy + vp_oy);
        if (sw >= 16384) x1 = 1e9;  // "unbounded" scissors stay unbounded
        if (sh >= 16384) y1 = 1e9;
        if (x1 > 1e9) x1 = 1e9;
        if (y1 > 1e9) y1 = 1e9;
        x = (int)x0; y = (int)y0; sw = (int)(x1 - x0); sh = (int)(y1 - y0);
    }
    if (x < 0) { sw += x; x = 0; }
    if (y < 0) { sh += y; y = 0; }
    if (x >= w || y >= h) { x = y = 0; sw = sh = 0; }
    if (x + sw > w) sw = w - x;
    if (y + sh > h) sh = h - y;
    if (sw < 0) sw = 0;
    if (sh < 0) sh = 0;
    [enc setScissorRect:(MTLScissorRect){(NSUInteger)x, (NSUInteger)y, (NSUInteger)sw, (NSUInteger)sh}];
}

// ------------------------------------------------------------------ clears (full-screen triangle)
static const char *clear_src =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 pos [[position]]; uint layer [[render_target_array_index]]; };\n"
    "vertex V vs(uint vid [[vertex_id]], uint iid [[instance_id]], constant float4 &d [[buffer(0)]]) {\n"
    "  float2 p = float2((vid << 1) & 2, vid & 2); V o; o.pos = float4(p * 2.0 - 1.0, d.x, 1); o.layer = iid; return o; }\n"
    "struct OF { float4 c [[color(INDEX)]]; };\n"
    "fragment OF fs_f(V in [[stage_in]], constant float4 &c [[buffer(0)]]) { OF o; o.c = c; return o; }\n"
    "struct OI { int4 c [[color(INDEX)]]; };\n"
    "fragment OI fs_i(V in [[stage_in]], constant int4 &c [[buffer(0)]]) { OI o; o.c = c; return o; }\n"
    "struct OU { uint4 c [[color(INDEX)]]; };\n"
    "fragment OU fs_u(V in [[stage_in]], constant uint4 &c [[buffer(0)]]) { OU o; o.c = c; return o; }\n"
    "fragment void fs_none(V in [[stage_in]]) {}\n";

static id<MTLLibrary> clear_lib(int index) {
    static id<MTLLibrary> libs[8];
    if (!libs[index]) {
        NSString *src = [@(clear_src) stringByReplacingOccurrencesOfString:@"INDEX" withString:[NSString stringWithFormat:@"%d", index]];
        NSError *err;
        libs[index] = TIMED_COMPILE([dev newLibraryWithSource:src options:nil error:&err]);
        if (!libs[index]) FATAL("clear shader: %s\n", err.localizedDescription.UTF8String);
    }
    return libs[index];
}

static void attachment_formats(MTLRenderPipelineDescriptor *pd) {
    for (int i = 0; i < st.rt.ncolor; i++)
        if (st.rt.color[i]) pd.colorAttachments[i].pixelFormat = view_texture(st.rt.color[i], &st.rt.cview[i], st.rt.has_cview[i], true, nil).pixelFormat;
    if (st.rt.depth) {
        MTLPixelFormat pf = view_texture(st.rt.depth, &st.rt.dview, st.rt.has_dview, true, nil).pixelFormat;
        if (renderer_format_is_depth(st.rt.depth->format) && st.rt.depth->format != 0x31) pd.depthAttachmentPixelFormat = pf;
        if (renderer_format_has_stencil(st.rt.depth->format)) pd.stencilAttachmentPixelFormat = pf;
        if (st.rt.depth->samples > 1) pd.rasterSampleCount = st.rt.depth->samples;
    }
    for (int i = 0; i < st.rt.ncolor; i++)
        if (st.rt.color[i] && st.rt.color[i]->samples > 1) pd.rasterSampleCount = st.rt.color[i]->samples;
}

static void clear(int index, int kind, const void *color, uint32_t mask, bool depth, float dval, bool stencil,
                  uint32_t sval, uint32_t smask) {
    if (kind < 0 || kind > 2) kind = 0;  // (records from older encoders may carry garbage here)
    // Metal rejects a float4 output on an integer attachment (and vice versa), and NVN callers don't always
    // match the clear kind to the target's format (DiscardColor is recorded as a float clear). Trust the format.
    int rec_kind = kind;
    if (index >= 0 && index < st.rt.ncolor && st.rt.color[index]) {
        uint32_t f = st.rt.color[index]->format;
        if (renderer_format_is_uint(f)) kind = 2;
        else if (renderer_format_is_sint(f)) kind = 1;
        else kind = 0;
    }
    // A float clear of an integer target converts the value, as the hardware does (Ryujinx too): Pokémon Z-A clears
    // its R8_UINT shadow caster-class map with ClearColor(1.0) and expects 1. Its raw bits saturated to 255, every
    // empty texel then named a caster class, and the shadow mask self-shadowed the characters (faceted streaks).
    uint32_t conv[4];
    if (index >= 0 && color && rec_kind == 0 && kind != 0) {
        const float *fc = (const float *)color;
        for (int i = 0; i < 4; i++) {
            float v = isnan(fc[i]) ? 0.0f : fc[i];
            if (kind == 2) conv[i] = v <= 0.0f ? 0u : v >= 4294967040.0f ? 0xFFFFFFFFu : (uint32_t)v;
            else conv[i] = (uint32_t)(int32_t)(v <= -2147483648.0f ? -2147483648.0f : v >= 2147483520.0f ? 2147483520.0f : v);
        }
        color = conv;
    }
    begin_pass();
    if (g_debug_frame) {
        int pw, ph;
        pass_size(&pw, &ph);
        LOG("[clear] pass %d idx %d depth %d (%g) stencil %d | pass %dx%d scissor %d,%d %dx%d\n", debug_pass_no, index, depth,
            dval, stencil, pw, ph, st.scissor[0][0], st.scissor[0][1], st.scissor[0][2], st.scissor[0][3]);
        if (index >= 0 && color) LOG("[clear]   color %g %g %g %g (kind %d mask %u f%#x)\n", ((const float *)color)[0], ((const float *)color)[1], ((const float *)color)[2], ((const float *)color)[3], kind, mask, st.rt.color[index] ? st.rt.color[index]->format : 0);
    }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    id<MTLLibrary> lib = clear_lib(index < 0 ? 0 : index);
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    static NSString *const fs[] = {@"fs_f", @"fs_i", @"fs_u"};
    pd.fragmentFunction = [lib newFunctionWithName:index >= 0 ? fs[kind] : @"fs_none"];
    attachment_formats(pd);
    for (int i = 0; i < 8; i++) pd.colorAttachments[i].writeMask = MTLColorWriteMaskNone;
    if (index >= 0) {
        MTLColorWriteMask m = 0;
        if (mask & 1) m |= MTLColorWriteMaskRed;
        if (mask & 2) m |= MTLColorWriteMaskGreen;
        if (mask & 4) m |= MTLColorWriteMaskBlue;
        if (mask & 8) m |= MTLColorWriteMaskAlpha;
        pd.colorAttachments[index].writeMask = m;
    }
    NSError *err;
    uint64_t formats[11] = {pd.depthAttachmentPixelFormat, pd.stencilAttachmentPixelFormat, pd.rasterSampleCount};
    for (int i = 0; i < 8; i++) formats[3 + i] = pd.colorAttachments[i].pixelFormat;
    NSString *key = [NSString stringWithFormat:@"clear %d %d %u %d %d %016llx", index, kind, mask, depth, stencil,
                     (unsigned long long)hmix(0xcbf29ce484222325ull, formats, sizeof formats)];
    id<MTLRenderPipelineState> pipe = cache[key];
    if ((id)pipe == [NSNull null]) return;  // known-bad combination; building it again would only spam
    if (!pipe) {
        pipe = TIMED_COMPILE([dev newRenderPipelineStateWithDescriptor:pd error:&err]);
        if (!pipe) {
            static int nlog;
            if (nlog++ < 8) LOG("[metal] clear pipeline: %s\n", err.localizedDescription.UTF8String);
            cache[key] = [NSNull null];
            return;
        }
        cache[key] = pipe;
    }
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionAlways;
    dd.depthWriteEnabled = depth;
    if (stencil) {
        MTLStencilDescriptor *sd = [MTLStencilDescriptor new];
        sd.stencilCompareFunction = MTLCompareFunctionAlways;
        sd.depthStencilPassOperation = MTLStencilOperationReplace;
        sd.writeMask = smask;
        dd.frontFaceStencil = sd;
        dd.backFaceStencil = sd;
    }
    [enc setRenderPipelineState:pipe];
    [enc setDepthStencilState:[dev newDepthStencilStateWithDescriptor:dd]];
    [enc setStencilReferenceValue:sval];
    [enc setCullMode:MTLCullModeNone];
    [enc setTriangleFillMode:MTLTriangleFillModeFill];
    [enc setDepthBias:0 slopeScale:0 clamp:0];
    [enc setDepthClipMode:MTLDepthClipModeClip];
    last_bias_enc = nil;  // the next guest draw must restore its cached bias on this encoder
    int w, h;
    pass_size(&w, &h);
    [enc setViewport:(MTLViewport){0, 0, w, h, 0, 1}];
    vp_sx = pass_sx; vp_sy = pass_sy; vp_ox = 0; vp_oy = 0;
    apply_scissor();
    float d4[4] = {dval, 0, 0, 0};
    [enc setVertexBytes:d4 length:16 atIndex:0];
    if (index >= 0) [enc setFragmentBytes:color length:16 atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:pass_layers];
}

// ------------------------------------------------------------------ shaders (debug dump)
static void dump_program(NvnProgram *p) {
    if (!getenv("LARECOMP_DUMP_SHADERS")) return;
    static int n;
    mkdir("build/shaders", 0755);
    for (int s = 0; s < 6; s++) {
        if (!(p->stage_mask & (1u << s))) continue;
        char path[256];
        snprintf(path, sizeof path, "build/shaders/%llx_s%d_code.bin", p->stages[s].code_addr, s);
        FILE *f = fopen(path, "wb");
        fwrite((void *)(uintptr_t)p->stages[s].code_addr, 1, 0x10000, f);
        fclose(f);
        snprintf(path, sizeof path, "build/shaders/%llx_s%d_ctrl.bin", p->stages[s].code_addr, s);
        f = fopen(path, "wb");
        fwrite(p->stages[s].control, 1, 0x4000, f);
        fclose(f);
    }
    n++;
}

// ------------------------------------------------------------------ draw support
uint32_t nvn_window_origin(void);
uint32_t nvn_depth_mode(void);
static void op_ring_dump(int back);  // (defined with the executor)
static int cbuf_base = 3, tex_base = 8;

@interface Prog : NSObject {
@public
    id<MTLFunction> vs, fs;
    ShaderInfo *vi, *fi;
    uint64_t vs_addr, fs_addr;  // guest shader code addresses, for failure logs
    _Atomic bool failed;  // published by async compilation, read by get_program and draw waits
    _Atomic bool ready;  // functions compiled (async compile: draws are skipped until then)
    bool ov_active;      // live shader override applied (build/dbgcmd): ov_path is the source to reload
    char ov_path[256];
}
@end
@implementation Prog
@end

static id<MTLBuffer> ring;
static uint64_t ring_off;
#define RING_SIZE (64u << 20)

static uint64_t ring_alloc(const void *data, uint64_t size) {
    if (!ring) ring = [dev newBufferWithLength:RING_SIZE options:MTLResourceStorageModeShared];
    uint64_t aligned = (ring_off + 255) & ~255ull;
    if (aligned + size > RING_SIZE) {
        // Start a fresh ring; command buffers in flight keep the old one alive until they complete.
        ring = [dev newBufferWithLength:(size > RING_SIZE ? size : RING_SIZE) options:MTLResourceStorageModeShared];
        aligned = 0;
    }
    memcpy((uint8_t *)ring.contents + aligned, data, size);
    ring_off = aligned + size;
    return aligned;
}

static void ring_reset(void) { ring_off = 0; }

// Bind guest memory [addr, addr+size) as a buffer: zero-copy inside the heap, copied otherwise.
static void bind_guest(id<MTLRenderCommandEncoder> e, bool vertex_stage, uint64_t addr, uint64_t size, int index) {
    if (addr >= g_gwin_base && addr + size <= g_gwin_base + g_gwin_max && (addr & 3) == 0) {
        if (vertex_stage) [e setVertexBuffer:g_guest_buffer offset:addr - g_gwin_base atIndex:index];
        else [e setFragmentBuffer:g_guest_buffer offset:addr - g_gwin_base atIndex:index];
        return;
    }
    uint64_t off = ring_alloc((void *)(uintptr_t)addr, size);
    if (vertex_stage) [e setVertexBuffer:ring offset:off atIndex:index];
    else [e setFragmentBuffer:ring offset:off atIndex:index];
}

static int attr_kind(uint32_t fmt) {
    switch (fmt) {
    case 0x03: case 0x08: case 0x0B: case 0x0F: case 0x14: case 0x17: case 0x1B: case 0x20: case 0x23:
    case 0x27: case 0x2C: case 0x2F: case 0x3E:
        return 2;
    case 0x04: case 0x09: case 0x0C: case 0x10: case 0x15: case 0x18: case 0x1C: case 0x21: case 0x24:
    case 0x28: case 0x2D: case 0x30:
        return 1;
    default: return 0;
    }
}

static MTLVertexFormat vertex_format(uint32_t f) {
    switch (f) {
    case 0x01: return MTLVertexFormatUCharNormalized;
    case 0x02: return MTLVertexFormatCharNormalized;
    case 0x03: return MTLVertexFormatUChar;
    case 0x04: return MTLVertexFormatChar;
    case 0x05: return MTLVertexFormatHalf;
    case 0x06: return MTLVertexFormatUShortNormalized;
    case 0x07: return MTLVertexFormatShortNormalized;
    case 0x08: return MTLVertexFormatUShort;
    case 0x09: return MTLVertexFormatShort;
    case 0x0A: return MTLVertexFormatFloat;
    case 0x0B: return MTLVertexFormatUInt;
    case 0x0C: return MTLVertexFormatInt;
    case 0x0D: return MTLVertexFormatUChar2Normalized;
    case 0x0E: return MTLVertexFormatChar2Normalized;
    case 0x0F: return MTLVertexFormatUChar2;
    case 0x10: return MTLVertexFormatChar2;
    case 0x11: return MTLVertexFormatHalf2;
    case 0x12: return MTLVertexFormatUShort2Normalized;
    case 0x13: return MTLVertexFormatShort2Normalized;
    case 0x14: return MTLVertexFormatUShort2;
    case 0x15: return MTLVertexFormatShort2;
    case 0x16: return MTLVertexFormatFloat2;
    case 0x17: return MTLVertexFormatUInt2;
    case 0x18: return MTLVertexFormatInt2;
    case 0x19: return MTLVertexFormatUChar3Normalized;
    case 0x1A: return MTLVertexFormatChar3Normalized;
    case 0x1B: return MTLVertexFormatUChar3;
    case 0x1C: return MTLVertexFormatChar3;
    case 0x1D: return MTLVertexFormatHalf3;
    case 0x1E: return MTLVertexFormatUShort3Normalized;
    case 0x1F: return MTLVertexFormatShort3Normalized;
    case 0x20: return MTLVertexFormatUShort3;
    case 0x21: return MTLVertexFormatShort3;
    case 0x22: return MTLVertexFormatFloat3;
    case 0x23: return MTLVertexFormatUInt3;
    case 0x24: return MTLVertexFormatInt3;
    case 0x25: return MTLVertexFormatUChar4Normalized;
    case 0x26: return MTLVertexFormatChar4Normalized;
    case 0x27: return MTLVertexFormatUChar4;
    case 0x28: return MTLVertexFormatChar4;
    case 0x29: return MTLVertexFormatHalf4;
    case 0x2A: return MTLVertexFormatUShort4Normalized;
    case 0x2B: return MTLVertexFormatShort4Normalized;
    case 0x2C: return MTLVertexFormatUShort4;
    case 0x2D: return MTLVertexFormatShort4;
    case 0x2E: return MTLVertexFormatFloat4;
    case 0x2F: return MTLVertexFormatUInt4;
    case 0x30: return MTLVertexFormatInt4;
    case 0x3D: return MTLVertexFormatUInt1010102Normalized;
    case 0x69: return MTLVertexFormatInt1010102Normalized;
    case 0x3F: return MTLVertexFormatFloatRG11B10;
    case 0x40: return MTLVertexFormatFloatRGB9E5;
    // integer-to-float ("I2F") formats: converted to float by the vertex fetch
    case 0x51: return MTLVertexFormatUChar;   // these read as raw integers converted in shader
    default: {
        static uint32_t seen[64]; static int n;
        for (int i = 0; i < n; i++) if (seen[i] == f) return MTLVertexFormatFloat4;
        if (n < 64) seen[n++] = f;
        LOG("[vertex] unsupported attribute format %#x: read as float4\n", f);
        return MTLVertexFormatFloat4;
    }
    }
}

static bool is_int_format(uint32_t f) { return attr_kind(f) != 0; }

static MTLBlendFactor blend_factor(uint8_t f) {
    switch (f) {
    case 1: return MTLBlendFactorZero;
    case 2: return MTLBlendFactorOne;
    case 3: return MTLBlendFactorSourceColor;
    case 4: return MTLBlendFactorOneMinusSourceColor;
    case 5: return MTLBlendFactorSourceAlpha;
    case 6: return MTLBlendFactorOneMinusSourceAlpha;
    case 7: return MTLBlendFactorDestinationAlpha;
    case 8: return MTLBlendFactorOneMinusDestinationAlpha;
    case 9: return MTLBlendFactorDestinationColor;
    case 10: return MTLBlendFactorOneMinusDestinationColor;
    case 11: return MTLBlendFactorSourceAlphaSaturated;
    case 0x10: return MTLBlendFactorSource1Color;
    case 0x11: return MTLBlendFactorOneMinusSource1Color;
    case 0x12: return MTLBlendFactorSource1Alpha;
    case 0x13: return MTLBlendFactorOneMinusSource1Alpha;
    case 0x61: return MTLBlendFactorBlendColor;
    case 0x62: return MTLBlendFactorOneMinusBlendColor;
    case 0x63: return MTLBlendFactorBlendAlpha;
    case 0x64: return MTLBlendFactorOneMinusBlendAlpha;
    default: {
        static uint8_t warned[256];
        if (!warned[f]++) LOG("[metal] unknown blend factor %#x\n", f);
        return MTLBlendFactorOne;
    }
    }
}

static MTLBlendOperation blend_op(uint8_t e) {
    switch (e) {
    case 2: return MTLBlendOperationSubtract;
    case 3: return MTLBlendOperationReverseSubtract;
    case 4: return MTLBlendOperationMin;
    case 5: return MTLBlendOperationMax;
    default: return MTLBlendOperationAdd;
    }
}

static MTLCompareFunction compare_fn(uint8_t f) {
    switch (f) {
    case 1: return MTLCompareFunctionNever;
    case 2: return MTLCompareFunctionLess;
    case 3: return MTLCompareFunctionEqual;
    case 4: return MTLCompareFunctionLessEqual;
    case 5: return MTLCompareFunctionGreater;
    case 6: return MTLCompareFunctionNotEqual;
    case 7: return MTLCompareFunctionGreaterEqual;
    default: return MTLCompareFunctionAlways;
    }
}

static MTLStencilOperation stencil_op(uint8_t o) {
    switch (o) {
    case 2: return MTLStencilOperationZero;
    case 3: return MTLStencilOperationReplace;
    case 4: return MTLStencilOperationIncrementClamp;
    case 5: return MTLStencilOperationDecrementClamp;
    case 6: return MTLStencilOperationInvert;
    case 7: return MTLStencilOperationIncrementWrap;
    case 8: return MTLStencilOperationDecrementWrap;
    default: return MTLStencilOperationKeep;
    }
}

static int rt_kind(uint32_t f) {
    switch (f) {
    case 0x03: case 0x08: case 0x0B: case 0x0F: case 0x14: case 0x17: case 0x27: case 0x2C: case 0x2F: case 0x3E: return 2;
    case 0x04: case 0x09: case 0x0C: case 0x10: case 0x15: case 0x18: case 0x28: case 0x2D: case 0x30: return 1;
    default: return 0;
    }
}

#define PROG_TAB 4096
static struct { uint64_t key; void *prog; } prog_tab[PROG_TAB];

// Shader warm-up cache: every translated shader's MSL is kept in cache/shaders/ (v_/f_<hash>.metal). At startup
// they're all compiled once on a background queue, which fills Metal's own on-disk shader cache so that a later
// first use in-game costs ~0.1 ms instead of ~40 ms. Delete cache/ to reset it.
static uint64_t fnv64(const char *t) {
    uint64_t h = 0xcbf29ce484222325ull;
    for (; *t; t++) { h ^= (uint8_t)*t; h *= 0x100000001B3ull; }
    return h;
}

static void shader_cache_note(const char *vs, const char *fs) {
    static int made;
    if (!made) { made = 1; mkdir("cache", 0755); mkdir("cache/shaders", 0755); }
    const char *src[2] = {vs, fs};
    for (int i = 0; i < 2; i++) {
        if (!src[i] || !*src[i]) continue;
        char path[96];
        snprintf(path, sizeof path, "cache/shaders/%c_%016llx.metal", i ? 'f' : 'v', (unsigned long long)fnv64(src[i]));
        if (access(path, F_OK) == 0) continue;
        FILE *f = fopen(path, "w");
        if (f) { fputs(src[i], f); fclose(f); }
    }
}

// Compile options for the game's shaders (vs: keep invariance for depth-equal passes). LARECOMP_SAFE_MATH=1 turns
// Metal's fast math off: it may fold isnan / NaN-propagating min/max and reassociate, unlike the Switch (A/B for
// NaN-like colour artifacts; strahlender-xnu compiles everything with fp math_mode(safe) for this reason).
static MTLCompileOptions *game_shader_opts(bool vs) {
    static MTLCompileOptions *o[2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bool safe = getenv("LARECOMP_SAFE_MATH") && atoi(getenv("LARECOMP_SAFE_MATH"));
        for (int i = 0; i < 2; i++) {
            o[i] = [MTLCompileOptions new];
            o[i].preserveInvariance = i == 1;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            if (safe) o[i].fastMathEnabled = NO;
#pragma clang diagnostic pop
        }
        if (safe) LOG("[metal] LARECOMP_SAFE_MATH: shaders compiled without fast math\n");
    });
    return o[vs];
}

void shader_cache_warm(void) {
    static int started;
    if (started++ || getenv("LARECOMP_NO_SHADER_WARM")) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        DIR *d = opendir("cache/shaders");
        if (!d) return;
        double t0 = now_ms();
        int n = 0;
        struct dirent *e;
        while ((e = readdir(d))) {
            if (e->d_name[0] != 'v' && e->d_name[0] != 'f') continue;
            char path[300];
            snprintf(path, sizeof path, "cache/shaders/%s", e->d_name);
            NSString *src = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:nil];
            if (!src) continue;
            @autoreleasepool { (void)[dev newLibraryWithSource:src options:game_shader_opts(e->d_name[0] == 'v') error:nil]; }
            n++;
        }
        closedir(d);
        LOG("[shader] warm-up: %d cached shaders compiled in %.0f ms\n", n, now_ms() - t0);
    });
}

// Pipeline archive: every game pipeline built in this run is also added to an MTLBinaryArchive, saved as
// cache/pipelines.bin. The next run opens that file (no compiling) and looks new pipelines up in it first: a hit is
// built at once, so its draws are not skipped while it compiles. The archive read from the file is only looked up;
// this run's pipelines (hits included) go into a new one, written on a background queue, which then replaces the file
// (on the Mac, saving an archive loaded from a file failed with "Invalid URL").
// LARECOMP_NO_PIPELINE_ARCHIVE=1 turns it off (A/B); delete cache/ to reset it.
static id<MTLBinaryArchive> g_archive;       // this run's pipelines, saved to the file (on g_archive_q only)
static id<MTLBinaryArchive> g_archive_read;  // the last run's file, only looked up (render thread)
static dispatch_queue_t g_archive_q;
static int g_archive_dirty;  // pipelines added since the last save (on g_archive_q)
static NSMutableArray<MTLRenderPipelineDescriptor *> *g_archive_saved, *g_archive_new;  // in the last save / since (on g_archive_q)
static int g_archive_hits;   // pipelines found in the archive this run (render thread)
static NSURL *g_archive_url; // absolute, fixed at open: the working directory may be gone at exit (the tests delete it)

// A failed save leaves the archive empty ("Nothing to serialize"): build it again from the pipelines given
static void pipeline_archive_rebuild(NSArray<MTLRenderPipelineDescriptor *> *with) {  // on g_archive_q
    g_archive = [dev newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:nil];
    for (MTLRenderPipelineDescriptor *pd in with) [g_archive addRenderPipelineFunctionsWithDescriptor:pd error:nil];
}

static void pipeline_archive_save(void) {  // on g_archive_q
    if (!g_archive_dirty || !g_archive) return;
    // write next to the file and rename: the archive being looked up still reads the old one
    NSURL *tmp = [g_archive_url URLByAppendingPathExtension:@"tmp"];
    NSError *err;
    if (![g_archive serializeToURL:tmp error:&err]) {
        // Some pipelines save alone but not next to others ("expecting 'fragment' stage in pipeline no. N", where N is
        // not the order they were added in): start again from the last saved set and add the new ones one at a time,
        // leaving out each that breaks the save. shortcut: one full save per new pipeline, only after a failure.
        LOG("[shader] pipeline archive save failed (%s): finding the pipelines that break it\n", err.localizedDescription.UTF8String);
        NSArray *fresh = [g_archive_new copy];
        pipeline_archive_rebuild(g_archive_saved);
        for (MTLRenderPipelineDescriptor *pd in fresh) {
            if ([g_archive addRenderPipelineFunctionsWithDescriptor:pd error:nil] && [g_archive serializeToURL:tmp error:&err]) {
                [g_archive_saved addObject:pd];
                continue;
            }
            LOG("[shader] pipeline archive: %s left out: %s\n", pd.label.UTF8String, err.localizedDescription.UTF8String);
            pipeline_archive_rebuild(g_archive_saved);
        }
        [g_archive_new removeAllObjects];
        if (![g_archive serializeToURL:tmp error:&err]) { LOG("[shader] pipeline archive save failed: %s\n", err.localizedDescription.UTF8String); return; }
    }
    if (rename(tmp.fileSystemRepresentation, g_archive_url.fileSystemRepresentation) != 0) {
        LOG("[shader] pipeline archive save failed: %s\n", strerror(errno));
        return;
    }
    [g_archive_saved addObjectsFromArray:g_archive_new];
    [g_archive_new removeAllObjects];
    LOG("[shader] pipeline archive saved (%d new, %d found in it this run)\n", g_archive_dirty, g_archive_hits);
    g_archive_dirty = 0;
}

void renderer_save_pipeline_archive(void) { if (g_archive_q) dispatch_sync(g_archive_q, ^{ pipeline_archive_save(); }); }

static id<MTLBinaryArchive> pipeline_archive(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (getenv("LARECOMP_NO_PIPELINE_ARCHIVE") && atoi(getenv("LARECOMP_NO_PIPELINE_ARCHIVE"))) return;
        mkdir("cache", 0755);
        g_archive_url = [NSURL fileURLWithPath:@"cache/pipelines.bin"].absoluteURL;
        MTLBinaryArchiveDescriptor *ad = [MTLBinaryArchiveDescriptor new];
        NSError *err;
        if (access(g_archive_url.fileSystemRepresentation, R_OK) == 0) {
            ad.url = g_archive_url;
            g_archive_read = [dev newBinaryArchiveWithDescriptor:ad error:&err];
            // made by another OS / GPU, or damaged: this run writes a new one
            if (!g_archive_read) LOG("[shader] pipeline archive not usable (%s), starting over\n", err.localizedDescription.UTF8String);
            ad.url = nil;
        }
        g_archive = [dev newBinaryArchiveWithDescriptor:ad error:&err];
        if (!g_archive) { g_archive_read = nil; LOG("[shader] no pipeline archive: %s\n", err.localizedDescription.UTF8String); return; }
        LOG("[shader] pipeline archive %s\n", g_archive_read ? "loaded" : "new");
        g_archive_saved = [NSMutableArray new];
        g_archive_new = [NSMutableArray new];
        g_archive_q = dispatch_queue_create("pipeline-archive", DISPATCH_QUEUE_SERIAL);
        atexit(renderer_save_pipeline_archive);
    });
    return g_archive;
}

// Metal drops a fragment stage that has no effect: nothing written to a colour channel an attachment keeps, no depth, no
// discard (depth-only passes). Such a pipeline can save on its own and still fail the whole archive next to the others
// ("expecting 'fragment' stage in pipeline no. N" in test-metal-renderer, every pipeline having saved alone; its
// depth-only draw-multisample-depth is the likely one). Those pipelines, and vertex-only ones (transform feedback), stay on
// the usual async path.
static bool pipeline_archivable(MTLRenderPipelineDescriptor *pd, Prog *pr) {
    if (!pd.rasterizationEnabled || !pr->fi) return false;
    if (pr->fi->writes_depth || pr->fi->uses_discard) return true;
    for (int i = 0; i < 8; i++) {
        MTLColorWriteMask w = pd.colorAttachments[i].writeMask;
        uint32_t keep = (w & MTLColorWriteMaskRed ? 1 : 0) | (w & MTLColorWriteMaskGreen ? 2 : 0) |
                        (w & MTLColorWriteMaskBlue ? 4 : 0) | (w & MTLColorWriteMaskAlpha ? 8 : 0);
        if (pd.colorAttachments[i].pixelFormat && (pr->fi->out_mask >> (i * 4) & keep)) return true;
    }
    return false;
}

static void pipeline_archive_add(MTLRenderPipelineDescriptor *pd, Prog *pr) {
    if (!g_archive || !pipeline_archivable(pd, pr)) return;
    dispatch_async(g_archive_q, ^{
        NSError *err;
        pd.binaryArchives = nil;  // (our own copy) built from its functions alone
        if (![g_archive addRenderPipelineFunctionsWithDescriptor:pd error:&err]) {
            static int n;
            if (n++ < 10) LOG("[shader] pipeline archive add failed: %s\n", err.localizedDescription.UTF8String);
            return;
        }
        [g_archive_new addObject:pd];
        // save 30 s after the first unsaved add, so a crash loses little; exit and the screenshot tests save too.
        // shortcut: each save rewrites the whole file, fine for a few thousand pipelines; append-only files if it gets slow
        if (g_archive_dirty++ == 0)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), g_archive_q, ^{ pipeline_archive_save(); });
    });
}

static bool sync_shaders(void) {  // LARECOMP_SYNC_SHADERS: compile on first use, blocking (deterministic tests)
    static int v = -1;
    if (v < 0) v = getenv("LARECOMP_SYNC_SHADERS") != NULL;
    return v;
}

// Native shader arguments must match the effective view's scalar type; integer/stencil reads return raw bits.
static void texture_key(int stage, ShaderKey *key) {
    key->stencil_slots = key->sint_slots = key->uint_slots = 0;
    key->img_sint = key->img_uint = 0;
    if (!st.tpool) return;
    for (int k = 0; k < 8; k++) {  // bound images (SUST / SURED): their formats pick the shader's image type
        uint64_t h = st.img[stage][k];
        uint32_t tic = h & 0xFFFFF;
        if (!h || tic >= (uint32_t)st.tpool->count) continue;
        NvnTexEntry *e = &((NvnTexEntry *)st.tpool->entries)[tic];
        if (!e->tex) continue;
        uint32_t format = e->has_view && (e->view.setmask & 4) ? e->view.format : e->tex->format;
        if (renderer_format_is_uint(format)) key->img_uint |= 1u << k;
        else if (renderer_format_is_sint(format)) key->img_sint |= 1u << k;
    }
    for (int s = 0; s < 32; s++) {
        uint64_t h = st.tex[stage][s];
        uint32_t tic = h & 0xFFFFF;
        if (!h || tic >= (uint32_t)st.tpool->count) continue;
        NvnTexEntry *e = &((NvnTexEntry *)st.tpool->entries)[tic];
        if (!e->tex) continue;
        bool stencil = renderer_format_has_stencil(e->tex->format) &&
            (e->has_view && (e->view.setmask & 16) ? e->view.ds_mode : e->tex->ds_mode) == 1;
        uint32_t format = e->has_view && (e->view.setmask & 4) ? e->view.format : e->tex->format;
        if (stencil) key->stencil_slots |= 1u << s;
        if (stencil || renderer_format_is_uint(format)) key->uint_slots |= 1u << s;
        else if (renderer_format_is_sint(format)) key->sint_slots |= 1u << s;
    }
}

// Transform feedback (Z-A skins its characters / runs its particles in vertex-only passes whose output later draws read as
// vertex streams): BeginTransformFeedback .. End, with the buffers bound and rasterizer discard on.
static bool g_xfb_on, g_raster_discard, g_xfb_dirty;
static uint64_t g_xfb_addr[4], g_xfb_size[4];
static uint64_t g_ind_off = UINT64_MAX;  // an indirect draw whose arguments the GPU fills in (offset in the gmem window)
static NvnProgram g_comp_prog;  // the stages bound so far (a game may bind them from several programs)

static void compile_program(Prog *pr) {
    NSError *err = nil;
    double t0 = now_ms();
    // LARECOMP_SHADER_SALT=<text>: tag sources so Metal's disk cache misses (measure cold first-use compiles)
    NSString *salt = getenv("LARECOMP_SHADER_SALT") ? [NSString stringWithFormat:@"\n// %s\n", getenv("LARECOMP_SHADER_SALT")] : @"";
    id<MTLLibrary> vl = [dev newLibraryWithSource:[@(pr->vi->msl) stringByAppendingString:salt] options:game_shader_opts(true) error:&err];
    if (!vl) { LOG("[shader] VS compile failed (%llx): %s\n%s\n", pr->vs_addr, err.localizedDescription.UTF8String, pr->vi->msl); pr->failed = true; return; }
    id<MTLLibrary> fl = pr->fi->msl ? [dev newLibraryWithSource:[@(pr->fi->msl) stringByAppendingString:salt] options:game_shader_opts(false) error:&err] : nil;
    if (!fl && pr->fi->msl) { LOG("[shader] FS compile failed (%llx): %s\n%s\n", pr->fs_addr, err.localizedDescription.UTF8String, pr->fi->msl); pr->failed = true; return; }
    pr->vs = [vl newFunctionWithName:@"main0"];
    pr->fs = fl ? [fl newFunctionWithName:@"main0"] : nil;
    __atomic_fetch_add(&stat_compiles, 1, __ATOMIC_RELAXED);
    double dt = now_ms() - t0;
    @synchronized(cache) { stat_compile_ms += dt; }
    pr->ready = true;
}

static Prog *get_program(NvnProgram *p, ShaderKey *vkey, ShaderKey *fkey) {
    shader_cache_warm();
    if (!(p->stage_mask & 1) || (!(p->stage_mask & 2) && !g_xfb_on)) return nil;
    // fast path: hash of the code addresses and keys
    uint64_t h = 0xcbf29ce484222325ull;
    for (int i = 0; i < 2; i++) { uint64_t a = p->stages[i].code_addr; for (int k = 0; k < 8; k++) { h ^= (a >> (k * 8)) & 0xFF; h *= 0x100000001B3ull; } }
    const uint8_t *vb = (const uint8_t *)vkey;
    for (size_t i = 0; i < sizeof *vkey; i++) { h ^= vb[i]; h *= 0x100000001B3ull; }
    for (int i = 0; i < 8; i++) { h ^= fkey->rt_kind[i]; h *= 0x100000001B3ull; }
    h ^= fkey->stencil_slots; h *= 0x100000001B3ull;
    h ^= fkey->sint_slots; h *= 0x100000001B3ull;
    h ^= fkey->uint_slots; h *= 0x100000001B3ull;
    h ^= (uint64_t)fkey->img_uint << 8 | fkey->img_sint; h *= 0x100000001B3ull;
    if (!h) h = 1;
    uint32_t slot = (uint32_t)(h ^ (h >> 31)) & (PROG_TAB - 1);
    while (prog_tab[slot].key && prog_tab[slot].key != h) slot = (slot + 1) & (PROG_TAB - 1);
    if (prog_tab[slot].key) { Prog *fp = (__bridge Prog *)prog_tab[slot].prog; return fp->failed ? nil : fp; }
    NSString *vertex_key = [[NSData dataWithBytes:vkey length:sizeof *vkey] base64EncodedStringWithOptions:0];
    NSString *key = [NSString stringWithFormat:@"%llx/%llx/%@/%@/%x/%x/%x/%x%x%s", p->stages[0].code_addr, p->stages[1].code_addr,
                     vertex_key, [NSData dataWithBytes:fkey->rt_kind length:8],
                     fkey->stencil_slots, fkey->sint_slots, fkey->uint_slots, fkey->img_uint, fkey->img_sint, vkey->flip_x ? "/mirror" : ""];
    Prog *pr = cache[key];
    if (pr) {
        prog_tab[slot].key = h;
        prog_tab[slot].prog = (__bridge void *)pr;
        return pr->failed ? nil : pr;
    }
    pr = [Prog new];
    pr->vs_addr = p->stages[0].code_addr;
    pr->fs_addr = p->stages[1].code_addr;
    cache[key] = pr;
    prog_tab[slot].key = h;
    prog_tab[slot].prog = (__bridge void *)pr;  // retained by the cache dictionary
    dump_program(p);
    backend_gwin_pick();
    maxwell_gmem_base = g_gwin_base;
    maxwell_gmem_size = g_gwin_max;
    {
        // LARECOMP_DBG_FS=<fs code addr hex>:<pc hex>:<reg>
        static int parsed;
        static unsigned long long dbg_addr;
        static unsigned dbg_pc;
        static int dbg_reg;
        if (!parsed) { parsed = 1; const char *e = getenv("LARECOMP_DBG_FS"); if (e) sscanf(e, "%llx:%x:%d", &dbg_addr, &dbg_pc, &dbg_reg); }
        maxwell_dbg_code = dbg_addr ? (const uint8_t *)(uintptr_t)dbg_addr : NULL;
        static unsigned long long dbg_vs;
        static int vparsed;
        if (!vparsed) { vparsed = 1; const char *e = getenv("LARECOMP_DBG_VS"); if (e) dbg_vs = strtoull(e, NULL, 16); }
        maxwell_dbg_vs = dbg_vs ? (const uint8_t *)(uintptr_t)dbg_vs : NULL;
        maxwell_dbg_pc = dbg_pc;
        maxwell_dbg_reg = dbg_reg;
    }
    // the compiler constants follow the code, so they bound the instruction scan
    size_t vmax = p->stages[0].const_offset ? p->stages[0].const_offset : 0x10000;
    size_t fmax = p->stages[1].const_offset ? p->stages[1].const_offset : 0x10000;
    pr->vi = maxwell_translate((const uint8_t *)(uintptr_t)p->stages[0].code_addr, vmax, STAGE_VERTEX, vkey);
    if (!pr->vi->msl) {
        LOG("[shader] VS translate failed: %s (code %llx)\n", pr->vi->error, p->stages[0].code_addr);
        char path[128];
        snprintf(path, sizeof path, "build/shaders/fail_%llx_s0_code.bin", p->stages[0].code_addr);
        FILE *f = fopen(path, "wb");
        if (f) { fwrite((void *)(uintptr_t)p->stages[0].code_addr, 1, 0x4000, f); fclose(f); }
        pr->failed = true;
        return nil;
    }
    fkey->vs_out_mask = pr->vi->out_mask;
    if (!(p->stage_mask & 2)) {  // vertex-only (transform feedback): no fragment stage, nothing is rasterized
        pr->fi = calloc(1, sizeof *pr->fi);
        pr->fi->stage = STAGE_FRAGMENT;
        shader_cache_note(pr->vi->msl, "");
        if (sync_shaders()) { compile_program(pr); return pr->failed ? nil : pr; }
        static dispatch_queue_t xq;
        if (!xq) xq = dispatch_queue_create("larecomp.shaders.xfb", DISPATCH_QUEUE_CONCURRENT);
        dispatch_async(xq, ^{ compile_program(pr); });
        return pr;
    }
    pr->fi = maxwell_translate((const uint8_t *)(uintptr_t)p->stages[1].code_addr, fmax, STAGE_FRAGMENT, fkey);
    if (!pr->fi->msl) { LOG("[shader] FS translate failed (%llx): %s\n", p->stages[1].code_addr, pr->fi->error); pr->failed = true; return nil; }
    if (getenv("LARECOMP_SAVE_MSL")) {
        mkdir("build/msl", 0755);
        char path[256];
        snprintf(path, sizeof path, "build/msl/%llx_vs.metal", p->stages[0].code_addr);
        FILE *f = fopen(path, "w"); fputs(pr->vi->msl, f); fclose(f);
        snprintf(path, sizeof path, "build/msl/%llx_fs.metal", p->stages[1].code_addr);
        f = fopen(path, "w"); fputs(pr->fi->msl, f); fclose(f);
    }
    {   // LARECOMP_FS_OVERRIDE=<fs code addr hex>:<path>: compile that MSL instead (diagnostics)
        static char ov_addr[32], ov_path[256];
        static int ov_parsed;
        if (!ov_parsed) {
            ov_parsed = 1;
            const char *e = getenv("LARECOMP_FS_OVERRIDE");
            const char *c = e ? strchr(e, ':') : NULL;
            if (c) { snprintf(ov_addr, sizeof ov_addr, "%.*s", (int)(c - e), e); snprintf(ov_path, sizeof ov_path, "%s", c + 1); }
        }
        if (ov_path[0] && p->stages[1].code_addr == strtoull(ov_addr, NULL, 16)) {
            FILE *f = fopen(ov_path, "rb");
            if (f) {
                fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
                char *b = malloc(n + 1);
                if (b && fread(b, 1, n, f) == (size_t)n) { b[n] = 0; pr->fi->msl = b; pr->ov_active = true; snprintf(pr->ov_path, sizeof pr->ov_path, "%s", ov_path); LOG("[shader] FS %llx: MSL overridden from %s\n", p->stages[1].code_addr, ov_path); }
                fclose(f);
            }
        }
    }
    {   // LARECOMP_FS_OVERRIDE_HASH=<fnv64 of the translated MSL, hex>:<path>: same override, matched by source text
        // (the game uploads its shaders to a moving guest address, so the code address differs between runs)
        static char ovh_path[256];
        static uint64_t ovh_hash;
        static int ovh_parsed;
        if (!ovh_parsed) {
            ovh_parsed = 1;
            const char *e = getenv("LARECOMP_FS_OVERRIDE_HASH");
            const char *c = e ? strchr(e, ':') : NULL;
            if (c) { ovh_hash = strtoull(e, NULL, 16); snprintf(ovh_path, sizeof ovh_path, "%s", c + 1); }
        }
        if (ovh_path[0] && fnv64(pr->fi->msl) == ovh_hash) {
            FILE *f = fopen(ovh_path, "rb");
            if (f) {
                fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
                char *b = malloc(n + 1);
                if (b && fread(b, 1, n, f) == (size_t)n) { b[n] = 0; pr->fi->msl = b; pr->ov_active = true; snprintf(pr->ov_path, sizeof pr->ov_path, "%s", ovh_path); LOG("[shader] FS %llx (msl %016llx, pr %p): MSL overridden from %s (new msl %016llx)\n", p->stages[1].code_addr, (unsigned long long)ovh_hash, (__bridge void *)pr, ovh_path, (unsigned long long)fnv64(b)); }
                fclose(f);
            }
        }
    }
    shader_cache_note(pr->vi->msl, pr->fi->msl);
    if (sync_shaders()) {
        compile_program(pr);
        return pr->failed ? nil : pr;
    }
    // First-time compiles take ~40 ms each on Metal: build off the render thread; draws using this program are
    // skipped until it's ready (the object appears a few frames later instead of the game stalling).
    static dispatch_queue_t q;
    if (!q) q = dispatch_queue_create("larecomp.shaders", DISPATCH_QUEUE_CONCURRENT);
    dispatch_async(q, ^{ compile_program(pr); });
    return pr;
}

static id<MTLSamplerState> sampler_for(NvnSamplerDesc *d) {
    if (d->backend) return (__bridge id<MTLSamplerState>)d->backend;
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.magFilter = d->mag_filter == 1 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    uint32_t mf = d->min_filter;
    sd.minFilter = (mf == 1 || mf == 3 || mf == 5) ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    sd.mipFilter = mf <= 1 ? MTLSamplerMipFilterNotMipmapped : (mf == 2 || mf == 3) ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterLinear;
    MTLSamplerAddressMode modes[3];
    for (int i = 0; i < 3; i++) {
        switch (d->wrap[i]) {
        case 0: case 7: modes[i] = MTLSamplerAddressModeClampToEdge; break;
        case 1: modes[i] = MTLSamplerAddressModeRepeat; break;
        case 2: case 3: modes[i] = MTLSamplerAddressModeMirrorClampToEdge; break;
        case 4: case 5: modes[i] = MTLSamplerAddressModeClampToBorderColor; break;
        case 6: modes[i] = MTLSamplerAddressModeMirrorRepeat; break;
        default: modes[i] = MTLSamplerAddressModeRepeat;
        }
    }
    sd.sAddressMode = modes[0]; sd.tAddressMode = modes[1]; sd.rAddressMode = modes[2];
    const float *border = d->border;
    if (border[0] == 1 && border[1] == 1 && border[2] == 1 && border[3] == 1)
        sd.borderColor = MTLSamplerBorderColorOpaqueWhite;
    else if (border[0] == 0 && border[1] == 0 && border[2] == 0 && border[3] == 1)
        sd.borderColor = MTLSamplerBorderColorOpaqueBlack;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (@available(macOS 26.0, *)) {
        if (d->reduction == 1) sd.reductionMode = MTLSamplerReductionModeMinimum;
        else if (d->reduction == 2) sd.reductionMode = MTLSamplerReductionModeMaximum;
        sd.lodBias = d->lod_bias;
    }
#endif
    sd.lodMinClamp = d->lod_min;
    sd.lodMaxClamp = d->lod_max > 1000 ? FLT_MAX : d->lod_max;
    if (d->max_aniso > 1) sd.maxAnisotropy = (NSUInteger)fminf(d->max_aniso, 16);
    if (d->lod_bias != 0 && getenv("LARECOMP_LOG_BIAS"))
        LOG("[sampler] lod bias %g (min filter %u, aniso %g)\n", d->lod_bias, mf, d->max_aniso);
    static float lodmin = -1;  // LARECOMP_LOD_MIN=<n>: skip the n sharpest mips everywhere (aliasing experiments)
    if (lodmin < 0) lodmin = getenv("LARECOMP_LOD_MIN") ? (float)atof(getenv("LARECOMP_LOD_MIN")) : 0;
    if (lodmin > 0 && mf > 1) sd.lodMinClamp = fmaxf(sd.lodMinClamp, lodmin);
    static int stest = -1;  // LARECOMP_SAMPLER_TEST: full mip range + 16x aniso on mipmapped samplers (moire test)
    if (stest < 0) stest = getenv("LARECOMP_SAMPLER_TEST") != NULL;
    if (stest && mf > 1) { sd.lodMinClamp = 0; sd.lodMaxClamp = FLT_MAX; sd.maxAnisotropy = 16; }
    if (getenv("LARECOMP_LOD_MAX0")) sd.lodMaxClamp = 0;  // (debug: mip 0 only; stripes vanish => mip chain layout bug)
    if (getenv("LARECOMP_LOG_SAMPLERS"))
        LOG("[sampler] min %u mag %u lod %g..%g aniso %g wrap %u %u\n", mf, d->mag_filter, d->lod_min, d->lod_max, d->max_aniso,
            d->wrap[0], d->wrap[1]);
    if (d->compare_mode) sd.compareFunction = getenv("LARECOMP_NO_SHADOW") ? MTLCompareFunctionAlways : compare_fn((uint8_t)d->compare_func);
    sd.supportArgumentBuffers = NO;
    id<MTLSamplerState> s = [dev newSamplerStateWithDescriptor:sd];
    d->backend = (void *)CFBridgingRetain(s);
    return s;
}

static id<MTLSamplerState> default_sampler(void) {
    static id<MTLSamplerState> s;
    if (!s) {
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        s = [dev newSamplerStateWithDescriptor:sd];
    }
    return s;
}

static uint64_t g_cur_fs_hash;
static id<MTLTexture> dummy_texture_ex(int type, int kind, bool image) {
    static id<MTLTexture> t[2][10][3];
    if (!t[image][type][kind]) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor new];
        d.pixelFormat = image ? (kind == 2 ? MTLPixelFormatR32Uint : kind == 1 ? MTLPixelFormatR32Sint : MTLPixelFormatR32Float)
                             : (kind == 2 ? MTLPixelFormatRGBA8Uint : kind == 1 ? MTLPixelFormatRGBA8Sint : MTLPixelFormatRGBA8Unorm);
        d.usage = MTLTextureUsageShaderRead | (image ? MTLTextureUsageShaderWrite : 0);
        if (@available(macOS 14.0, *))
            if (image && kind) d.usage |= MTLTextureUsageShaderAtomic;
        d.width = d.height = 1;
        d.textureType = type == TEXTYPE_CUBE ? MTLTextureTypeCube : type == TEXTYPE_3D ? MTLTextureType3D
                      : type == TEXTYPE_2D_ARRAY ? MTLTextureType2DArray : type == TEXTYPE_1D ? MTLTextureType1D
                      : type == TEXTYPE_CUBE_ARRAY ? MTLTextureTypeCubeArray : type == TEXTYPE_1D_ARRAY ? MTLTextureType1DArray
                      : MTLTextureType2D;
        if (type == TEXTYPE_2D_ARRAY || type == TEXTYPE_CUBE_ARRAY || type == TEXTYPE_1D_ARRAY) d.arrayLength = 1;
        id<MTLTexture> texture = [dev newTextureWithDescriptor:d];
        // (was MTLTextureType2D for cube arrays: a 2D bound to a texturecube_array slot is invalid)
        uint32_t zero[6] = {0};
        for (int sl = 0; sl < (type == TEXTYPE_CUBE || type == TEXTYPE_CUBE_ARRAY ? 6 : 1); sl++)  // (every face: new texels are undefined)
            if (d.textureType == MTLTextureType3D || d.textureType == MTLTextureType2D || d.textureType == MTLTextureType1D)
                [texture replaceRegion:MTLRegionMake3D(0, 0, 0, 1, 1, 1) mipmapLevel:0 withBytes:zero bytesPerRow:4];
            else
                [texture replaceRegion:MTLRegionMake3D(0, 0, 0, 1, 1, 1) mipmapLevel:0 slice:sl withBytes:zero bytesPerRow:4 bytesPerImage:4];
        t[image][type][kind] = texture;
    }
    return t[image][type][kind];
}

static id<MTLTexture> dummy_texture(int type, int kind) {
    return dummy_texture_ex(type, kind, false);
}

static MTLTextureType mtl_type_for(int t) {
    switch (t) {
    case TEXTYPE_1D: return MTLTextureType1D;
    case TEXTYPE_3D: return MTLTextureType3D;
    case TEXTYPE_CUBE: return MTLTextureTypeCube;
    case TEXTYPE_2D_ARRAY: return MTLTextureType2DArray;
    case TEXTYPE_CUBE_ARRAY: return MTLTextureTypeCubeArray;
    case TEXTYPE_1D_ARRAY: return MTLTextureType1DArray;
    default: return MTLTextureType2D;
    }
}

// Shadow slots (depth2d, sample_compare) need a depth texture: with nothing usable bound they get a 1x1 Depth32Float
// cleared to 1.0 (lit under less / less-equal, as an empty shadow map) instead of the RGBA8 dummy, which compares as 0
// (in shadow) and is not a valid depth2d binding. (As LASRecomp c7e85df.)
static id<MTLTexture> shadow_slot_texture(id<MTLTexture> tex, const ShaderTexture *st_) {
    if (tex && tex.textureType != MTLTextureType2DMultisample)
        switch (tex.pixelFormat) {
        case MTLPixelFormatDepth16Unorm: case MTLPixelFormatDepth32Float: case MTLPixelFormatDepth32Float_Stencil8: return tex;
        default: break;
        }
    int type = st_->type;
    if (type != TEXTYPE_2D && type != TEXTYPE_2D_ARRAY && type != TEXTYPE_CUBE && type != TEXTYPE_CUBE_ARRAY) return tex;
    static id<MTLTexture> t[10];
    static bool logged;
    if (!logged) { logged = true; LOG("[metal] shadow slot without a depth texture (format %lu): 1x1 depth dummy (once)\n", tex ? (unsigned long)tex.pixelFormat : 0ul); }
    if (!t[type]) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor new];
        d.pixelFormat = MTLPixelFormatDepth32Float;
        d.width = d.height = 1;
        d.textureType = mtl_type_for(type);
        if (type == TEXTYPE_2D_ARRAY || type == TEXTYPE_CUBE_ARRAY) d.arrayLength = 1;
        d.storageMode = MTLStorageModePrivate;
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        id<MTLTexture> dt = [dev newTextureWithDescriptor:d];
        if (!dt) return tex;
        id<MTLCommandBuffer> cb = [renderer_queue() commandBuffer];  // (committed now: runs before the current one)
        for (NSUInteger sl = 0; sl < (type == TEXTYPE_CUBE || type == TEXTYPE_CUBE_ARRAY ? 6 : 1); sl++) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.depthAttachment.texture = dt;
            rp.depthAttachment.slice = sl;
            rp.depthAttachment.loadAction = MTLLoadActionClear;
            rp.depthAttachment.storeAction = MTLStoreActionStore;
            rp.depthAttachment.clearDepth = 1.0;
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        }
        [cb commit];
        t[type] = dt;
    }
    return t[type];
}

// NVN texture/view component swizzle (same enum values as MTLTextureSwizzle), applied as a view.
static id<MTLTexture> apply_swizzle(id<MTLTexture> tex, NvnTexture *t, const NvnTextureView *v, bool has_view) {
    const uint8_t *sw = (has_view && (v->setmask & 8)) ? v->swizzle : t->swizzle;
    uint8_t c[4];
    for (int i = 0; i < 4; i++) c[i] = sw[i] <= 5 ? sw[i] : (uint8_t)(2 + i);
    if (renderer_format_alpha_one(t->format))
        for (int i = 0; i < 4; i++) if (c[i] == MTLTextureSwizzleAlpha) c[i] = MTLTextureSwizzleOne;
    if (c[0] == 2 && c[1] == 3 && c[2] == 4 && c[3] == (renderer_format_alpha_one(t->format) ? 1 : 5)) return tex;
    if (tex.sampleCount > 1 || renderer_format_is_depth(t->format)) return tex;
    uint32_t swz = c[0] | c[1] << 8 | c[2] << 16 | (uint32_t)c[3] << 24;
    MTLTextureSwizzleChannels chans = MTLTextureSwizzleChannelsMake(c[0], c[1], c[2], c[3]);
    id<MTLTexture> view = view_cached(tex, 0x5000000000000000ull | swz, ^{
        NSUInteger slices = tex.textureType == MTLTextureType3D ? 1 : tex.arrayLength * (tex.textureType == MTLTextureTypeCube || tex.textureType == MTLTextureTypeCubeArray ? 6 : 1);
        return [tex newTextureViewWithPixelFormat:tex.pixelFormat textureType:tex.textureType
                                           levels:NSMakeRange(0, tex.mipmapLevelCount) slices:NSMakeRange(0, slices)
                                          swizzle:chans];
    });
    return view;
}

// (diagnostics) touch/rm build/hdr29 to sample every RGBA16F (0x29) texture as a constant 1.0, without restarting:
// the two 1920x1080 0x29 buffers the lighting pass reads are cleared to zero and nothing in our command stream
// writes them, so this tells us whether they gate the output.
static id<MTLTexture> hdr_const_tex(void) {
    static id<MTLTexture> tex;
    if (!tex) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor new];
        d.pixelFormat = MTLPixelFormatRGBA16Float;
        d.width = d.height = 1;
        d.usage = MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeManaged;
        tex = [dev newTextureWithDescriptor:d];
        uint16_t one[4] = {0x3C00, 0x3C00, 0x3C00, 0x3C00};  // half 1.0
        [tex replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:one bytesPerRow:8];
    }
    return tex;
}

// Upload helper: a separate command buffer, committed now so it runs before the current pass.
static id<MTLTexture> sampled_texture_ex(NvnTexture *t, const NvnTextureView *v, bool has_view, int want_type, bool image) {
    static int hdr29, hdr29_tick;
    if (!(hdr29_tick++ & 255)) hdr29 = access("build/hdr29", F_OK) == 0;
    if (!image && hdr29 && t->format == 0x29) {
        static int once;
        if (!once++) LOG("[hdr29] sampling 0x29 textures as 1.0\n");
        return hdr_const_tex();
    }
    // uploads (if the CPU-side contents changed) go into their own command buffer, committed before
    // the current one so they land first
    id<MTLTexture> tex = view_texture(t, v, has_view, false, nil);
    // (the type conversion below makes a fresh view with an identity swizzle, so the swizzle goes on last)
    MTLTextureType want = mtl_type_for(want_type);
    if (tex.textureType != want && tex.textureType != MTLTextureType2DMultisample) {
        id<MTLTexture> src = tex;
        if (want == MTLTextureType2D && (tex.textureType == MTLTextureType2DArray || tex.textureType == MTLTextureTypeCube))
            tex = view_cached(src, 0x6000000000000000ull | 1, ^{ return [src newTextureViewWithPixelFormat:src.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(0, src.mipmapLevelCount) slices:NSMakeRange(0, 1)]; });
        else if (want == MTLTextureType2DArray && tex.textureType == MTLTextureType2D)
            tex = view_cached(src, 0x6000000000000000ull | 2, ^{ return [src newTextureViewWithPixelFormat:src.pixelFormat textureType:MTLTextureType2DArray levels:NSMakeRange(0, src.mipmapLevelCount) slices:NSMakeRange(0, 1)]; });
        else if (want == MTLTextureTypeCube && tex.textureType == MTLTextureType2DArray && tex.arrayLength >= 6)
            tex = view_cached(src, 0x6000000000000000ull | 3, ^{ return [src newTextureViewWithPixelFormat:src.pixelFormat textureType:MTLTextureTypeCube levels:NSMakeRange(0, src.mipmapLevelCount) slices:NSMakeRange(0, 6)]; });
        else {
            static int nlog;
            if (nlog++ < 30) LOG("[tex] type mismatch: fs %llx want %lu have %lu (%ux%ux%u target %u fmt %#x arr %lu)\n", (unsigned long long)g_cur_fs_hash, (unsigned long)want,
                                 (unsigned long)tex.textureType, t->width, t->height, t->depth, t->target, t->format, (unsigned long)tex.arrayLength);
            uint32_t format = has_view && (v->setmask & 4) ? v->format : t->format;
            return dummy_texture_ex(want_type, rt_kind(format), image);
        }
    }
    // Upload initial CPU data first, then protect shader-written results from later upload probes.
    if (image && tex) renderer_mark_gpu_owned(t);
    return image ? tex : apply_swizzle(tex, t, v, has_view);  // (a swizzled view can't be written: images keep the identity)
}

static id<MTLTexture> sampled_texture(NvnTexture *t, const NvnTextureView *v, bool has_view, int want_type) {
    return sampled_texture_ex(t, v, has_view, want_type, false);
}

// A stencil view for a slot the guest bound in depth/stencil mode STENCIL. Metal's castable stencil formats
// for the depth-stencil formats we allocate are X32_Stencil8 (from D32F_S8) and X24_Stencil8 (from D24S8);
// texture2d<uint>.read() then returns the stencil byte.
static id<MTLTexture> stencil_texture(NvnTexture *t) {
    id<MTLTexture> base = renderer_texture(t, nil, false);
    MTLPixelFormat pf = base.pixelFormat;
    if (pf == MTLPixelFormatDepth32Float_Stencil8) pf = MTLPixelFormatX32_Stencil8;
    else if (pf == MTLPixelFormatDepth24Unorm_Stencil8) pf = MTLPixelFormatX24_Stencil8;
    else return base;
    id<MTLTexture> v = view_cached(base, 0x5700000000000000ull | (uint64_t)pf, ^{
        return [base newTextureViewWithPixelFormat:pf textureType:MTLTextureType2D
                                            levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1)];
    });
    static int nfail;
    if (v == base && nfail++ < 5) LOG("[stencil] view failed: fmt %#x mtl %lu\n", t->format, (unsigned long)base.pixelFormat);
    return v;
}


// ---- render-target feedback: a draw that samples one of the pass's own attachments (e.g. depth
// bound for testing while the shader reads it) gets a snapshot copy, as sampling an attachment of the
// current Metal pass is undefined.
// Snapshots stay valid until their texture is written again (a draw writing that attachment, a clear, copy or
// compute). Soft particles (grass-cut leaves, smoke) sample the depth buffer they're tested against but don't
// write it, so a burst of them shares one snapshot instead of a pass break + full-screen copy per draw.
static const char *snap_why[8];
static const char *snap_reason = "?";
static void snapshots_invalidate(NvnTexture *t) {  // NULL = all
    for (int i = 0; i < 8; i++) if ((!t || snap_tex[i] == t) && snap_ok[i]) { snap_ok[i] = false; snap_why[i] = snap_reason; }
}

static uint64_t shader_texture_handle(int stage, const ShaderTexture *texture) {
    uint32_t base = texture->is_image ? IMAGE_HANDLE_BASE : 0x20;
    uint32_t count = texture->is_image ? 8 : 32;
    uint32_t offset = texture->handle_offset - base;
    if (offset >= count * 8) return 0;
    uint32_t slot = offset / 8;
    return texture->is_image ? st.img[stage][slot] : st.tex[stage][slot];
}

static NvnTexture *shader_texture_object(int stage, ShaderTexture *st_) {
    if (st_->is_image) return NULL; // image writes must target the original allocation, never a feedback snapshot
    uint64_t h = shader_texture_handle(stage, st_);
    uint32_t tic = h & 0xFFFFF;
    if (!h || !st.tpool || tic >= (uint32_t)st.tpool->count) return NULL;
    return ((NvnTexEntry *)st.tpool->entries)[tic].tex;
}

static bool needs_feedback_snapshot(NvnTexture *t) {
    if (!t) return false;
    // Z-A builds its depth pyramid by writing higher mips while reading the preceding level.
    // Sample those draws in place: our mip-zero snapshot cannot supply the intermediate levels.
    // Keep the snapshot if any attachment also writes mip zero, including a clamped single-level view.
    bool mipmapped = t->levels > 1;
    if (t == st.rt.depth && !(mipmapped && st.rt.has_dview && (st.rt.dview.setmask & 1) && st.rt.dview.base_level))
        return true;
    for (int i = 0; i < st.rt.ncolor; i++)
        if (t == st.rt.color[i] && !(mipmapped && st.rt.has_cview[i] && (st.rt.cview[i].setmask & 1) && st.rt.cview[i].base_level))
            return true;
    return false;
}

static void resolve_feedback(Prog *pr) {
    nfeedback = 0;
    static int off = -1;
    if (off < 0) off = getenv("LARECOMP_NO_FEEDBACK") != NULL;
    if (off) return;
    ShaderInfo *infos[2] = {pr->vi, pr->fi};
    for (int sg = 0; sg < 2; sg++)
        for (int i = 0; i < infos[sg]->ntex; i++) {
            NvnTexture *t = shader_texture_object(sg, &infos[sg]->tex[i]);
            if (!needs_feedback_snapshot(t)) continue;
            bool have = false;
            for (int k = 0; k < nfeedback; k++) have |= feedback_tex[k] == t;
            if (have || nfeedback == 4) continue;
            if (!g_snap_copies) g_snap_copies = [NSMutableDictionary new];
            NSMutableDictionary *copies = g_snap_copies;
            NSValue *key = [NSValue valueWithPointer:t];
            static int nosnap = -1;
            if (nosnap < 0) nosnap = getenv("LARECOMP_NO_SNAPSHOT_REUSE") != NULL;
            int si = -1;
            for (int k = 0; k < 8; k++) if (snap_tex[k] == t) si = k;
            // A draw that writes the same depth buffer it samples can't depend on what it reads (that is undefined on the
            // Switch too): seen in the shadow-map pass, whose material shader still declares the shadow map from the
            // main pass. Any earlier snapshot does; no copy, no pass break.
            bool self_write = t == st.rt.depth && st.ds[0] && st.ds[1];
            if (!nosnap && si >= 0 && (snap_ok[si] || self_write) && copies[key]) {  // unchanged since the last snapshot
                feedback_tex[nfeedback] = t;
                feedback_copy[nfeedback++] = copies[key];
                continue;
            }
            stat_feedback_copies++;
            static int logfb = -1;
            if (logfb < 0) logfb = getenv("LARECOMP_LOG_FEEDBACK") != NULL;
            if (logfb && stat_feedback_copies % 50 == 1)
                LOG("[feedback] copy %s %ux%u fmt %#x stage %d fs %016llx (last invalidated by %s) ds %d/%d/%d stencil %d ncolor %d c0 %ux%u fmt %#x mask %x\n", t == st.rt.depth ? "DEPTH" : "COLOR",
                    t->width, t->height, t->format, sg, (unsigned long long)g_cur_fs_hash, si >= 0 ? snap_why[si] : "new",
                    st.ds[0], st.ds[1], st.ds[2], st.ds[3], st.rt.ncolor, st.rt.ncolor && st.rt.color[0] ? st.rt.color[0]->width : 0,
                    st.rt.ncolor && st.rt.color[0] ? st.rt.color[0]->height : 0, st.rt.ncolor && st.rt.color[0] ? st.rt.color[0]->format : 0, st.channel_mask);
            end_pass();
            id<MTLTexture> src = renderer_texture(t, nil, true);
            id<MTLTexture> dst = copies[key];
            if (!dst || dst.width != src.width || dst.height != src.height || dst.pixelFormat != src.pixelFormat) {
                if (dst) views_forget((__bridge void *)dst);
                MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat width:src.width
                                                                                           height:src.height mipmapped:NO];
                d.textureType = src.textureType == MTLTextureType2DMultisample ? MTLTextureType2DMultisample : MTLTextureType2D;
                d.sampleCount = src.sampleCount;
                d.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
                d.storageMode = MTLStorageModePrivate;
                dst = [dev newTextureWithDescriptor:d];
                copies[key] = dst;
            }
            id<MTLBlitCommandEncoder> b = [cb() blitCommandEncoder];
            [b copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                    sourceSize:MTLSizeMake(src.width, src.height, 1) toTexture:dst destinationSlice:0 destinationLevel:0
             destinationOrigin:MTLOriginMake(0, 0, 0)];
            [b endEncoding];
            feedback_tex[nfeedback] = t;
            feedback_copy[nfeedback++] = dst;
            if (si < 0) { static int rr; si = rr++ & 7; snap_tex[si] = t; }
            snap_ok[si] = true;
            st.rt_dirty = true;  // the pass resumes (loading) after the copy
        }
}

static id<MTLTexture> feedback_sample(NvnTexEntry *entry, id<MTLTexture> sampled) {
    if (!entry->tex || !sampled) return sampled;
    for (int k = 0; k < nfeedback; k++) {
        if (entry->tex != feedback_tex[k]) continue;
        id<MTLTexture> copy = feedback_copy[k];
        MTLTextureType type = copy.textureType;
        if (sampled.textureType == MTLTextureType2DArray && type != sampled.textureType) type = MTLTextureType2DArray;
        MTLPixelFormat format = sampled.pixelFormat;
        if (format != copy.pixelFormat || type != copy.textureType) {
            id<MTLTexture> base = copy;
            uint64_t params = 0x6100000000000000ull | (uint64_t)format | (uint64_t)type << 16;
            copy = view_cached(base, params, ^{
                return [base newTextureViewWithPixelFormat:format textureType:type
                                                   levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1)];
            });
        }
        return apply_swizzle(copy, entry->tex, &entry->view, entry->has_view);
    }
    return sampled;
}

// Shaders with more textures than Metal's sampler slots (MSL_MAX_SAMPLERS; issue #215: a fragment shader of the Ukuku
// Prairie cave with 17) take their samplers as an array of the slots, and a table of each texture's slot
// (maxwell/translate.c). Each distinct sampler state the draw uses goes in a slot of its own - textures sharing a state
// share its slot - so every texture keeps its own filtering, wrapping and compare mode. smp[i] / desc[i]: texture i's
// state and its descriptor (NULL: the default sampler); fills slot[] and map[], returns the slots used.
static int sampler_slots(int n, __strong id<MTLSamplerState> *smp, NvnSamplerDesc *const *desc,
                         __strong id<MTLSamplerState> *slot, uint32_t *map) {
    const NvnSamplerDesc *sdesc[MSL_MAX_SAMPLERS] = {0};
    int ns = 0;
    for (int i = 0; i < n; i++) {
        int k = 0;
        for (; k < ns; k++)  // (one state: the same object, or descriptors alike apart from the cached object)
            if (slot[k] == smp[i] || (desc[i] && sdesc[k] && !memcmp(desc[i], sdesc[k], offsetof(NvnSamplerDesc, backend))))
                break;
        if (k == ns && ns < MSL_MAX_SAMPLERS) { slot[ns] = smp[i]; sdesc[ns++] = desc[i]; }
        else if (k == ns) {  // more distinct states than slots (not seen in the game): the nearest slot - one with the
            static int warned;  // same compare mode, else the last
            if (!warned++) LOG("[metal] a shader with %d textures uses more than %d sampler states: some share one\n", n, MSL_MAX_SAMPLERS);
            uint32_t cmp = desc[i] ? desc[i]->compare_mode : 0;
            for (k = 0; k < ns - 1; k++)
                if ((sdesc[k] ? sdesc[k]->compare_mode : 0) == cmp) break;
        }
        map[i] = (uint32_t)k;
    }
    return ns;
}

// (diagnostics) depth array layers noted while binding in a debug frame, dumped as raw floats once the GPU has finished
typedef struct { __strong id<MTLTexture> tex; int idx, slot, layer; bool stencil; } ArrPend;
static ArrPend g_arr_pend[16];
static int g_arr_n;
static void dump_pending_arrays(void) {
    for (int k = 0; k < g_arr_n; k++) {
        id<MTLTexture> t = g_arr_pend[k].tex;
        if (g_arr_pend[k].stencil) {  // the stencil aspect of a depth-stencil texture, one byte per pixel
            NSUInteger sn = t.width * t.height;
            id<MTLBuffer> sb = [dev newBufferWithLength:sn options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> sc = [renderer_queue() commandBuffer];
            id<MTLBlitCommandEncoder> sbl = [sc blitCommandEncoder];
            [sbl copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:sb destinationOffset:0
          destinationBytesPerRow:t.width destinationBytesPerImage:sn options:MTLBlitOptionStencilFromDepthStencil];
            [sbl endEncoding];
            [sc commit];
            [sc waitUntilCompleted];
            char sp[128];
            snprintf(sp, sizeof sp, "build/stc_%03d_%d.u8", g_arr_pend[k].idx, g_arr_pend[k].slot);
            FILE *sf = fopen(sp, "wb");
            if (sf) { fwrite(sb.contents, 1, sn, sf); fclose(sf); }
            g_arr_pend[k].tex = nil;
            continue;
        }
        NSUInteger bpp = t.pixelFormat == MTLPixelFormatR8Uint ? 1 : 4, n = t.width * t.height * bpp;
        id<MTLBuffer> rb = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> c = [renderer_queue() commandBuffer];
        id<MTLBlitCommandEncoder> bb = [c blitCommandEncoder];
        [bb copyFromTexture:t sourceSlice:g_arr_pend[k].layer sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:rb destinationOffset:0
             destinationBytesPerRow:t.width * bpp destinationBytesPerImage:n options:MTLBlitOptionNone];
        [bb endEncoding];
        [c commit];
        [c waitUntilCompleted];
        char path[128];
        snprintf(path, sizeof path, bpp == 1 ? "build/arr_%03d_%d_L%d.u8" : "build/arr_%03d_%d_L%d.f32", g_arr_pend[k].idx, g_arr_pend[k].slot, g_arr_pend[k].layer);
        FILE *ff = fopen(path, "wb");
        if (ff) { fwrite(rb.contents, 1, n, ff); fclose(ff); }
        g_arr_pend[k].tex = nil;
    }
    g_arr_n = 0;
}

static void bind_textures(int stage, ShaderInfo *si) {
    bool mapped = si->ntex > MSL_MAX_SAMPLERS;  // (fragment only: the translator refuses such vertex shaders)
    __strong id<MTLSamplerState> msmp[64];
    NvnSamplerDesc *mdesc[64];
    for (int i = 0; i < si->ntex; i++) {
        ShaderTexture *st_ = &si->tex[i];
        uint64_t h = shader_texture_handle(stage, st_);
        id<MTLTexture> tex = nil;
        id<MTLSamplerState> smp = nil;
        NvnTexture *e_dbg_tex = NULL;  // (diagnostics) the guest texture behind this slot
        uint32_t tic = h & 0xFFFFF, tsc = (uint32_t)(h >> 20) & 0xFFF;
        tex_sc[stage][i][0] = tex_sc[stage][i][1] = 1;
        if (i < 64) tex_wh[stage][i][0] = tex_wh[stage][i][1] = 0;
        if (h && st.tpool && tic < (uint32_t)st.tpool->count) {
            NvnTexEntry *e = &((NvnTexEntry *)st.tpool->entries)[tic];
            e_dbg_tex = e->tex;
            if (e->tex) tex = st_->stencil ? stencil_texture(e->tex) : sampled_texture_ex(e->tex, &e->view, e->has_view, st_->type, st_->is_image);
            if (e->tex && i < 64) {
                renderer_texture_scale(e->tex, &tex_sc[stage][i][0], &tex_sc[stage][i][1]);
                tex_wh[stage][i][0] = e->tex->width; tex_wh[stage][i][1] = e->tex->height;
            }
            if (!st_->is_image) tex = feedback_sample(e, tex);
            if (g_debug_frame && e->tex && e->tex->addr) {
                uint64_t total = tegra_total_size(&e->tex->layout), nz = 0;
                const uint8_t *p = (const uint8_t *)(uintptr_t)e->tex->addr;
                for (uint64_t k = 0; k < total; k++) nz += p[k] != 0;
                if (e->tex->width == 2048 && e->tex->height == 2048 && e->tex->format == 0x1) {  // (diagnostics) the label glyph atlas: raw bytes + the GPU copy
                    static uint64_t seen_atlas[4];
                    static int n_atlas;
                    int dup = 0;
                    for (int k = 0; k < n_atlas; k++) if (seen_atlas[k] == e->tex->addr) dup = 1;
                    if (!dup && n_atlas < 4) {
                        seen_atlas[n_atlas++] = e->tex->addr;
                        char ap[96];
                        snprintf(ap, sizeof ap, "build/atlas_%llx.bin", e->tex->addr);
                        FILE *af = fopen(ap, "wb");
                        if (af) { fwrite(p, 1, total, af); fclose(af); }
                        LOG("[dtex] atlas %s target %u stride %u flags %#x levels %u layers %u | gpu type %lu arr %lu\n", ap, e->tex->target,
                            e->tex->stride, e->tex->flags, e->tex->levels, e->tex->layout.layers,
                            (unsigned long)tex.textureType, (unsigned long)tex.arrayLength);
                        id<MTLTexture> abase = renderer_texture(e->tex, nil, false);
                        snprintf(ap, sizeof ap, "build/atlas_%llx_gpu.png", e->tex->addr);
                        renderer_save_texture(abase, ap);
                    }
                }
                if (e->tex->width == 1024 && e->tex->height == 2048) {
                    static int once;
                    if (!once++ || g_debug_frame) {
                        id<MTLTexture> base = renderer_texture(e->tex, nil, false);
                        LOG("[dtex] glyph cache target %u depth %u layers %u levels %u stride %u flags %#x base type %lu arrlen %lu\n",
                            e->tex->target, e->tex->depth, e->tex->layout.layers, e->tex->levels, e->tex->stride, e->tex->flags,
                            (unsigned long)base.textureType, (unsigned long)base.arrayLength);
                        LOG("[dtex] glyph view: has %d mask %#x levels %u+%u layers %u+%u fmt %#x target %u\n", e->has_view, e->view.setmask,
                            e->view.base_level, e->view.num_levels, e->view.min_layer, e->view.num_layers, e->view.format, e->view.target);
                        LOG("[dtex] glyph cache: mtl fmt %lu type %lu swizzle tex %d %d %d %d view(%d) %d %d %d %d, tex.swz %08x\n",
                            (unsigned long)base.pixelFormat, (unsigned long)tex.textureType, e->tex->swizzle[0], e->tex->swizzle[1],
                            e->tex->swizzle[2], e->tex->swizzle[3], e->has_view && (e->view.setmask & 8), e->view.swizzle[0],
                            e->view.swizzle[1], e->view.swizzle[2], e->view.swizzle[3],
                            (unsigned)(tex.swizzle.red | tex.swizzle.green << 8 | tex.swizzle.blue << 16 | tex.swizzle.alpha << 24));
                        renderer_save_texture(base, "build/glyph_gpu.png");
                        NvnSamplerDesc *sd = (h && st.spool && tsc < (uint32_t)st.spool->count) ? &((NvnSamplerDesc *)st.spool->entries)[tsc] : NULL;
                        if (sd) { const uint32_t *w = (const uint32_t *)sd; LOG("[dtex] glyph sampler words %08x %08x %08x %08x %08x %08x %08x %08x\n", w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7]); }
                    }
                }
                if (e->tex->width == 2 && e->tex->height == 2 && e->tex->depth == 6) {
                    static int once2;
                    if (!once2++) {
                        FILE *rf = fopen("build/raw_cube2.bin", "wb");
                        if (rf) { fwrite(p, 1, total, rf); fclose(rf); }
                        LOG("[dtex] cube2 levels %u layers %u bh %u layer_size %llu\n", e->tex->levels, e->tex->layout.layers,
                            e->tex->layout.block_height_log2, tegra_layer_size(&e->tex->layout));
                    }
                }
                if ((e->tex->flags & 0x10) && !getenv("NO_RAW")) {
                    static int nraw;
                    if (nraw++ < 2) {
                        char rp[64];
                        snprintf(rp, sizeof rp, "build/raw_%llx.bin", e->tex->addr);
                        FILE *rf = fopen(rp, "wb");
                        if (rf) { fwrite(p, 1, total, rf); fclose(rf); }
                        LOG("[dtex] linear texture stride %u -> %s\n", e->tex->stride, rp);
                    }
                }
                LOG("[dtex] slot %d tex %ux%u f%#x addr %llx size %llu nonzero %llu gpu_owned %d | swz %d %d %d %d view(%d,%#x) %d %d %d %d\n",
                    i, e->tex->width, e->tex->height, e->tex->format, e->tex->addr, total, nz,
                    renderer_is_gpu_owned(e->tex), e->tex->swizzle[0], e->tex->swizzle[1], e->tex->swizzle[2],
                    e->tex->swizzle[3], e->has_view && (e->view.setmask & 8), e->view.setmask, e->view.swizzle[0],
                    e->view.swizzle[1], e->view.swizzle[2], e->view.swizzle[3]);
                // (the GPU copy is saved below; the CPU bytes go next to it so the two can be compared offline)
                if (total <= (1u << 18)) {
                    char rp[64];
                    snprintf(rp, sizeof rp, "build/cpubin_%llx.bin", e->tex->addr);
                    static char seen_names[1024][64];
                    static int seen_n;
                    int dup = 0;
                    for (int k = 0; k < seen_n; k++) if (!strcmp(seen_names[k], rp)) { dup = 1; break; }
                    if (!dup && seen_n < 1024) {
                        strcpy(seen_names[seen_n++], rp);
                        FILE *rf = fopen(rp, "wb");
                        if (rf) { fwrite(p, 1, total, rf); fclose(rf); }
                    }
                }
            }
        }
        NvnSamplerDesc *sd = h && st.spool && tsc < (uint32_t)st.spool->count ? &((NvnSamplerDesc *)st.spool->entries)[tsc] : NULL;
        if (sd) smp = sampler_for(sd);
        if (st_->shadow) tex = shadow_slot_texture(tex, st_);
        if (!tex) tex = dummy_texture_ex(st_->type, st_->scalar_kind, st_->is_image);
        {   // LARECOMP_DUMMY_TEX=<fs addr or fsh>:<slot>,...: bind the neutral dummy texture to these fragment shader inputs (A/B tests)
            static uint64_t dfs[8];
            static int dslot[8], nd = -1;
            if (nd < 0) {
                nd = 0;
                for (const char *q = getenv("LARECOMP_DUMMY_TEX"); q && *q && nd < 8;) {
                    char *e;
                    dfs[nd] = strtoull(q, &e, 16);
                    dslot[nd++] = *e == ':' ? (int)strtol(e + 1, &e, 10) : -1;
                    q = e;
                    while (*q == ',') q++;
                }
            }
            if (stage == 1 && st.program && nd) {
                uint64_t mh = fnv64(si->msl ? si->msl : "");  // (address or MSL hash: addresses move between runs)
                for (int k = 0; k < nd; k++)
                    if ((dfs[k] == st.program->stages[1].code_addr || dfs[k] == mh) && dslot[k] == i) tex = dummy_texture_ex(st_->type, st_->scalar_kind, st_->is_image);
            }
        }
        if (!smp) smp = default_sampler();
        if (g_debug_frame && tex.textureType == MTLTextureType2D && stage == 1) {
            static int dn;
            char path[128];
            snprintf(path, sizeof path, "build/dtex_%03d_%d.png", dn++, i);
            LOG("[dtex]   %s mtl fmt %lu type %lu swz %d %d %d %d\n", path, (unsigned long)tex.pixelFormat,
                (unsigned long)tex.textureType, (int)tex.swizzle.red, (int)tex.swizzle.green, (int)tex.swizzle.blue,
                (int)tex.swizzle.alpha);
            renderer_save_texture(tex, path);
            snprintf(path, sizeof path, "build/dtex_%03d_%d_a.png", dn - 1, i);
            renderer_save_texture_alpha(tex, path);
        }
        if (g_debug_frame && st_->stencil && stage == 1 && e_dbg_tex && g_arr_n < 16) {  // (diagnostics) the stencil being sampled
            static int sn;
            id<MTLTexture> base = renderer_texture(e_dbg_tex, nil, false);
            if (base.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) g_arr_pend[g_arr_n++] = (ArrPend){base, sn++, i, 0, true};
        }
        if (g_debug_frame && tex.textureType == MTLTextureType2DArray && stage == 1 && tex.width >= 512 && !st_->is_image) {
            // (diagnostics) array textures (shadow cascades...): every layer (up to 4) as its own image
            static int an;
            int idx = an++;
            for (NSUInteger l = 0; l < tex.arrayLength && l < 4; l++) {
                id<MTLTexture> lv = [tex newTextureViewWithPixelFormat:tex.pixelFormat textureType:MTLTextureType2D
                                                                levels:NSMakeRange(0, 1) slices:NSMakeRange(l, 1)];
                char path[128];
                snprintf(path, sizeof path, "build/arr_%03d_%d_L%lu.png", idx, i, (unsigned long)l);
                LOG("[dtex]   %s array %lux%lu fmt %lu layer %lu\n", path, (unsigned long)tex.width, (unsigned long)tex.height,
                    (unsigned long)tex.pixelFormat, (unsigned long)l);
                if (lv) renderer_save_texture(lv, path);
                if ((tex.pixelFormat == MTLPixelFormatDepth32Float || tex.pixelFormat == MTLPixelFormatR8Uint) && g_arr_n < 16)
                    g_arr_pend[g_arr_n++] = (ArrPend){tex, idx, i, (int)l};
            }
        }
        if (stage == 0) { [enc setVertexTexture:tex atIndex:i]; [enc setVertexSamplerState:smp atIndex:i]; }
        else if (mapped) { [enc setFragmentTexture:tex atIndex:i]; msmp[i] = smp; mdesc[i] = sd; }
        else { [enc setFragmentTexture:tex atIndex:i]; [enc setFragmentSamplerState:smp atIndex:i]; }
    }
    if (mapped && stage == 1) {
        __strong id<MTLSamplerState> slot[MSL_MAX_SAMPLERS];
        uint32_t map[64];
        int ns = sampler_slots(si->ntex, msmp, mdesc, slot, map);
        for (int k = 0; k < MSL_MAX_SAMPLERS; k++) [enc setFragmentSamplerState:k < ns ? slot[k] : default_sampler() atIndex:k];
        [enc setFragmentBytes:map length:(NSUInteger)si->ntex * 4 atIndex:SMAP_BUFFER_INDEX];
    }
}

static void bind_cbufs(int stage, ShaderInfo *si) {
    for (int k = 0; k < 18; k++) {
        if (!(si->cbuf_mask & (1u << k))) continue;
        if (k == 0) {
            // driver constants: storage buffer bindings {addr_lo, addr_hi, size, 0} in a 0x100-byte table
            // per hardware stage at 0x110 + 0x100 * stage (vertex 0, fragment 4)
            uint32_t drv[0x800 / 4] = {0};
            uint32_t base = 0x110 + 0x100 * (stage == 1 ? 4 : 0);
            for (int i = 0; i < 16; i++) {
                uint32_t *e = &drv[(base + 16 * i) / 4];
                e[0] = (uint32_t)st.sbuf[stage][i].addr;
                e[1] = (uint32_t)(st.sbuf[stage][i].addr >> 32);
                e[2] = (uint32_t)st.sbuf[stage][i].size;
            }
            uint64_t size = si->cbuf_size[0] > sizeof drv ? sizeof drv : (si->cbuf_size[0] ? si->cbuf_size[0] : 256);
            uint64_t off = ring_alloc(drv, size);
            if (stage == 0) [enc setVertexBuffer:ring offset:off atIndex:0];
            else [enc setFragmentBuffer:ring offset:off atIndex:0];
            continue;
        }
        if (k == 1) {  // compiler constants stored after the shader code
            NvnShaderStage *ss = &st.program->stages[stage];
            uint64_t size = ss->const_size ? ss->const_size : 16;
            if (size < si->cbuf_size[1]) size = si->cbuf_size[1];
            uint64_t off = ring_alloc((void *)(uintptr_t)(ss->code_addr + ss->const_offset), size);
            if (stage == 0) [enc setVertexBuffer:ring offset:off atIndex:1];
            else [enc setFragmentBuffer:ring offset:off atIndex:1];
            continue;
        }
        int idx = k - cbuf_base;
        Range r = (idx >= 0 && idx < 18) ? st.ubuf[stage][idx] : (Range){0, 0};
        uint64_t size = si->cbuf_size[k];
        if (!r.addr) {
            static const uint8_t zeros[0x10000];
            uint64_t off = ring_alloc(zeros, size ? size : 256);
            if (stage == 0) [enc setVertexBuffer:ring offset:off atIndex:k];
            else [enc setFragmentBuffer:ring offset:off atIndex:k];
            continue;
        }
        if ((si->cbuf_dynamic & (1u << k)) && r.size) size = r.size > 0x10000 ? 0x10000 : r.size;  // indexed: whole buffer
        if (size > r.size && r.size) size = r.size;
        if (size < 16) size = 16;
        uint64_t off = ring_alloc((void *)(uintptr_t)r.addr, size);  // snapshot, as later CPU writes must not leak in
        if (stage == 0) [enc setVertexBuffer:ring offset:off atIndex:k];
        else [enc setFragmentBuffer:ring offset:off atIndex:k];
    }
}


// ------------------------------------------------------------------ compute
// Compute driver constants (c0): 0x200 work group counts, 0x210 + 16*i uniform buffers (compute has
// few hardware cbuf slots, so the compiler reads the rest through global memory), 0x310 + 16*i
// storage buffers; each table entry is {addr_lo, addr_hi, size, 0}.
typedef struct { id<MTLComputePipelineState> pipe; ShaderInfo *si; uint32_t local[3]; bool failed; } CsProg;
static NSMutableDictionary *g_cs_progs;  // code address + sampled texture types -> CsProg

static CsProg *compute_program(NvnProgram *p) {
    NvnShaderStage *ss = &p->stages[5];
    if (!ss->code_addr) return NULL;
    ShaderKey k = {0};
    texture_key(5, &k);
    NSString *key = [NSString stringWithFormat:@"%llx/%x/%x/%x/%x/%x", ss->code_addr, k.stencil_slots, k.sint_slots,
                    k.uint_slots, k.img_sint, k.img_uint];
    NSMutableDictionary *progs = g_cs_progs;
    if (!progs) progs = g_cs_progs = [NSMutableDictionary new];
    NSValue *v = progs[key];
    if (v) { CsProg *cp = v.pointerValue; return cp->failed ? NULL : cp; }
    CsProg *cp = calloc(1, sizeof *cp);
    progs[key] = [NSValue valueWithPointer:cp];
    backend_gwin_pick();
    maxwell_gmem_base = g_gwin_base;
    maxwell_gmem_size = g_gwin_max;
    cp->si = maxwell_translate((const uint8_t *)(uintptr_t)ss->code_addr, ss->const_offset ? ss->const_offset : 0x10000, STAGE_COMPUTE, &k);
    if (!cp->si->msl) { LOG("[compute] translate failed: %s (code %llx)\n", cp->si->error, ss->code_addr); cp->failed = true; return NULL; }
    for (int i = 0; i < 3; i++) {
        cp->local[i] = ss->control ? *(const uint32_t *)(ss->control + 0x748 + 4 * i) : 1;
        if (!cp->local[i]) cp->local[i] = 1;
    }
    if (getenv("LARECOMP_SAVE_MSL")) {
        mkdir("build/msl", 0755);
        char path[256];
        snprintf(path, sizeof path, "build/msl/%llx_cs.metal", ss->code_addr);
        FILE *f = fopen(path, "w"); if (f) { fputs(cp->si->msl, f); fclose(f); }
    }
    NSError *err = nil;
    id<MTLLibrary> lib = TIMED_COMPILE([dev newLibraryWithSource:@(cp->si->msl) options:game_shader_opts(false) error:&err]);
    id<MTLFunction> f = lib ? [lib newFunctionWithName:@"main0"] : nil;
    cp->pipe = f ? TIMED_COMPILE([dev newComputePipelineStateWithFunction:f error:&err]) : nil;
    if (!cp->pipe) {
        LOG("[compute] compile failed: %s\n%s\n", err.localizedDescription.UTF8String, cp->si->msl);
        cp->failed = true;
        return NULL;
    }
    LOG("[compute] program %llx: local size %ux%ux%u, %d cbufs mask %#x\n", ss->code_addr, cp->local[0], cp->local[1],
        cp->local[2], 0, cp->si->cbuf_mask);
    return cp;
}

static void dispatch_compute(uint32_t gx, uint32_t gy, uint32_t gz) {
    snap_reason = "compute"; snapshots_invalidate(NULL);
    if (!st.program || !gx || !gy || !gz) return;
    CsProg *cp = compute_program(st.program);
    if (!cp) return;
    static int trace = -1;
    if (trace < 0) trace = getenv("LARECOMP_TRACE_CS") != NULL;
#define CST(x) do { if (trace) { fprintf(stderr, "[cs] %s\n", x); fflush(stderr); } } while (0)
    CST("end_pass");
    end_pass();
    CST("encoder");
    id<MTLComputeCommandEncoder> ce = [cb() computeCommandEncoder];
    CST("pipeline");
    [ce setComputePipelineState:cp->pipe];
    ShaderInfo *si = cp->si;
    for (int k = 0; k < 18; k++) {
        if (!(si->cbuf_mask & (1u << k))) continue;
        uint64_t off;
        if (k == 0) {
            uint32_t drv[0x500 / 4] = {0};  // tables end at 0x310 + 16 * 16
            drv[0x200 / 4] = gx; drv[0x204 / 4] = gy; drv[0x208 / 4] = gz;
            for (int i = 0; i < 16; i++) {
                uint32_t *u = &drv[(0x210 + 16 * i) / 4];
                if (i < 18) { u[0] = (uint32_t)st.ubuf[5][i].addr; u[1] = (uint32_t)(st.ubuf[5][i].addr >> 32); u[2] = (uint32_t)st.ubuf[5][i].size; }
                uint32_t *e = &drv[(0x310 + 16 * i) / 4];
                e[0] = (uint32_t)st.sbuf[5][i].addr; e[1] = (uint32_t)(st.sbuf[5][i].addr >> 32); e[2] = (uint32_t)st.sbuf[5][i].size;
            }
            off = ring_alloc(drv, sizeof drv);
        } else if (k == 1) {
            NvnShaderStage *ss = &st.program->stages[5];
            uint64_t size = ss->const_size ? ss->const_size : 16;
            if (size < si->cbuf_size[1]) size = si->cbuf_size[1];
            off = ring_alloc((void *)(uintptr_t)(ss->code_addr + ss->const_offset), size);
        } else {
            int idx = k - cbuf_base;
            Range r = (idx >= 0 && idx < 18) ? st.ubuf[5][idx] : (Range){0, 0};
            uint64_t size = si->cbuf_size[k] ? si->cbuf_size[k] : 256;
            if (r.addr) {
                if ((si->cbuf_dynamic & (1u << k)) && r.size) size = r.size > 0x10000 ? 0x10000 : r.size;
                if (size > r.size && r.size) size = r.size;
                if (size < 16) size = 16;
                off = ring_alloc((void *)(uintptr_t)r.addr, size);
            } else {
                static const uint8_t zeros[0x10000];
                off = ring_alloc(zeros, size);
            }
        }
        [ce setBuffer:ring offset:off atIndex:k];
    }
    CST("gmem");
    if (si->uses_gmem) [ce setBuffer:g_guest_buffer offset:0 atIndex:GMEM_BUFFER_INDEX];
    CST("textures");
    bool cmapped = si->ntex > MSL_MAX_SAMPLERS;
    __strong id<MTLSamplerState> msmp[64];
    NvnSamplerDesc *mdesc[64];
    for (int i = 0; i < si->ntex; i++) {
        ShaderTexture *st_ = &si->tex[i];
        uint64_t h = shader_texture_handle(5, st_);
        id<MTLTexture> tex = nil;
        id<MTLSamplerState> smp = nil;
        uint32_t tic = h & 0xFFFFF, tsc = (uint32_t)(h >> 20) & 0xFFF;
        tex_sc[0][i][0] = tex_sc[0][i][1] = 1;
        if (h && st.tpool && tic < (uint32_t)st.tpool->count) {
            NvnTexEntry *e = &((NvnTexEntry *)st.tpool->entries)[tic];
            if (e->tex) tex = st_->stencil ? stencil_texture(e->tex) : sampled_texture_ex(e->tex, &e->view, e->has_view, st_->type, st_->is_image);
            if (e->tex && i < 64) renderer_texture_scale(e->tex, &tex_sc[0][i][0], &tex_sc[0][i][1]);
            if (!st_->is_image) tex = feedback_sample(e, tex);
        }
        NvnSamplerDesc *sd = h && st.spool && tsc < (uint32_t)st.spool->count ? &((NvnSamplerDesc *)st.spool->entries)[tsc] : NULL;
        if (sd) smp = sampler_for(sd);
        if (!smp) smp = default_sampler();
        if (st_->shadow) tex = shadow_slot_texture(tex, st_);
        [ce setTexture:tex ? tex : dummy_texture_ex(st_->type, st_->scalar_kind, st_->is_image) atIndex:i];
        if (cmapped) { msmp[i] = smp; mdesc[i] = sd; }
        else [ce setSamplerState:smp atIndex:i];
    }
    if (cmapped) {  // (more textures than sampler slots: as bind_textures)
        __strong id<MTLSamplerState> slot[MSL_MAX_SAMPLERS];
        uint32_t map[64];
        int ns = sampler_slots(si->ntex, msmp, mdesc, slot, map);
        for (int k = 0; k < MSL_MAX_SAMPLERS; k++) [ce setSamplerState:k < ns ? slot[k] : default_sampler() atIndex:k];
        [ce setBytes:map length:(NSUInteger)si->ntex * 4 atIndex:SMAP_BUFFER_INDEX];
    }
    if (si->uses_rscale) {
        float rs[65][4] = {{1, 1, 0, 0}};
        for (int i = 0; i < si->ntex && i < 64; i++) { rs[1 + i][0] = tex_sc[0][i][0]; rs[1 + i][1] = tex_sc[0][i][1]; }
        [ce setBytes:rs length:(NSUInteger)(1 + si->ntex) * 16 atIndex:RSCALE_BUFFER_INDEX];
    }
    CST("dispatch");
    extern bool g_debug_frame;
    if (g_debug_frame || trace_frame()) {
        extern uint64_t renderer_present_count(void);
        LOG("[dispatch] cs=%llx groups %ux%ux%u frame %llu ssbo:", st.program->stages[5].code_addr, gx, gy, gz,
            (unsigned long long)renderer_present_count());
        for (int i = 0; i < 16; i++) if (st.sbuf[5][i].addr) LOG(" %d(%llx,%llu)", i, st.sbuf[5][i].addr, st.sbuf[5][i].size);
        LOG(" ubo:");
        for (int i = 0; i < 18; i++) if (st.ubuf[5][i].addr) LOG(" %d(%llx,%llu)", i, st.ubuf[5][i].addr, st.ubuf[5][i].size);
        LOG(" gmem %d\n", si->uses_gmem);
    }
    [ce dispatchThreadgroups:MTLSizeMake(gx, gy, gz) threadsPerThreadgroup:MTLSizeMake(cp->local[0], cp->local[1], cp->local[2])];
    [ce endEncoding];
    CST("done");
    stat_dispatches++;
}

static MTLPrimitiveType prim_type(uint32_t mode, bool *ok) {
    *ok = true;
    switch (mode) {
    case 0: return MTLPrimitiveTypePoint;
    case 1: return MTLPrimitiveTypeLine;
    case 3: return MTLPrimitiveTypeLineStrip;
    case 4: return MTLPrimitiveTypeTriangle;
    case 5: return MTLPrimitiveTypeTriangleStrip;
    default: *ok = false; return MTLPrimitiveTypeTriangle;
    }
}

// Expand quads/fans/polygons into a triangle index list (32-bit) referencing the original vertices.
static id<MTLBuffer> expand_indices(uint32_t mode, uint32_t count, const void *indices, int itype, uint32_t first,
                                    uint32_t *out_count) {
    uint32_t tris = mode == 7 ? count / 4 * 2 : count >= 3 ? count - 2 : 0;
    uint32_t *out = malloc(tris * 3 * 4 + 4);
    uint32_t n = 0;
#define IDX(i) (indices ? (itype == 0 ? ((const uint8_t *)indices)[i] : itype == 1 ? ((const uint16_t *)indices)[i] : ((const uint32_t *)indices)[i]) : first + (i))
    if (mode == 7) {  // quads
        for (uint32_t q = 0; q + 3 < count; q += 4) {
            out[n++] = IDX(q); out[n++] = IDX(q + 1); out[n++] = IDX(q + 2);
            out[n++] = IDX(q); out[n++] = IDX(q + 2); out[n++] = IDX(q + 3);
        }
    } else {  // fan / polygon
        for (uint32_t i = 1; i + 1 < count; i++) { out[n++] = IDX(0); out[n++] = IDX(i); out[n++] = IDX(i + 1); }
    }
#undef IDX
    *out_count = n;
    id<MTLBuffer> b = [dev newBufferWithBytes:out length:n * 4 + 4 options:MTLResourceStorageModeShared];
    free(out);
    return b;
}

static void debug_draw(Prog *pr, CmdRec *r, bool indexed) {
    static uint64_t dump_fs = 1;
    if (dump_fs == 1) { const char *e = getenv("LARECOMP_DUMP_UBO"); dump_fs = e ? strtoull(e, NULL, 16) : 0; }
    if (dump_fs && st.program && (st.program->stages[1].code_addr == dump_fs || fnv64(pr->fi->msl ? pr->fi->msl : "") == dump_fs)) {  // (address or MSL hash: addresses move between runs)
        for (int i = 0; i < 18; i++) {
            if (!st.ubuf[1][i].addr) continue;
            const float *f = (const float *)(uintptr_t)st.ubuf[1][i].addr;
            LOG("[ubo] f%d (%llu):", i, st.ubuf[1][i].size);
            for (uint64_t k = 0; k < st.ubuf[1][i].size / 4 && k < 1200; k++) LOG(" %g", f[k]);
            LOG("\n");
        }
    }
    static int dump_vs = -1;  // LARECOMP_DUMP_VSUBO: every vertex-stage UBO (first 48 floats) of debug-frame draws
    if (dump_vs < 0) dump_vs = getenv("LARECOMP_DUMP_VSUBO") != NULL;
    for (int i = 0; dump_vs && i < 18; i++) {
        if (!st.ubuf[0][i].addr) continue;
        const float *f = (const float *)(uintptr_t)st.ubuf[0][i].addr;
        LOG("[vsubo] v%d (%llu):", i, st.ubuf[0][i].size);
        for (uint64_t k = 0; k < st.ubuf[0][i].size / 4 && k < 48; k++) LOG(" %g", f[k]);
        LOG("\n");
    }
    if (st.sbuf[0][0].addr && st.sbuf[0][0].size >= 64 && st.sbuf[0][0].size <= 8192) {
        int recw = (st.sbuf[0][0].size % 96 == 0 && st.sbuf[0][0].size % 64 != 0) ? 24 : 16;
        const float *f = (const float *)(uintptr_t)st.sbuf[0][0].addr;
        const uint32_t *u = (const uint32_t *)f;
        for (int g = 0; g < (int)(st.sbuf[0][0].size / (recw * 4)) && g < 6; g++) {
            LOG("[ssbo] rec%d:", g);
            for (int k = 0; k < recw; k++) LOG(" %g(%08x)", f[g * recw + k], u[g * recw + k]);
            LOG("\n");
        }
    }
    extern uint64_t renderer_present_count(void);
    LOG("[draw] p%d %s inst %llu frame %llu indirect %llx", debug_pass_no, indexed ? "e" : "a", indexed ? r->x[6] : r->x[4],
        (unsigned long long)renderer_present_count(), (unsigned long long)g_ind_off);
    LOG(" %s mode %llu first %llu count %llu prog vs=%llx fs=%llx fsh=%016llx fn=%p pr=%p | vs cb %#x fs cb %#x | ubufs:",
        indexed ? "elems" : "arrays", r->x[0], r->x[1], r->x[2], st.program->stages[0].code_addr, st.program->stages[1].code_addr,
        (unsigned long long)fnv64(pr->fi->msl ? pr->fi->msl : ""), (__bridge void *)pr->fs, (__bridge void *)pr,
        pr->vi->cbuf_mask, pr->fi->cbuf_mask);
    for (int s = 0; s < 2; s++)
        for (int i = 0; i < 18; i++)
            if (st.ubuf[s][i].addr) LOG(" %c%d(%llx,%llu)", s ? 'f' : 'v', i, st.ubuf[s][i].addr, st.ubuf[s][i].size);
    LOG(" | fubo0:");
    for (int i = 0; i < 6; i++)
        if (st.ubuf[1][i].addr) { const float *f = (const float *)(uintptr_t)st.ubuf[1][i].addr; LOG(" f%d=[%g %g %g %g]", i, f[0], f[1], f[2], f[3]); }
    if (st.ubuf[1][0].addr && st.ubuf[1][0].size >= 128) {  // (diagnostics) shader bank 3 is binding 0 (cbuf_base): text shaders keep tint / alpha scale at cb3[4..7]
        const float *f = (const float *)(uintptr_t)st.ubuf[1][0].addr;
        LOG(" | fcb3:");
        for (int i = 0; i < 8; i++) LOG(" [%g %g %g %g]", f[i * 4], f[i * 4 + 1], f[i * 4 + 2], f[i * 4 + 3]);
        if (st.ubuf[1][0].size >= 283 * 16 + 4) {  // the scene constants: the tone-map pass scales by [49].w, adds bloom by [251] and biases by [283].x
            LOG(" | cb3[49]=[%g %g %g %g] [251]=[%g %g %g %g] [283].x=%g", f[196], f[197], f[198], f[199],
                f[1004], f[1005], f[1006], f[1007], f[1132]);
        }
    }
    LOG(" | ssbo:");
    for (int sg = 0; sg < 2; sg++)
        for (int i = 0; i < 16; i++)
            if (st.sbuf[sg][i].addr) LOG(" %c%d(%llx,%llu)", sg ? 'f' : 'v', i, st.sbuf[sg][i].addr, st.sbuf[sg][i].size);
    LOG(" | tex:");
    for (int i = 0; i < pr->fi->ntex; i++) LOG(" off%u", pr->fi->tex[i].handle_offset);
    LOG(" bound:");
    for (int i = 0; i < 32; i++) {
        if (!st.tex[1][i]) continue;
        uint32_t tic = st.tex[1][i] & 0xFFFFF;
        NvnTexture *t = st.tpool && tic < (uint32_t)st.tpool->count ? ((NvnTexEntry *)st.tpool->entries)[tic].tex : NULL;
        if (t) LOG(" %d=[%ux%ux%u t%u f%#x fl%#x @%llx %s]", i, t->width, t->height, t->depth, t->target, t->format, t->flags,
                   (unsigned long long)t->addr, t->label);
        else LOG(" %d=%llx", i, st.tex[1][i]);
    }
    LOG(" | rt %d", st.rt.ncolor);
    for (int i = 0; i < st.rt.ncolor; i++) if (st.rt.color[i]) {
        LOG(" %ux%u/f%#x@%llx", st.rt.color[i]->width, st.rt.color[i]->height, st.rt.color[i]->format, (unsigned long long)st.rt.color[i]->addr);
        if (st.rt.color[i]->depth > 1 || st.rt.color[i]->target != 1)  // (diagnostics) layered / volume targets
            LOG("[tgt%u d%u L%u view%d %u+%u]", st.rt.color[i]->target, st.rt.color[i]->depth, st.rt.color[i]->layout.layers,
                st.rt.has_cview[i], st.rt.cview[i].min_layer, st.rt.cview[i].num_layers);
    }
    if (st.rt.depth) LOG(" d%#x", st.rt.depth->format);
    LOG(" | vp %.0f %.0f %.0f %.0f | attrs %#x streams:", st.viewport[0][0], st.viewport[0][1], st.viewport[0][2], st.viewport[0][3], pr->vi->attr_mask);
    for (int i = 0; i < st.nattrib; i++) LOG(" a%d(f%#x s%u o%u)", i, st.attrib[i] & 0xFF, (st.attrib[i] >> 8) & 0x1F, st.attrib[i] >> 13);
    for (int i = 0; i < 12; i++) if (st.vbuf[i].addr) LOG(" vb%d(%llx,%llu,stride %u div %u)", i, st.vbuf[i].addr, st.vbuf[i].size, st.stream[i][0], st.stream[i][1]);
    if (st.ubuf[0][0].addr && st.ubuf[0][0].size == 560) {
        const float *f = (const float *)(uintptr_t)st.ubuf[0][0].addr;
        LOG("\n  vs ubo0:");
        for (int i = 0; i < 36; i++) LOG("%s[%d] %g %g %g %g", i % 2 ? " " : "\n   ", i, f[i*4], f[i*4+1], f[i*4+2], f[i*4+3]);
    }
    if (st.poly[3] & 4) LOG(" po(en %#x) %g,%g,%g", st.poly[3], st.poly_offset[0], st.poly_offset[1], st.poly_offset[2]);
    LOG(" blend %#x ds %02x%02x%02x poly %02x%02x scissor %d,%d %dx%d chmask %08x stencil %02x%02x%02x%02x%02x ref %u/%u wm %x vm %x bf %d,%d,%d,%d,%d,%d\n", st.color_state[0], st.ds[0], st.ds[1], st.ds[2], st.poly[0], st.poly[1],
        st.scissor[0][0], st.scissor[0][1], st.scissor[0][2], st.scissor[0][3], st.channel_mask, st.ds[3], st.ds[4], st.ds[5], st.ds[6],
        st.ds[7], st.stencil_ref[0], st.stencil_ref[1], st.stencil_mask[0], st.stencil_vmask[0], st.blend[0][1], st.blend[0][2],
        st.blend[0][3], st.blend[0][4], st.blend[0][5], st.blend[0][6]);
}


// ---- pipeline cache keyed by a hash of the raw state that shapes the pipeline (avoids building a
// descriptor and a string key per draw)
// Shader function addresses may be reused after reloads or reboots. Include their generation in slow-cache keys.
static unsigned g_pipeline_gen;
static NSMutableDictionary *g_ready_pipes;

#define PIPE_TAB 8192
static struct { uint64_t key; void *pipe; } pipe_tab[PIPE_TAB];

// ---- live diagnostics: commands in build/dbgcmd, applied between passes (no restart to A/B a state).
// One command per line:
//   fs <fs code addr hex> <path.metal>   compile <path> as that program's fragment shader
//   reload                                recompile every program that already has a live shader from its file
//   cull <-1|0|1|2>                       -1: guest cull mode, 0 none, 1 front, 2 back
//   nodepth <0|1>                         depth compare Always (no write), like LARECOMP_NO_DEPTH_TEST
//   bias <factor> <units> <clamp>|off     force the polygon offset (shadow-acne A/B)
//   clear <rrggbbaa hex> [pass]           force that clear colour (pass < 0 or omitted: every pass)
//   nocolor                               stop the forced clear
//   dump                                  capture the next frame (same as touching build/dumpframe)
//   trace <1..120>                        log draws/dispatches for a bounded window, without texture dumps
//   list                                  log the programs and their fragment sources
static bool live_override_fs(Prog *pr, const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { LOG("[dbgcmd] cannot open %s\n", path); return false; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    char *b = malloc(n + 1);
    bool ok = b && fread(b, 1, n, f) == (size_t)n;
    fclose(f);
    if (!ok) { free(b); return false; }
    b[n] = 0;
    NSError *err = nil;
    id<MTLLibrary> fl = TIMED_COMPILE([dev newLibraryWithSource:@(b) options:game_shader_opts(false) error:&err]);
    id<MTLFunction> fn = fl ? [fl newFunctionWithName:@"main0"] : nil;
    if (!fn) {
        LOG("[dbgcmd] FS %llx: compile failed: %s\n", (unsigned long long)pr->fs_addr, err.localizedDescription.UTF8String);
        free(b);
        return false;
    }
    pr->fi->msl = b;  // (the translated source leaks: diagnostic path)
    pr->fs = fn;
    g_pipeline_gen++; // old slow-cache entries must not match recycled native function addresses
    pr->ov_active = true;
    snprintf(pr->ov_path, sizeof pr->ov_path, "%s", path);
    memset(pipe_tab, 0, sizeof pipe_tab);  // pipeline keys carry the function pointer: rebuild on the next draw
    LOG("[dbgcmd] FS %llx: live override from %s (msl %016llx)\n", (unsigned long long)pr->fs_addr, path,
        (unsigned long long)fnv64(b));
    return true;
}

static void debug_live_controls(void) {
    static int tick;
    if (tick++ & 15) return;
    if (access("build/dbgcmd", F_OK) != 0) return;
    FILE *f = fopen("build/dbgcmd", "r");
    if (!f) return;
    NSArray *progs;
    @synchronized(cache) { progs = [[cache allValues] copy]; }
    char line[512];
    while (fgets(line, sizeof line, f)) {
        char cmd[32] = "", arg[420] = "";
        if (sscanf(line, "%31s %419[^\n]", cmd, arg) < 1) continue;
        if (!strcmp(cmd, "cull")) {
            int c = atoi(arg);
            g_live_cull = (c == 0 || c == 1 || c == 2) ? c : -1;
            LOG("[dbgcmd] cull %d (-1 = guest)\n", g_live_cull);
        } else if (!strcmp(cmd, "nodepth")) {
            g_live_nodt = atoi(arg) != 0;
            LOG("[dbgcmd] nodepth %d\n", g_live_nodt);
        } else if (!strcmp(cmd, "bias")) {
            if (!strncmp(arg, "off", 3)) {
                g_live_bias_on = 0;
                LOG("[dbgcmd] bias: guest values\n");
            } else if (sscanf(arg, "%f %f %f", &g_live_bias_val[0], &g_live_bias_val[1], &g_live_bias_val[2]) == 3) {
                g_live_bias_on = 1;
                LOG("[dbgcmd] bias %g %g %g (factor units clamp)\n", g_live_bias_val[0], g_live_bias_val[1], g_live_bias_val[2]);
            }
        } else if (!strcmp(cmd, "clear")) {
            unsigned v = 0; int pass = -1;
            if (sscanf(arg, "%x %d", &v, &pass) >= 1) {
                g_ca_on = 1;
                g_ca_col = MTLClearColorMake(((v >> 24) & 255) / 255.0, ((v >> 16) & 255) / 255.0, ((v >> 8) & 255) / 255.0, (v & 255) / 255.0);
                g_ca_pass = pass;
                LOG("[dbgcmd] clear %08x pass %d\n", v, g_ca_pass);
            }
        } else if (!strcmp(cmd, "nocolor")) {
            g_ca_on = 0;
            LOG("[dbgcmd] forced clear off\n");
        } else if (!strcmp(cmd, "fs")) {
            unsigned long long addr = 0; char path[400] = "";
            if (sscanf(arg, "%llx %399s", &addr, path) == 2) {
                int hit = 0;
                for (id v in progs) if ([v isKindOfClass:[Prog class]]) {
                    Prog *pr = v;
                    if (pr->fs_addr == addr && pr->ready) hit += live_override_fs(pr, path);
                }
                LOG("[dbgcmd] fs %llx <- %s: %d program(s)\n", addr, path, hit);
            }
        } else if (!strcmp(cmd, "reload")) {
            int hit = 0;
            for (id v in progs) if ([v isKindOfClass:[Prog class]]) {
                Prog *pr = v;
                if (pr->ov_active && pr->ready) hit += live_override_fs(pr, pr->ov_path);
            }
            LOG("[dbgcmd] reload: %d program(s)\n", hit);
        } else if (!strcmp(cmd, "list")) {
            for (id v in progs) if ([v isKindOfClass:[Prog class]]) {
                Prog *pr = v;
                LOG("[dbgcmd] prog fs %llx vs %llx ov %d %s msl %016llx\n", (unsigned long long)pr->fs_addr,
                    (unsigned long long)pr->vs_addr, pr->ov_active, pr->ov_active ? pr->ov_path : "-",
                    (unsigned long long)(pr->fi->msl ? fnv64(pr->fi->msl) : 0));
            }
        } else if (!strcmp(cmd, "rt")) {
            uint64_t a[4] = {0}; int n = 0;
            const char *p = arg;
            while (*p && n < 4) {
                a[n++] = strtoull(p, (char **)&p, 16);
                if (*p == ',') p++; else break;
            }
            memcpy(g_live_log_rt, a, sizeof g_live_log_rt);
            LOG("[dbgcmd] rt %llx %llx %llx %llx\n", (unsigned long long)a[0], (unsigned long long)a[1],
                (unsigned long long)a[2], (unsigned long long)a[3]);
        } else if (!strcmp(cmd, "trace")) {
            extern uint64_t renderer_present_count(void);
            int n = atoi(arg);
            if (n < 1) n = 1;
            if (n > 120) n = 120;
            g_live_trace_end = renderer_present_count() + (uint64_t)n;
            LOG("[dbgcmd] trace until frame %llu\n", (unsigned long long)g_live_trace_end);
        } else if (!strcmp(cmd, "dump")) {
            FILE *d = fopen("build/dumpframe", "w");
            if (d) fclose(d);
            if (arg[0] >= '0' && arg[0] <= '9') {
                FILE *l = fopen("build/dumplen", "w");
                if (l) { fputs(arg, l); fclose(l); }
            }
            LOG("[dbgcmd] frame dump requested\n");
        } else {
            LOG("[dbgcmd] unknown command '%s'\n", cmd);
        }
    }
    fclose(f);
    remove("build/dbgcmd");
}


// Metal has 31 vertex-stage buffer slots. Keep shader arguments separate from the guest's logical streams.
static bool vertex_stream_slots(const ShaderInfo *info, bool debug, uint32_t *streams, uint8_t slots[16]) {
    *streams = 0;
    memset(slots, 0xff, 16);
    for (int i = 0; i < 32; i++) {
        if (!(info->attr_mask & (1u << i))) continue;
        if (i >= st.nattrib || !(st.attrib[i] & 0xff)) *streams |= 1u << 31;
        else {
            unsigned stream = (st.attrib[i] >> 8) & 0x1f;
            if (stream >= 16) return false;
            *streams |= 1u << stream;
        }
    }
    uint32_t used = info->cbuf_mask;
    if (info->uses_gmem) used |= 1u << GMEM_BUFFER_INDEX;
    if (info->uses_xfb) used |= 1u << XFB_BUFFER_INDEX;
    if (debug) used |= 1u << DBG_VS_BUFFER_INDEX;
    if (*streams & (1u << 31)) used |= 1u << 30; // constant default attributes
    for (int stream = 0; stream < 16; stream++) {
        if (!(*streams & (1u << stream))) continue;
        int slot = 18 + stream;
        if (slot >= 31 || (used & (1u << slot))) {
            for (slot = 30; slot >= 0 && (used & (1u << slot)); slot--) {}
        }
        if (slot < 0) return false;
        slots[stream] = (uint8_t)slot;
        used |= 1u << slot;
    }
    return true;
}

static uint64_t pipeline_state_hash(Prog *pr) {
    uint64_t h = 0xcbf29ce484222325ull;
    h = hmix(h, &pr, sizeof pr);
    h = hmix(h, &st.rt.ncolor, sizeof st.rt.ncolor);
    for (int i = 0; i < st.rt.ncolor && i < 8; i++) {
        NvnTexture *t = st.rt.color[i];
        uint32_t v[4] = {t ? t->format : 0, t ? t->samples : 0, st.rt.has_cview[i], st.rt.has_cview[i] ? st.rt.cview[i].format | (st.rt.cview[i].setmask << 16) : 0};
        h = hmix(h, v, sizeof v);
        h = hmix(h, st.blend[i], 8);
    }
    NvnTexture *depth = st.rt.depth;
    uint32_t dstate[4] = {depth ? depth->format : 0, depth ? depth->samples : 0, st.rt.has_dview,
                         st.rt.has_dview ? st.rt.dview.format | (st.rt.dview.setmask << 16) : 0};
    h = hmix(h, dstate, sizeof dstate);
    h = hmix(h, &st.nattrib, sizeof st.nattrib);
    h = hmix(h, st.attrib, sizeof st.attrib[0] * (size_t)(st.nattrib < 32 ? st.nattrib : 32));
    h = hmix(h, &st.nstream, sizeof st.nstream);
    h = hmix(h, st.stream, sizeof st.stream[0] * (size_t)(st.nstream < 16 ? st.nstream : 16));
    h = hmix(h, &st.channel_mask, sizeof st.channel_mask);
    h = hmix(h, &st.color_state[0], sizeof st.color_state[0]);
    h = hmix(h, &st.ms[0xC], 1);
    h = hmix(h, &g_raster_discard, 1);
    return h ? h : 1;
}

// (diagnostics) per-debug-frame log budget: counters restart on each captured frame instead of running dry after the first
static bool dbg_budget(int *n, uint64_t *frame, int limit) {
    extern uint64_t renderer_present_count(void);
    uint64_t f = renderer_present_count();
    if (*frame != f) { *frame = f; *n = 0; }
    return g_debug_frame && (*n)++ < limit;
}

// A draw of a handful of vertices - a full-screen pass: post-processing, a menu's backdrop, the composite into the
// window image - whose program is still compiling is waited for (a few ms, once) rather than skipped: skipping one left
// the whole frame black. Scene draws are still skipped until ready. (As ZA Recomp's Vulkan wait_built, 302bd07.)
static bool prog_ready_or_wait(Prog *pr, const CmdRec *r) {
    if (!pr || pr->ready) return pr != nil;
    if (r->x[2] > 6) return false;
    double t0 = now_ms();
    while (!pr->ready && !pr->failed && now_ms() - t0 < 2000) usleep(1000);
    static int n;
    if (n++ < 20) LOG("[metal] full-screen draw waited %.1f ms for its program\n", now_ms() - t0);
    return pr->ready;
}

// (diagnostics) classify a dropped draw. get_program returns nil both for a program missing a stage and for one whose
// shader never compiled, so the stage mask is what tells them apart; missing text is usually the second kind.
static void prog_skip_stat(Prog *pr, NvnProgram *p, CmdRec *r) {
    stat_skipped++;
    dbg_skips++;
    if (pr && !pr->failed) { stat_skip_wait++; return; }
    if (!pr && (p->stage_mask & 3) != 3) {
        stat_skip_none++;
        static int dbg_nostage; static uint64_t dbg_nostage_f;  // (diagnostics) a program with a stage missing: vertex-only xfb, or text that lost its fragment shader
        if (dbg_budget(&dbg_nostage, &dbg_nostage_f, 300))
            LOG("[metal] pass %d: draw op %d count %llu program has stage_mask %#x vs %llx fs %llx (rt %ux%u)\n", debug_pass_no, r->op,
                (unsigned long long)r->x[2], p->stage_mask, p->stages[0].code_addr, p->stages[1].code_addr,
                st.rt.color[0] ? st.rt.color[0]->width : 0, st.rt.color[0] ? st.rt.color[0]->height : 0);
        return;
    }
    stat_skip_failed++;
    static uint64_t seen[64];
    static int n;
    static int dbg_failed;
    uint64_t fs = pr ? pr->fs_addr : p->stages[1].code_addr;
    if (g_debug_frame && dbg_failed++ < 40)
        LOG("[metal] pass %d: draw op %d first %llu count %llu dropped, program never compiled (fs %llx)\n",
            debug_pass_no, r->op, (unsigned long long)r->x[1], (unsigned long long)r->x[2], fs);
    for (int i = 0; i < n; i++) if (seen[i] == fs) return;
    if (n < 64) seen[n++] = fs;
    LOG("[metal] %llu draws so far used a program that never compiled (fs %llx)\n", stat_draws, fs);
}

static void draw(CmdRec *r, bool indexed) {
    if (!(uint32_t)(indexed ? r->x[6] : r->x[4])) return;
    if (!st.program) {        stat_skipped++; stat_skip_none++; dbg_skips++;
        // (diagnostics) what the dropped draws are: they turn out to be transform-feedback passes (rasterizer
        // discard on, no pixels), not the profile screen's missing labels.
        static int dbg_noprog; static uint64_t dbg_noprog_f;
        if (dbg_budget(&dbg_noprog, &dbg_noprog_f, 40)) {
            LOG("[metal] pass %d: draw op %d idx %d first %llu count %llu with no program (rt %p %ux%u, vp %u,%u %ux%u)\n",
                debug_pass_no, r->op, indexed, (unsigned long long)r->x[1], (unsigned long long)r->x[2],
                (void *)st.rt.color[0], st.rt.color[0] ? st.rt.color[0]->width : 0,
                st.rt.color[0] ? st.rt.color[0]->height : 0,
                (unsigned)st.viewport[0][0], (unsigned)st.viewport[0][1],
                (unsigned)st.viewport[0][2], (unsigned)st.viewport[0][3]);
            op_ring_dump(28);
        }
        return;
    }
    dbg_draws++;
    static bool logged_modes;
    if (!logged_modes) {
        logged_modes = true;
        const char *cb = getenv("LARECOMP_CBUF_BASE"), *tb = getenv("LARECOMP_TEX_BASE");
        if (cb) cbuf_base = atoi(cb);
        if (tb) tex_base = atoi(tb);
    }
    ShaderKey vkey = {0}, fkey = {0};
    vkey.flip_y = fkey.flip_y = nvn_window_origin() == 0;
    vkey.depth_minus_one = nvn_depth_mode() == 0;
    for (int i = 0; i < st.nattrib; i++) vkey.attr_kind[i] = (uint8_t)attr_kind(st.attrib[i] & 0xFF);
    for (int i = 0; i < st.rt.ncolor; i++) if (st.rt.color[i]) fkey.rt_kind[i] = (uint8_t)rt_kind(st.rt.color[i]->format);
    texture_key(0, &vkey);
    texture_key(1, &fkey);
    if (g_xfb_on && st.program->stages[0].control) {  // the program's transform feedback layout (its control section)
        const uint8_t *ctl = st.program->stages[0].control;
        for (int b = 0; b < 4; b++) {
            vkey.xfb_count[b] = (uint8_t)*(const uint32_t *)(ctl + 0x4DC + 0x80 * b);
            vkey.xfb_stride[b] = *(const uint16_t *)(ctl + 0x6DC + 2 * b);
        }
    }
    vkey.xfb_void = g_raster_discard || !(st.program->stage_mask & 2);
    Prog *pr = get_program(st.program, &vkey, &fkey);
    if (!prog_ready_or_wait(pr, r)) { prog_skip_stat(pr, st.program, r); return; }
    if (g_rt_plane < 0 && pr->vi->writes_layer && st.rt.ncolor && st.rt.color[0] && st.rt.color[0]->target == 2 &&
        st.rt.color[0]->depth > 1) {  // (target 2: 3D)
        uint32_t ni = indexed ? (uint32_t)r->x[6] : (uint32_t)r->x[4], nb = indexed ? (uint32_t)r->x[5] : (uint32_t)r->x[3];
        CmdRec c = *r;
        for (uint32_t k = 0; k < ni && k < st.rt.color[0]->depth; k++) {
            if (indexed) { c.x[6] = 1; c.x[5] = nb + k; } else { c.x[4] = 1; c.x[3] = nb + k; }
            g_rt_plane = (int)k;
            st.rt_dirty = true;
            draw(&c, indexed);
        }
        g_rt_plane = -1;
        st.rt_dirty = true;
        return;
    }
    {   // mirror mode (runtime/hle/mirror.c): the scene's composite into the window image is drawn mirrored - the
        // unblended full-screen draw sampling an image the window's size (the window images also serve as scratch
        // targets earlier in the frame: those draws sample smaller images; the HUD after it blends)
        extern bool mirror_draw(bool composite);
        bool composite = false;
        if (st.rt.ncolor && st.rt.color[0] && renderer_texture_presented(st.rt.color[0]) && !(st.color_state[0] & 1) &&
            r->x[2] <= 6 && st.viewport[0][0] == 0 && st.viewport[0][1] == 0 &&
            st.viewport[0][2] >= st.rt.color[0]->width && st.viewport[0][3] >= st.rt.color[0]->height && pr->fi->ntex) {
            NvnTexture *t0 = shader_texture_object(1, &pr->fi->tex[0]);
            composite = t0 && t0->width == st.rt.color[0]->width && t0->height == st.rt.color[0]->height;
        }
        if (mirror_draw(composite)) {  // (the vertex flip mirrors a composite drawn with uvs, the fragment one a
            vkey.flip_x = fkey.flip_x = true;  // composite reading pixel positions; get_program keys on vkey)
            pr = get_program(st.program, &vkey, &fkey);
            if (!prog_ready_or_wait(pr, r)) { prog_skip_stat(pr, st.program, r); return; }
        }
    }
    {   // The hash of the current fragment shader's code (debug logs, LARECOMP_SKIP_FSHASH, g_cur_fs_hash)
        static uint64_t last_fs, last_hash;
        uint64_t fs = st.program->stages[1].code_addr;
        if (fs != last_fs) {
            last_fs = fs;
            last_hash = fs ? hmix(1469598103934665603ull, (const void *)(uintptr_t)(fs + 0x30), 0x200) : 0;
        }
        static uint64_t log_hash = 1;
        if (log_hash == 1) log_hash = getenv("LARECOMP_LOG_FSHASH") ? 0 : 2;
        if (!log_hash && g_debug_frame) LOG("[fshash] fs=%llx hash %016llx\n", fs, last_hash);
        {   // LARECOMP_SKIP_FSHASH=h1,h2,...: drop draws using these fragment shaders (find which draw makes what)
            static uint64_t skip[16];
            static int nskip = -1;
            if (nskip < 0) {
                nskip = 0;
                for (const char *p = getenv("LARECOMP_SKIP_FSHASH"); p && *p && nskip < 16;) {
                    skip[nskip++] = strtoull(p, (char **)&p, 16);
                    while (*p == ',') p++;
                }
            }
            if (nskip) {  // (also the MSL hash, fsh= in the [draw] log: stable across runs, unlike shader addresses)
                uint64_t mh = pr && pr->fi && pr->fi->msl ? fnv64(pr->fi->msl) : 0;
                for (int i = 0; i < nskip; i++) if (last_hash == skip[i] || (mh && mh == skip[i])) { stat_skipped++; return; }
            }
            {   // LARECOMP_SKIP_FSADDR=a1,a2,...: the same by guest fragment shader address (the `fs=` of the [draw] log)
                static uint64_t askip[16];
                static int naskip = -1;
                if (naskip < 0) {
                    naskip = 0;
                    for (const char *p = getenv("LARECOMP_SKIP_FSADDR"); p && *p && naskip < 16;) {
                        askip[naskip++] = strtoull(p, (char **)&p, 16);
                        while (*p == ',') p++;
                    }
                }
                for (int i = 0; i < naskip; i++) if (st.program && st.program->stages[1].code_addr == askip[i]) { stat_skipped++; return; }
            }
        }
        g_cur_fs_hash = last_hash;
        if (last_hash == 0x71fe31bbf03c3515ull && ENV("LARECOMP_LOG_INDOOR")) {
            static uint64_t lf;
            extern uint64_t renderer_present_count(void);
            if (renderer_present_count() != lf) {
                lf = renderer_present_count();
                LOG("[backdrop] frame %llu count %llu rt %ux%u vp %.0f %.0f %.0f %.0f scissor %d %d %d %d\n", (unsigned long long)lf, r->x[2],
                    st.rt.ncolor && st.rt.color[0] ? st.rt.color[0]->width : 0, st.rt.ncolor && st.rt.color[0] ? st.rt.color[0]->height : 0,
                    st.viewport[0][0], st.viewport[0][1], st.viewport[0][2], st.viewport[0][3], st.scissor[0][0], st.scissor[0][1],
                    st.scissor[0][2], st.scissor[0][3]);
            }
        }
    }
    static int log_rt_w = -1, log_rt_h;
    if (log_rt_w < 0) { const char *e = getenv("LARECOMP_LOG_RT"); log_rt_w = 0; if (e) sscanf(e, "%dx%d", &log_rt_w, &log_rt_h); }
    static uint64_t log_rt_addr = 1;
    if (log_rt_addr == 1) { const char *e = getenv("LARECOMP_LOG_RT_ADDR"); log_rt_addr = e ? strtoull(e, NULL, 16) : 0; }
    bool addr_hit = false;
    for (int q = 0; q < 4 && !addr_hit; q++) if (g_live_log_rt[q])
        for (int i = 0; i < st.rt.ncolor; i++)
            if (st.rt.color[i] && st.rt.color[i]->addr <= g_live_log_rt[q] + 0x40000 && st.rt.color[i]->addr + 0x40000 >= g_live_log_rt[q]) addr_hit = true;
    for (int i = 0; log_rt_addr && i < st.rt.ncolor; i++)
        if (st.rt.color[i] && st.rt.color[i]->addr <= log_rt_addr + 0x40000 && st.rt.color[i]->addr + 0x40000 >= log_rt_addr) addr_hit = true;
    if (addr_hit) LOG("[rtaddr] rt0 addr %llx\n", st.rt.color[0] ? st.rt.color[0]->addr : 0);
    if (g_debug_frame || trace_frame() || addr_hit || (log_rt_w && st.rt.ncolor && st.rt.color[0] && (int)st.rt.color[0]->width == log_rt_w &&
                          (int)st.rt.color[0]->height == log_rt_h))
        debug_draw(pr, r, indexed);
    resolve_feedback(pr);
    // this draw's writes make snapshots of its attachments stale
    snap_reason = "draw-depthwrite";
    if (st.rt.depth && st.ds[0] && st.ds[1]) snapshots_invalidate(st.rt.depth);  // stencil-only writes: shaders sample depth
    snap_reason = "draw-colorwrite";
    for (int i = 0; i < st.rt.ncolor; i++)
        if (st.rt.color[i] && ((st.channel_mask >> (i * 4)) & 0xF)) snapshots_invalidate(st.rt.color[i]);
    begin_pass();

    uint32_t used_streams;
    uint8_t stream_slots[16];
    bool dbg_this = maxwell_dbg_vs && (const uint8_t *)(uintptr_t)st.program->stages[0].code_addr == maxwell_dbg_vs;
    if (!vertex_stream_slots(pr->vi, dbg_this, &used_streams, stream_slots)) {
        static int logged;
        if (logged++ < 4) LOG("[metal] vertex stream buffer slots unavailable\n");
        stat_skipped++; dbg_skips++; return;
    }
    // pipeline
    uint64_t phash = pipeline_state_hash(pr);
    phash = hmix(phash, stream_slots, sizeof stream_slots);
    if (!phash) phash = 1;
    uint32_t pslot = (uint32_t)(phash ^ (phash >> 29)) & (PIPE_TAB - 1);
    while (pipe_tab[pslot].key && pipe_tab[pslot].key != phash) pslot = (pslot + 1) & (PIPE_TAB - 1);
    id<MTLRenderPipelineState> pipe = pipe_tab[pslot].key ? (__bridge id<MTLRenderPipelineState>)pipe_tab[pslot].pipe : nil;
    if (!pipe) {
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = pr->vs;
    pd.fragmentFunction = pr->fs;
    if (!pr->fs || g_raster_discard) pd.rasterizationEnabled = NO;  // transform feedback: the vertex stage runs, nothing is drawn
    pd.label = [NSString stringWithFormat:@"fsh%016llx", (unsigned long long)fnv64(pr->fi->msl ? pr->fi->msl : "")];
    // Metal requires the topology class when a vertex function picks the render target layer itself (array / cube
    // render targets; without this the pipeline fails to build and every layered draw is skipped).
    if (pr->vi && pr->vi->writes_layer) pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    attachment_formats(pd);
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    for (int i = 0; i < 32; i++) {
        if (!(pr->vi->attr_mask & (1u << i))) continue;
        uint32_t a = i < st.nattrib ? st.attrib[i] : 0x2E;
        uint32_t fmt = a & 0xFF, stream = (a >> 8) & 0x1F, off = a >> 13;
        if (i >= st.nattrib || fmt == 0) {
            // unbound attribute: read zeros from a constant stream
            vd.attributes[i].format = MTLVertexFormatFloat4;
            vd.attributes[i].offset = 0;
            vd.attributes[i].bufferIndex = 30;
            vd.layouts[30].stepFunction = MTLVertexStepFunctionConstant;
            vd.layouts[30].stepRate = 0;
            vd.layouts[30].stride = 16;
            used_streams |= 1u << 31;
            continue;
        }
        vd.attributes[i].format = vertex_format(fmt);
        vd.attributes[i].offset = off;
        vd.attributes[i].bufferIndex = stream_slots[stream];
        used_streams |= 1u << stream;
        (void)is_int_format;
    }
    for (int s = 0; s < 16; s++) {
        if (!(used_streams & (1u << s))) continue;
        unsigned slot = stream_slots[s];
        uint32_t stride = s < st.nstream ? st.stream[s][0] : 0, div = s < st.nstream ? st.stream[s][1] : 0;
        if (stride == 0) { vd.layouts[slot].stepFunction = MTLVertexStepFunctionConstant; vd.layouts[slot].stepRate = 0; vd.layouts[slot].stride = 16; }
        else {
            vd.layouts[slot].stride = (stride + 3) & ~3u;
            if (div) { vd.layouts[slot].stepFunction = MTLVertexStepFunctionPerInstance; vd.layouts[slot].stepRate = div; }
        }
    }
    pd.vertexDescriptor = vd;
    for (int i = 0; i < st.rt.ncolor && i < 8; i++) {
        if (!st.rt.color[i]) continue;
        MTLRenderPipelineColorAttachmentDescriptor *ca = pd.colorAttachments[i];
        uint32_t m = (st.channel_mask >> (i * 4)) & 0xF;
        ca.writeMask = (m & 1 ? MTLColorWriteMaskRed : 0) | (m & 2 ? MTLColorWriteMaskGreen : 0) |
                       (m & 4 ? MTLColorWriteMaskBlue : 0) | (m & 8 ? MTLColorWriteMaskAlpha : 0);
        bool blend_on = (st.color_state[0] >> i) & 1;
        if (blend_on && !rt_kind(st.rt.color[i]->format)) {
            uint8_t *b = st.blend[i];
            ca.blendingEnabled = YES;
            ca.sourceRGBBlendFactor = blend_factor(b[1]);
            ca.destinationRGBBlendFactor = blend_factor(b[2]);
            ca.sourceAlphaBlendFactor = blend_factor(b[3]);
            ca.destinationAlphaBlendFactor = blend_factor(b[4]);
            ca.rgbBlendOperation = blend_op(b[5]);
            ca.alphaBlendOperation = blend_op(b[6]);
        }
    }
    pd.alphaToCoverageEnabled = st.ms[0xC] != 0;
    NSMutableString *pk = [NSMutableString stringWithFormat:@"%u %p %p %lu %lu", g_pipeline_gen, pr->vs, pr->fs,
                           (unsigned long)pd.depthAttachmentPixelFormat, (unsigned long)pd.stencilAttachmentPixelFormat];
    for (int i = 0; i < 8; i++) {
        MTLRenderPipelineColorAttachmentDescriptor *ca = pd.colorAttachments[i];
        [pk appendFormat:@" %lu/%lu/%d/%lu/%lu/%lu/%lu/%lu/%lu", (unsigned long)ca.pixelFormat, (unsigned long)ca.writeMask,
                         ca.blendingEnabled, (unsigned long)ca.sourceRGBBlendFactor, (unsigned long)ca.destinationRGBBlendFactor,
                         (unsigned long)ca.sourceAlphaBlendFactor, (unsigned long)ca.destinationAlphaBlendFactor,
                         (unsigned long)ca.rgbBlendOperation, (unsigned long)ca.alphaBlendOperation];
    }
    for (int i = 0; i < 32; i++)
        if (pr->vi->attr_mask & (1u << i))
            [pk appendFormat:@" a%d:%lu/%lu/%lu", i, (unsigned long)vd.attributes[i].format, (unsigned long)vd.attributes[i].offset, (unsigned long)vd.attributes[i].bufferIndex];
    for (int s = 0; s < 31; s++)
        [pk appendFormat:@" l%lu/%lu/%lu", (unsigned long)vd.layouts[s].stride, (unsigned long)vd.layouts[s].stepFunction, (unsigned long)vd.layouts[s].stepRate];
    [pk appendFormat:@" s%lu a%d", (unsigned long)pd.rasterSampleCount, pd.alphaToCoverageEnabled];
    if (!pd.rasterizationEnabled) [pk appendString:@" nr"];
    id pobj = cache[pk];
    NSMutableDictionary *ready_pipes = g_ready_pipes;  // async pipeline builds finished on Metal's threads
    static id pending;
    if (!ready_pipes) { ready_pipes = g_ready_pipes = [NSMutableDictionary new]; pending = [NSObject new]; }
    if (pobj == pending) {
        @synchronized(ready_pipes) {
            id done = ready_pipes[pk];
            if (done) { [ready_pipes removeObjectForKey:pk]; cache[pk] = done; pobj = done; }
        }
        if (pobj == pending) { stat_skipped++; stat_skip_wait++; dbg_skips++; return; }
    }
    if (!pobj && pipeline_archive() && g_archive_read) {
        // in the last run's archive: built at once without compiling; a miss fails right away and goes the usual way
        pd.binaryArchives = @[g_archive_read];
        pobj = [dev newRenderPipelineStateWithDescriptor:pd options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:nil];
        pd.binaryArchives = nil;
        if (pobj) { cache[pk] = pobj; g_archive_hits++; pipeline_archive_add([pd copy], pr); }  // the new file keeps what is still used
    }
    if (!pobj) {
        if (sync_shaders() || r->x[2] <= 6) {  // a full-screen draw waits for its pipeline too, as for its program (prog_ready_or_wait)
            NSError *err;
            pobj = TIMED_COMPILE([dev newRenderPipelineStateWithDescriptor:pd error:&err]);
            if (!pobj) {
                static int n;
                if (n++ < 10) LOG("[metal] pipeline failed: %s\n", err.localizedDescription.UTF8String);
                pobj = [NSNull null];
            } else pipeline_archive_add([pd copy], pr);
            cache[pk] = pobj;
        } else {
            cache[pk] = pending;
            NSString *k = [pk copy];
            MTLRenderPipelineDescriptor *pdc = [pd copy];
            double t0 = now_ms();
            [dev newRenderPipelineStateWithDescriptor:pd completionHandler:^(id<MTLRenderPipelineState> ps, NSError *e) {
                if (!ps) { static int n; if (n++ < 10) LOG("[metal] pipeline failed: %s\n", e.localizedDescription.UTF8String); }
                else pipeline_archive_add(pdc, pr);
                @synchronized(ready_pipes) { ready_pipes[k] = ps ? (id)ps : (id)[NSNull null]; }
                @synchronized(cache) { stat_compile_ms += now_ms() - t0; }
                __atomic_fetch_add(&stat_compiles, 1, __ATOMIC_RELAXED);
            }];
            stat_skipped++;
            stat_skip_wait++;  // counted as "compiling", like a draw whose shaders are not ready yet
            dbg_skips++;
            return;
        }
    }
    if (pobj == [NSNull null]) { stat_skipped++; dbg_skips++; return; }
    pipe = pobj;
    pipe_tab[pslot].key = phash;
    pipe_tab[pslot].pipe = (__bridge void *)pipe;  // retained by the cache dictionary
    }
    g_last_pipe_label = pipe.label;
    [enc setRenderPipelineState:pipe];

    // depth / stencil
    static uint64_t last_dsk;
    static id<MTLDepthStencilState> last_dss;
    bool has_depth = st.rt.depth && renderer_format_is_depth(st.rt.depth->format) && st.rt.depth->format != 0x31;
    bool has_stencil = st.rt.depth && renderer_format_has_stencil(st.rt.depth->format);
    uint8_t aspects = (has_depth ? 1 : 0) | (has_stencil ? 2 : 0);
    uint64_t dsk = hmix(hmix(hmix(0xcbf29ce484222325ull, st.ds, 8), st.stencil_mask, sizeof st.stencil_mask), st.stencil_vmask, sizeof st.stencil_vmask);
    dsk = hmix(dsk, &aspects, sizeof aspects);
    id<MTLDepthStencilState> dss = dsk == last_dsk ? last_dss : nil;
    NSString *dk = nil;
    if (!dss) {
        dk = [NSString stringWithFormat:@"ds %02x%02x%02x%02x%02x%02x%02x%02x %x %x %x %x d%d s%d nd%d", st.ds[0], st.ds[1], st.ds[2], st.ds[3],
                    st.ds[4], st.ds[5], st.ds[6], st.ds[7], st.stencil_mask[0], st.stencil_vmask[0], st.stencil_mask[1], st.stencil_vmask[1],
                    has_depth, has_stencil, g_live_nodt];
        dss = cache[dk];
    }
    if (!dss) {
        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
        static int nodt = -1;
        if (nodt < 0) nodt = getenv("LARECOMP_NO_DEPTH_TEST") != NULL;
        // Without a depth target NVN ignores the depth test; Metal instead compares against an implicit 0, so a guest
        // that leaves the test enabled (e.g. the scene tonemap pass) loses every fragment.
        if (has_depth && st.ds[0] && !nodt && !g_live_nodt) { dd.depthCompareFunction = compare_fn(st.ds[2]); dd.depthWriteEnabled = st.ds[1] != 0; }
        else { dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = NO; }
        if (has_stencil && st.ds[3]) {
            uint32_t ops = st.ds[5] | st.ds[6] << 8 | st.ds[7] << 16;
            for (int f = 0; f < 2; f++) {
                MTLStencilDescriptor *sd = [MTLStencilDescriptor new];
                sd.stencilCompareFunction = compare_fn(f ? st.ds[4] >> 4 : st.ds[4] & 0xF);
                uint32_t o = f ? ops >> 12 : ops;
                sd.stencilFailureOperation = stencil_op(o & 0xF);
                sd.depthFailureOperation = stencil_op((o >> 4) & 0xF);
                sd.depthStencilPassOperation = stencil_op((o >> 8) & 0xF);
                sd.readMask = st.stencil_vmask[f] & 0xFF;
                sd.writeMask = st.stencil_mask[f] & 0xFF;
                if (f) dd.backFaceStencil = sd; else dd.frontFaceStencil = sd;
            }
        }
        dss = [dev newDepthStencilStateWithDescriptor:dd];
        cache[dk] = dss;
    }
    [enc setDepthStencilState:dss];
    last_dsk = dsk;
    last_dss = dss;
    [enc setStencilFrontReferenceValue:st.stencil_ref[0] backReferenceValue:st.stencil_ref[1]];
    [enc setBlendColorRed:st.blend_color[0] green:st.blend_color[1] blue:st.blend_color[2] alpha:st.blend_color[3]];

    // rasterizer
    uint8_t cull = st.poly[0];
    if (vkey.flip_x) cull = 0;  // (mirror mode's composite: one full-screen quad, either winding)
    static int nocull = -1;  // LARECOMP_NO_CULL: A/B test for a wrong winding convention
    if (nocull < 0) nocull = getenv("LARECOMP_NO_CULL") != NULL;
    if (nocull) cull = 0;
    if (g_live_cull >= 0) cull = (uint8_t)g_live_cull;
    [enc setCullMode:cull == 1 ? MTLCullModeFront : cull == 2 ? MTLCullModeBack : MTLCullModeNone];
    bool ccw = st.poly[1] == 1;
    [enc setFrontFacingWinding:(ccw != vkey.flip_y) ? MTLWindingCounterClockwise : MTLWindingClockwise];
    [enc setTriangleFillMode:st.poly[2] == 1 ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
    // Depth clamp: Z-A's shadow casters outside the light's clip planes (the NPCs' shadows on the plaza) are clamped, not
    // clipped (as ZA Recomp 4d5174e). LARECOMP_NO_DEPTH_CLAMP=1 ignores it (A/B).
    static int noclamp = -1;
    if (noclamp < 0) noclamp = getenv("LARECOMP_NO_DEPTH_CLAMP") != NULL;
    [enc setDepthClipMode:st.depth_clamp && !noclamp ? MTLDepthClipModeClamp : MTLDepthClipModeClip];
    {   // polygon offset (decals on floors: without it they z-fight). Enables: bit 2 = fill (NVN PolygonOffsetEnable)
        static float last[3] = {0, 0, 0};
        float f[3] = {0, 0, 0};
        static int off = -1;  // LARECOMP_NO_DEPTH_BIAS: ignore the game's polygon offset (A/B tests)
        if (off < 0) off = getenv("LARECOMP_NO_DEPTH_BIAS") != NULL;
        if (g_live_bias_on) memcpy(f, g_live_bias_val, sizeof f);
        else if ((st.poly[3] & 4) && !off) memcpy(f, st.poly_offset, sizeof f);
        static int nlog;
        if ((st.poly[3] & 4) && nlog < 3 && ENV("LARECOMP_LOG_BIAS")) { nlog++; LOG("[bias] factor %g units %g clamp %g\n", st.poly_offset[0], st.poly_offset[1], st.poly_offset[2]); }
        if (memcmp(f, last, sizeof f) || enc != last_bias_enc) {
            [enc setDepthBias:f[1] slopeScale:f[0] clamp:f[2]];
            memcpy(last, f, sizeof f);
            last_bias_enc = enc;
        }
    }
    float *vp = st.viewport[0];
    float zn = st.depth_range[0][0], zf = st.depth_range[0][1];

    // resources
    bind_cbufs(0, pr->vi);
    bind_cbufs(1, pr->fi);
    if (pr->vi->uses_gmem) [enc setVertexBuffer:g_guest_buffer offset:0 atIndex:GMEM_BUFFER_INDEX];
    if (pr->vi->uses_xfb) {  // (word offset in the gmem window, size in words, on) of each bound buffer
        uint32_t xt[4][4] = {{0}};
        for (int b = 0; b < 4; b++) {
            uint64_t a = g_xfb_addr[b];
            if (!a || a < g_gwin_base || a - g_gwin_base + g_xfb_size[b] > g_gwin_max || (a & 3)) continue;
            xt[b][0] = (uint32_t)((a - g_gwin_base) >> 2); xt[b][1] = (uint32_t)(g_xfb_size[b] >> 2); xt[b][2] = 1;
        }
        [enc setVertexBytes:xt length:sizeof xt atIndex:XFB_BUFFER_INDEX];
        // a draw may read what an earlier one of the session wrote (skinning stages chained through the buffers)
        static int nobar = -1;
        if (nobar < 0) nobar = getenv("LARECOMP_NO_XFB_BARRIER") != NULL;
        if (g_xfb_dirty && !nobar && @available(macOS 13.0, *))
            [enc memoryBarrierWithScope:MTLBarrierScopeBuffers afterStages:MTLRenderStageVertex beforeStages:MTLRenderStageVertex];
        g_xfb_dirty = true;
        if (g_debug_frame)
            LOG("[xfb] vs %llx indexed %d mode %llu first %llu count %llu inst %llu | cnt %u/%u/%u/%u stride %u/%u/%u/%u | %llx+%llx %llx+%llx %llx+%llx %llx+%llx\n",
                (unsigned long long)st.program->stages[0].code_addr, indexed, (unsigned long long)r->x[0], (unsigned long long)r->x[1],
                (unsigned long long)r->x[2], (unsigned long long)(indexed ? r->x[6] : r->x[4]), vkey.xfb_count[0], vkey.xfb_count[1],
                vkey.xfb_count[2], vkey.xfb_count[3], vkey.xfb_stride[0], vkey.xfb_stride[1], vkey.xfb_stride[2], vkey.xfb_stride[3],
                (unsigned long long)g_xfb_addr[0], (unsigned long long)g_xfb_size[0], (unsigned long long)g_xfb_addr[1], (unsigned long long)g_xfb_size[1],
                (unsigned long long)g_xfb_addr[2], (unsigned long long)g_xfb_size[2], (unsigned long long)g_xfb_addr[3], (unsigned long long)g_xfb_size[3]);
    }
    if (g_debug_frame && pr->vi->uses_xfb) {
        for (int i = 0; i < 32 && i < st.nattrib; i++)
            if (pr->vi->attr_mask & (1u << i)) LOG("[xfb]   attr %d fmt %#x stream %u off %u stride %u\n", i, st.attrib[i] & 0xFF, (st.attrib[i] >> 8) & 0x1F, st.attrib[i] >> 13, st.stream[(st.attrib[i] >> 8) & 0x1F][0]);
    }
    static id<MTLBuffer> dbgvs;
    if (dbg_this) {
        if (!dbgvs) dbgvs = [dev newBufferWithLength:2 * 64 * 8 * 16 options:MTLResourceStorageModeShared];
        memset(dbgvs.contents, 0xff, 2 * 64 * 8 * 16);
        [enc setVertexBuffer:dbgvs offset:0 atIndex:DBG_VS_BUFFER_INDEX];
    }
    if (pr->fi->uses_gmem) [enc setFragmentBuffer:g_guest_buffer offset:0 atIndex:GMEM_BUFFER_INDEX];
    bind_textures(0, pr->vi);
    bind_textures(1, pr->fi);
    vp_sx = pass_sx; vp_sy = pass_sy; vp_ox = 0; vp_oy = 0;
    if (fabsf(pass_sx - pass_sy) > 0.01f * pass_sy && st.rt.ncolor && renderer_texture_presented(st.rt.color[0])) {
        // Draws into the swapchain image: draws that sample the full-size reshaped scene (the final
        // composite, blurred menu backgrounds) and untextured full-screen fades fill the window; everything
        // else (HUD, text, menus, movie frames) goes into a centred 16:9 box.
        bool reads_scene = false;  // samples a reshaped texture the size of the framebuffer (the scene itself)
        for (int i = 0; i < pr->fi->ntex && i < 64; i++)
            if ((tex_sc[1][i][0] != 1 || tex_sc[1][i][1] != 1) && tex_wh[1][i][0] == st.rt.color[0]->width &&
                tex_wh[1][i][1] == st.rt.color[0]->height)
                reads_scene = true;
        // Full-screen overlays without textures (fades, flashes) cover the whole window too.
        bool fullscreen_quad = r->x[2] <= 6 && st.viewport[0][0] == 0 && st.viewport[0][1] == 0 &&
                               st.viewport[0][2] >= st.rt.color[0]->width && st.viewport[0][3] >= st.rt.color[0]->height;
        bool fullscreen_fill = pr->fi->ntex == 0 && fullscreen_quad;
        // A full-screen quad sampling a reshaped (screen-shaped) texture is a scene background too, even a
        // downscaled one: the blurred scene behind the pause menu reads a 192x108 copy.
        // (single-texture draws only: the menu's frosted panels sample the same blurred copy but are UI pieces)
        if (fullscreen_quad && !reads_scene && pr->fi->ntex == 1 && (tex_sc[1][0][0] != 1 || tex_sc[1][0][1] != 1))
            reads_scene = true;
        extern uint64_t renderer_present_count(void);
        static uint64_t wide_frame = ~0ull;  // the latest draw this frame filled the window (nothing boxed since)
        if (reads_scene) wide_frame = renderer_present_count();
        // Black or white fills are fades and flashes: always the whole window. Coloured ones (the file-select
        // tint) stay boxed unless they directly follow the composite. Colour = first fragment cbuf (rgb).
        bool fade_fill = false;
        if (fullscreen_fill && st.ubuf[1][0].addr && st.ubuf[1][0].size >= 12) {
            const float *c = (const float *)(uintptr_t)st.ubuf[1][0].addr;
            bool black = c[0] < 0.01f && c[1] < 0.01f && c[2] < 0.01f, white = c[0] > 0.99f && c[1] > 0.99f && c[2] > 0.99f;
            fade_fill = black || white;
        }
        bool composite = reads_scene || fade_fill || (fullscreen_fill && wide_frame == renderer_present_count());
        if (!composite) wide_frame = ~0ull;
        static int log_fills = -1;  // LARECOMP_LOG_FILLS: every full-screen untextured fill (fs hash, colour cbuf, decision)
        if (log_fills < 0) log_fills = getenv("LARECOMP_LOG_FILLS") != NULL;
        if (log_fills && fullscreen_fill) {
            static uint64_t lastf; static int nthis;
            uint64_t f = renderer_present_count();
            if (f != lastf) { lastf = f; nthis = 0; }
            if (nthis++ < 4 && f % 6 == 0) {
                const float *c = st.ubuf[1][0].addr ? (const float *)(uintptr_t)st.ubuf[1][0].addr : NULL;
                LOG("[fill] frame %llu fs=%llx composite %d cb0 %g %g %g %g | %g %g %g %g\n", (unsigned long long)f,
                    st.program->stages[1].code_addr, composite, c ? c[0] : -1, c ? c[1] : -1, c ? c[2] : -1, c ? c[3] : -1,
                    c ? c[4] : -1, c ? c[5] : -1, c ? c[6] : -1, c ? c[7] : -1);
            }
        }
        if (g_debug_frame && getenv("LARECOMP_LOG_UI")) {
            LOG("[ui2] fs=%llx count %llu ntex %d reads_scene %d fill %d quad %d -> %d |", st.program->stages[1].code_addr, r->x[2],
                pr->fi->ntex, reads_scene, fullscreen_fill, fullscreen_quad, composite);
            for (int i = 0; i < pr->fi->ntex && i < 4; i++)
                LOG(" t%d %dx%d sc %.2f,%.2f", i, tex_wh[1][i][0], tex_wh[1][i][1], tex_sc[1][i][0], tex_sc[1][i][1]);
            LOG(" | rt %ux%u vp %.0f,%.0f %.0fx%.0f\n", st.rt.color[0]->width, st.rt.color[0]->height, st.viewport[0][0],
                st.viewport[0][1], st.viewport[0][2], st.viewport[0][3]);
        }
        if (!composite) {  // centred 16:9 region with a uniform scale
            int pw, ph;
            pass_size(&pw, &ph);
            float u = fminf(pass_sx, pass_sy);
            vp_sx = vp_sy = u;
            vp_ox = (pw - st.rt.color[0]->width * u) * 0.5f;
            vp_oy = (ph - st.rt.color[0]->height * u) * 0.5f;
        }
    }
    [enc setViewport:(MTLViewport){vp[0] * vp_sx + vp_ox, vp[1] * vp_sy + vp_oy, vp[2] * vp_sx, vp[3] * vp_sy, zn, zf}];
    apply_scissor();
    if (pr->fi->uses_rscale) {  // [0] = render target scale, [1 + i] = scale of texture i
        float rs[66][4] = {{vp_sx, vp_sy, vp_ox, vp_oy}};
        for (int i = 0; i < pr->fi->ntex && i < 64; i++) { rs[1 + i][0] = tex_sc[1][i][0]; rs[1 + i][1] = tex_sc[1][i][1]; }
        if (fkey.flip_x) rs[65][0] = (float)st.rt.color[0]->width;  // (mirror mode: the composite's width, guest pixels)
        [enc setFragmentBytes:rs length:(NSUInteger)(fkey.flip_x ? 66 : 1 + pr->fi->ntex) * 16 atIndex:RSCALE_BUFFER_INDEX];
    }
    if (pr->fi->uses_tint) {  // (shaders that read a per-draw tint get none: zero)
        float tint[8] = {0};
        [enc setFragmentBytes:tint length:sizeof tint atIndex:19];
    }
    for (int s = 0; s < 16; s++) {
        if (!(used_streams & (1u << s))) continue;
        Range v = st.vbuf[s];
        if (v.addr) bind_guest(enc, true, v.addr, v.size ? v.size : 16, stream_slots[s]);
        else { static const float zero[4]; [enc setVertexBytes:zero length:16 atIndex:stream_slots[s]]; }
    }
    if (used_streams & (1u << 31)) { static const float zero[4] = {0, 0, 0, 1}; [enc setVertexBytes:zero length:16 atIndex:30]; }

    uint32_t inst_all = indexed ? (uint32_t)r->x[6] : (uint32_t)r->x[4], base_all = indexed ? (uint32_t)r->x[5] : (uint32_t)r->x[3];
    const uint32_t run_at[1] = {0}, run_n[1] = {inst_all};
    const int nruns = 1;
    for (int ri = 0; ri < nruns; ri++) {
    // draw
    bool native;
    uint32_t mode = (uint32_t)r->x[0];
    MTLPrimitiveType pt = prim_type(mode, &native);
    if (!indexed) {
        uint32_t first = (uint32_t)r->x[1], count = (uint32_t)r->x[2], base_inst = base_all + run_at[ri], inst = run_n[ri];
        if (native && g_ind_off != UINT64_MAX) {
            dbg_enc++;
            [enc drawPrimitives:pt indirectBuffer:g_guest_buffer indirectBufferOffset:g_ind_off];
        } else if (g_ind_off != UINT64_MAX) { stat_skipped++; return; }
        else if (native) {
            dbg_enc++;
            [enc drawPrimitives:pt vertexStart:first vertexCount:count instanceCount:inst baseInstance:base_inst];
        } else if (mode == 6 || mode == 7 || mode == 9) {
            uint32_t n;
            id<MTLBuffer> ib = expand_indices(mode, count, NULL, 0, first, &n);
            dbg_enc++;
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:n indexType:MTLIndexTypeUInt32 indexBuffer:ib
                     indexBufferOffset:0 instanceCount:inst baseVertex:0 baseInstance:base_inst];
        } else { stat_skipped++; return; }
    } else {
        uint32_t itype = (uint32_t)r->x[1], count = (uint32_t)r->x[2];
        uint64_t iaddr = r->x[3];
        int32_t base_vertex = (int32_t)r->x[4];
        uint32_t base_inst = base_all + run_at[ri], inst = run_n[ri];
        if (native && itype != 0) {
            MTLIndexType it = itype == 1 ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32;
            uint32_t isz = itype == 1 ? 2 : 4;
            id<MTLBuffer> ib;
            uint64_t ioff;
            if (iaddr >= g_gwin_base && iaddr + (uint64_t)count * isz <= g_gwin_base + g_gwin_max && (iaddr % isz) == 0) {
                ib = g_guest_buffer; ioff = iaddr - g_gwin_base;
            } else {
                ioff = ring_alloc((void *)(uintptr_t)iaddr, (uint64_t)count * isz); ib = ring;
            }
            dbg_enc++;
            if (g_ind_off != UINT64_MAX)
                [enc drawIndexedPrimitives:pt indexType:it indexBuffer:ib indexBufferOffset:ioff indirectBuffer:g_guest_buffer
                      indirectBufferOffset:g_ind_off];
            else
            [enc drawIndexedPrimitives:pt indexCount:count indexType:it indexBuffer:ib indexBufferOffset:ioff
                         instanceCount:inst baseVertex:base_vertex baseInstance:base_inst];
        } else if (g_ind_off != UINT64_MAX) { stat_skipped++; return; }
        else {
            uint32_t n;
            id<MTLBuffer> ib;
            if (native) {  // 8-bit indices: widen
                uint32_t *w = malloc(count * 4 + 4);
                for (uint32_t i = 0; i < count; i++) w[i] = ((const uint8_t *)(uintptr_t)iaddr)[i];
                ib = [dev newBufferWithBytes:w length:count * 4 + 4 options:MTLResourceStorageModeShared];
                free(w);
                n = count;
            } else {
                ib = expand_indices(mode, count, (const void *)(uintptr_t)iaddr, (int)itype, 0, &n);
                pt = MTLPrimitiveTypeTriangle;
            }
            dbg_enc++;
            [enc drawIndexedPrimitives:pt indexCount:n indexType:MTLIndexTypeUInt32 indexBuffer:ib indexBufferOffset:0
                         instanceCount:inst baseVertex:base_vertex baseInstance:base_inst];
        }
    }
    }  // runs
    stat_draws++;
    if (dbg_this) {
        static int nlog;
        if (nlog++ < 4) {
            renderer_flush();
            const float *f = dbgvs.contents;
            LOG("[dbgvs] draw %d:", nlog);
            for (int i = 0; i < 2; i++)
                for (int v = 0; v < 4; v++) LOG(" i%d v%d (%g %g %g %g) uv(%g %g %g)", i, v, f[(i * 8 + v) * 4], f[(i * 8 + v) * 4 + 1], f[(i * 8 + v) * 4 + 2], f[(i * 8 + v) * 4 + 3],
                                                f[(512 + i * 8 + v) * 4], f[(512 + i * 8 + v) * 4 + 1], f[(512 + i * 8 + v) * 4 + 2]);
            LOG("\n");
        }
    }
}

// Indirect draws (NVN DrawArrays / DrawElements Indirect, MultiDraw...IndirectCount). Z-A's culling compute fills in the
// instance counts on the GPU, so arguments inside the gmem window are read by the GPU (Metal's indirect draw); the CPU
// copy only sizes the index range. Arguments elsewhere are read here. (As vulkan/exec.c.)
static void draw_indirect(CmdRec *r) {
    bool elements = r->op == CMD_DRAW_ELEMENTS_INDIRECT || r->op == CMD_MULTI_DRAW_ELEMENTS_INDIRECT_COUNT;
    bool multi = r->op == CMD_MULTI_DRAW_ARRAYS_INDIRECT_COUNT || r->op == CMD_MULTI_DRAW_ELEMENTS_INDIRECT_COUNT;
    int k = elements ? 3 : 1;
    uint64_t ind = r->x[k];
    uint32_t n = 1, stride = elements ? 20 : 16;
    if (multi) {
        uint64_t cnt = r->x[k + 1];
        n = (uint32_t)r->x[k + 2];
        if (cnt && cnt >= GUEST_LO) { uint32_t c = *(const uint32_t *)(uintptr_t)cnt; if (c < n) n = c; }
        if (r->x[k + 3]) stride = (uint32_t)r->x[k + 3];
    }
    static int nlog;
    if (nlog++ < 8) LOG("[metal] indirect draw op %u: %u draw(s) at %llx stride %u\n", r->op, n, (unsigned long long)ind, stride);
    if (!ind || ind < GUEST_LO || n > 4096) return;
    CmdRec d;
    memset(&d, 0, sizeof d);
    d.op = elements ? CMD_DRAW_ELEMENTS : CMD_DRAW_ARRAYS;
    for (uint32_t i = 0; i < n; i++) {
        uint64_t pa = ind + (uint64_t)i * stride;
        const uint32_t *p = (const uint32_t *)(uintptr_t)pa;
        d.x[0] = r->x[0];
        bool gpu = pa >= g_gwin_base && pa - g_gwin_base + 20 <= g_gwin_max && !(pa & 3);
        {   // LARECOMP_LOG_INDIRECT=<n>: the arguments the CPU sees at replay (the GPU's culling rewrites them later)
            static int nl = -1;
            if (nl < 0) nl = getenv("LARECOMP_LOG_INDIRECT") ? atoi(getenv("LARECOMP_LOG_INDIRECT")) : 0;
            if (nl > 0) {   // (the GPU's culling of this frame has run once the work so far is done: read its result then)
                extern uint64_t renderer_present_count(void);
                static uint64_t lastf = ~0ull;
                if (renderer_present_count() != lastf) { lastf = renderer_present_count(); renderer_flush(); }
            }
            if (nl > 0) {
                nl--;
                extern uint64_t renderer_present_count(void);
                LOG("[indirect] f%llu op %u %s %llx: %u %u %u %d %u rt %u vs %llx fs %llx\n",
                    (unsigned long long)renderer_present_count(), r->op, gpu ? "gpu" : "cpu", (unsigned long long)pa,
                    p[0], p[1], p[2], (int)p[3], elements ? p[4] : 0,
                    st.rt.color[0] ? st.rt.color[0]->width : (st.rt.depth ? st.rt.depth->width : 0),
                    st.program ? (unsigned long long)st.program->stages[0].code_addr : 0ull,
                    st.program ? (unsigned long long)st.program->stages[1].code_addr : 0ull);
            }
        }
        if (gpu) {
            if (elements) { d.x[1] = r->x[1]; d.x[2] = p[0] + p[2]; d.x[3] = r->x[2]; d.x[4] = (uint64_t)(int64_t)(int32_t)p[3]; d.x[5] = p[4]; d.x[6] = 1; }
            else { d.x[1] = 0; d.x[2] = p[0] + p[2]; d.x[3] = p[3]; d.x[4] = 1; }
            if (!d.x[2]) continue;
            g_ind_off = pa - g_gwin_base;
            draw(&d, elements);
            g_ind_off = UINT64_MAX;
            continue;
        }
        if (!p[0] || !p[1]) continue;
        if (elements) {
            d.x[1] = r->x[1]; d.x[2] = p[0];
            d.x[3] = r->x[2] + (uint64_t)p[2] * (r->x[1] == 0 ? 1 : r->x[1] == 1 ? 2 : 4);
            d.x[4] = (uint64_t)(int64_t)(int32_t)p[3]; d.x[5] = p[4]; d.x[6] = p[1];
        } else {
            d.x[1] = p[2]; d.x[2] = p[0]; d.x[3] = p[3]; d.x[4] = p[1];
        }
        draw(&d, elements);
    }
}

// ------------------------------------------------------------------ texture copies
typedef struct { uint64_t tex; NvnTextureView view; uint8_t has_view; int32_t region[6]; } TexRefRec;

static const char *copy_src =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 pos [[position]]; float2 uv; };\n"
    "vertex V vs(uint vid [[vertex_id]], constant float4 &r [[buffer(0)]]) {\n"
    "  float2 p = float2((vid << 1) & 2, vid & 2); V o; o.pos = float4(p.x * 2 - 1, 1 - p.y * 2, 0, 1);\n"
    "  o.uv = r.xy + p * r.zw; return o; }\n"
    "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "  return t.sample(s, in.uv); }\n"
    "struct D { float d [[depth(any)]]; };\n"
    "fragment D fs_depth(V in [[stage_in]], depth2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "  D o; o.d = t.sample(s, in.uv); return o; }\n";

// Bytes per block of the Metal texture backing an NVN format (RGB8 is expanded to RGBA8 on the host).
static uint64_t renderer_pixel_format_bytes(MTLPixelFormat pf, uint64_t nvn_bpb) {
    (void)pf;
    return nvn_bpb == 3 ? 4 : nvn_bpb;
}

// Linear guest memory <-> texture region. Row/image strides of 0 mean tightly packed.
static void copy_region_dims(NvnTexture *t, const TexRefRec *ref, const FormatInfo **fi, int32_t rg[6], int *level,
                             uint64_t *row, uint64_t *img) {
    *fi = nvn_format_info(t->format);
    memcpy(rg, ref->region, sizeof ref->region);
    if (!rg[3]) rg[3] = (int32_t)t->width;
    if (!rg[4]) rg[4] = (int32_t)t->height;
    if (!rg[5]) rg[5] = 1;
    *level = ref->has_view && (ref->view.setmask & 1) ? ref->view.base_level : 0;
    uint32_t wb = ((uint32_t)rg[3] + (*fi)->bw - 1) / (*fi)->bw, hb = ((uint32_t)rg[4] + (*fi)->bh - 1) / (*fi)->bh;
    *row = st.copy_row_stride ? st.copy_row_stride : (uint64_t)wb * (*fi)->bpb;
    *img = st.copy_image_stride ? st.copy_image_stride : *row * hb;
}

static void copy_buffer_to_texture(uint64_t src, const TexRefRec *dst) {
    snap_reason = "buf2tex"; snapshots_invalidate(NULL);
    NvnTexture *t = (NvnTexture *)(uintptr_t)dst->tex;
    if (!t || !src) return;
    end_pass();
    const FormatInfo *fi;
    int32_t rg[6];
    int level;
    uint64_t row, img;
    copy_region_dims(t, dst, &fi, rg, &level, &row, &img);
    if (!fi || !fi->bpb) return;
    static int nlog;
    if (nlog++ < 20) LOG("[copy] buf %llx -> tex %ux%u f%#x region %d,%d,%d %dx%dx%d row %llu lvl %d\n", src, t->width, t->height, t->format, rg[0], rg[1], rg[2], rg[3], rg[4], rg[5], row, level);
    id<MTLBlitCommandEncoder> b = [cb() blitCommandEncoder];
    id<MTLTexture> tex = renderer_texture(t, b, false);  // make sure prior CPU contents are uploaded first
    renderer_mark_gpu_owned(t);
    bool array = tex.textureType == MTLTextureType2DArray || tex.textureType == MTLTextureTypeCube;
    uint32_t hb = ((uint32_t)rg[4] + fi->bh - 1) / fi->bh, wb = ((uint32_t)rg[3] + fi->bw - 1) / fi->bw;
    uint64_t mtl_bpb = renderer_pixel_format_bytes(tex.pixelFormat, fi->bpb);
    for (int z = 0; z < (array ? rg[5] : 1); z++) {
        const uint8_t *s = (const uint8_t *)(uintptr_t)(src + (uint64_t)z * img);
        uint64_t out_row = (uint64_t)wb * mtl_bpb;
        uint8_t *data = malloc(out_row * hb * (array ? 1 : rg[5]));
        for (int d = 0; d < (array ? 1 : rg[5]); d++)
            for (uint32_t y = 0; y < hb; y++) {
                const uint8_t *sr = s + (uint64_t)d * img + (uint64_t)y * row;
                uint8_t *dr = data + ((uint64_t)d * hb + y) * out_row;
                if (mtl_bpb == fi->bpb) memcpy(dr, sr, out_row);
                else if (fi->bpb == 3 && mtl_bpb == 4)
                    for (uint32_t x = 0; x < wb; x++) { memcpy(dr + x * 4, sr + x * 3, 3); dr[x * 4 + 3] = 255; }
                else memset(dr, 0, out_row);
            }
        id<MTLBuffer> staging = [dev newBufferWithBytes:data length:out_row * hb * (array ? 1 : rg[5])
                                                options:MTLResourceStorageModeShared];
        free(data);
        [b copyFromBuffer:staging sourceOffset:0 sourceBytesPerRow:out_row sourceBytesPerImage:out_row * hb
               sourceSize:MTLSizeMake(rg[3], rg[4], array ? 1 : rg[5]) toTexture:tex
         destinationSlice:array ? rg[2] + z : 0 destinationLevel:level
        destinationOrigin:MTLOriginMake(rg[0], rg[1], array ? 0 : rg[2])];
    }
    [b endEncoding];
}

// Color copy with scaling: draw src rect into dst rect (physical texels).
static id<MTLTexture> copy_raw_view(id<MTLTexture> t) {
    MTLPixelFormat pf = t.pixelFormat;
    MTLPixelFormat raw = pf == MTLPixelFormatRGBA8Unorm_sRGB ? MTLPixelFormatRGBA8Unorm
                       : pf == MTLPixelFormatBGRA8Unorm_sRGB ? MTLPixelFormatBGRA8Unorm : pf;
    if (raw == pf) return t;
    id<MTLTexture> v = [t newTextureViewWithPixelFormat:raw];
    return v ? v : t;
}

static void draw_copy(id<MTLTexture> s, int sx0, int sy0, int sw, int sh, id<MTLTexture> d, int dx0, int dy0, int dw, int dh,
                      bool linear) {
    static int raw = -1;  // LARECOMP_COPY_RAW_SRGB: copies move values unchanged (no sRGB decode/encode on either side)
    if (raw < 0) raw = getenv("LARECOMP_COPY_RAW_SRGB") != NULL;
    if (raw) { s = copy_raw_view(s); d = copy_raw_view(d); }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = d;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb() renderCommandEncoderWithDescriptor:rp];
    NSString *key = [NSString stringWithFormat:@"copy %lu", (unsigned long)d.pixelFormat];
    id<MTLRenderPipelineState> pipe = cache[key];
    if (!pipe) {
        static id<MTLLibrary> lib;
        if (!lib) lib = TIMED_COMPILE([dev newLibraryWithSource:@(copy_src) options:nil error:nil]);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = d.pixelFormat;
        pipe = TIMED_COMPILE([dev newRenderPipelineStateWithDescriptor:pd error:nil]);
        cache[key] = pipe;
    }
    static id<MTLSamplerState> lin, near;
    if (!lin) {
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        near = [dev newSamplerStateWithDescriptor:sd];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        lin = [dev newSamplerStateWithDescriptor:sd];
    }
    float r[4] = {(float)sx0 / s.width, (float)sy0 / s.height, (float)sw / s.width, (float)sh / s.height};
    [e setRenderPipelineState:pipe];
    [e setViewport:(MTLViewport){dx0, dy0, dw, dh, 0, 1}];
    [e setVertexBytes:r length:16 atIndex:0];
    [e setFragmentTexture:s atIndex:0];
    [e setFragmentSamplerState:linear ? lin : near atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    stat_passes++;
}

static void copy_texture_to_buffer(const TexRefRec *src, uint64_t dst) {
    NvnTexture *t = (NvnTexture *)(uintptr_t)src->tex;
    if (!t || !dst || dst < g_gwin_base) return;
    end_pass();
    const FormatInfo *fi;
    int32_t rg[6];
    int level;
    uint64_t row, img;
    copy_region_dims(t, src, &fi, rg, &level, &row, &img);
    if (!fi || !fi->bpb) return;
    {
        static int nlog;
        if (nlog++ < 12 || getenv("LARECOMP_LOG_READBACK"))
            LOG("[readback] tex %ux%u f%#x level %d region %d,%d %dx%d -> %llx row %llu\n", t->width, t->height,
                t->format, level, rg[0], rg[1], rg[3], rg[4], dst, row);
    }
    id<MTLTexture> tex = renderer_texture(t, nil, false);
    float tsx, tsy;
    renderer_texture_scale(t, &tsx, &tsy);
    if ((tsx != 1 || tsy != 1) && level == 0 && !renderer_format_is_depth(t->format)) {
        // the CPU expects guest-sized texels: filter the scaled allocation down first
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:tex.pixelFormat width:t->width
                                                                                      height:t->height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> small = [dev newTextureWithDescriptor:td];
        draw_copy(tex, 0, 0, tex.width, tex.height, small, 0, 0, t->width, t->height, true);
        tex = small;
    }
    id<MTLBlitCommandEncoder> b = [cb() blitCommandEncoder];
    if (renderer_pixel_format_bytes(tex.pixelFormat, fi->bpb) != fi->bpb) { [b endEncoding]; return; }
    bool array = tex.textureType == MTLTextureType2DArray || tex.textureType == MTLTextureTypeCube;
    for (int z = 0; z < (array ? rg[5] : 1); z++)
        [b copyFromTexture:tex sourceSlice:array ? rg[2] + z : 0 sourceLevel:level
              sourceOrigin:MTLOriginMake(rg[0], rg[1], array ? 0 : rg[2])
                sourceSize:MTLSizeMake(rg[3], rg[4], array ? 1 : rg[5]) toBuffer:g_guest_buffer
         destinationOffset:dst - g_gwin_base + (uint64_t)z * img destinationBytesPerRow:row destinationBytesPerImage:img];
    [b endEncoding];
    renderer_flush();  // the CPU may read the result right after the fence
}

static void copy_texture(const TexRefRec *src, const TexRefRec *dst, uint64_t flags) {
    snap_reason = "tex2tex"; snapshots_invalidate(NULL);
    NvnTexture *st_ = (NvnTexture *)(uintptr_t)src->tex, *dt = (NvnTexture *)(uintptr_t)dst->tex;
    if (!st_ || !dt) return;
    end_pass();
    id<MTLTexture> s = sampled_texture(st_, &src->view, src->has_view, TEXTYPE_2D);
    renderer_mark_gpu_owned(dt);
    id<MTLTexture> d = view_texture(dt, &dst->view, dst->has_view, true, nil);
    // a full copy into a swapchain image: the source is the frame's final framebuffer (UI is drawn there)
    extern void renderer_texture_mark_presented(NvnTexture *t);
    if (renderer_texture_presented(dt) && st_->width == dt->width && st_->height == dt->height)
        renderer_texture_mark_presented(st_);
    extern bool renderer_texture_first_write(NvnTexture *t);
    renderer_texture_first_write(dt);  // a copy fills the image: no clear afterwards this frame
    extern bool renderer_texture_level_fresh(NvnTexture *t);
    renderer_texture_level_fresh(dt);  // nor a level-change clear
    const int32_t *sr = src->region, *dr = dst->region;
    if (g_debug_frame) {
        static int nl;
        uint64_t total = tegra_total_size(&st_->layout), nz = 0;
        for (uint64_t k = 0; k < total && st_->addr; k++) nz += ((const uint8_t *)(uintptr_t)st_->addr)[k] != 0;
        if (nl < 400) LOG("[copytex] src addr %llx size %llu nonzero %llu tflags %#x stride %u bh %u\n", st_->addr, total, nz, st_->flags, st_->stride, st_->layout.block_height_log2);
        if (nl++ < 400) LOG("[copytex] %ux%u f%#x (%d,%d %dx%d) -> %ux%u f%#x (%d,%d %dx%d) flags %llx src_gpu %d\n", st_->width, st_->height, st_->format,
            sr[0], sr[1], sr[3], sr[4], dt->width, dt->height, dt->format, dr[0], dr[1], dr[3], dr[4], flags, renderer_is_gpu_owned(st_));
    }
    // regions are in guest texels; scaled allocations (output resolution) need physical texels
    float ssx, ssy, dsx, dsy;
    renderer_texture_scale(st_, &ssx, &ssy);
    renderer_texture_scale(dt, &dsx, &dsy);
    int sx0 = (int)lroundf(sr[0] * ssx), sy0 = (int)lroundf(sr[1] * ssy);
    int dx0 = (int)lroundf(dr[0] * dsx), dy0 = (int)lroundf(dr[1] * dsy);
    int sw = sr[3] ? (int)lroundf(sr[3] * ssx) : (int)s.width, sh = sr[4] ? (int)lroundf(sr[4] * ssy) : (int)s.height;
    int dw = dr[3] ? (int)lroundf(dr[3] * dsx) : (int)d.width, dh = dr[4] ? (int)lroundf(dr[4] * dsy) : (int)d.height;
    static int no_depth_scale = -1;
    if (no_depth_scale < 0) no_depth_scale = getenv("LARECOMP_NO_DEPTH_SCALE") != NULL;
    if (!no_depth_scale && renderer_format_is_depth(dt->format) && (sw != dw || sh != dh) && s.sampleCount == 1 && dt->format != 0x31) {
        // scaled depth copy (the game builds its depth pyramid this way): draw, writing fragment depth
        MTLRenderPassDescriptor *drp = [MTLRenderPassDescriptor renderPassDescriptor];
        drp.depthAttachment.texture = d;
        drp.depthAttachment.loadAction = MTLLoadActionLoad;
        drp.depthAttachment.storeAction = MTLStoreActionStore;
        if (renderer_format_has_stencil(dt->format)) {
            drp.stencilAttachment.texture = d;
            drp.stencilAttachment.loadAction = MTLLoadActionLoad;
            drp.stencilAttachment.storeAction = MTLStoreActionStore;
        }
        id<MTLRenderCommandEncoder> e = [cb() renderCommandEncoderWithDescriptor:drp];
        NSString *key = [NSString stringWithFormat:@"copydepth %lu", (unsigned long)d.pixelFormat];
        id<MTLRenderPipelineState> pipe = cache[key];
        if (!pipe) {
            static id<MTLLibrary> dlib;
            NSError *derr = nil;
            if (!dlib) dlib = TIMED_COMPILE([dev newLibraryWithSource:@(copy_src) options:nil error:&derr]);
            if (!dlib) LOG("[copy] depth copy library: %s\n", derr.localizedDescription.UTF8String);
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = [dlib newFunctionWithName:@"vs"];
            pd.fragmentFunction = [dlib newFunctionWithName:@"fs_depth"];
            pd.depthAttachmentPixelFormat = d.pixelFormat;
            if (renderer_format_has_stencil(dt->format)) pd.stencilAttachmentPixelFormat = d.pixelFormat;
            NSError *perr = nil;
            pipe = TIMED_COMPILE([dev newRenderPipelineStateWithDescriptor:pd error:&perr]);
            if (!pipe) { LOG("[copy] depth copy pipeline: %s\n", perr.localizedDescription.UTF8String); return; }
            cache[key] = pipe;
        }
        static id<MTLDepthStencilState> always;
        if (!always) {
            MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
            dd.depthCompareFunction = MTLCompareFunctionAlways;
            dd.depthWriteEnabled = YES;
            always = [dev newDepthStencilStateWithDescriptor:dd];
        }
        static id<MTLSamplerState> dnear;
        if (!dnear) dnear = [dev newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
        id<MTLTexture> sdepth = s;
        if (s.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 || s.pixelFormat == MTLPixelFormatDepth24Unorm_Stencil8)
            sdepth = [s newTextureViewWithPixelFormat:s.pixelFormat];
        float r[4] = {(float)sx0 / s.width, (float)sy0 / s.height, (float)sw / s.width, (float)sh / s.height};
        [e setRenderPipelineState:pipe];
        [e setDepthStencilState:always];
        [e setViewport:(MTLViewport){dx0, dy0, dw, dh, 0, 1}];
        [e setVertexBytes:r length:16 atIndex:0];
        [e setFragmentTexture:sdepth atIndex:0];
        [e setFragmentSamplerState:dnear atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        stat_passes++;
        static int dbgc = -1;
        if (dbgc < 0) dbgc = getenv("LARECOMP_DEBUG_DEPTHCOPY") != NULL;
        if (dbgc) {
            static int nlog;
            if (nlog++ < 6) {
                id<MTLBuffer> rb = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
                id<MTLBlitCommandEncoder> bb = [cb() blitCommandEncoder];
                MTLBlitOption opt = (s.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) ? MTLBlitOptionDepthFromDepthStencil : MTLBlitOptionNone;
                [bb copyFromTexture:s sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(s.width / 2, s.height / 2, 0)
                         sourceSize:MTLSizeMake(1, 1, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:4 destinationBytesPerImage:4 options:opt];
                opt = (d.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) ? MTLBlitOptionDepthFromDepthStencil : MTLBlitOptionNone;
                [bb copyFromTexture:d sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(d.width / 2, d.height / 2, 0)
                         sourceSize:MTLSizeMake(1, 1, 1) toBuffer:rb destinationOffset:16 destinationBytesPerRow:4 destinationBytesPerImage:4 options:opt];
                [bb endEncoding];
                renderer_flush();
                const float *f = rb.contents;
                LOG("[copy] depth %lux%lu fmt %lu -> %lux%lu fmt %lu: centre src %g dst %g\n", (unsigned long)s.width, (unsigned long)s.height,
                    (unsigned long)s.pixelFormat, (unsigned long)d.width, (unsigned long)d.height, (unsigned long)d.pixelFormat, f[0], f[4]);
            }
        }
        return;
    }
    if (renderer_format_is_depth(dt->format) || (s.pixelFormat == d.pixelFormat && sw == dw && sh == dh && s.sampleCount == d.sampleCount)) {
        id<MTLBlitCommandEncoder> b = [cb() blitCommandEncoder];
        [b copyFromTexture:s sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(sx0, sy0, 0)
                sourceSize:MTLSizeMake(MIN(sw, dw), MIN(sh, dh), 1) toTexture:d destinationSlice:0 destinationLevel:0
         destinationOrigin:MTLOriginMake(dx0, dy0, 0)];
        [b endEncoding];
        return;
    }
    draw_copy(s, sx0, sy0, sw, sh, d, dx0, dy0, dw, dh, flags & 1);
}

// ------------------------------------------------------------------ executor
// The last commands executed, for the draws that arrive with no program bound (diagnostic).
static uint32_t op_ring[64];
static uint64_t op_ring_a[64];
static unsigned op_ring_pos;
static void op_ring_push(CmdRec *r) {
    unsigned i = op_ring_pos++ & 63;
    op_ring[i] = r->op;
    op_ring_a[i] = r->x[0];
}
static void op_ring_dump(int back) {
    LOG("[metal] %d commands before it:", back);
    for (int i = back; i >= 1; i--) {
        unsigned k = (op_ring_pos - 1 - (unsigned)i) & 63;
        LOG(" %u(%llx)", op_ring[k], (unsigned long long)op_ring_a[k]);
    }
    LOG("\n");
}
// (diagnostics) LARECOMP_PROBE=x,y: in a debug frame, log every command after which a 32x32 block of colour target 0
// changed (draws of every kind, clears, copies) - who paints a given spot. Ends the pass per command: debug frames only.
static void probe_step(const CmdRec *r) {
    static int px = -2, py;
    static uint64_t frame = ~0ull, prev_addr;
    static uint32_t prev_op;
    static NvnTexture *prev_rt, *seen_rt[16];
    static uint32_t seen_sum[16];
    if (px == -2) { px = -1; if (getenv("LARECOMP_PROBE")) sscanf(getenv("LARECOMP_PROBE"), "%d,%d", &px, &py); }
    if (px < 0 || !g_debug_frame) return;
    extern uint64_t renderer_present_count(void);
    if (renderer_present_count() != frame) {  // a new capture: forget targets the game may have destroyed since
        frame = renderer_present_count();
        prev_rt = NULL;
        memset(seen_rt, 0, sizeof seen_rt);
    }
    if (prev_rt && prev_rt->backend) {  // what the previous command did to its target
        end_pass();
        id<MTLTexture> t = renderer_texture(prev_rt, nil, true);
        MTLPixelFormat f = t.pixelFormat;
        NSUInteger bpp = f == MTLPixelFormatRGBA32Float ? 16 : (f == MTLPixelFormatRGBA16Float || f == MTLPixelFormatRG32Float) ? 8
                       : (f == MTLPixelFormatR8Unorm || f == MTLPixelFormatR8Uint) ? 1 : 4;
        NSUInteger x0 = MIN((NSUInteger)px, t.width - 32), y0 = MIN((NSUInteger)py, t.height - 32);
        id<MTLBuffer> pb = [dev newBufferWithLength:32 * 32 * bpp options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> bl = [cb() blitCommandEncoder];
        [bl copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x0, y0, 0) sourceSize:MTLSizeMake(32, 32, 1)
                   toBuffer:pb destinationOffset:0 destinationBytesPerRow:32 * bpp destinationBytesPerImage:32 * 32 * bpp];
        [bl endEncoding];
        renderer_flush();
        uint32_t sum = 0;
        const uint8_t *q = pb.contents;
        for (NSUInteger k = 0; k < 32 * 32 * bpp; k++) sum = sum * 31 + q[k];
        int slot = -1;
        for (int k = 0; k < 16; k++) if (seen_rt[k] == prev_rt) slot = k;
        if (slot < 0) for (int k = 0; k < 16 && slot < 0; k++) if (!seen_rt[k]) { slot = k; seen_rt[k] = prev_rt; seen_sum[k] = 0; }
        if (slot >= 0 && sum != seen_sum[slot]) {
            const uint8_t *c = q + (16 * 32 + 16) * bpp;
            LOG("[probe] pass %d rt %llx f%#x changed after op %u fs %llx | centre %02x %02x %02x %02x\n", debug_pass_no,
                (unsigned long long)prev_rt->addr, prev_rt->format, prev_op, (unsigned long long)prev_addr, c[0], c[1], c[2], bpp > 3 ? c[3] : 0);
            seen_sum[slot] = sum;
        }
        st.rt_dirty = true;
    }
    prev_rt = NULL;
    bool writes = (r->op >= CMD_CLEAR_COLOR && r->op <= CMD_DRAW_ELEMENTS_INDIRECT) || r->op == CMD_DRAW_TEXTURE ||
                  r->op == CMD_DRAW_XFB || r->op == CMD_MULTI_DRAW_ARRAYS_INDIRECT_COUNT || r->op == CMD_MULTI_DRAW_ELEMENTS_INDIRECT_COUNT ||
                  (r->op >= CMD_COPY_BUFFER_TO_TEXTURE && r->op <= CMD_DOWNSAMPLE) || r->op == CMD_DISCARD_COLOR;
    NvnTexture *rt = st.rt.ncolor ? st.rt.color[0] : NULL;
    if (writes && rt && rt->width >= 32 && rt->height >= 32) {
        prev_rt = rt;
        prev_op = r->op;
        prev_addr = st.program ? st.program->stages[1].code_addr : 0;
    }
}

static void exec_list(uint64_t handle, int depth) {
    uint64_t p = handle;
    for (int guard = 0; guard < 10000000; guard++) {
        CmdRec *r = (CmdRec *)(uintptr_t)p;
        void *x = r->extra;
        if (r->op < CMD_COUNT) op_counts[r->op]++;
        op_ring_push(r);
        probe_step(r);
        switch (r->op) {
        case CMD_END: return;
        case CMD_JUMP: p = r->x[0]; continue;
        case CMD_CALL: {
            const uint64_t *h = x;
            for (uint64_t i = 0; i < r->x[0] && depth < 8; i++) exec_list(h[i], depth + 1);
            break;
        }
        case CMD_BIND_PROGRAM: {  // (program, NVNshaderStageBits): a game may bind its stages from several programs
            NvnProgram *bp = (NvnProgram *)(uintptr_t)r->x[0];
            uint32_t bm = (uint32_t)r->x[1] & 0x3F;
            if (!bm) bm = 0x3F;
            for (int i = 0; i < 6; i++) {
                if (!(bm >> i & 1)) continue;
                if (bp && (bp->stage_mask >> i & 1)) { g_comp_prog.stages[i] = bp->stages[i]; g_comp_prog.stage_mask |= 1u << i; }
                else { memset(&g_comp_prog.stages[i], 0, sizeof g_comp_prog.stages[i]); g_comp_prog.stage_mask &= ~(1u << i); }
            }
            st.program = g_comp_prog.stage_mask ? &g_comp_prog : NULL;
            static int dbg_bind; static uint64_t dbg_bind_f;  // (diagnostics) does the game really unbind the program, or is the recorded pointer lost?
            if (dbg_budget(&dbg_bind, &dbg_bind_f, 60)) {
                LOG("[bindprog] pass %d program %p stage_mask %#x x1 %llx\n", debug_pass_no, (void *)st.program,
                    st.program ? st.program->stage_mask : 0, (unsigned long long)r->x[1]);
            }
            break;
        }
        case CMD_BEGIN_XFB: g_xfb_on = true; g_xfb_dirty = false; break;
        case CMD_END_XFB:
            g_xfb_on = false;
            if (g_xfb_dirty) { end_pass(); g_xfb_dirty = false; }  // (later draws read the written buffers as vertex streams)
            break;
        case CMD_BIND_XFB_BUFFER:
            if (r->x[0] < 4) { g_xfb_addr[r->x[0]] = r->x[1]; g_xfb_size[r->x[0]] = r->x[2]; }
            break;
        case CMD_BIND_XFB_BUFFERS: {
            const uint64_t *xb = x;
            for (uint64_t i = 0; i < r->x[1] && i < 4 && r->x[0] + i < 4; i++) {
                g_xfb_addr[r->x[0] + i] = xb[2 * i];
                g_xfb_size[r->x[0] + i] = xb[2 * i + 1];
            }
            break;
        }
        case CMD_SET_RASTERIZER_DISCARD: g_raster_discard = r->x[0] & 1; break;
        case CMD_SET_DEPTH_CLAMP: st.depth_clamp = r->x[0] & 1; break;
        case CMD_BIND_BLEND: { uint8_t *b = x; memcpy(st.blend[b[0] & 7], b, 8); break; }
        case CMD_BIND_CHANNEL_MASK: memcpy(&st.channel_mask, x, 4); break;
        case CMD_BIND_COLOR: memcpy(st.color_state, x, 4); break;
        case CMD_BIND_DEPTH_STENCIL: memcpy(st.ds, x, 8); break;
        case CMD_BIND_MULTISAMPLE: memcpy(st.ms, x, 0x18); break;
        case CMD_BIND_POLYGON: memcpy(st.poly, x, 4); break;
        case CMD_BIND_VERTEX_ATTRIB:
            st.nattrib = (int)r->x[0] > 16 ? 16 : (int)r->x[0];
            memcpy(st.attrib, x, st.nattrib * 4);
            break;
        case CMD_BIND_VERTEX_STREAM:
            st.nstream = (int)r->x[0] > 16 ? 16 : (int)r->x[0];
            memcpy(st.stream, x, st.nstream * 8);
            break;
        case CMD_BIND_VERTEX_BUFFERS:
            for (uint64_t i = 0; i < r->x[1] && r->x[0] + i < 16; i++) memcpy(&st.vbuf[r->x[0] + i], (uint8_t *)x + i * 16, 16);
            break;
        case CMD_BIND_UNIFORM_BUFFERS:
            for (uint64_t i = 0; i < r->x[2] && r->x[1] + i < 18 && r->x[0] < 6; i++)
                memcpy(&st.ubuf[r->x[0]][r->x[1] + i], (uint8_t *)x + i * 16, 16);
            break;
        case CMD_BIND_STORAGE_BUFFERS:
            for (uint64_t i = 0; i < r->x[2] && r->x[1] + i < 16 && r->x[0] < 6; i++)
                memcpy(&st.sbuf[r->x[0]][r->x[1] + i], (uint8_t *)x + i * 16, 16);
            break;
        case CMD_BIND_TEXTURES:
            for (uint64_t i = 0; i < r->x[2] && r->x[1] + i < 32 && r->x[0] < 6; i++)
                memcpy(&st.tex[r->x[0]][r->x[1] + i], (uint8_t *)x + i * 8, 8);
            break;
        case CMD_BIND_IMAGES:
            for (uint64_t i = 0; i < r->x[2] && r->x[1] + i < 8 && r->x[0] < 6; i++)
                memcpy(&st.img[r->x[0]][r->x[1] + i], (uint8_t *)x + i * 8, 8);
            break;
        case CMD_SET_TEXTURE_POOL: st.tpool = (NvnDescPool *)(uintptr_t)r->x[0]; break;
        case CMD_SET_SAMPLER_POOL: st.spool = (NvnDescPool *)(uintptr_t)r->x[0]; break;
        case CMD_SET_RENDER_TARGETS: {
            {
                const uint64_t *tx = x;
                for (int i = 0; i < (int)r->x[0] && i < 8; i++) {
                    NvnTexture *t = (NvnTexture *)(uintptr_t)tx[i];
                    static int nlog;
                    if (t && (t->flags & 2) && nlog++ < 5) LOG("[metal] video texture %p used as render target\n", t);
                }
            }
            const struct { uint64_t tex[8]; NvnTextureView views[8]; uint8_t has_view[8]; uint64_t depth;
                           NvnTextureView dview; uint8_t has_dview; } *rt = x;
            memset(&st.rt, 0, sizeof st.rt);
            st.rt.ncolor = (int)r->x[0];
            for (int i = 0; i < st.rt.ncolor; i++) {
                st.rt.color[i] = (NvnTexture *)(uintptr_t)rt->tex[i];
                st.rt.cview[i] = rt->views[i];
                st.rt.has_cview[i] = rt->has_view[i];
            }
            st.rt.depth = (NvnTexture *)(uintptr_t)rt->depth;
            st.rt.dview = rt->dview;
            st.rt.has_dview = rt->has_dview;
            st.rt_dirty = true;
            break;
        }
        case CMD_SET_VIEWPORTS:
            for (uint64_t i = 0; i < r->x[1] && r->x[0] + i < 16; i++) memcpy(st.viewport[r->x[0] + i], (uint8_t *)x + i * 16, 16);
            break;
        case CMD_SET_SCISSORS:
            for (uint64_t i = 0; i < r->x[1] && r->x[0] + i < 16; i++) memcpy(st.scissor[r->x[0] + i], (uint8_t *)x + i * 16, 16);
            break;
        case CMD_SET_DEPTH_RANGES:
            for (uint64_t i = 0; i < r->x[1] && r->x[0] + i < 16; i++) memcpy(st.depth_range[r->x[0] + i], (uint8_t *)x + i * 8, 8);
            break;
        case CMD_SET_BLEND_COLOR: memcpy(st.blend_color, x, 16); break;
        case CMD_SET_STENCIL: {
            int face = (int)r->x[0];
            for (int f = 0; f < 2; f++) {
                if (!(face & (1 << f))) continue;
                if (r->x[6] == 0) st.stencil_ref[f] = (uint32_t)r->x[1];
                else if (r->x[6] == 1) st.stencil_mask[f] = (uint32_t)r->x[1];
                else st.stencil_vmask[f] = (uint32_t)r->x[1];
            }
            break;
        }
        case CMD_SET_POLYGON_OFFSET:
            memcpy(st.poly_offset, r->f, sizeof st.poly_offset);
            if (ENV("LARECOMP_LOG_BIAS")) {  // (diagnostics) every distinct value the game sets, raw argument registers too
                static float seen[32][3];
                static int nseen;
                bool dup = false;
                for (int k = 0; k < nseen; k++) dup |= !memcmp(seen[k], r->f, sizeof seen[k]);
                if (!dup && nseen < 32) {
                    memcpy(seen[nseen++], r->f, sizeof seen[0]);
                    LOG("[bias] set factor %g units %g clamp %g (x1 %#llx x2 %#llx f3 %g)\n", r->f[0], r->f[1], r->f[2],
                        (unsigned long long)r->x[0], (unsigned long long)r->x[1], r->f[3]);
                }
            }
            break;
        case CMD_SET_PRIMITIVE_RESTART: st.prim_restart = r->x[0] != 0; st.restart_index = (uint32_t)r->x[1]; break;
        case CMD_SET_COPY_STRIDES: st.copy_row_stride = r->x[0]; st.copy_image_stride = r->x[1]; break;
        case CMD_CLEAR_COLOR: {
            snap_reason = "clear-color"; snapshots_invalidate(NULL);
            int index = (int)r->x[0];
            static int log_clears = -1;  // LARECOMP_LOG_CLEARS: every colour clear (frame, target size, mask, scissor)
            if (log_clears < 0) log_clears = getenv("LARECOMP_LOG_CLEARS") != NULL;
            if (log_clears && index < st.rt.ncolor && st.rt.color[index])
                LOG("[cclear] frame %llu idx %d %ux%u f%#x mask %#x scissor %d,%d %dx%d\n", (unsigned long long)renderer_present_count(),
                    index, st.rt.color[index]->width, st.rt.color[index]->height, st.rt.color[index]->format, (uint32_t)r->x[2],
                    st.scissor[0][0], st.scissor[0][1], st.scissor[0][2], st.scissor[0][3]);
            else if (log_clears) LOG("[cclear] frame %llu idx %d: no target bound (ncolor %d)\n", (unsigned long long)renderer_present_count(), index, st.rt.ncolor);
            if (index < st.rt.ncolor && st.rt.color[index]) clear(index, (int)r->x[5], x, (uint32_t)r->x[2], false, 0, false, 0, 0);
            break;
        }
        case CMD_CLEAR_TEXTURE: {
            // ClearTexture(cmd, texture, view, region, color, mask) (runtime/nvn/cmdbuf.c clear_texture). Was never
            // executed: the game clears its text-box textures this way before drawing a new message, so the old
            // text stayed behind the new one (user 2026-10-08: "Load this file?" over "Please select a file.").
            // Done as a render-target clear: bind the texture alone, scissor = region, clear(), restore.
            const struct { uint64_t tex; NvnTextureView view; uint8_t has_view; int32_t region[6]; float color[4]; } *ct = x;
            NvnTexture *t = (NvnTexture *)(uintptr_t)ct->tex;
            if (!t) break;
            snap_reason = "clear-texture"; snapshots_invalidate(NULL);
            RtState saved = st.rt;
            int32_t sc[4];
            memcpy(sc, st.scissor[0], sizeof sc);
            end_pass();
            memset(&st.rt, 0, sizeof st.rt);
            st.rt.ncolor = 1;
            st.rt.color[0] = t;
            if (ct->has_view) { st.rt.cview[0] = ct->view; st.rt.has_cview[0] = 1; }
            st.rt_dirty = true;
            const int32_t *rg = ct->region;
            if (rg[3] > 0 && rg[4] > 0) { st.scissor[0][0] = rg[0]; st.scissor[0][1] = rg[1]; st.scissor[0][2] = rg[3]; st.scissor[0][3] = rg[4]; }
            else { st.scissor[0][0] = st.scissor[0][1] = 0; st.scissor[0][2] = st.scissor[0][3] = 16384; }
            static int nlog;
            if (nlog++ < 8 || g_debug_frame)
                LOG("[cleartex] %ux%u f%#x region %d,%d %dx%d color %g %g %g %g mask %#llx kind %llu\n", t->width, t->height, t->format,
                    rg[0], rg[1], rg[3], rg[4], ct->color[0], ct->color[1], ct->color[2], ct->color[3], r->x[4], r->x[6]);
            clear(0, (int)r->x[6], ct->color, (uint32_t)r->x[4] ? (uint32_t)r->x[4] : 0xF, false, 0, false, 0, 0);
            end_pass();
            st.rt = saved;
            memcpy(st.scissor[0], sc, sizeof sc);
            st.rt_dirty = true;
            break;
        }
        case CMD_CLEAR_DEPTH_STENCIL:
            snap_reason = "clear-depth"; snapshots_invalidate(NULL);
            if (st.rt.depth) {
                // (depth s0, depthMask x1, stencil x2, stencilMask x3)
                bool has_stencil = renderer_format_has_stencil(st.rt.depth->format);
                clear(-1, 0, NULL, 0, r->x[0] != 0, r->f[0], has_stencil && r->x[2] != 0, (uint32_t)r->x[1],
                      (uint32_t)r->x[2]);
            }
            break;
        case CMD_DISPATCH:
            dispatch_compute((uint32_t)r->x[0], (uint32_t)r->x[1], (uint32_t)r->x[2]);
            if (st.program) {
                static uint64_t seen[16];
                static int nseen;
                uint64_t cs = st.program->stages[5].code_addr;
                bool known = false;
                for (int i = 0; i < nseen; i++) known |= seen[i] == cs;
                if (!known && nseen < 16) {
                    seen[nseen++] = cs;
                    char path[64];
                    snprintf(path, sizeof path, "build/cs_%d.bin", nseen - 1);
                    FILE *f = fopen(path, "wb");  // (no build/ outside a source checkout: the app's data root)
                    if (f) fwrite((void *)(uintptr_t)cs, 1, 0x4000, f), fclose(f);
                    LOG("[dispatch] new compute program %d: cs %llx groups %llu %llu %llu images:", nseen - 1, cs, r->x[0], r->x[1], r->x[2]);
                    for (int i = 0; i < 8; i++) if (st.img[5][i]) LOG(" %d=%llx", i, st.img[5][i]);
                    LOG(" tex:");
                    for (int i = 0; i < 8; i++) if (st.tex[5][i]) LOG(" %d=%llx", i, st.tex[5][i]);
                    LOG(" ubuf:");
                    for (int i = 0; i < 8; i++) if (st.ubuf[5][i].addr) LOG(" %d=%llx/%llu", i, st.ubuf[5][i].addr, st.ubuf[5][i].size);
                    LOG(" ssbo:");
                    for (int i = 0; i < 8; i++) if (st.sbuf[5][i].addr) LOG(" %d=%llx/%llu", i, st.sbuf[5][i].addr, st.sbuf[5][i].size);
                    LOG("\n");
                }
            }
            if (g_debug_frame && st.program) {
                LOG("[dispatch] %llu %llu %llu prog %p cs %llx\n", r->x[0], r->x[1], r->x[2], st.program, st.program->stages[5].code_addr);
                FILE *f = fopen("build/cs_code.bin", "wb");
                if (f) fwrite((void *)(uintptr_t)st.program->stages[5].code_addr, 1, 0x4000, f), fclose(f);
                f = fopen("build/cs_ctrl.bin", "wb");
                if (f) fwrite(st.program->stages[5].control, 1, 0x900, f), fclose(f);
                LOG("[dispatch] images:");
                for (int i = 0; i < 8; i++) if (st.img[5][i]) LOG(" %d=%llx", i, st.img[5][i]);
                LOG(" tex:");
                for (int i = 0; i < 8; i++) if (st.tex[5][i]) LOG(" %d=%llx", i, st.tex[5][i]);
                LOG(" ubuf:");
                for (int i = 0; i < 8; i++) if (st.ubuf[5][i].addr) LOG(" %d=%llx/%llu", i, st.ubuf[5][i].addr, st.ubuf[5][i].size);
                LOG("\n");
            }
            break;
        case CMD_DRAW_ARRAYS: draw(r, false); break;
        case CMD_DRAW_ARRAYS_INDIRECT: case CMD_DRAW_ELEMENTS_INDIRECT:
        case CMD_MULTI_DRAW_ARRAYS_INDIRECT_COUNT: case CMD_MULTI_DRAW_ELEMENTS_INDIRECT_COUNT:
            draw_indirect(r);
            break;
        case CMD_DRAW_ELEMENTS: draw(r, true); break;
        case CMD_UPDATE_UNIFORM_BUFFER:
            // (buffer, size, offset, dataSize, data): apply the update in command order
            memcpy((void *)(uintptr_t)(r->x[0] + r->x[2]), x, r->x[3]);
            break;
        case CMD_FENCE_SYNC: {
            // The CPU may read GPU-written memory (compute results) once the fence is signaled.
            static int fence_flush = -1;
            if (fence_flush < 0) fence_flush = getenv("LARECOMP_FENCE_FLUSH") ? 1 : 0;
            if (fence_flush) renderer_flush();
            extern void nvn_sync_set_seq(uint64_t guest, uint64_t seq);
            if (r->x[1]) nvn_sync_set_seq(r->x[1], renderer_fence_seq());
            break;
        }
        case CMD_REPORT_COUNTER: {
            uint64_t *out = (uint64_t *)(uintptr_t)r->x[1];
            static uint32_t seen;
            uint32_t type = (uint32_t)r->x[0];
            if (type < 32 && !(seen & (1u << type))) { seen |= 1u << type; LOG("[nvn] ReportCounter type %u\n", type); }
            // No occlusion queries yet: keep SAMPLES_PASSED growing, as on Vulkan. Returning zero makes Z-A
            // consider visible actors occluded and stops their ground-contact updates, leaving foot IK behind.
            static uint64_t samples;
            if (out) {
                out[0] = type == 1 ? (samples += 1u << 20) : 0;
                // Switch GPU ticks, 614.4 MHz: the game converts the difference to ns itself.
                // The game's own dynamic resolution reads the difference of two of these as its GPU time. Here they stamp
                // the host time the commands run at, so a stall (the window in the background, a throttled app) read as a
                // huge GPU time and dropped its resolution to the floor, climbing back in steps afterwards. Unless the
                // setting asks for it, the clock advances at most 0.5 ms between two reports: the game stays at full.
                extern bool g_za_frame_hook;
                static uint64_t virt, last_real;
                uint64_t now = plat_now_ns();
                if (!g_za_frame_hook || g_settings.game_drs || !last_real) virt = now;
                else virt += now - last_real < 500000 ? now - last_real : 500000;
                last_real = now;
                out[1] = (uint64_t)((unsigned __int128)virt * 384 / 625);
            }
            break;
        }
        case CMD_COPY_TEXTURE_TO_TEXTURE: {
            const TexRefRec *t = x;
            copy_texture(&t[0], &t[1], r->x[6]);
            break;
        }
        case CMD_DOWNSAMPLE: {
            const TexRefRec *t = x;
            copy_texture(&t[0], &t[1], 1);
            break;
        }
        case CMD_COPY_BUFFER_TO_TEXTURE: copy_buffer_to_texture(r->x[0], x); break;
        case CMD_COPY_TEXTURE_TO_BUFFER: copy_texture_to_buffer(x, r->x[3]); break;
        case CMD_COPY_BUFFER_TO_BUFFER:
            renderer_flush();
            memmove((void *)(uintptr_t)r->x[1], (void *)(uintptr_t)r->x[0], r->x[2]);
            break;
        default: break;
        }
        p += r->size;
    }
}

// In-place reboot (runtime/nvn/metal.m backend_reset; GPU idle, the game's textures already destroyed): drop
// everything keyed by guest addresses or guest-owned objects - programs (by code address), pipelines (by program),
// views, snapshots, bound state - so the next boot can't hit a stale entry. Metal's own shader cache stays warm.
void renderer_reset(void) {
    renderer_flush();
    renderer_gpu_timing_reset();
    pthread_mutex_lock(&gone_lock);
    ngone = 0;
    pthread_mutex_unlock(&gone_lock);
    for (int i = 0; i < VIEW_TAB; i++) {
        if (view_tab[i].view) CFRelease(view_tab[i].view);
        view_tab[i].view = view_tab[i].base = NULL;
        view_tab[i].key = 0;
    }
    g_views_live = 0;
    memset(prog_tab, 0, sizeof prog_tab);
    memset(pipe_tab, 0, sizeof pipe_tab);
    [cache removeAllObjects];
    [g_cs_progs removeAllObjects];
    @synchronized(g_ready_pipes) { [g_ready_pipes removeAllObjects]; }
    g_pipeline_gen++;
    [g_snap_copies removeAllObjects];
    memset(snap_tex, 0, sizeof snap_tex);
    memset(snap_ok, 0, sizeof snap_ok);
    for (int i = 0; i < 4; i++) { feedback_tex[i] = NULL; feedback_copy[i] = nil; }
    nfeedback = 0;
    g_cur_fs_hash = 0;
    last_bias_enc = nil;
    pthread_mutex_lock(&cb_lock);
    last_cb = nil;
    for (int i = 0; i < CB_HIST; i++) cb_hist[i] = nil;  // (they retain the old guest heap buffer)
    pthread_mutex_unlock(&cb_lock);
    st_defaults();
}

void backend_execute(uint64_t handle) {
    @autoreleasepool {
        exec_list(handle, 0);
        static int sync_submit = -1;
        if (sync_submit < 0) sync_submit = getenv("LARECOMP_SYNC_SUBMIT") ? 1 : 0;
        if (sync_submit) renderer_flush();  // old behaviour: finish the GPU work before returning
        else renderer_submit();  // the guest fences (nvnSyncWait) before reusing memory the GPU reads
    }
}
