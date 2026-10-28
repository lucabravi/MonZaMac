// Real offscreen Metal regressions; no game files or window are needed.
#include <stddef.h>
static double gpu_interval_sum_ms(const double *intervals, size_t count, double window_start, double window_end);
static double gpu_interval_union_ms(const double *intervals, size_t count, double window_start, double window_end);
#include "../runtime/nvn/renderer.m"
#import <ImageIO/ImageIO.h>

void metal_test_bootstrap(void);
void metal_test_texture_dump(void);
void metal_test_next_texture_frame(void);
void renderer_set_scale(float sx, float sy);

#define CHECK(c, message) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, message); exit(1); } } while (0)

static void uniform_snapshots(void) {
    renderer_flush();
    ring_reset();
    uint32_t value[4] = {17};
    uint64_t first = ring_snapshot(value, sizeof value);
    uint64_t repeated = ring_snapshot(value, sizeof value);
    if (!getenv("LARECOMP_NO_UNIFORM_CACHE")) CHECK(first == repeated, "unchanged uniforms reuse their snapshot");
    value[0] = 23;
    uint64_t second = ring_snapshot(value, sizeof value);
    CHECK(first != second, "changed uniforms get a separate snapshot");

    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void copy_value(constant uint *v [[buffer(0)]], device uint *out [[buffer(1)]],"
        "constant uint &i [[buffer(2)]]) { out[i] = v[0]; }" options:nil error:&err];
    CHECK(lib != nil, "snapshot test kernel compiles");
    id<MTLComputePipelineState> pipe = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"copy_value"] error:&err];
    CHECK(pipe != nil, "snapshot test pipeline compiles");
    id<MTLBuffer> result = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command = [renderer_queue() commandBuffer];
    id<MTLComputeCommandEncoder> e = [command computeCommandEncoder];
    [e setComputePipelineState:pipe];
    [e setBuffer:result offset:0 atIndex:1];
    uint64_t offsets[] = {first, second, 0};
    for (uint32_t i = 0; i < 3; i++) {
        if (i == 2) {  // replace the ring while the first two GPU reads are encoded but not submitted
            ring_off = RING_SIZE;
            value[0] = 31;
            offsets[i] = ring_snapshot(value, sizeof value);
        }
        [e setBuffer:ring offset:offsets[i] atIndex:0];
        [e setBytes:&i length:sizeof i atIndex:2];
        [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    }
    [e endEncoding];
    [command commit];
    [command waitUntilCompleted];
    CHECK(command.error == nil, "snapshot GPU reads complete");
    CHECK(((uint32_t *)result.contents)[0] == 17 && ((uint32_t *)result.contents)[1] == 23 &&
          ((uint32_t *)result.contents)[2] == 31,
          "GPU retains snapshots across source changes and ring replacement before submission");

    ring_reset();
    value[0] = 55;
    ring_snapshot(value, sizeof value);
    ring_reset();
    uint64_t fresh = ring_snapshot(value, sizeof value);
    uint8_t overwrite[512] = {0};
    ring_alloc(overwrite, sizeof overwrite);
    CHECK(*(uint32_t *)(ring_data + fresh) == 55, "reset invalidates reused offsets before new allocations overwrite them");
    id<MTLBuffer> previous = ring;
    ring_off = RING_SIZE;
    ring_alloc(overwrite, 16);
    CHECK(ring != previous, "ring exhaustion creates a new buffer");
    uint64_t wrapped = ring_snapshot(value, sizeof value);
    CHECK(*(uint32_t *)(ring_data + wrapped) == 55 && *(uint32_t *)((uint8_t *)previous.contents + fresh) == 55,
          "ring replacement preserves the old snapshot and copies uniforms into the new buffer");
}

static void gpu_interval_union(void) {
    const double intervals[] = {
        0.020, 0.025,  // [20, 25] ms
        0.000, 0.010,  // [0, 10] ms
        0.022, 0.028,  // [22, 28] ms
        0.005, 0.015,  // [5, 15] ms
        0.022, 0.026,  // contained in [22, 28] ms
    };
    double sum = gpu_interval_sum_ms(intervals, 5, 0.003, 0.026);
    double busy = gpu_interval_union_ms(intervals, 5, 0.003, 0.026);
    CHECK(sum > 29.999 && sum < 30.001, "summed command-buffer spans are clipped to the present window");
    CHECK(busy > 17.999 && busy < 18.001, "overlapping GPU intervals are clipped and counted once");
    CHECK(gpu_interval_union_ms(intervals, 5, 0.030, 0.040) == 0,
          "GPU intervals outside a present window contribute no busy time");
}

static void gpu_timing_state_machine(void) {
    renderer_gpu_timing_reset();
    double start, second, third, frame_ms, gpu_ms;
    unsigned samples;

    gpu_ms = renderer_gpu_timing_present(1, &start, &frame_ms, &samples);
    CHECK(gpu_ms < 0 && samples == 0, "the first present opens a measurement window");
    RendererGpuTimingToken *token = renderer_gpu_timing_submit(2, "renderer");
    CHECK(token != NULL, "a submitted command buffer gets a timing token");
    renderer_gpu_timing_mark_commit(token);
    gpu_ms = renderer_gpu_timing_present(2, &second, &frame_ms, &samples);
    CHECK(gpu_ms < 0 && samples == 0, "a window waits for its delayed command-buffer completion");
    gpu_ms = renderer_gpu_timing_present(3, &third, &frame_ms, &samples);
    CHECK(gpu_ms < 0 && samples == 0, "an outstanding command buffer remains attached to later windows");
    renderer_gpu_timing_complete(token, start, third);
    gpu_ms = renderer_gpu_timing_present(4, NULL, &frame_ms, &samples);
    CHECK(samples == 3, "a delayed completion releases all crossed present windows");
    CHECK(gpu_ms > 0 && gpu_ms <= frame_ms + 0.01, "the union stays bounded by the matching elapsed windows");

    renderer_gpu_timing_reset();
    renderer_gpu_timing_present(10, &start, &frame_ms, &samples);
    token = renderer_gpu_timing_submit(11, "renderer");
    renderer_gpu_timing_mark_commit(token);
    renderer_gpu_timing_complete(token, 0, renderer_host_time_seconds());
    gpu_ms = renderer_gpu_timing_present(11, NULL, &frame_ms, &samples);
    CHECK(gpu_ms < 0 && samples == 0, "a zero GPU start timestamp makes the frame sample unknown");

    renderer_gpu_timing_reset();
    renderer_gpu_timing_present(20, &start, &frame_ms, &samples);
    token = renderer_gpu_timing_submit(21, "renderer");
    renderer_gpu_timing_mark_commit(token);
    renderer_gpu_timing_reset();
    renderer_gpu_timing_complete(token, start, renderer_host_time_seconds());
    gpu_ms = renderer_gpu_timing_present(21, NULL, &frame_ms, &samples);
    CHECK(gpu_ms < 0 && samples == 0, "reset discards outstanding timing tokens safely");
    renderer_gpu_timing_reset();
}

static NvnTexture test_texture(uint32_t target, uint32_t width, uint32_t height, uint32_t layers,
                               uint32_t levels, uint32_t format, uint32_t samples) {
    NvnTexture t = {.target = target, .format = format, .flags = 8, .width = width, .height = height,
                    .depth = layers, .levels = levels, .samples = samples, .swizzle = {2, 3, 4, 5}};
    t.layout = (TexLayout){.width = width, .height = height, .depth = 1, .layers = layers,
                           .levels = levels, .fmt = nvn_format_info(format)};
    tegra_layout_init(&t.layout);
    return t;
}

static void check_gpu(void) {
    renderer_flush();
    CHECK(!last_cb.error, "production command buffer failed");
}

static id<MTLBuffer> read_texture(id<MTLTexture> tex, NSUInteger slice, NSUInteger level, NSUInteger bpp) {
    check_gpu();
    NSUInteger w = MAX((NSUInteger)1, tex.width >> level), h = MAX((NSUInteger)1, tex.height >> level);
    NSUInteger row = (w * bpp + 255) & ~(NSUInteger)255;
    id<MTLBuffer> out = [dev newBufferWithLength:row * h options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cmd = [renderer_queue() commandBuffer];
    id<MTLBlitCommandEncoder> bl = [cmd blitCommandEncoder];
    [bl copyFromTexture:tex sourceSlice:slice sourceLevel:level sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(w, h, 1) toBuffer:out destinationOffset:0
     destinationBytesPerRow:row destinationBytesPerImage:row * h];
    [bl endEncoding]; [cmd commit]; [cmd waitUntilCompleted];
    CHECK(!cmd.error, "readback command buffer failed");
    return out;
}

static void destroy_texture(NvnTexture *t) {
    check_gpu();
    backend_texture_destroyed(t);
    renderer_flush();
}

static void smoke(void) {
    NvnTexture t = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    struct { TexRefRec ref; float color[4]; } ct = {.ref.tex = (uint64_t)&t, .color = {1, 0, 0, 1}};
    uint64_t commands[128] = {0}, report[2] = {0};
    CmdRec *r = (CmdRec *)commands;
    r->op = CMD_CLEAR_TEXTURE; r->size = (sizeof *r + sizeof ct + 7) & ~7u; r->x[4] = 15;
    memcpy(r->extra, &ct, sizeof ct);
    r = (CmdRec *)((uint8_t *)r + r->size);
    r->op = CMD_REPORT_COUNTER; r->size = sizeof *r; r->x[0] = 1; r->x[1] = (uint64_t)report;
    r = (CmdRec *)((uint8_t *)r + r->size); r->op = CMD_END;
    backend_execute((uint64_t)commands);
    id<MTLBuffer> out = read_texture(renderer_texture(&t, nil, true), 0, 0, 4);
    for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {
        const uint8_t *px = (const uint8_t *)out.contents + y * 256 + x * 4;
        CHECK(px[0] == 255 && px[1] == 0 && px[2] == 0 && px[3] == 255, "clear/report smoke pixel");
    }
    CHECK(report[0] != 0 && report[1] != 0, "visible sample report and timestamp");
    destroy_texture(&t);
}

// Schedule words and termination are fixture data, not copied game instructions.
static void compute_fixture(uint64_t code[32], NvnProgram *p, const uint64_t *ops, unsigned count) {
    unsigned at = 0;
    for (unsigned i = 0; i < count + 2; i++) {
        if (!(at & 3)) code[at++] = 0x001f8000fc0007e0ull;
        code[at++] = i < count ? ops[i] : i == count ? 0xe30000000007000full : 0xe2400fffff87000full;
    }
    p->stage_mask = 1u << STAGE_COMPUTE;
    p->stages[5] = (NvnShaderStage){.stage = 5, .code_addr = (uint64_t)code, .const_offset = 32 * sizeof *code};
}

static void ldc64_overlap(void) {
    static uint64_t code[3][32];
    static NvnProgram programs[3];
    uint32_t constants[8] = {0, 16, 0xcafebabe, 0, 0, 0xbad, 0, 0};
    unsigned bad = 0;
    st.ubuf[5][1] = (Range){.addr = (uint64_t)constants, .size = sizeof constants}; // hardware CB4
    for (unsigned i = 0; i < 3; i++) {
        uint64_t ops[] = {
            0x010000000007f000ull | (4ull << 20) | (4 + i), // address 4 in R4, R5, or R6
            0xef90000000000000ull | (5ull << 48) | (4ull << 36) | (7ull << 16) | ((4ull + i) << 8) | 4,
            0x010000000007f002ull | ((uint64_t)(uint32_t)(g_gwin_base + 512) << 20),
            0x010000000007f003ull | ((g_gwin_base >> 32) << 20),
            0xeed8000000000000ull | (5ull << 48) | (1ull << 45) | (7ull << 16) | (2ull << 8) | 4,
        };
        compute_fixture(code[i], &programs[i], ops, sizeof ops / sizeof *ops);
        st.program = &programs[i];
        uint32_t *out = (uint32_t *)((uint8_t *)g_guest_buffer.contents + 512);
        out[0] = out[1] = 0xdeadbeef;
        dispatch_compute(1, 1, 1); check_gpu();
        fprintf(stderr, "LDC64 address R%u got=%08x,%08x want=00000010,cafebabe\n", 4 + i, out[0], out[1]);
        if (out[0] != 16 || out[1] != 0xcafebabe) bad++;
    }
    st.ubuf[5][1] = (Range){0};
    CHECK(bad == 0, "LDC64 must use the original address for both words when source and destination overlap");
}

static void safe_math_compute(void) {
    // Load zero at runtime: prevent constant folding of the NaN-producing arithmetic.
    uint32_t zero[4] = {0};
    st.ubuf[5][1] = (Range){.addr = (uint64_t)zero, .size = sizeof zero};
    static uint64_t code[32]; static NvnProgram program;
    uint64_t ops[] = {
        (0x4c98ull << 48) | (15ull << 39) | (4ull << 34) | (7ull << 16) | 4,
        (0x5080ull << 48) | (4ull << 20) | (7ull << 16) | (4ull << 8) | 5, // RCP R5, R4
        (0x5c68ull << 48) | (5ull << 20) | (7ull << 16) | (4ull << 8) | 6, // FMUL R6, R4, R5
        0x010000000007f008ull | ((uint64_t)(uint32_t)(g_gwin_base + 512) << 20),
        0x010000000007f009ull | ((g_gwin_base >> 32) << 20),
        0xeed8000000000000ull | (4ull << 48) | (1ull << 45) | (7ull << 16) | (8ull << 8) | 6,
    };
    compute_fixture(code, &program, ops, sizeof ops / sizeof *ops); st.program = &program;
    uint32_t *out = (uint32_t *)((uint8_t *)g_guest_buffer.contents + 512); *out = 0xdeadbeef;
    dispatch_compute(1, 1, 1); check_gpu();
    fprintf(stderr, "safe math compute=%s got=%08x\n", getenv("LARECOMP_SAFE_MATH") ?: "default", *out);
    if (getenv("LARECOMP_SAFE_MATH") && atoi(getenv("LARECOMP_SAFE_MATH")))
        CHECK((*out & 0x7f800000u) == 0x7f800000u && (*out & 0x007fffffu), "safe compute math must preserve NaN");
    st.ubuf[5][1] = (Range){0};
}

static void integer_opcode_semantics(void) {
#define REG_OP(top, flags) (((uint64_t)(top) << 48) | 9ull | (1ull << 8) | (7ull << 16) | (2ull << 20) | (flags))
    static const struct { const char *name; uint64_t opcode; uint32_t input[3], want; bool predicate; uint32_t want_gpr; } cases[] = {
        {"SHF.R.U64 register 40", REG_OP(0x5cf8, (3ull << 39) | (2ull << 37)), {0, 40, 0x100}, 1},
        {"SHF.L.U64 register 40", REG_OP(0x5bf8, (3ull << 39) | (2ull << 37)), {1, 40, 0}, 0x100},
        {"SHF.R.S64 clamps 64", REG_OP(0x5cf8, (3ull << 39) | (3ull << 37)), {0, 64, 0x80000000}, 0xffffffff},
        {"SHF.R.U64 clamps 100", REG_OP(0x5cf8, (3ull << 39) | (2ull << 37)), {0xffffffff, 100, 1}, 0},
        {"SHF.R.U64 immediate 40", (0x38f8ull << 48) | (3ull << 39) | (2ull << 37) | (40ull << 20) | (7ull << 16) | (1ull << 8) | 9,
            {0, 0, 0x100}, 1},
        {"IADD3 half selection", REG_OP(0x5cc0, (3ull << 39) | (1ull << 35) | (1ull << 31)), {0x12345678, 1, 0xabcd0002}, 0x567b},
        {"IADD3.RS preserves carry", REG_OP(0x5cc0, (3ull << 39) | (1ull << 37)), {0xffffffff, 1, 2}, 0x10002},
        {"IADD3.LS", REG_OP(0x5cc0, (3ull << 39) | (2ull << 37)), {1, 2, 3}, 0x30003},
        {"FLO.SH", REG_OP(0x5c30, 1ull << 41), {0, 0x100, 0}, 23},
        {"FLO inverted zero", REG_OP(0x5c30, 1ull << 40), {0, 0xffffffff, 0}, 0xffffffff},
        {"FLO.SH signed", REG_OP(0x5c30, (1ull << 48) | (1ull << 41)), {0, 0xfffffffe, 0}, 31},
        {"SHR.W", REG_OP(0x5c28, 1ull << 39), {0x80000000, 32, 0}, 0x80000000},
        {"SHR.BREV", REG_OP(0x5c28, 1ull << 40), {1, 0, 0}, 0x80000000},
        {"SHR.W signed", REG_OP(0x5c28, (1ull << 48) | (1ull << 39)), {0x80000000, 32, 0}, 0x80000000},
        {"IMUL32I.HI unsigned", (0x1full << 56) | (1ull << 53) | (0x9abcdef1ull << 20) | (7ull << 16) | (1ull << 8) | 9,
            {0xffffffff, 0, 0}, 0x9abcdef0},
        {"IMUL32I.HI signed", (0x1full << 56) | (7ull << 53) | (2ull << 20) | (7ull << 16) | (1ull << 8) | 9,
            {0x80000000, 0, 0}, 0xffffffff},
        {"LOP3 predicate true", REG_OP(0x5be0, (3ull << 39) | (1ull << 36) | (0x96ull << 28)), {0, 0, 0}, 1, true},
        {"LOP3 predicate zero", REG_OP(0x5be0, (3ull << 39) | (2ull << 36) | (0x96ull << 28)), {0, 0, 0}, 1, true},
        {"LOP3 predicate nonzero", REG_OP(0x5be0, (3ull << 39) | (3ull << 36) | (0x96ull << 28)), {1, 0, 0}, 1, true, 1},
        {"LOP3 predicate zero false", REG_OP(0x5be0, (3ull << 39) | (2ull << 36) | (0x96ull << 28)), {1, 0, 0}, 0, true, 1},
        {"LOP3 predicate nonzero false", REG_OP(0x5be0, (3ull << 39) | (3ull << 36) | (0x96ull << 28)), {0, 0, 0}, 0, true},
        {"LOP3 predicate false", REG_OP(0x5be0, (3ull << 39) | (0x96ull << 28)), {1, 0, 0}, 0, true, 1},
    };
#undef REG_OP
    enum { count = sizeof cases / sizeof *cases };
    static uint64_t code[count][32];
    static NvnProgram programs[count];
    unsigned bad = 0;
    for (unsigned i = 0; i < count; i++) {
        uint64_t instructions[12]; unsigned n = 0;
        for (unsigned k = 0; k < 3; k++) instructions[n++] = 0x010000000007f000ull | ((uint64_t)cases[i].input[k] << 20) | (k + 1);
        if (cases[i].predicate && !cases[i].want)
            instructions[n++] = 0x5090000000000000ull | (7ull << 39) | (7ull << 29) | (7ull << 16) | (7ull << 12) | 7; // P0 = PT && PT && PT
        instructions[n++] = cases[i].opcode;
        if (cases[i].predicate) {
            instructions[n++] = 0x010000000017f004ull;  // r4 = 1
            instructions[n++] = 0x5ca0000000000000ull | (255ull << 20) | (7ull << 16) | (4ull << 8) | 10; // r10 = P0 ? r4 : RZ
        }
        instructions[n++] = 0x010000000007f014ull | ((uint64_t)(uint32_t)(g_gwin_base + 512) << 20);
        instructions[n++] = 0x010000000007f015ull | ((g_gwin_base >> 32) << 20);
        instructions[n++] = 0xeed8000000000000ull | ((cases[i].predicate ? 5ull : 4ull) << 48) | (1ull << 45) | (7ull << 16) | (20ull << 8) | 9;
        instructions[n++] = 0xe30000000007000full;
        instructions[n++] = 0xe2400fffff87000full;
        unsigned at = 0;
        for (unsigned k = 0; k < n; k++) {
            if (!(at & 3)) code[i][at++] = 0x001f8000fc0007e0ull;
            code[i][at++] = instructions[k];
        }
        programs[i].stage_mask = 1u << STAGE_COMPUTE;
        programs[i].stages[5] = (NvnShaderStage){.stage = 5, .code_addr = (uint64_t)code[i], .const_offset = sizeof code[i]};
        st.program = &programs[i];
        uint32_t *result = (uint32_t *)((uint8_t *)g_guest_buffer.contents + 512);
        result[0] = result[1] = 0xdeadbeef;
        dispatch_compute(1, 1, 1); check_gpu();
        if (cases[i].predicate) {
            fprintf(stderr, "integer %s: pred=%08x/%08x gpr=%08x/%08x\n", cases[i].name, result[1], cases[i].want, result[0], cases[i].want_gpr);
            if (result[1] != cases[i].want || result[0] != cases[i].want_gpr) bad++;
        } else {
            fprintf(stderr, "integer %s: got=%08x want=%08x\n", cases[i].name, *result, cases[i].want);
            if (*result != cases[i].want) bad++;
        }
    }
    CHECK(bad == 0, "integer opcode results and destination predicates must match the reference vectors");
}

static void check_png(const char *path, const uint8_t want[3]) {
    NSData *data = [NSData dataWithContentsOfFile:@(path)];
    CHECK(data != nil, "screenshot PNG was written");
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    CHECK(source != NULL, "screenshot is a readable image");
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CHECK(image && CGImageGetWidth(image) == 4 && CGImageGetHeight(image) == 4, "screenshot preserves source dimensions");
    uint8_t pixels[4 * 4 * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, 4, 4, 8, 16, space,
                                               kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CHECK(context != NULL, "PNG pixel decode context");
    CGContextDrawImage(context, CGRectMake(0, 0, 4, 4), image);
    for (int i = 0; i < 16; i++) for (int c = 0; c < 3; c++)
        CHECK(abs((int)pixels[i * 4 + c] - want[c]) <= 1, "screenshot contains the expected slice and channel values");
    CGContextRelease(context); CGColorSpaceRelease(space); CGImageRelease(image); CFRelease(source);
}

static void screenshot_rgba(bool volume) {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                                                                 width:4 height:4 mipmapped:NO];
    desc.textureType = volume ? MTLTextureType3D : MTLTextureType2D;
    desc.depth = volume ? 2 : 1;
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> texture = [dev newTextureWithDescriptor:desc];
    CHECK(texture != nil, "RGBA screenshot fixture texture");
    uint8_t pixels[2 * 4 * 4 * 4];
    for (int i = 0; i < 32; i++) {
        const uint8_t first[4] = {128, 64, 32, 64}, second[4] = {0, 0, 255, 192};
        memcpy(pixels + i * 4, i < 16 ? first : second, 4);
    }
    [texture replaceRegion:MTLRegionMake3D(0, 0, 0, 4, 4, desc.depth) mipmapLevel:0 slice:0
                 withBytes:pixels bytesPerRow:16 bytesPerImage:64];
    const char *color_path = volume ? "volume-color.png" : "2d-color.png";
    const char *alpha_path = volume ? "volume-alpha.png" : "2d-alpha.png";
    renderer_save_texture(texture, color_path);
    check_png(color_path, (const uint8_t[]){128, 64, 32});
    renderer_save_texture_alpha(texture, alpha_path);
    check_png(alpha_path, (const uint8_t[]){64, 64, 64});
}

static void screenshot_2d(void) { screenshot_rgba(false); }
static void screenshot_volume(void) { screenshot_rgba(true); }

static void screenshot_volume_r16(void) {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Float
                                                                                 width:4 height:4 mipmapped:NO];
    desc.textureType = MTLTextureType3D; desc.depth = 2;
    desc.storageMode = MTLStorageModeShared; desc.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> texture = [dev newTextureWithDescriptor:desc];
    CHECK(texture != nil, "R16F screenshot fixture texture");
    uint16_t pixels[32];
    for (int i = 0; i < 32; i++) pixels[i] = i < 16 ? 0x3400 : 0x3a00;  // half: 0.25, 0.75
    [texture replaceRegion:MTLRegionMake3D(0, 0, 0, 4, 4, 2) mipmapLevel:0 slice:0
                 withBytes:pixels bytesPerRow:8 bytesPerImage:32];
    renderer_save_texture(texture, "r16-color.png");
    check_png("r16-color.png", (const uint8_t[]){64, 0, 0});
    renderer_save_texture_alpha(texture, "r16-alpha.png");
    check_png("r16-alpha.png", (const uint8_t[]){255, 255, 255});
    id<MTLTexture> view = [texture newTextureViewWithPixelFormat:texture.pixelFormat textureType:MTLTextureType3D
                                                       levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1)
                                                      swizzle:MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleRed,
                                                                                           MTLTextureSwizzleRed, MTLTextureSwizzleRed)];
    CHECK(view != nil, "swizzled volume view");
    renderer_save_texture(view, "r16-swizzle.png");
    check_png("r16-swizzle.png", (const uint8_t[]){64, 64, 64});
    renderer_save_texture_alpha(view, "r16-swizzle-alpha.png");
    check_png("r16-swizzle-alpha.png", (const uint8_t[]){64, 64, 64});
}

static void view_array_count(void) {
    NvnTexture t = test_texture(4, 8, 8, 8, 1, 0x25, 1);
    NvnTextureView v = {.setmask = 2, .min_layer = 0, .num_layers = 1};
    id<MTLTexture> got = view_texture(&t, &v, true, false, nil);
    CHECK(got.arrayLength == 1, "explicit first-layer view exposes exactly one layer");
    destroy_texture(&t);
}

static void view_bounds(void) {
    NvnTexture t = test_texture(4, 128, 128, 8, 8, 0x25, 1);
    NvnTextureView v = {.setmask = 3};
    for (unsigned start = 8; start <= 9; start++) {
        v.base_level = v.min_layer = start;
        id<MTLTexture> got = view_texture(&t, &v, true, false, nil);
        CHECK(got.mipmapLevelCount == 1 && got.arrayLength == 1, "out-of-range starts retain a nonempty final subresource");
        CHECK(got.parentRelativeLevel == 7 && got.parentRelativeSlice == 7, "starts are clamped before counts are derived");
    }
    v.base_level = v.min_layer = 0; v.num_levels = v.num_layers = UINT16_MAX;
    id<MTLTexture> got = view_texture(&t, &v, true, false, nil);
    CHECK(got.mipmapLevelCount == 8 && got.arrayLength == 8, "oversized explicit counts cannot overflow the bounds check");
    destroy_texture(&t);
}

static void view_cube_faces(void) {
    NvnTexture cube = test_texture(8, 8, 8, 6, 4, 0x25, 1);
    NvnTextureView face = {.setmask = 2, .min_layer = 5, .num_layers = 1};
    id<MTLTexture> got = view_texture(&cube, &face, true, true, nil);
    CHECK(got.textureType == MTLTextureType2D && got.parentRelativeSlice == 5, "cube face 5 must not become face 0");
    NvnTextureView mip = {.setmask = 1, .base_level = 1, .num_levels = 1};
    got = view_texture(&cube, &mip, true, false, nil);
    CHECK(got.textureType == MTLTextureTypeCube && got.mipmapLevelCount == 1, "mip-restricted cube retains all six faces");
    destroy_texture(&cube);
    NvnTexture array = test_texture(9, 8, 8, 12, 1, 0x25, 1);
    face.min_layer = 11;
    got = view_texture(&array, &face, true, true, nil);
    CHECK(got.textureType == MTLTextureType2D && got.parentRelativeSlice == 11, "cube-array face 11 is independently renderable");
    destroy_texture(&array);
}

static void view_zero_swizzle(void) {
    NvnTexture t = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    NvnTextureView v = {.setmask = 8, .swizzle = {0, 0, 0, 0}};
    id<MTLTexture> got = apply_swizzle(renderer_texture(&t, nil, false), &t, &v, true);
    CHECK(got.swizzle.red == MTLTextureSwizzleZero && got.swizzle.green == MTLTextureSwizzleZero &&
          got.swizzle.blue == MTLTextureSwizzleZero && got.swizzle.alpha == MTLTextureSwizzleZero,
          "explicit zero swizzle is not identity");
    destroy_texture(&t);
}

static void view_sampled_cube_face(void) {
    NvnTexture cube = test_texture(8, 8, 8, 6, 1, 0x25, 1);
    NvnTextureView face = {.setmask = 2, .min_layer = 5, .num_layers = 1};
    id<MTLTexture> got = view_texture(&cube, &face, true, false, nil);
    CHECK(got.textureType == MTLTextureType2D && got.parentRelativeSlice == 5, "sampled cube face keeps its selected face as a compatible 2D view");
    got = sampled_texture(&cube, &face, true, TEXTYPE_2D);
    CHECK(got.textureType == MTLTextureType2D && got.width == 8, "sampled face must reach the shader without a dummy substitute");
    destroy_texture(&cube);
}

static void view_partial_cube_range(void) {
    NvnTexture cube = test_texture(9, 8, 8, 12, 1, 0x25, 1);
    NvnTextureView view = {.setmask = 2, .min_layer = 1, .num_layers = 2};
    for (int render = 0; render <= 1; render++) {
        id<MTLTexture> got = view_texture(&cube, &view, true, render, nil);
        CHECK(got.textureType == MTLTextureType2DArray && got.arrayLength == 2 && got.parentRelativeSlice == 1,
              "partial cube face range is a 2D array for sampling and rendering");
    }
    view.num_layers = 6;
    id<MTLTexture> got = view_texture(&cube, &view, true, false, nil);
    CHECK(got.textureType == MTLTextureType2DArray && got.arrayLength == 6 && got.parentRelativeSlice == 1,
          "six unaligned faces cannot form a cube");
    view.min_layer = 6;
    got = view_texture(&cube, &view, true, false, nil);
    CHECK(got.textureType == MTLTextureTypeCubeArray && got.arrayLength == 1 && got.parentRelativeSlice == 6,
          "a whole aligned cube retains its cube type");
    destroy_texture(&cube);
}

static void view_chain_cleanup(void) {
    int initial_views = g_views_live;
    NvnTexture texture = test_texture(4, 8, 8, 2, 2, 0x25, 1);
    NvnTextureView view = {.setmask = 1 | 8, .base_level = 1, .num_levels = 1};
    id<MTLTexture> partial = view_texture(&texture, &view, true, false, nil);
    (void)apply_swizzle(partial, &texture, &view, true);
    CHECK(g_views_live > initial_views, "fixture must create a retained native view chain");
    destroy_texture(&texture);
    CHECK(g_views_live == initial_views, "destroying a texture must release every cached descendant view");
}

static void bind_targets(NvnTexture *color, NvnTexture *depth, NvnTexture *second) {
    end_pass("attachment");
    memset(&st.rt, 0, sizeof st.rt);
    st.rt.ncolor = second ? 2 : color ? 1 : 0;
    st.rt.color[0] = color; st.rt.color[1] = second; st.rt.depth = depth; st.rt_dirty = true;
    st.viewport[0][0] = st.viewport[0][1] = 0;
    st.viewport[0][2] = st.viewport[0][3] = 4;
    st.scissor[0][0] = st.scissor[0][1] = 0;
    st.scissor[0][2] = st.scissor[0][3] = 4;
}

static void prepare_draw(void) {
    // Synthetic ISA fixture written for this test: a0 -> clip position; constant green fragment output.
    static uint64_t vs[128], fs[128];
    static NvnProgram program;
    if (!program.stage_mask) {
        const uint64_t schedule = 0x001f8000fc0007e0ull;
        vs[16] = schedule;
        vs[17] = 0xefd8000000000000ull | (3ull << 47) | (0x80ull << 20) | (7ull << 16) | (255ull << 8);
        vs[18] = 0xeff0000000000000ull | (3ull << 47) | (0x70ull << 20) | (7ull << 16);
        vs[19] = 0xeff0000000000000ull | (3ull << 47) | (0x80ull << 20) | (7ull << 16);
        vs[20] = schedule;
        vs[21] = 0xe30000000007000full;
        vs[22] = 0xe2400fffff87000full;
        *(uint32_t *)((uint8_t *)fs + 0x78) = 15;
        fs[16] = schedule;
        fs[17] = 0x0100000000070000ull;
        fs[18] = 0x0100000000070001ull | ((uint64_t)0x3f800000 << 20);
        fs[19] = 0x0100000000070002ull;
        fs[20] = schedule;
        fs[21] = 0x0100000000070003ull | ((uint64_t)0x3f800000 << 20);
        fs[22] = 0xe30000000007000full;
        fs[23] = 0xe2400fffff87000full;
        program.stage_mask = 3;
        program.stages[0] = (NvnShaderStage){.stage = 0, .code_addr = (uint64_t)vs, .const_offset = 0xc0};
        program.stages[1] = (NvnShaderStage){.stage = 1, .code_addr = (uint64_t)fs, .const_offset = 0xc0};
    }
    st.program = &program;
    st.ds[0] = 1; st.ds[1] = st.rt.depth != NULL; st.ds[2] = 8;
    st.poly[0] = 0;
    const float vertices[3][4] = {{-1, -1, 0, 1}, {3, -1, 0, 1}, {-1, 3, 0, 1}};
    memcpy(g_guest_buffer.contents, vertices, sizeof vertices);
    st.nattrib = st.nstream = 1; st.attrib[0] = 0x2e;
    st.stream[0][0] = 16; st.stream[0][1] = 0;
    st.vbuf[0] = (Range){.addr = (uint64_t)g_guest_buffer.contents, .size = sizeof vertices};
}

static void fullscreen_draw(uint32_t instances) {
    CmdRec r = {.op = CMD_DRAW_ARRAYS, .size = sizeof(CmdRec), .x = {4, 0, 3, 0, instances}};
    draw(&r, false);
}

static void gpu_profile_boundaries(void) {
    NvnTexture first = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    NvnTexture second = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    CHECK(!g_profile_frames && !g_capture_pending && !g_capture_active, "profiling is off by default");
    CHECK(!gpu_profile_request(0), "zero frames cannot arm a profile");
    mkdir("build", 0755);
    FILE *command = fopen("build/dbgcmd", "w");
    CHECK(command != NULL, "live profiler command file");
    fputs("gpuprofile 2\n", command); fclose(command);
    for (unsigned i = 0; i < 16; i++) debug_live_controls();
    CHECK(g_profile_pending_frames == 2 && access("build/dbgcmd", F_OK), "live command arms and consumes a profile request");
    renderer_profile_pass_end("attachment");
    CHECK(!g_profile_frames, "a request must not include the partial current frame");
    renderer_debug_frame_boundary(100);
    CHECK(g_profile_frames == 2, "profiling starts at the next frame boundary");
    CHECK(!gpu_profile_request(1), "an in-progress profile cannot be replaced");
    bind_targets(&first, NULL, NULL); prepare_draw(); fullscreen_draw(1);
    bind_targets(&second, NULL, NULL); prepare_draw(); fullscreen_draw(1);
    renderer_submit_reason("guest-submit");
    renderer_submit_reason("guest-submit");  // no pending command buffer
    CHECK(g_profile.pass_end[gpu_profile_reason("attachment")] == 1, "only an actual attachment break is counted");
    CHECK(g_profile.pass_end[gpu_profile_reason("guest-submit")] == 1, "submission closes the second pass");
    CHECK(g_profile.cb_end[gpu_profile_reason("guest-submit")] == 1, "empty submissions are not counted");
    CHECK(g_profile.draws == 2, "count the encoded guest draws");
    renderer_debug_frame_boundary(101);
    CHECK(g_profile_frames == 1 && !g_profile.draws, "each completed frame has separate counters");
    bind_targets(&second, NULL, NULL); prepare_draw(); fullscreen_draw(1);
    TexRefRec source = {.tex = (uint64_t)&second};
    copy_texture_to_buffer(&source, g_gwin_base + 1024);
    CHECK(g_profile.pass_end[gpu_profile_reason("readback")] == 1, "CPU texture read closes the render pass");
    CHECK(g_profile.cb_end[gpu_profile_reason("cpu-read")] == 1, "CPU read records its actual flush cause");
    renderer_debug_frame_boundary(102);
    CHECK(!g_profile_frames, "profiling ends after exactly the requested frames");
    renderer_profile_pass_end("attachment");
    CHECK(!g_profile.pass_end[gpu_profile_reason("attachment")], "disabled profiling stops counting");
    id<MTLBuffer> pixels = read_texture(renderer_texture(&second, nil, true), 0, 0, 4);
    for (unsigned y = 0; y < 4; y++) for (unsigned x = 0; x < 4; x++) {
        const uint8_t *p = (const uint8_t *)pixels.contents + y * 256 + x * 4;
        CHECK(p[0] == 0 && p[1] == 255 && p[2] == 0 && p[3] == 255, "profiling preserves rendered pixels");
    }
    CHECK(gpu_profile_request(1), "a later profile can be armed");
    renderer_reset();
    renderer_debug_frame_boundary(103);
    CHECK(!g_profile_frames && !g_profile_pending_frames, "reboot cancels a pending profile");
    destroy_texture(&first); destroy_texture(&second);
}

static void gpu_capture_boundaries(void) {
    CHECK(!g_capture_active && !g_capture_pending, "capture starts disabled");
    CHECK(gpu_capture_request(), "arm a capture");
    CHECK(!gpu_capture_request(), "a second capture request cannot replace the first");
    CHECK(!g_capture_active, "requesting mid-frame does not start the capture");
    renderer_debug_frame_boundary(200);
    CHECK(!g_capture_pending, "the boundary consumes the capture request even on failure");
    const char *capture_enabled = getenv("MTL_CAPTURE_ENABLED");
    if (!capture_enabled || !atoi(capture_enabled)) {
        CHECK(!g_capture_active, "capture fails safely without launch-time Metal capture support");
        CHECK(access("build/gputrace", F_OK) != 0, "unsupported capture creates no output directory");
        renderer_reset();
        return;
    }
    CHECK(g_capture_active && [MTLCaptureManager sharedCaptureManager].isCapturing,
          "capture is active for the next complete frame");
    NSURL *first_path = g_capture_url;
    NvnTexture color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    bind_targets(&color, NULL, NULL); prepare_draw(); fullscreen_draw(1); renderer_submit();
    renderer_debug_frame_boundary(201);
    CHECK(!g_capture_active && ![MTLCaptureManager sharedCaptureManager].isCapturing, "capture stops after one frame");
    CHECK([[NSFileManager defaultManager] fileExistsAtPath:first_path.path], "one-frame GPU trace was written");
    CHECK(gpu_capture_request(), "a later capture can be armed");
    renderer_debug_frame_boundary(202);
    CHECK(![first_path isEqual:g_capture_url], "captures never overwrite an existing file");
    renderer_reset();
    CHECK(!g_capture_active && !g_capture_pending && ![MTLCaptureManager sharedCaptureManager].isCapturing,
          "reset stops only the capture owned by the profiler");

    NSFileManager *files = [NSFileManager defaultManager];
    CHECK([files moveItemAtPath:@"build/gputrace" toPath:@"build/saved-traces" error:nil], "temporarily block output directory");
    FILE *blocker = fopen("build/gputrace", "w"); CHECK(blocker != NULL, "capture directory failure fixture"); fclose(blocker);
    CHECK(gpu_capture_request(), "arm capture with an invalid output directory");
    renderer_debug_frame_boundary(204);
    CHECK(!g_capture_active && !g_capture_pending, "directory failure leaves no capture in flight");
    remove("build/gputrace");
    CHECK([files moveItemAtPath:@"build/saved-traces" toPath:@"build/gputrace" error:nil], "restore fixture traces");
    renderer_reset();

    MTLCaptureManager *manager = [MTLCaptureManager sharedCaptureManager];
    MTLCaptureDescriptor *external = [MTLCaptureDescriptor new];
    external.captureObject = dev; external.destination = MTLCaptureDestinationGPUTraceDocument;
    external.outputURL = [NSURL fileURLWithPath:@"build/gputrace/external.gputrace"];
    CHECK([manager startCaptureWithDescriptor:external error:nil], "external capture fixture starts");
    gpu_capture_drain();
    CHECK(gpu_capture_request(), "request while another tool owns the capture");
    renderer_debug_frame_boundary(205);
    renderer_reset();
    CHECK(manager.isCapturing && !g_capture_active, "request and reset must leave another tool's capture untouched");
    [manager stopCapture];
    destroy_texture(&color);
}

static void expect_rgba_slice(NvnTexture *t, unsigned slice, uint8_t red, uint8_t green, uint8_t blue) {
    id<MTLBuffer> out = read_texture(renderer_texture(t, nil, true), slice, 0, 4);
    for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {
        const uint8_t *p = (const uint8_t *)out.contents + y * 256 + x * 4;
        CHECK(p[0] == red && p[1] == green && p[2] == blue && p[3] == 255, "unexpected color pixel");
    }
}

static void expect_rgba(NvnTexture *t, uint8_t red, uint8_t green, uint8_t blue) {
    expect_rgba_slice(t, 0, red, green, blue);
}

static void expect_depth_slice(NvnTexture *t, unsigned slice, float want) {
    id<MTLBuffer> out = read_texture(renderer_texture(t, nil, true), slice, 0, 4);
    for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {
        float got = *(const float *)((const uint8_t *)out.contents + y * 256 + x * 4);
        if (fabsf(got - want) > 0.00001f) fprintf(stderr, "depth got %.8g, want %.8g\n", got, want);
        CHECK(fabsf(got - want) < 0.00001f, "unexpected depth pixel");
    }
}

static void expect_depth(NvnTexture *t, float want) { expect_depth_slice(t, 0, want); }

static void clear_bias(void) {
    NvnTexture color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    NvnTexture depth = test_texture(1, 4, 4, 1, 1, 0x33, 1);
    bind_targets(&color, &depth, NULL); prepare_draw();
    st.poly[3] = 4; st.poly_offset[1] = -1048576;
    fullscreen_draw(1);
    clear(-1, 0, NULL, 0, true, 0.5f, false, 0, 0);
    expect_depth(&depth, 0.5f);
    destroy_texture(&color); destroy_texture(&depth);
}

static void clear_wireframe(void) {
    NvnTexture color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    bind_targets(&color, NULL, NULL);
    const float black[4] = {0, 0, 0, 1}, red[4] = {1, 0, 0, 1};
    clear(0, 0, black, 15, false, 0, false, 0, 0);
    prepare_draw(); st.poly[2] = 1; fullscreen_draw(1);
    clear(0, 0, red, 15, false, 0, false, 0, 0);
    expect_rgba(&color, 255, 0, 0);
    destroy_texture(&color);
}

static void clear_bias_restore(void) {
    NvnTexture color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    NvnTexture depth = test_texture(1, 4, 4, 1, 1, 0x33, 1);
    bind_targets(&color, &depth, NULL); prepare_draw();
    st.poly[3] = 4; st.poly_offset[1] = -1048576;
    fullscreen_draw(1);
    clear(-1, 0, NULL, 0, true, 0.75f, false, 0, 0);
    fullscreen_draw(1);
    expect_depth(&depth, 0.4375f);
    destroy_texture(&color); destroy_texture(&depth);
}

static void clear_layouts(void) {
    NvnTexture color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    NvnTexture second = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    NvnTexture half = test_texture(1, 4, 4, 1, 1, 0x29, 1);
    const float red[4] = {1, 0, 0, 1};
    bind_targets(&color, NULL, &second);
    clear(0, 0, red, 15, false, 0, false, 0, 0);
    bind_targets(&color, NULL, &half);
    clear(0, 0, red, 15, false, 0, false, 0, 0);
    expect_rgba(&color, 255, 0, 0);
    destroy_texture(&color); destroy_texture(&second); destroy_texture(&half);
}

static void clear_multisample_depth(void) {
    CHECK([dev supportsTextureSampleCount:4], "device must support four samples for this test");
    NvnTexture depth = test_texture(1, 4, 4, 1, 1, 0x33, 1);
    NvnTexture msaa = test_texture(1, 4, 4, 1, 1, 0x33, 4);
    bind_targets(NULL, &depth, NULL);
    clear(-1, 0, NULL, 0, true, 0.5f, false, 0, 0);
    bind_targets(NULL, &msaa, NULL);
    clear(-1, 0, NULL, 0, true, 0.5f, false, 0, 0);
    check_gpu();
    destroy_texture(&depth); destroy_texture(&msaa);
}

static void draw_multisample_depth(void) {
    CHECK([dev supportsTextureSampleCount:4], "device must support four samples for this test");
    NvnTexture depth = test_texture(1, 4, 4, 1, 1, 0x33, 1);
    NvnTexture msaa = test_texture(1, 4, 4, 1, 1, 0x33, 4);
    bind_targets(NULL, &depth, NULL); prepare_draw();
    // Same vertex program, with a fragment stage that has no color outputs.
    static NvnProgram program;
    static uint64_t fragment[128];
    program = *st.program;
    memcpy(fragment, (const void *)(uintptr_t)program.stages[1].code_addr, sizeof fragment);
    *(uint32_t *)((uint8_t *)fragment + 0x78) = 0;
    program.stages[1].code_addr = (uint64_t)fragment;
    st.program = &program;
    fullscreen_draw(1); expect_depth(&depth, 0.5f);
    bind_targets(NULL, &msaa, NULL);
    fullscreen_draw(1); check_gpu();
    bind_targets(NULL, &depth, NULL);
    fullscreen_draw(1); expect_depth(&depth, 0.5f);
    destroy_texture(&depth); destroy_texture(&msaa);
}

static void draw_layers(NvnTexture *color, NvnTexture *depth, unsigned count) {
    bind_targets(color, depth, NULL);
    begin_pass();
    static id<MTLLibrary> library;
    if (!library) {
        NSError *error = nil;
        library = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct V { float4 pos [[position]]; uint layer [[render_target_array_index]]; };"
            "vertex V vs(uint vid [[vertex_id]], uint iid [[instance_id]]) {"
            "float2 p = float2((vid << 1) & 2, vid & 2); return {float4(p * 2 - 1, 0.5, 1), iid}; }"
            "fragment float4 fs() { return float4(0,1,0,1); } fragment void fs_none() {}"
                                     options:nil error:&error];
        CHECK(library != nil, "layer fixture shader compiles");
    }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [library newFunctionWithName:@"vs"];
    pd.fragmentFunction = [library newFunctionWithName:color ? @"fs" : @"fs_none"];
    pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    attachment_formats(pd);
    NSError *error = nil;
    id<MTLRenderPipelineState> pipe = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
    CHECK(pipe != nil, "layer fixture pipeline");
    MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
    ds.depthCompareFunction = MTLCompareFunctionAlways; ds.depthWriteEnabled = depth != NULL;
    [enc setDepthStencilState:[dev newDepthStencilStateWithDescriptor:ds]];
    [enc setRenderPipelineState:pipe];
    [enc setViewport:(MTLViewport){0, 0, 4, 4, 0, 1}];
    [enc setScissorRect:(MTLScissorRect){0, 0, 4, 4}];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:count];
    check_gpu();
    for (unsigned layer = 0; layer < count; layer++) {
        if (color) {
            id<MTLBuffer> out = read_texture(renderer_texture(color, nil, true), layer, 0, 4);
            for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {
                const uint8_t *p = (const uint8_t *)out.contents + y * 256 + x * 4;
                CHECK(p[0] == 0 && p[1] == 255 && p[2] == 0 && p[3] == 255, "shader-selected layer must receive the triangle");
            }
        }
        if (depth) {
            id<MTLBuffer> out = read_texture(renderer_texture(depth, nil, true), layer, 0, 4);
            for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {
                float got = *(const float *)((const uint8_t *)out.contents + y * 256 + x * 4);
                CHECK(fabsf(got - 0.5f) < 0.00001f, "depth layers must receive the triangle, including without color attachments");
            }
        }
    }
}

static void layer_single(void) {
    NvnTexture color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    draw_layers(&color, NULL, 1);
    destroy_texture(&color);
}

static void layer_color_array(void) {
    NvnTexture color = test_texture(4, 4, 4, 3, 1, 0x25, 1);
    draw_layers(&color, NULL, 3);
    destroy_texture(&color);
}

static void layer_mixed_depth(void) {
    NvnTexture color = test_texture(4, 4, 4, 3, 1, 0x25, 1);
    NvnTexture depth = test_texture(4, 4, 4, 2, 1, 0x33, 1);
    draw_layers(&color, &depth, 2);
    destroy_texture(&color); destroy_texture(&depth);
}

static void layer_depth_only(void) {
    NvnTexture depth = test_texture(4, 4, 4, 3, 1, 0x33, 1);
    draw_layers(NULL, &depth, 3);
    destroy_texture(&depth);
}

static void clear_layered(void) {
    NvnTexture color = test_texture(4, 4, 4, 3, 1, 0x25, 1);
    NvnTexture depth = test_texture(4, 4, 4, 2, 1, 0x33, 1);
    bind_targets(&color, &depth, NULL);
    const float red[] = {1, 0, 0, 1};
    clear(0, 0, red, 15, true, 0.75f, false, 0, 0);
    for (unsigned layer = 0; layer < 2; layer++) {
        expect_rgba_slice(&color, layer, 255, 0, 0);
        expect_depth_slice(&depth, layer, 0.75f);
    }
    destroy_texture(&color); destroy_texture(&depth);
}

static void clear_mip_extent(void) {
    NvnTexture color = test_texture(1, 8, 8, 1, 2, 0x25, 1);
    bind_targets(&color, NULL, NULL);
    st.rt.has_cview[0] = 1;
    st.rt.cview[0] = (NvnTextureView){.setmask = 1, .base_level = 1, .num_levels = 1};
    st.scissor[0][2] = st.scissor[0][3] = 16384;
    const float red[] = {1, 0, 0, 1};
    clear(0, 0, red, 15, false, 0, false, 0, 0);
    id<MTLBuffer> out = read_texture(renderer_texture(&color, nil, true), 0, 1, 4);
    for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {
        const uint8_t *p = (const uint8_t *)out.contents + y * 256 + x * 4;
        CHECK(p[0] == 255 && p[1] == 0 && p[2] == 0 && p[3] == 255, "clear/scissor extent must use the selected mip dimensions");
    }
    destroy_texture(&color);
}

static void clear_minimum_extent(bool with_depth) {
    NvnTexture color = test_texture(1, 8, 8, 1, 1, 0x25, 1);
    NvnTexture small = test_texture(1, 4, 4, 1, 1, with_depth ? 0x33 : 0x25, 1);
    bind_targets(&color, with_depth ? &small : NULL, with_depth ? NULL : &small);
    st.scissor[0][2] = st.scissor[0][3] = 16384;
    const float red[] = {1, 0, 0, 1};
    clear(0, 0, red, 15, with_depth, 0.75f, false, 0, 0);
    // The common pass covers only the first 4x4 pixels of the larger color attachment.
    expect_rgba(&color, 255, 0, 0);
    if (with_depth) expect_depth(&small, 0.75f);
    destroy_texture(&color); destroy_texture(&small);
}

static void clear_minimum_color_extent(void) { clear_minimum_extent(false); }
static void clear_minimum_depth_extent(void) { clear_minimum_extent(true); }

static void stencil_without_attachment(void) {
    NvnTexture color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    NvnTexture depth = test_texture(1, 4, 4, 1, 1, 0x33, 1);
    const float black[] = {0, 0, 0, 1};
    for (int use_depth = 0; use_depth <= 1; use_depth++) {
        bind_targets(&color, use_depth ? &depth : NULL, NULL); prepare_draw();
        st.ds[0] = st.ds[1] = 0; st.ds[3] = 1; st.ds[4] = 0x11; // both stencil faces NEVER
        clear(0, 0, black, 15, false, 0, false, 0, 0);
        fullscreen_draw(1); expect_rgba(&color, 0, 255, 0);
    }
    destroy_texture(&color); destroy_texture(&depth);
}

static void depth_attachment_cache(void) {
    NvnTexture color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    NvnTexture depth = test_texture(1, 4, 4, 1, 1, 0x33, 1);
    const float black[] = {0, 0, 0, 1};
    for (int phase = 0; phase < 3; phase++) {
        bind_targets(&color, phase == 1 ? NULL : &depth, NULL); prepare_draw();
        st.ds[0] = 1; st.ds[1] = 0; st.ds[2] = 1; // depth NEVER with unchanged guest state
        clear(0, 0, black, 15, false, 0, false, 0, 0);
        fullscreen_draw(1); expect_rgba(&color, 0, phase == 1 ? 255 : 0, 0);
    }
    destroy_texture(&color); destroy_texture(&depth);
}

static void stencil_attachment_cache(void) {
    NvnTexture color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    NvnTexture depth = test_texture(1, 4, 4, 1, 1, 0x33, 1);
    NvnTexture stencil = test_texture(1, 4, 4, 1, 1, 0x35, 1);
    const float black[] = {0, 0, 0, 1};
    for (int phase = 0; phase < 3; phase++) {
        bind_targets(&color, phase == 1 ? &depth : &stencil, NULL); prepare_draw();
        st.ds[0] = st.ds[1] = 0; st.ds[3] = 1; st.ds[4] = 0x11;
        clear(0, 0, black, 15, false, 0, false, 0, 0);
        fullscreen_draw(1); expect_rgba(&color, 0, phase == 1 ? 255 : 0, 0);
    }
    destroy_texture(&color); destroy_texture(&depth); destroy_texture(&stencil);
}

static void stencil_only_depth_ignored(void) {
    NvnTexture color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    NvnTexture stencil = test_texture(1, 4, 4, 1, 1, 0x31, 1);
    bind_targets(&color, &stencil, NULL); prepare_draw();
    st.ds[0] = 1; st.ds[1] = 0; st.ds[2] = 1;
    fullscreen_draw(1); expect_rgba(&color, 0, 255, 0);
    destroy_texture(&color); destroy_texture(&stencil);
}

static void direct_zero_instances(bool indexed) {
    NvnTexture color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    bind_targets(&color, NULL, NULL); prepare_draw();
    const float black[4] = {0, 0, 0, 1};
    clear(0, 0, black, 15, false, 0, false, 0, 0);
    CmdRec r = {.op = CMD_DRAW_ARRAYS, .size = sizeof(CmdRec), .x = {4, 0, 3, 0, 0}};
    if (indexed) {
        const uint16_t indices[] = {0, 1, 2};
        memcpy((uint8_t *)g_guest_buffer.contents + 128, indices, sizeof indices);
        r.op = CMD_DRAW_ELEMENTS; r.x[1] = 1; r.x[3] = (uint64_t)g_guest_buffer.contents + 128;
    }
    draw(&r, indexed);
    expect_rgba(&color, 0, 0, 0);
    r.x[indexed ? 6 : 4] = 1;
    draw(&r, indexed);
    expect_rgba(&color, 0, 255, 0);
    destroy_texture(&color);
}

static void zero_array_instances(void) { direct_zero_instances(false); }
static void zero_indexed_instances(void) { direct_zero_instances(true); }

static void raster_discard_restore(void) {
    NvnTexture color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    bind_targets(&color, NULL, NULL); prepare_draw();
    // A unique vertex address keeps both variants cold regardless of earlier test cases.
    static NvnProgram program;
    static uint64_t vertex[128];
    program = *st.program;
    memcpy(vertex, (const void *)(uintptr_t)program.stages[0].code_addr, sizeof vertex);
    program.stages[0].code_addr = (uint64_t)vertex;
    st.program = &program;
    const float black[] = {0, 0, 0, 1};
    clear(0, 0, black, 15, false, 0, false, 0, 0);
    g_raster_discard = true; fullscreen_draw(1); expect_rgba(&color, 0, 0, 0);
    g_raster_discard = false; fullscreen_draw(1); expect_rgba(&color, 0, 255, 0);
    destroy_texture(&color);
}

static void check_xfb_instances(unsigned stream) {
    NvnTexture color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    bind_targets(&color, NULL, NULL); prepare_draw();
    st.attrib[0] = 0x2e | (stream << 8);
    st.nstream = stream + 1; st.stream[stream][0] = 16; st.vbuf[stream] = st.vbuf[0];
    static uint8_t control[0x800];
    *(uint32_t *)(control + 0x4dc) = 1;
    *(uint16_t *)(control + 0x6dc) = 4;
    st.program->stages[0].control = control;
    st.program->stage_mask = 1;
    g_xfb_on = g_raster_discard = true;
    g_xfb_addr[0] = g_gwin_base + 1024; g_xfb_size[0] = 12;
    uint32_t *out = (uint32_t *)((uint8_t *)g_guest_buffer.contents + 1024);
    for (int i = 0; i < 3; i++) out[i] = 0xdeadbeef;
    fullscreen_draw(0); check_gpu();
    for (int i = 0; i < 3; i++) CHECK(out[i] == 0xdeadbeef, "zero-instance transform feedback must not write guest memory");
    fullscreen_draw(1); check_gpu();
    CHECK(out[0] == 0xbf800000 && out[1] == 0x40400000 && out[2] == 0xbf800000,
          "one-instance transform feedback writes the three vertex x values");
    st.program->stage_mask = 3; st.program->stages[0].control = NULL;
    g_xfb_on = g_raster_discard = g_xfb_dirty = false;
    memset(g_xfb_addr, 0, sizeof g_xfb_addr); memset(g_xfb_size, 0, sizeof g_xfb_size);
    destroy_texture(&color);
}

static void zero_xfb_instances(void) { check_xfb_instances(0); }
static void xfb_stream_four(void) { check_xfb_instances(4); }

static void xfb_vertex_reuse(void) {
    NvnTexture color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    bind_targets(&color, NULL, NULL); prepare_draw();
    static uint8_t control[0x800];
    *(uint32_t *)(control + 0x4dc) = 4;
    *(uint16_t *)(control + 0x6dc) = 16;
    st.program->stages[0].control = control;
    st.program->stage_mask = 1;
    g_xfb_on = g_raster_discard = true;
    g_xfb_addr[0] = g_gwin_base + 1024; g_xfb_size[0] = 48;
    memset((uint8_t *)g_guest_buffer.contents + 1024, 0, 48);
    uint64_t passes = stat_passes;
    fullscreen_draw(1);
    uint64_t commands[32] = {0};
    CmdRec *end = (CmdRec *)commands;
    end->op = CMD_END_XFB; end->size = sizeof *end;
    ((CmdRec *)((uint8_t *)end + end->size))->op = CMD_END;
    exec_list((uint64_t)commands, 0);
    st.program->stage_mask = 3; st.program->stages[0].control = NULL;
    g_raster_discard = false;
    st.vbuf[0] = (Range){.addr = g_gwin_base + 1024, .size = 48};
    // Consume GPU-produced positions without a CPU wait or intervening submission.
    fullscreen_draw(1);
    const char *option = getenv("LARECOMP_XFB_END_BARRIER");
    bool merged = false;
    if (@available(macOS 13.0, *)) merged = option ? atoi(option) != 0 : g_settings.xfb_barrier;
    CHECK(stat_passes - passes == (merged ? 1 : 2), "XFB barrier reuses the pass when on (the setting's default); the original boundary when off");
    expect_rgba(&color, 0, 255, 0);
    g_xfb_on = g_xfb_dirty = false;
    memset(g_xfb_addr, 0, sizeof g_xfb_addr); memset(g_xfb_size, 0, sizeof g_xfb_size);
    destroy_texture(&color);
}

static void vertex_stream_fifteen(void) {
    NvnTexture color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    bind_targets(&color, NULL, NULL); prepare_draw();
    st.attrib[0] = 0x2e | (15u << 8);
    st.nstream = 16; st.stream[15][0] = 16; st.vbuf[15] = st.vbuf[0];
    fullscreen_draw(1); expect_rgba(&color, 0, 255, 0);
    destroy_texture(&color);
}

static void vertex_stream_layout_cache(void) {
    NvnTexture color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    bind_targets(&color, NULL, NULL); prepare_draw();
    static NvnProgram program;
    static uint64_t vertex[128];
    program = *st.program;
    const uint64_t schedule = 0x001f8000fc0007e0ull;
    unsigned at = 16;
#define VINS(w) do { if (!(at & 3)) vertex[at++] = schedule; vertex[at++] = (w); } while (0)
    VINS(0xefd8000000000000ull | (3ull << 47) | (0x80ull << 20) | (7ull << 16) | (255ull << 8));
    // Sum zero-valued attributes into position.x, so all streams and the unbound attribute 16 are consumed.
    for (unsigned attr = 1; attr <= 16; attr++) {
        VINS(0xefd8000000000004ull | ((0x80ull + 16 * attr) << 20) | (7ull << 16) | (255ull << 8));
        VINS(0x5c58000000000000ull | (4ull << 20) | (7ull << 16));
    }
    // An active constant at native slot 16 must survive assignment of the high vertex streams.
    VINS(0x4c98078000000005ull | (16ull << 34) | (7ull << 16));
    VINS(0x5c58000000000000ull | (5ull << 20) | (7ull << 16));
    VINS(0x0100000000070006ull | (0xc0000000ull << 20)); // -2.0
    VINS(0x5c58000000000000ull | (6ull << 20) | (7ull << 16));
    VINS(0xeff0000000000000ull | (3ull << 47) | (0x70ull << 20) | (7ull << 16));
    VINS(0xe30000000007000full); VINS(0xe2400fffff87000full);
#undef VINS
    program.stages[0].code_addr = (uint64_t)vertex;
    program.stages[0].const_offset = sizeof vertex;
    st.program = &program; st.nattrib = st.nstream = 16;
    memset((uint8_t *)g_guest_buffer.contents + 2048, 0, 128);
    memset((uint8_t *)g_guest_buffer.contents + 4096, 0, 128);
    *(float *)((uint8_t *)g_guest_buffer.contents + 8192) = 2.0f;
    st.ubuf[0][13] = (Range){.addr = g_gwin_base + 8192, .size = 256};
    for (unsigned s = 0; s < 16; s++) {
        st.attrib[s] = 0x2e | (s << 8);
        if (s) {
            st.stream[s][0] = 0;
            st.vbuf[s] = (Range){.addr = g_gwin_base + 2048, .size = 128};
        }
    }
    st.vbuf[15].addr = g_gwin_base + 4096; st.stream[15][0] = 16;
    const float black[] = {0, 0, 0, 1};
    clear(0, 0, black, 15, false, 0, false, 0, 0);
    fullscreen_draw(1); expect_rgba(&color, 0, 255, 0);
    *(float *)((uint8_t *)g_guest_buffer.contents + 4096 + 16) = -8;
    st.stream[15][0] = 32;
    clear(0, 0, black, 15, false, 0, false, 0, 0);
    fullscreen_draw(1); expect_rgba(&color, 0, 255, 0);
    memset((uint8_t *)g_guest_buffer.contents + 4096, 0, 128); st.stream[15][0] = 16;
    clear(0, 0, black, 15, false, 0, false, 0, 0);
    fullscreen_draw(1); expect_rgba(&color, 0, 255, 0);
    destroy_texture(&color);
}

static void gpu_indirect_instances(bool indexed) {
    NvnTexture color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    bind_targets(&color, NULL, NULL); prepare_draw();
    const float black[4] = {0, 0, 0, 1};
    const uint16_t indices[] = {0, 1, 2};
    memcpy((uint8_t *)g_guest_buffer.contents + 128, indices, sizeof indices);
    uint32_t *args = (uint32_t *)((uint8_t *)g_guest_buffer.contents + 2048);
    CmdRec r = {.op = CMD_DRAW_ARRAYS_INDIRECT, .size = sizeof(CmdRec), .x = {4, g_gwin_base + 2048}};
    if (indexed) {
        r.op = CMD_DRAW_ELEMENTS_INDIRECT; r.x[1] = 1; r.x[2] = g_gwin_base + 128; r.x[3] = g_gwin_base + 2048;
    }
    for (int visible = 1; visible >= 0; visible--) {
        clear(0, 0, black, 15, false, 0, false, 0, 0);
        args[0] = 3; args[1] = !visible; args[2] = args[3] = args[4] = 0;
        uint32_t count = (uint32_t)visible;
        id<MTLBuffer> update = [dev newBufferWithBytes:&count length:sizeof count options:MTLResourceStorageModeShared];
        end_pass("other");
        id<MTLBlitCommandEncoder> bl = [cb() blitCommandEncoder];
        [bl copyFromBuffer:update sourceOffset:0 toBuffer:g_guest_buffer destinationOffset:2052 size:4];
        [bl endEncoding];
        CHECK(args[1] == (uint32_t)!visible, "the CPU must still see the stale indirect count before submission");
        draw_indirect(&r);
        expect_rgba(&color, 0, visible ? 255 : 0, 0);
    }
    destroy_texture(&color);
}

static void gpu_indirect_arrays(void) { gpu_indirect_instances(false); }
static void gpu_indirect_indexed(void) { gpu_indirect_instances(true); }

static NvnSamplerDesc test_sampler(void) {
    return (NvnSamplerDesc){.min_filter = 3, .mag_filter = 1, .wrap = {7, 7, 7},
                            .lod_max = 1000, .max_aniso = 1};
}

static void sample_pixel(id<MTLTexture> texture, NvnSamplerDesc *desc, float u, float v, float lod, float out[4]) {
    static id<MTLComputePipelineState> pipe;
    if (!pipe) {
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void sample_pixel(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],"
            "constant float4 &p [[buffer(0)]], device float4 &out [[buffer(1)]]) {"
            "out = t.sample(s, p.xy, level(p.z)); }";
        NSError *error = nil;
        id<MTLLibrary> library = [dev newLibraryWithSource:source options:nil error:&error];
        CHECK(library != nil, "sampler fixture shader compiles");
        pipe = [dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"sample_pixel"] error:&error];
        CHECK(pipe != nil, "sampler fixture pipeline");
    }
    id<MTLSamplerState> sampler = sampler_for(desc);
    CHECK(sampler != nil, "production sampler creation");
    id<MTLBuffer> result = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    for (int i = 0; i < 4; i++) ((float *)result.contents)[i] = NAN;
    id<MTLCommandBuffer> cmd = [renderer_queue() commandBuffer];
    id<MTLComputeCommandEncoder> compute = [cmd computeCommandEncoder];
    const float p[] = {u, v, lod, 0};
    [compute setComputePipelineState:pipe]; [compute setTexture:texture atIndex:0];
    [compute setSamplerState:sampler atIndex:0]; [compute setBytes:p length:sizeof p atIndex:0];
    [compute setBuffer:result offset:0 atIndex:1];
    [compute dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [compute endEncoding]; [cmd commit]; [cmd waitUntilCompleted];
    CHECK(!cmd.error, "sampler GPU command buffer");
    memcpy(out, result.contents, 16);
}

static void sampler_reduction(void) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                               width:2 height:2 mipmapped:YES];
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [dev newTextureWithDescriptor:td];
    const float texels[] = {0, 1, 1, 1}, mip = 1, want[] = {0.75f, 0, 1};
    [texture replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0 withBytes:texels bytesPerRow:8];
    [texture replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:1 withBytes:&mip bytesPerRow:4];
    for (unsigned mf = 3; mf <= 5; mf += 2) for (unsigned reduction = 0; reduction < 3; reduction++) {
        NvnSamplerDesc desc = test_sampler(); desc.min_filter = mf; desc.reduction = reduction;
        float got[4]; sample_pixel(texture, &desc, 0.5f, 0.5f, 0, got);
        fprintf(stderr, "sampler min=%u reduction=%u got=%g want=%g\n", mf, reduction, got[0], want[reduction]);
        CHECK(fabsf(got[0] - want[reduction]) < 0.00001f, "MIN/MAX must reduce the contributing texels instead of averaging");
        CFRelease(desc.backend);
    }
}

static void sampler_border(void) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                               width:1 height:1 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [dev newTextureWithDescriptor:td];
    const uint8_t red[] = {255, 0, 0, 255};
    [texture replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:red bytesPerRow:4];
    const float colors[][4] = {{0, 0, 0, 0}, {0, 0, 0, 1}, {1, 1, 1, 1}};
    const float coords[][2] = {{-1, 0.5f}, {0.5f, 2}};
    for (unsigned color = 0; color < 3; color++) {
        NvnSamplerDesc desc = test_sampler(); desc.min_filter = desc.mag_filter = 0;
        desc.wrap[0] = desc.wrap[1] = 5; memcpy(desc.border, colors[color], 16);
        for (unsigned coord = 0; coord < 2; coord++) {
            float got[4]; sample_pixel(texture, &desc, coords[coord][0], coords[coord][1], 0, got);
            for (int c = 0; c < 4; c++) {
                fprintf(stderr, "border=%u axis=%u component=%d got=%g want=%g\n", color, coord, c, got[c], colors[color][c]);
                CHECK(fabsf(got[c] - colors[color][c]) < 0.00001f, "out-of-range sample must return the requested standard border color");
            }
        }
        CFRelease(desc.backend);
    }
}

static void sampler_bias(void) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                               width:4 height:4 mipmapped:YES];
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [dev newTextureWithDescriptor:td];
    const uint32_t colors[] = {0xff0000ff, 0xff00ff00, 0xffff0000};
    for (unsigned level = 0; level < 3; level++) {
        unsigned width = 4 >> level; uint32_t pixels[16];
        for (unsigned i = 0; i < width * width; i++) pixels[i] = colors[level];
        [texture replaceRegion:MTLRegionMake2D(0, 0, width, width) mipmapLevel:level withBytes:pixels bytesPerRow:width * 4];
    }
    const struct { float bias, lod, want[4]; } cases[] = {
        {-1, 1, {1, 0, 0, 1}}, {0, 1, {0, 1, 0, 1}}, {1, 0, {0, 1, 0, 1}}, {1, 1, {0, 0, 1, 1}},
    };
    for (unsigned mf = 3; mf <= 5; mf += 2) for (unsigned i = 0; i < sizeof cases / sizeof *cases; i++) {
        NvnSamplerDesc desc = test_sampler(); desc.min_filter = mf; desc.lod_bias = cases[i].bias;
        float got[4]; sample_pixel(texture, &desc, 0.5f, 0.5f, cases[i].lod, got);
        fprintf(stderr, "sampler min=%u bias=%g lod=%g got=(%g,%g,%g,%g)\n", mf, desc.lod_bias, cases[i].lod, got[0], got[1], got[2], got[3]);
        for (int c = 0; c < 4; c++) CHECK(fabsf(got[c] - cases[i].want[c]) < 0.00001f, "sampler bias must select the expected colored mip even with explicit LOD");
        CFRelease(desc.backend);
    }
}

static bool native_sampler_available(void) {
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (@available(macOS 26.0, *)) return true;
#endif
    return false;
}

enum { TEX_FETCH, TEX_SAMPLE, TEX_GATHER, TEX_MISSING_SHAPE, TEX_FEEDBACK, TEX_MODE_COUNT };

// A float clear of an integer target converts the value (Pokémon Z-A clears its R8_UINT shadow caster map with 1.0).
static void clear_float_uint(void) {
    NvnTexture t = test_texture(1, 4, 4, 1, 1, 0x03, 1);
    bind_targets(&t, NULL, NULL); prepare_draw();
    const float one[4] = {1, 1, 1, 1};
    clear(0, 0, one, 15, false, 0, false, 0, 0);
    id<MTLBuffer> out = read_texture(renderer_texture(&t, nil, true), 0, 0, 1);
    fprintf(stderr, "float clear 1.0 of R8_UINT -> %u\n", *(const uint8_t *)out.contents);
    CHECK(*(const uint8_t *)out.contents == 1, "float clear of an integer target converts the value");
    destroy_texture(&t);
}

static void typed_texture_reads(bool compute, int sample) {
    // One shader/handle is rebound across scalar kinds, then reused: both fast and slow program keys must vary.
    const struct { uint32_t format, bits, view_format; } cases[] = {
        {0x03, 173, 0}, {0x0b, 0xf1234567, 0}, {0x0c, 0xffffffe9, 0},
        {0x0a, 0x3f200000, 0}, {0x0b, 0xfffffffe, 0x0c}, {0x03, 173, 0},
    };
    NvnTexture output = test_texture(1, 4, 4, 1, 1, 0x0b, 1);
    static NvnProgram graphics[TEX_MODE_COUNT], dispatch[TEX_MODE_COUNT];
    static uint64_t fragment[TEX_MODE_COUNT][128], kernel[TEX_MODE_COUNT][32];
    const uint64_t schedule = 0x001f8000fc0007e0ull;
    const uint64_t lookup = sample == TEX_GATHER
        ? 0xc800000000000000ull | (2ull << 54) | (8ull << 36) | (1ull << 31) | (2ull << 28) | (6ull << 20) | (7ull << 16) | (4ull << 8)
        : (sample ? 0xd000000000000000ull : 0xd200000000000000ull) |
            (1ull << 59) | ((sample == TEX_MISSING_SHAPE ? 11ull : 2ull) << 53) | (8ull << 36) | (255ull << 28) | (5ull << 20) | (7ull << 16) | (4ull << 8);
    const uint64_t coord = sample ? 0x3f000000ull : 0;
    if (!kernel[sample][0]) {
        kernel[sample][0] = kernel[sample][4] = kernel[sample][8] = schedule;
        kernel[sample][1] = 0x0100000000070004ull | (coord << 20);
        kernel[sample][2] = 0x0100000000070005ull | (coord << 20);
        kernel[sample][3] = lookup;
        kernel[sample][5] = 0x0100000000070008ull | ((uint64_t)(uint32_t)(g_gwin_base + 512) << 20);
        kernel[sample][6] = 0x0100000000070009ull | ((g_gwin_base >> 32) << 20);
        kernel[sample][7] = 0xeed8000000000000ull | (4ull << 48) | (1ull << 45) | (7ull << 16) | (8ull << 8);
        kernel[sample][9] = 0xe30000000007000full; kernel[sample][10] = 0xe2400fffff87000full;
        dispatch[sample].stage_mask = 1u << STAGE_COMPUTE;
        dispatch[sample].stages[5] = (NvnShaderStage){.stage = 5, .code_addr = (uint64_t)kernel[sample], .const_offset = sizeof kernel[sample]};
    }
    for (unsigned c = 0; c < sizeof cases / sizeof *cases; c++) {
        if (sample == TEX_FEEDBACK && cases[c].format == 0x03) continue; // this case reads back 32-bit render targets
        uint32_t want = sample == TEX_MISSING_SHAPE ? 0 : cases[c].bits;
        NvnTexture source = test_texture(1, 4, 4, 1, 1, cases[c].format, 1);
        bind_targets(&source, NULL, NULL);
        const uint32_t color[] = {cases[c].bits, 0, 0, 1};
        // raw bits through the integer clears (ClearColorui / ClearColori); a float clear converts the value
        int kind = renderer_format_is_uint(cases[c].format) ? 2 : renderer_format_is_sint(cases[c].format) ? 1 : 0;
        clear(0, kind, color, 15, false, 0, false, 0, 0);
        NvnTexEntry entries[2] = {{0}, {.tex = &source}};
        if (cases[c].view_format) {
            entries[1].has_view = 1;
            entries[1].view = (NvnTextureView){.setmask = 4, .format = cases[c].view_format};
        }
        NvnDescPool textures = {.entries = entries, .count = 2};
        NvnSamplerDesc sampler = {.lod_max = 1000, .max_aniso = 1};
        NvnDescPool samplers = {.entries = &sampler, .count = 1};
        st.tpool = &textures; st.spool = &samplers;
        if (compute) {
            st.program = &dispatch[sample]; st.tex[5][0] = 1;
            uint32_t *result = (uint32_t *)((uint8_t *)g_guest_buffer.contents + 512);
            *result = 0xdeadbeef;
            dispatch_compute(1, 1, 1); check_gpu();
            fprintf(stderr, "compute mode=%d format=%#x view=%#x got=%#x want=%#x\n", sample, cases[c].format, cases[c].view_format, *result, want);
            CHECK(*result == want, "compute texture read preserves raw integer or float bits across bindings");
        } else {
            NvnTexture *destination = sample == TEX_FEEDBACK ? &source : &output;
            bind_targets(destination, NULL, NULL); prepare_draw();
            if (!graphics[sample].stage_mask) {
                graphics[sample] = *st.program;
                uint64_t *fs = fragment[sample];
                *(uint32_t *)((uint8_t *)fs + 0x78) = 1;
                fs[16] = fs[20] = schedule;
                fs[17] = 0x0100000000070004ull | (coord << 20);
                fs[18] = 0x0100000000070005ull | (coord << 20);
                fs[19] = lookup;
                fs[21] = 0xe30000000007000full; fs[22] = 0xe2400fffff87000full;
                graphics[sample].stages[1].code_addr = (uint64_t)fs;
            }
            st.program = &graphics[sample]; st.tex[1][0] = 1;
            fullscreen_draw(1);
            id<MTLBuffer> readback = read_texture(renderer_texture(destination, nil, true), 0, 0, 4);
            uint32_t got = *(uint32_t *)readback.contents;
            fprintf(stderr, "graphics mode=%d format=%#x view=%#x got=%#x want=%#x\n", sample, cases[c].format, cases[c].view_format, got, want);
            for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++)
                CHECK(*(uint32_t *)((uint8_t *)readback.contents + y * 256 + x * 4) == want,
                      "fragment texture read preserves raw integer or float bits across bindings");
        }
        destroy_texture(&source);
        if (sampler.backend) CFRelease(sampler.backend);
        st.tpool = st.spool = NULL;
    }
    destroy_texture(&output);
}

static void typed_fragment_fetch(void) { typed_texture_reads(false, TEX_FETCH); }
static void typed_fragment_sample(void) { typed_texture_reads(false, TEX_SAMPLE); }
static void typed_compute_fetch(void) { typed_texture_reads(true, TEX_FETCH); }
static void typed_compute_sample(void) { typed_texture_reads(true, TEX_SAMPLE); }
static void typed_fragment_gather(void) { typed_texture_reads(false, TEX_GATHER); }
static void typed_compute_gather(void) { typed_texture_reads(true, TEX_GATHER); }
static void typed_fragment_fallback(void) { typed_texture_reads(false, TEX_MISSING_SHAPE); }
static void typed_compute_fallback(void) { typed_texture_reads(true, TEX_MISSING_SHAPE); }
static void typed_fragment_feedback(void) { typed_texture_reads(false, TEX_FEEDBACK); }
static void typed_feedback_cleanup(void) {
    int initial_views = g_views_live;
    NSUInteger initial_snapshots = g_snap_copies.count;
    typed_texture_reads(false, TEX_FEEDBACK);
    fprintf(stderr, "feedback cleanup: views=%d (initial%d) snapshots=%lu (initial%lu)\n", g_views_live, initial_views,
            (unsigned long)g_snap_copies.count, (unsigned long)initial_snapshots);
    CHECK(g_snap_copies.count == initial_snapshots && g_views_live == initial_views,
          "destroying feedback sources must release snapshots and all cached snapshot views");
    NvnTexEntry empty = {0};
    CHECK(feedback_sample(&empty, nil) == nil, "an unbound descriptor must still reach its normal fallback after feedback cleanup");
}

static void scaled_fragment_fetch(void) {
    // A screen-space integer fetch must retain each physical pixel, rather than repeat one guest-pixel centre.
    // The fixed-coordinate shader is a control: without a fragment-position input it must remain uniform.
    static const struct { float x, y; uint32_t fixed; } scales[] = {
        {1, 1, 514}, {1.5f, 1.5f, 771}, {2, 2, 1284}, {1.5f, 2, 1283}, {0.75f, 0.75f, 258},
    };
    static uint64_t fragment[7][128];
    static NvnProgram graphics[7];
    unsigned bad = 0;
    for (unsigned c = 0; c < sizeof scales / sizeof *scales; c++) {
        renderer_set_scale(scales[c].x, scales[c].y);
        NvnTexture source = test_texture(1, 64, 36, 1, 1, 0x0b, 1);
        NvnTexture destination = test_texture(1, 64, 36, 1, 1, 0x0b, 1);
        bind_targets(&source, NULL, NULL);
        const uint32_t zero[4] = {0};
        clear(0, 2, zero, 15, false, 0, false, 0, 0);
        check_gpu();
        id<MTLTexture> texture = renderer_texture(&source, nil, true);
        NSUInteger w = texture.width, h = texture.height, row = (w * 4 + 255) & ~(NSUInteger)255;
        id<MTLBuffer> upload = [dev newBufferWithLength:row * h options:MTLResourceStorageModeShared];
        for (NSUInteger y = 0; y < h; y++) for (NSUInteger x = 0; x < w; x++)
            *(uint32_t *)((uint8_t *)upload.contents + y * row + x * 4) = 1 + x + 256 * y;
        id<MTLCommandBuffer> command = [renderer_queue() commandBuffer];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        [blit copyFromBuffer:upload sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:row * h
                 sourceSize:MTLSizeMake(w, h, 1) toTexture:texture destinationSlice:0 destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding]; [command commit]; [command waitUntilCompleted];
        CHECK(!command.error, "scaled source upload completes");
        NvnTexEntry entries[2] = {{0}, {.tex = &source}};
        NvnDescPool textures = {.entries = entries, .count = 2};
        NvnSamplerDesc sampler = {.lod_max = 1000, .max_aniso = 1};
        NvnDescPool samplers = {.entries = &sampler, .count = 1};
        for (unsigned mode = 0; mode < 7; mode++) {
            bool fixed = mode == 1 || mode == 2;
            bind_targets(&destination, NULL, NULL); prepare_draw();
            st.viewport[0][2] = st.scissor[0][2] = 64;
            st.viewport[0][3] = st.scissor[0][3] = 36;
            if (!graphics[mode].stage_mask) {
                graphics[mode] = *st.program;
                uint64_t ops[12]; unsigned n = 0;
                uint64_t lookup = 0xd200000000000000ull | (1ull << 59) | (2ull << 53) | (8ull << 36) |
                                  (255ull << 28) | (5ull << 20) | (7ull << 16) | (4ull << 8);
                if (!fixed || mode == 2) {
                    if (mode == 6) {
                        ops[n++] = 0xe000000000000004ull | (0x70ull << 28) | (7ull << 16) | (255ull << 8);
                        ops[n++] = 0xe000000000000005ull | (0x74ull << 28) | (7ull << 16) | (255ull << 8);
                    } else ops[n++] = 0xefd8000000000004ull | (1ull << 47) | (0x70ull << 20) | (7ull << 16) | (255ull << 8);
                    for (unsigned r = 4; r <= 5; r++)
                        ops[n++] = 0x5cb0000000000000ull | (3ull << 39) | ((uint64_t)r << 20) |
                                   (7ull << 16) | (2ull << 10) | (2ull << 8) | r;
                    if (mode == 2) ops[n++] = lookup | 8;  // screen read, then overwrite its coordinate registers
                }
                if (fixed) {
                    // Position.w is common in ordinary material shaders; it does not make a fetch screen-relative.
                    if (mode == 1) ops[n++] = 0xefd8000000000006ull | (0x7cull << 20) | (7ull << 16) | (255ull << 8);
                    ops[n++] = 0x0100000000070004ull | (1ull << 20);
                    ops[n++] = 0x0100000000070005ull | (2ull << 20);
                }
                if (mode == 3) {  // moving a converted coordinate retains its phase
                    ops[n++] = 0x5c98000000000006ull | (4ull << 20) | (7ull << 16);
                    ops[n++] = 0x5c98000000000007ull | (5ull << 20) | (7ull << 16);
                    lookup = (lookup & ~((255ull << 8) | (255ull << 20))) | (6ull << 8) | (7ull << 20);
                }
                if (mode == 4) ops[n++] = 0x0100000000000004ull | (1ull << 20);  // @P0 (false): must not reset phase
                if (mode == 5) {
                    ops[n++] = 0x0100000000070006ull;  // explicit LOD zero; y is Ra+1, LOD is Rb
                    lookup = (lookup & ~((15ull << 53) | (255ull << 20))) | (5ull << 53) | (6ull << 20);
                }
                ops[n++] = lookup;
                ops[n++] = 0xe30000000007000full; ops[n++] = 0xe2400fffff87000full;
                uint64_t *fs = fragment[mode];
                *(uint32_t *)((uint8_t *)fs + 0x78) = 1;
                unsigned at = 16;
                for (unsigned i = 0; i < n; i++) {
                    if (!(at & 3)) fs[at++] = 0x001f8000fc0007e0ull;
                    fs[at++] = ops[i];
                }
                graphics[mode].stages[1].code_addr = (uint64_t)fs;
                graphics[mode].stages[1].const_offset = sizeof fragment[mode];
            }
            st.program = &graphics[mode]; st.tpool = &textures; st.spool = &samplers; st.tex[1][0] = 1;
            fullscreen_draw(1);
            id<MTLBuffer> result = read_texture(renderer_texture(&destination, nil, true), 0, 0, 4);
            unsigned wrong = 0;
            for (NSUInteger y = 0; y < h; y++) for (NSUInteger x = 0; x < w; x++) {
                uint32_t got = *(uint32_t *)((uint8_t *)result.contents + y * row + x * 4);
                uint32_t want = fixed ? scales[c].fixed : 1 + x + 256 * y;
                if (got != want && wrong++ < 2)
                    fprintf(stderr, "scale %.2fx%.2f mode=%u pixel %lu,%lu got=%u want=%u\n",
                            scales[c].x, scales[c].y, mode, (unsigned long)x, (unsigned long)y, got, want);
            }
            fprintf(stderr, "scale %.2fx%.2f mode=%u wrong=%u/%lu\n", scales[c].x, scales[c].y,
                    mode, wrong, (unsigned long)(w * h));
            bad += wrong;
        }
        st.tpool = st.spool = NULL;
        if (sampler.backend) CFRelease(sampler.backend);
        destroy_texture(&source); destroy_texture(&destination);
    }
    renderer_set_scale(1, 1);
    CHECK(!bad, "scaled fragment texel fetch must preserve physical pixels and fixed-coordinate reads");
}

static void feedback_mip_chain(bool depth) {
    // Each pass reads the preceding mip of the same texture, as in a depth pyramid.
    static id<MTLLibrary> library;
    if (!library) {
        NSError *error = nil;
        library = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 mip_vs(uint v [[vertex_id]]) { return float4(float2((v << 1) & 2, v & 2) * 2 - 1, 0, 1); }\n"
            "fragment float4 mip_color(texture2d<float, access::read> t [[texture(0)]], constant uint &lod [[buffer(0)]]) {"
            "return float4(t.read(uint2(0), lod).r + 0.125, 0, 0, 1); }\n"
            "struct D { float z [[depth(any)]]; };\n"
            "fragment D mip_depth(depth2d<float> t [[texture(0)]], constant uint &lod [[buffer(0)]]) {"
            "return D{t.read(uint2(0), lod) + 0.125}; }\n" options:nil error:&error];
        if (!library) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        CHECK(library != nil, "mip-chain fixture shaders compile");
    }
    NvnTexture texture = test_texture(1, 8, 8, 1, 4, depth ? 0x33 : 0x0a, 1);
    NvnTexEntry entries[2] = {{0}, {.tex = &texture}};
    NvnDescPool pool = {.entries = entries, .count = 2};
    ShaderInfo vi = {0}, fi = {.ntex = 1};
    fi.tex[0].handle_offset = 0x20; fi.tex[0].type = TEXTYPE_2D;
    Prog *program = [Prog new]; program->vi = &vi; program->fi = &fi;
    st.tpool = &pool; st.tex[1][0] = 1;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [library newFunctionWithName:@"mip_vs"];
    pd.fragmentFunction = [library newFunctionWithName:depth ? @"mip_depth" : @"mip_color"];
    if (depth) pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    else pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
    CHECK(pipeline != nil, "mip-chain fixture pipeline");
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthWriteEnabled = depth; dd.depthCompareFunction = MTLCompareFunctionAlways;
    id<MTLDepthStencilState> ds = [dev newDepthStencilStateWithDescriptor:dd];
    for (unsigned round = 0; round < 2; round++) {
        float seed = 0.25f + round * 0.125f;
        for (unsigned level = 0; level < 4; level++) {
            bind_targets(depth ? NULL : &texture, depth ? &texture : NULL, NULL);
            NvnTextureView view = {.setmask = 1, .base_level = level, .num_levels = 1};
            if (depth) st.rt.dview = view, st.rt.has_dview = 1;
            else st.rt.cview[0] = view, st.rt.has_cview[0] = 1;
            const float color[] = {level ? 0.875f : seed, 0, 0, 1};
            clear(0, 0, color, 15, depth, color[0], false, 0, 0);
        }
        for (unsigned level = 1; level < 4; level++) {
            bind_targets(depth ? NULL : &texture, depth ? &texture : NULL, NULL);
            NvnTextureView view = {.setmask = 1, .base_level = level, .num_levels = 1};
            if (depth) st.rt.dview = view, st.rt.has_dview = 1;
            else st.rt.cview[0] = view, st.rt.has_cview[0] = 1;
            st.ds[0] = st.ds[1] = depth;
            resolve_feedback(program);
            id<MTLTexture> sampled = sampled_texture(&texture, NULL, false, TEXTYPE_2D);
            sampled = feedback_sample(&entries[1], sampled);
            begin_pass();
            NSUInteger size = 8u >> level;
            [enc setRenderPipelineState:pipeline]; [enc setDepthStencilState:ds];
            [enc setViewport:(MTLViewport){0, 0, size, size, 0, 1}];
            [enc setScissorRect:(MTLScissorRect){0, 0, size, size}];
            [enc setFragmentTexture:sampled atIndex:0];
            unsigned lod = level - 1;
            [enc setFragmentBytes:&lod length:sizeof lod atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            end_pass("other"); snapshots_invalidate(&texture);
        }
        for (unsigned level = 1; level < 4; level++) {
            id<MTLBuffer> out = read_texture(renderer_texture(&texture, nil, true), 0, level, 4);
            float want = seed + level * 0.125f, got = *(float *)out.contents;
            fprintf(stderr, "mip-chain depth=%d round=%u level=%u got=%g want=%g\n", depth, round, level, got, want);
            for (unsigned y = 0; y < (8u >> level); y++) for (unsigned x = 0; x < (8u >> level); x++)
                CHECK(fabsf(*(float *)((uint8_t *)out.contents + y * 256 + x * 4) - want) < 0.00001f,
                      "each mip must read the preceding mip, including after the base changes");
        }
    }
    destroy_texture(&texture); st.tpool = NULL;
}

static void feedback_mip_color(void) { feedback_mip_chain(false); }
static void feedback_mip_depth(void) { feedback_mip_chain(true); }

static void feedback_base_alias(void) {
    for (unsigned mode = 0; mode < 3; mode++) {
        NvnTexture texture = test_texture(1, 4, 4, 1, mode == 2 ? 1 : 2, 0x0a, 1);
        bind_targets(&texture, NULL, NULL);
        const float color[] = {0.25f, 0, 0, 1};
        clear(0, 0, color, 15, false, 0, false, 0, 0);
        if (mode == 0) {
            bind_targets(&texture, NULL, &texture);
            st.rt.has_cview[1] = 1;
            st.rt.cview[1] = (NvnTextureView){.setmask = 1, .base_level = 1, .num_levels = 1};
        } else {
            st.rt.has_cview[0] = 1;
            st.rt.cview[0] = (NvnTextureView){.setmask = mode == 2 ? 1 : 0, .base_level = 3, .num_levels = 1};
        }
        NvnTexEntry entries[2] = {{0}, {.tex = &texture}};
        NvnDescPool pool = {.entries = entries, .count = 2};
        ShaderInfo vi = {0}, fi = {.ntex = 1}; fi.tex[0].handle_offset = 0x20;
        Prog *program = [Prog new]; program->vi = &vi; program->fi = &fi;
        st.tpool = &pool; st.tex[1][0] = 1;
        resolve_feedback(program); check_gpu();
        CHECK(nfeedback == 1, "an effective mip-zero attachment still requires a feedback snapshot");
        id<MTLTexture> copy = feedback_sample(&entries[1], renderer_texture(&texture, nil, true));
        NvnSamplerDesc sampler = test_sampler(); float got[4];
        sample_pixel(copy, &sampler, 0.5f, 0.5f, 0, got);
        CHECK(fabsf(got[0] - 0.25f) < 0.00001f, "the base-alias snapshot preserves native GPU texture contents");
        if (sampler.backend) CFRelease(sampler.backend);
        destroy_texture(&texture); st.tpool = NULL;
    }
}

static Prog *source_program(const char *fragment) {
    Prog *pr = [Prog new];
    pr->vi = calloc(1, sizeof *pr->vi); pr->fi = calloc(1, sizeof *pr->fi);
    pr->vi->msl = strdup("#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 main0(uint v [[vertex_id]]) { return float4(float2((v<<1)&2,v&2)*2-1,0,1); }");
    pr->fi->msl = strdup(fragment);
    return pr;
}

static void free_source_program(Prog *pr) {
    free(pr->vi->msl); free(pr->fi->msl); free(pr->vi); free(pr->fi);
}

static void program_readiness(void) {
    CmdRec r = {.op = CMD_DRAW_ARRAYS, .x = {4, 0, 7}};
    CHECK(!prog_ready_or_wait(nil, &r), "a missing program cannot draw");
    Prog *pr = source_program("#include <metal_stdlib>\nusing namespace metal; fragment float4 main0() { return float4(0,1,0,1); }");
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    dispatch_group_t work = dispatch_group_create();
    dispatch_group_async(work, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
        compile_program(pr);
    });
    CHECK(!prog_ready_or_wait(pr, &r), "larger draws skip while real compilation is pending");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        dispatch_semaphore_signal(gate);
    });
    r.x[2] = 6; // inclusive boundary of the small-draw wait
    CHECK(prog_ready_or_wait(pr, &r), "a small draw must wait for actual shader functions");
    dispatch_group_wait(work, DISPATCH_TIME_FOREVER);
    CHECK(pr->vs && pr->fs, "ready publishes both compiled shader functions");
    free_source_program(pr);

    pr = source_program("this is intentionally invalid MSL for the compilation-failure test");
    Prog *failed = pr;
    double start = now_ms();
    dispatch_group_async(work, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ compile_program(failed); });
    CHECK(!prog_ready_or_wait(pr, &r), "a failed compile cannot draw");
    double elapsed = now_ms() - start;
    dispatch_group_wait(work, DISPATCH_TIME_FOREVER);
    CHECK(pr->failed && elapsed < 1500, "failed compilation must release the wait before its two-second timeout");
    fprintf(stderr, "expected compilation failure released the wait after %.1f ms\n", elapsed);
    free_source_program(pr);
}

static void safe_math_graphics(void) {
    const char *source = "#include <metal_stdlib>\nusing namespace metal;\n"
        "fragment float4 main0(constant float &x [[buffer(0)]]) { return float4(isnan(x*(1.0f/x)),0,0,1); }";
    Prog *pr = source_program(source); compile_program(pr);
    CHECK(pr->ready, "safe-math graphics fixture compiles through production options");
    NvnTexture output = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    for (unsigned live = 0; live < 2; live++) {
        if (live) {
            FILE *f = fopen("safe-override.metal", "w"); CHECK(f != NULL, "live override source");
            fputs(source, f); fclose(f);
            char *previous = pr->fi->msl;
            CHECK(live_override_fs(pr, "safe-override.metal"), "live override compiles");
            free(previous);
        }
        bind_targets(&output, NULL, NULL); begin_pass();
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = pr->vs; pd.fragmentFunction = pr->fs; attachment_formats(pd);
        NSError *error = nil;
        id<MTLRenderPipelineState> pipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
        CHECK(pipeline != nil, "safe math render pipeline");
        float zero = 0;
        [enc setRenderPipelineState:pipeline]; [enc setFragmentBytes:&zero length:sizeof zero atIndex:0];
        [enc setViewport:(MTLViewport){0,0,4,4,0,1}]; [enc setScissorRect:(MTLScissorRect){0,0,4,4}];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        id<MTLBuffer> result = read_texture(renderer_texture(&output, nil, true), 0, 0, 4);
        uint8_t red = *(const uint8_t *)result.contents;
        fprintf(stderr, "safe math graphics=%s live=%u isnan=%u\n", getenv("LARECOMP_SAFE_MATH") ?: "default", live, red);
        if (getenv("LARECOMP_SAFE_MATH") && atoi(getenv("LARECOMP_SAFE_MATH")))
            CHECK(red == 255, "safe graphics and live override must retain isnan for runtime zero times infinity");
    }
    destroy_texture(&output); free_source_program(pr);
}

static void shadow_fallback(void) {
    const char *source = "#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void s2(depth2d<float> t [[texture(0)]], sampler s [[sampler(0)]], device float *o [[buffer(0)]], constant float3 &d [[buffer(1)]]) { *o=t.sample_compare(s,float2(0.5),0.5,level(0)); }\n"
        "kernel void sa(depth2d_array<float> t [[texture(0)]], sampler s [[sampler(0)]], device float *o [[buffer(0)]], constant float3 &d [[buffer(1)]]) { *o=t.sample_compare(s,float2(0.5),0,0.5,level(0)); }\n"
        "kernel void sc(depthcube<float> t [[texture(0)]], sampler s [[sampler(0)]], device float *o [[buffer(0)]], constant float3 &d [[buffer(1)]]) { *o=t.sample_compare(s,d,0.5,level(0)); }\n"
        "kernel void ss(depthcube_array<float> t [[texture(0)]], sampler s [[sampler(0)]], device float *o [[buffer(0)]], constant float3 &d [[buffer(1)]]) { *o=t.sample_compare(s,d,0,0.5,level(0)); }\n";
    NSError *error = nil;
    id<MTLLibrary> library = [dev newLibraryWithSource:@(source) options:nil error:&error];
    if (!library) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
    CHECK(library != nil, "shadow comparison fixtures compile");
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.compareFunction = MTLCompareFunctionLessEqual;
    id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
    const struct { int type; const char *entry; unsigned faces; } cases[] = {
        {TEXTYPE_2D,"s2",1}, {TEXTYPE_2D_ARRAY,"sa",1}, {TEXTYPE_CUBE,"sc",6}, {TEXTYPE_CUBE_ARRAY,"ss",6},
    };
    const float direction[6][4] = {{1,0,0,0},{-1,0,0,0},{0,1,0,0},{0,-1,0,0},{0,0,1,0},{0,0,-1,0}};
    id<MTLTexture> color = [dev newTextureWithDescriptor:[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO]];
    for (unsigned i = 0; i < sizeof cases / sizeof *cases; i++) {
        ShaderTexture shape = {.type = cases[i].type, .shadow = true};
        id<MTLComputePipelineState> pipe = [dev newComputePipelineStateWithFunction:[library newFunctionWithName:@(cases[i].entry)] error:&error];
        CHECK(pipe != nil, "shadow comparison pipeline");
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:1 height:1 mipmapped:NO];
        desc.textureType = mtl_type_for(shape.type); desc.storageMode = MTLStorageModePrivate;
        desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        id<MTLTexture> valid = [dev newTextureWithDescriptor:desc]; CHECK(valid != nil, "valid depth input");
        id<MTLCommandBuffer> init = [renderer_queue() commandBuffer];
        for (unsigned face = 0; face < cases[i].faces; face++) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.depthAttachment.texture = valid; rp.depthAttachment.slice = face;
            rp.depthAttachment.clearDepth = 0.25; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionStore;
            [[init renderCommandEncoderWithDescriptor:rp] endEncoding];
        }
        [init commit];
        for (unsigned input = 0; input < 3; input++) for (unsigned face = 0; face < cases[i].faces; face++) {
            end_pass("other"); (void)cb(); // fallback initialization must precede this already-created, uncommitted buffer
            id<MTLTexture> texture = shadow_slot_texture(input == 0 ? nil : input == 1 ? color : valid, &shape);
            id<MTLBuffer> result = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
            *(float *)result.contents = -1;
            id<MTLComputeCommandEncoder> ce = [cb() computeCommandEncoder];
            [ce setComputePipelineState:pipe]; [ce setTexture:texture atIndex:0]; [ce setSamplerState:sampler atIndex:0];
            [ce setBuffer:result offset:0 atIndex:0]; [ce setBytes:direction[face] length:16 atIndex:1];
            [ce dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)]; [ce endEncoding]; check_gpu();
            float want = input == 2 ? 0 : 1, got = *(float *)result.contents;
            fprintf(stderr, "shadow shape=%d input=%u face=%u got=%g want=%g\n", shape.type, input, face, got, want);
            CHECK(got == want, "missing or color shadow inputs must be lit; valid depth must preserve its comparison");
        }
    }
}

static void surface_handle_provenance(void) {
    static uint64_t code[3][128];
    static NvnProgram programs[3];
    unsigned bad = 0;
    for (unsigned computed = 0; computed < 3; computed++) {
        NvnTexture output = test_texture(1, 4, 4, 1, 1, 0x0a, 1);
        NvnTexture screen = test_texture(1, 4, 4, 1, 1, 0x25, 1);
        bind_targets(&output, NULL, NULL);
        const float initial[4] = {1, 0, 0, 1};
        clear(0, 0, initial, 15, false, 0, false, 0, 0);
        bind_targets(&screen, NULL, NULL); prepare_draw();
        programs[computed] = *st.program;
        st.scissor[0][2] = st.scissor[0][3] = 1; // one fragment writes the image
        NvnTexEntry entries[2] = {{0}, {.tex = &output}};
        NvnDescPool pool = {.entries = entries, .count = 2};
        st.tpool = &pool; st.img[1][0] = 1;
        uint64_t words[5]; unsigned n = 0;
        words[n++] = (0x4c98ull << 48) | (15ull << 39) | (2ull << 34) | ((uint64_t)(IMAGE_HANDLE_BASE / 4) << 20) | (7ull << 16) | 9;
        if (computed == 1) words[n++] = (0x5be0ull << 48) | (3ull << 39) | (2ull << 20) | (7ull << 16) | (1ull << 8) | 9; // LOP3.P writes handle zero
        if (computed == 2) words[n++] = (0x5c40ull << 48) | (2ull << 20) | (7ull << 16) | (1ull << 8) | 9; // LOP.P writes handle zero
        words[n++] = (0xeb2ull << 52) | (9ull << 39) | (3ull << 33) | (1ull << 20) | (7ull << 16) | 4; // SUST.B writes r4=0 at (0,0)
        words[n++] = 0xe30000000007000full; words[n++] = 0xe2400fffff87000full;
        *(uint32_t *)((uint8_t *)code[computed] + 0x78) = 15;
        unsigned at = 16;
        for (unsigned i = 0; i < n; i++) {
            if (!(at & 3)) code[computed][at++] = 0x001f8000fc0007e0ull;
            code[computed][at++] = words[i];
        }
        programs[computed].stages[1] = (NvnShaderStage){.stage = 1, .code_addr = (uint64_t)code[computed], .const_offset = sizeof code[computed]};
        st.program = &programs[computed];
        fullscreen_draw(1); check_gpu();
        id<MTLBuffer> data = read_texture(renderer_texture(&output, nil, true), 0, 0, 4);
        for (unsigned y = 0; y < 4; y++) for (unsigned x = 0; x < 4; x++) {
            float got = *(const float *)((const uint8_t *)data.contents + y * 256 + x * 4);
            float want = computed || x || y ? 1 : 0;
            fprintf(stderr, "surface handle computed=%u pixel=%u,%u got=%g want=%g\n", computed, x, y, got, want);
            if (got != want) bad++;
        }
        destroy_texture(&output); destroy_texture(&screen); st.tpool = NULL;
    }
    CHECK(bad == 0, "a modified handle must not write to its former constant-buffer image");
}

static void audit_f2f(void) {
    const struct { uint64_t opcode; uint32_t input, want; } cases[] = {
        {0x5ca8048000270909ull,0x3fc00000,0x00003e00}, // half 1.5, exactly representable
        {0x5ca8048000270909ull,0xbfc00000,0x0000be00}, // half -1.5
        {0x5ca8068000270609ull,0x3e000000,0x3fc00000}, // high half -> float 1.5
        {0x5ca8048000270a09ull,0x3fc00000,0x3f800000}, // equal-format floor remains active
    };
    static uint64_t code[4][32]; static NvnProgram programs[4]; unsigned bad=0;
    for(unsigned i=0;i<4;i++) {
        uint64_t ops[]={0x010000000007f002ull|((uint64_t)cases[i].input<<20),cases[i].opcode,
            0x010000000007f014ull|((uint64_t)(uint32_t)(g_gwin_base+512)<<20),
            0x010000000007f015ull|((g_gwin_base>>32)<<20),
            0xeed8000000000000ull|(4ull<<48)|(1ull<<45)|(7ull<<16)|(20ull<<8)|9};
        compute_fixture(code[i],&programs[i],ops,sizeof ops/sizeof*ops);st.program=&programs[i];
        uint32_t *out=(uint32_t*)((uint8_t*)g_guest_buffer.contents+512);*out=0xdeadbeef;
        dispatch_compute(1,1,1);check_gpu();fprintf(stderr,"F2F case%u got=%08x want=%08x\n",i,*out,cases[i].want);
        if(*out!=cases[i].want)bad++;
    }
    CHECK(!bad,"format conversions must preserve fractional values while equal-format floor still rounds");
}

static void audit_shuffle(void) {
    // PTX shfl.sync uses b[4:0] and maxLane as the UP lower bound, including nonzero clamps.
    const struct { unsigned mode,amount,clamp,mask; } cases[]={{1,1,1,0},{2,32,31,0},{3,32,31,0},{1,1,0,28}};
    static uint64_t code[4][32];static NvnProgram programs[4];static uint8_t control[0x754];
    *(uint32_t*)(control+0x748)=32;unsigned bad=0;
    for(unsigned i=0;i<4;i++) {
        uint64_t ops[]={0xf0c8000000070000ull, // R0=SR_LANEID
            0x010000000007f002ull|((uint64_t)cases[i].amount<<20),
            0xef10000000000000ull|((uint64_t)cases[i].mode<<30)|(1ull<<29)|
                ((uint64_t)(cases[i].clamp|(cases[i].mask<<8))<<34)|(2ull<<20)|(7ull<<16)|8,
            0x010000000017f004ull,
            0x5ca0000000000000ull|(255ull<<20)|(7ull<<16)|(4ull<<8)|9, // R9=P0?1:0
            (0x1full<<56)|(8ull<<20)|(7ull<<16)|10, // R10=lane*8
            0x010000000007f014ull|((uint64_t)(uint32_t)(g_gwin_base+512)<<20),
            0x010000000007f015ull|((g_gwin_base>>32)<<20),
            (0x5cc0ull<<48)|(255ull<<39)|(10ull<<20)|(7ull<<16)|(20ull<<8)|20,
            0xeed8000000000000ull|(5ull<<48)|(1ull<<45)|(7ull<<16)|(20ull<<8)|8};
        compute_fixture(code[i],&programs[i],ops,sizeof ops/sizeof*ops);programs[i].stages[5].control=control;st.program=&programs[i];
        uint32_t *out=(uint32_t*)((uint8_t*)g_guest_buffer.contents+512);
        for(unsigned k=0;k<64;k++)out[k]=0xdeadbeef;
        dispatch_compute(1,1,1);check_gpu();
        for(unsigned lane=0;lane<32;lane++) {
            // Literal expected vectors: case0 lane0/1 invalid then lane-1; cases1/2 b32 wraps to0;
            // case3 each quad's first lane invalid, other lanes read their predecessor.
            bool valid=i==0?lane>=2:i==3?(lane%4)!=0:true;
            unsigned want=(i==0||i==3)&&valid?lane-1:lane;
            if(out[2*lane]!=want||out[2*lane+1]!=(unsigned)valid) {
                fprintf(stderr,"SHFL case%u lane%u got=%u/P%u want=%u/P%u\n",i,lane,out[2*lane],out[2*lane+1],want,valid);bad++;
            }
        }
    }
    CHECK(!bad,"shuffle register amounts and UP clamp must preserve the hardware value and validity predicate");
}

static void structured_brx(void) {
    // A bounded c1 switch nested inside reconvergence, followed by a cross-lane read.
    static uint64_t code[8320]; static NvnProgram program; static uint8_t control[0x754];
#define FPC(n) ((unsigned)((n) / 3 * 4 + (n) % 3 + 1) * 8)
    uint64_t ops[] = {
        0xf0c8000000070000ull,
        0xe290000000000000ull | ((uint64_t)(FPC(20) - FPC(1) - 8) << 20),
        0xe2a0000000000000ull | ((uint64_t)(FPC(15) - FPC(2) - 8) << 20),
        0x3820000000000000ull | (7ull << 39) | (3ull << 20) | (7ull << 16) | 2,
        0x3848000000000000ull | (2ull << 20) | (7ull << 16) | (2ull << 8) | 2,
        0xef90000000000000ull | (4ull << 48) | (1ull << 36) | (7ull << 16) | (2ull << 8) | 3,
        0xe25000000007000full | (3ull << 8),
        0x010000000007f005ull | (10ull << 20), 0xe34000000007000full,
        0x010000000007f005ull | (20ull << 20), 0xe34000000007000full,
        0x010000000007f005ull | (30ull << 20), 0xe34000000007000full,
        0x010000000007f005ull | (40ull << 20), 0xe34000000007000full,
        0x010000000007f006ull | (30ull << 20),
        0x5b6d038000070507ull | (6ull << 20),
        0xf0f800000000000full,
        0x1c00000000170505ull,
        0xf0f800000007000full,
        0xef10000000000000ull | (3ull << 30) | (1ull << 29) | (1ull << 28) | (7171ull << 34) |
            (1ull << 20) | (7ull << 16) | (5ull << 8) | 8,
        (0x1full << 56) | (4ull << 20) | (7ull << 16) | 10,
        0x010000000007f014ull | ((uint64_t)(uint32_t)(g_gwin_base + 512) << 20),
        0x010000000007f015ull | ((g_gwin_base >> 32) << 20),
        (0x5cc0ull << 48) | (255ull << 39) | (10ull << 20) | (7ull << 16) | (20ull << 8) | 20,
        0xeed8000000000000ull | (4ull << 48) | (1ull << 45) | (7ull << 16) | (20ull << 8) | 8,
    };
    compute_fixture(code, &program, ops, sizeof ops / sizeof *ops);
    program.stages[5].const_offset = 512; program.stages[5].const_size = 16;
    uint32_t *table = (uint32_t *)((uint8_t *)code + 512);
    for (unsigned i = 0; i < 4; i++) table[i] = FPC(7 + 2 * i) - FPC(6) - 8;
    table[1] -= 8;  // a target on the scheduling word normalizes to the next instruction
    *(uint32_t *)(control + 0x748) = 32;
    program.stages[5].control = control; st.program = &program;
    uint32_t *out = (uint32_t *)((uint8_t *)g_guest_buffer.contents + 512);
    for (unsigned i = 0; i < 32; i++) out[i] = 0xdeadbeef;
    dispatch_compute(1, 1, 1); check_gpu();
    const uint32_t values[] = {11, 21, 30, 40};
    for (unsigned i = 0; i < 32; i++) CHECK(out[i] == values[MIN(i ^ 1, 3u)], "bounded BRX and nested SYNC/BRK reconverge before SHFL");
    const char *enabled = getenv("LARECOMP_STRUCTURED_FLOW");
    CHECK(compute_program(&program)->si->structured_flow == (enabled && atoi(enabled)), "the bounded forward switch uses the requested structured path");
    ShaderInfo *fallback = maxwell_translate_with_constants((uint8_t *)code, 512, STAGE_COMPUTE, NULL, (uint8_t *)table, 4);
    CHECK(fallback->msl && !fallback->structured_flow, "an incomplete constant table retains the dispatcher");
    maxwell_free(fallback);
    uint32_t saved = table[0]; table[0] = FPC(0) - FPC(6) - 8;
    fallback = maxwell_translate_with_constants((uint8_t *)code, 512, STAGE_COMPUTE, NULL, (uint8_t *)table, 16);
    CHECK(fallback->msl && !fallback->structured_flow, "a backward computed edge retains the dispatcher");
    maxwell_free(fallback); table[0] = saved;
#undef FPC
}

static void break_reconvergence(void) {
    // Every lane leaves this PBK loop after a different number of iterations.
    // The following SHFL must see its neighbour's completed loop result.
    static uint64_t code[32]; static NvnProgram program; static uint8_t control[0x754];
    *(uint32_t *)(control + 0x748) = 32;
    const unsigned loop_pc = 6 * 8, end_pc = 15 * 8;
    uint64_t ops[] = {
        0xf0c8000000070000ull, // R0 = lane
        0x010000000007f009ull, // R9 = 0
        0x010000000017f00bull, // R11 = 1
        0xe2a0000000000000ull | ((uint64_t)(end_pc - 5 * 8 - 8) << 20),
        0x5b6d038000070907ull, // P0 = R9 >= R0
        0xe34000000000000full, // @P0 BRK
        (0x1full << 56) | (1664525ull << 20) | (7ull << 16) | (11ull << 8) | 11,
        0x1c00000000000000ull | (1013904223ull << 20) | (7ull << 16) | (11ull << 8) | 11,
        0x1c00000000170909ull, // R9++
        0xe24000000007000full | ((uint64_t)((loop_pc - 13 * 8 - 8) & 0xffffff) << 20),
        0x50b0000000070f00ull, // unreachable NOP
        0xef10000000000000ull | (3ull << 30) | (1ull << 29) | (1ull << 28) | (7171ull << 34) |
            (1ull << 20) | (7ull << 16) | (11ull << 8) | 8, // R8 = SHFL.BFLY R11,1
        (0x1full << 56) | (4ull << 20) | (7ull << 16) | 10,
        0x010000000007f014ull | ((uint64_t)(uint32_t)(g_gwin_base + 512) << 20),
        0x010000000007f015ull | ((g_gwin_base >> 32) << 20),
        (0x5cc0ull << 48) | (255ull << 39) | (10ull << 20) | (7ull << 16) | (20ull << 8) | 20,
        0xeed8000000000000ull | (4ull << 48) | (1ull << 45) | (7ull << 16) | (20ull << 8) | 8,
    };
    compute_fixture(code, &program, ops, sizeof ops / sizeof *ops);
    program.stages[5].control = control; st.program = &program;
    uint32_t *out = (uint32_t *)((uint8_t *)g_guest_buffer.contents + 512);
    for (unsigned lane = 0; lane < 32; lane++) out[lane] = 0xdeadbeef;
    dispatch_compute(1, 1, 1); check_gpu();
    unsigned bad = 0;
    for (unsigned lane = 0; lane < 32; lane++) {
        uint32_t want = 1;
        for (unsigned iteration = 0; iteration < (lane ^ 1); iteration++) want = want * 1664525u + 1013904223u;
        if (out[lane] != want) {
            fprintf(stderr, "BRK lane%u got=%u want=%u\n", lane, out[lane], want); bad++;
        }
    }
    CHECK(!bad, "lanes must reconverge after BRK before exchanging loop results");
}

static void audit_shadow_array(void) {
    NvnTexture depth=test_texture(4,4,4,2,1,0x33,1);
    bind_targets(NULL,&depth,NULL);
    for(unsigned layer=0;layer<2;layer++) {
        st.rt.has_dview=true;st.rt.dview=(NvnTextureView){.setmask=2,.min_layer=layer,.num_layers=1};st.rt_dirty=true;
        clear(-1,0,NULL,0,true,layer?0.75f:0.25f,false,0,0);
    }
    NvnTexEntry entries[2]={{0},{.tex=&depth}};NvnDescPool pool={.entries=entries,.count=2};
    NvnSamplerDesc sd={.compare_mode=1,.compare_func=4,.lod_max=1000,.max_aniso=1};
    NvnDescPool samplers={.entries=&sd,.count=1};st.tpool=&pool;st.spool=&samplers;st.tex[5][0]=1;
    const unsigned layer[3]={0,1,7};static uint64_t code[3][32];static NvnProgram programs[3];unsigned bad=0;
    for(unsigned i=0;i<3;i++) {
        uint64_t ops[]={0x010000000007f002ull|((uint64_t)layer[i]<<20),
            0x010000000007f003ull|(0x3f000000ull<<20),0x010000000007f004ull|(0x3f000000ull<<20),0x010000000007f005ull|(0x3f000000ull<<20),
            0xd920008ff0470208ull,
            0x010000000007f014ull|((uint64_t)(uint32_t)(g_gwin_base+512)<<20),0x010000000007f015ull|((g_gwin_base>>32)<<20),
            0xeed8000000000000ull|(4ull<<48)|(1ull<<45)|(7ull<<16)|(20ull<<8)|8};
        compute_fixture(code[i],&programs[i],ops,sizeof ops/sizeof*ops);st.program=&programs[i];
        uint32_t *out=(uint32_t*)((uint8_t*)g_guest_buffer.contents+512);*out=0xdeadbeef;
        dispatch_compute(1,1,1);check_gpu();uint32_t want=i?0x3f800000:0;
        fprintf(stderr,"TEXS shadow layer%u got=%08x want=%08x\n",layer[i],*out,want);if(*out!=want)bad++;
    }
    st.tpool=st.spool=NULL;if(sd.backend)CFRelease(sd.backend);destroy_texture(&depth);
    CHECK(!bad,"array depth compare must clamp to the last layer and preserve valid layer selection");
}

static void audit_sured_bytes(void) {
    static uint64_t code[2][128];static NvnProgram programs[2];unsigned bad=0;
    for(unsigned ba=0;ba<2;ba++) {
        NvnTexture image=test_texture(1,8,4,1,1,0x0b,1),screen=test_texture(1,4,4,1,1,0x25,1);
        bind_targets(&image,NULL,NULL);st.scissor[0][2]=8;
        const uint32_t zero[4]={0};clear(0,2,zero,15,false,0,false,0,0);
        bind_targets(&screen,NULL,NULL);prepare_draw();programs[ba]=*st.program;st.scissor[0][2]=st.scissor[0][3]=1;
        NvnTexEntry entries[2]={{0},{.tex=&image}};NvnDescPool pool={.entries=entries,.count=2};st.tpool=&pool;st.img[1][0]=1;
        const uint64_t ops[]={0x010000000047f002ull,0x010000000007f003ull,0x010000000077f004ull,
            (0x4c98ull<<48)|(15ull<<39)|(2ull<<34)|((uint64_t)(IMAGE_HANDLE_BASE/4)<<20)|(7ull<<16)|9,
            0xeb50048600070204ull|((uint64_t)ba<<23),0xe30000000007000full,0xe2400fffff87000full};
        unsigned at=16;*(uint32_t*)((uint8_t*)code[ba]+0x78)=15;
        for(unsigned i=0;i<sizeof ops/sizeof*ops;i++) {if(!(at&3))code[ba][at++]=0x001f8000fc0007e0ull;code[ba][at++]=ops[i];}
        programs[ba].stages[1]=(NvnShaderStage){.stage=1,.code_addr=(uint64_t)code[ba],.const_offset=sizeof code[ba]};st.program=&programs[ba];
        fullscreen_draw(1);check_gpu();id<MTLBuffer> data=read_texture(renderer_texture(&image,nil,true),0,0,4);
        for(unsigned y=0;y<4;y++)for(unsigned x=0;x<8;x++) {
            uint32_t got=*(const uint32_t*)((const uint8_t*)data.contents+y*256+x*4),want=y==0&&x==(ba?1u:4u)?7:0;
            if(got!=want) {fprintf(stderr,"SURED BA%u pixel%u,%u got=%u want=%u\n",ba,x,y,got,want);bad++;}
        }
        destroy_texture(&image);destroy_texture(&screen);st.tpool=NULL;
    }
    CHECK(!bad,"byte-addressed reductions must update x/4 while ordinary reductions use texel x");
}

static NvnProgram *compute_image_fixture(bool reduction, bool array) {
    static uint64_t code[4][32];
    static NvnProgram programs[4];
    unsigned mode = (reduction ? 2u : 0u) + array;
    if (!programs[mode].stage_mask) {
        uint64_t ops[] = {
            (0x4c98ull << 48) | (15ull << 39) | (4ull << 34) | (7ull << 16) | 4,
            (0x4c98ull << 48) | (15ull << 39) | (4ull << 34) | (1ull << 20) | (7ull << 16),
            (0x4c98ull << 48) | (15ull << 39) | (4ull << 34) | (2ull << 20) | (7ull << 16) | 1,
            (0x4c98ull << 48) | (15ull << 39) | (4ull << 34) | (3ull << 20) | (7ull << 16) | 2,
            (0x4c98ull << 48) | (15ull << 39) | (2ull << 34) | ((uint64_t)(IMAGE_HANDLE_BASE / 4) << 20) | (7ull << 16) | 9,
            ((reduction ? 0xeb5ull : 0xeb2ull) << 52) | (9ull << 39) | ((array ? 4ull : 3ull) << 33) |
                ((reduction ? 0ull : 1ull) << 20) | (7ull << 16) | 4,
        };
        compute_fixture(code[mode], &programs[mode], ops, sizeof ops / sizeof *ops);
    }
    return &programs[mode];
}

static void compute_images(bool reduction, bool array, bool view) {
    const struct { uint32_t format, value, view_format; } cases[] = {
        {0x0a, 0x3f400000}, {0x0b, 17}, {0x0c, 0xffffffe9}, {0x0b, 0xfffffff7, 0x0c}, {0x0a, 0x3f400000},
    };
    unsigned bad = 0;
    for (unsigned c = reduction ? 1 : 0; c < (reduction ? 4 : 5); c++) {
        NvnTexture output = test_texture(array || view ? 4 : 1, view ? 8 : 4, view ? 8 : 4, array || view ? 3 : 1, view ? 3 : 1, cases[c].format, 1);
        output.swizzle[0] = 5; output.swizzle[3] = 2; // writes must ignore sampled swizzles
        NvnTexture decoy = test_texture(1, 4, 4, 1, 1, 0x0a, 1); // sampled kind stays float as image kinds change
        id<MTLTexture> native = renderer_texture(&output, nil, true);
        id<MTLCommandBuffer> init = [renderer_queue() commandBuffer];
        for (unsigned layer = 0; layer < output.depth; layer++) for (unsigned level = 0; level < output.levels; level++) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = native; rp.colorAttachments[0].slice = layer; rp.colorAttachments[0].level = level;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0);
            [[init renderCommandEncoderWithDescriptor:rp] endEncoding];
        }
        [init commit];
        bind_targets(&decoy, NULL, NULL); const float sentinel[4] = {1,0,0,1}; clear(0,0,sentinel,15,false,0,false,0,0);
        NvnTexEntry entries[3] = {{0}, {.tex = &output}, {.tex = &decoy}};
        if (view) { entries[1].has_view = true; entries[1].view = (NvnTextureView){.setmask=3, .base_level=1, .num_levels=1, .min_layer=1, .num_layers=1}; }
        if (cases[c].view_format) { entries[1].has_view = true; entries[1].view.setmask |= 4; entries[1].view.format = cases[c].view_format; }
        NvnDescPool textures = {.entries=entries,.count=3}; st.tpool = &textures;
        st.img[5][0] = 1; st.tex[5][0] = 2;
        uint32_t value[4] = {cases[c].value, 1, 2, 1};
        st.ubuf[5][1] = (Range){.addr=(uint64_t)value,.size=sizeof value}; st.program = compute_image_fixture(reduction, array);
        dispatch_compute(1,1,1); check_gpu();
        if (reduction) { dispatch_compute(1,1,1); check_gpu(); }
        for (unsigned layer = 0; layer < output.depth; layer++) for (unsigned level = 0; level < output.levels; level++) {
            id<MTLBuffer> result = read_texture(native,layer,level,4);
            unsigned width = output.width >> level, height = output.height >> level;
            for (unsigned y = 0; y < height; y++) for (unsigned x = 0; x < width; x++) {
                bool target = x==1 && y==2 && level==(view ? 1u : 0u) && layer==(array || view ? 1u : 0u);
                uint32_t want = target ? (reduction ? 2 * cases[c].value : cases[c].value) : 0;
                uint32_t got = *(const uint32_t *)((const uint8_t *)result.contents + y*256 + x*4);
                if (got != want) { fprintf(stderr,"compute image format=%#x layer=%u level=%u pixel=%u,%u got=%08x want=%08x\n",cases[c].format,layer,level,x,y,got,want);bad++; }
            }
        }
        id<MTLBuffer> unchanged = read_texture(renderer_texture(&decoy,nil,true),0,0,4);
        for (unsigned y=0;y<4;y++) for (unsigned x=0;x<4;x++)
            CHECK(*(const uint32_t *)((const uint8_t *)unchanged.contents+y*256+x*4)==0x3f800000,
                  "image writes must leave every sampled-table decoy pixel intact");
        fprintf(stderr,"compute image reduction=%d array=%d view=%d format=%#x viewformat=%#x verified\n",reduction,array,view,cases[c].format,cases[c].view_format);
        destroy_texture(&output); destroy_texture(&decoy); st.tpool = NULL; st.ubuf[5][1] = (Range){0};
    }
    CHECK(bad==0,"compute writes and atomics must use the image's selected subresource and scalar type");
}

static void compute_image_store(void) { compute_images(false,false,false); }
static void compute_image_array(void) { compute_images(false,true,false); }
static void compute_image_view(void) { compute_images(false,false,true); }
static void compute_image_atomic(void) { compute_images(true,false,false); }
static void compute_image_atomic_array(void) { compute_images(true,true,false); }

static void compute_image_missing(void) {
    NvnTexture image = test_texture(1,4,4,1,1,0x0a,1);
    bind_targets(&image,NULL,NULL); const float zero[4]={0}; clear(0,0,zero,15,false,0,false,0,0);
    NvnTexEntry entries[2]={{0},{.tex=&image}}; NvnDescPool pool={.entries=entries,.count=2};st.tpool=&pool;
    uint32_t value[4]={0x3f000000,0,0,0};st.ubuf[5][1]=(Range){.addr=(uint64_t)value,.size=sizeof value};
    st.program=compute_image_fixture(false,false);st.img[5][0]=0;
    dispatch_compute(1,1,1);check_gpu(); // a store to an unbound image must have a writable fallback
    id<MTLBuffer> result=read_texture(renderer_texture(&image,nil,true),0,0,4);
    CHECK(*(uint32_t*)result.contents==0,"an unbound image must not modify a former descriptor");
    st.img[5][0]=1;dispatch_compute(1,1,1);check_gpu();
    result=read_texture(renderer_texture(&image,nil,true),0,0,4);
    CHECK(*(uint32_t*)result.contents==0x3f000000,"rebind after an unbound image must write the actual image");
    destroy_texture(&image);st.tpool=NULL;st.ubuf[5][1]=(Range){0};
}

static void compute_image_ownership(void) {
    NvnTexture image = test_texture(1,4,4,1,1,0x0b,1);
    image.flags |= 0x10; image.stride = 16; // CPU-written linear textures are checked every frame
    uint64_t size = tegra_total_size(&image.layout);
    CHECK(size <= 4096 && !(size & 3), "CPU-backed image fixture fits the reserved guest storage");
    uint32_t *storage = (uint32_t *)((uint8_t *)g_guest_buffer.contents + 2048);
    for (unsigned i=0;i<size/4;i++) storage[i]=11;
    image.addr=(uint64_t)storage;
    id<MTLTexture> native=renderer_texture(&image,nil,false); // upload the initial CPU contents without making it a target
    id<MTLBuffer> result=read_texture(native,0,0,4);
    CHECK(*(uint32_t*)result.contents==11,"an image's initial CPU contents must be uploaded");
    NvnTexEntry entries[2]={{0},{.tex=&image}};NvnDescPool pool={.entries=entries,.count=2};st.tpool=&pool;st.img[5][0]=1;
    uint32_t value[4]={5,1,2,0};st.ubuf[5][1]=(Range){.addr=(uint64_t)value,.size=sizeof value};
    st.program=compute_image_fixture(true,false);dispatch_compute(1,1,1);check_gpu();
    result=read_texture(native,0,0,4);
    CHECK(*(uint32_t*)((uint8_t*)result.contents+2*256+4)==16,"first reduction starts with uploaded image data");
    memset(storage,0x7a,size);metal_test_next_texture_frame();
    dispatch_compute(1,1,1);check_gpu();result=read_texture(native,0,0,4);
    uint32_t got=*(uint32_t*)((uint8_t*)result.contents+2*256+4);
    fprintf(stderr,"CPU-backed image second reduction got=%08x want=00000015\n",got);
    CHECK(got==21,"later CPU upload probes must preserve GPU-owned image results");
    destroy_texture(&image);st.tpool=NULL;st.ubuf[5][1]=(Range){0};
}

static void compute_image_feedback(void) {
    NvnTexture image=test_texture(1,4,4,1,1,0x0a,1);
    bind_targets(&image,NULL,NULL);const float initial[4]={0.25f,0,0,1};clear(0,0,initial,15,false,0,false,0,0);
    NvnTexEntry entries[2]={{0},{.tex=&image}};NvnDescPool pool={.entries=entries,.count=2};st.tpool=&pool;st.tex[1][0]=1;
    ShaderInfo vi={.stage=STAGE_VERTEX},fi={.stage=STAGE_FRAGMENT,.ntex=1};
    fi.tex[0]=(ShaderTexture){.handle_offset=0x20,.type=TEXTYPE_2D};
    Prog *graphics=[Prog new];graphics->vi=&vi;graphics->fi=&fi;
    resolve_feedback(graphics);check_gpu();
    CHECK(nfeedback==1,"fixture must create a real read-only render-target feedback snapshot");
    id<MTLTexture> snapshot=feedback_copy[0];
    st.program=compute_image_fixture(false,false);st.img[5][0]=1;
    uint32_t value[4]={0x3f400000,0,0,0};st.ubuf[5][1]=(Range){.addr=(uint64_t)value,.size=sizeof value};
    dispatch_compute(1,1,1);check_gpu();
    id<MTLBuffer> original=read_texture(renderer_texture(&image,nil,true),0,0,4);
    id<MTLBuffer> previous=read_texture(snapshot,0,0,4);
    CHECK(*(uint32_t*)original.contents==0x3f400000,"image writes must reach the actual resource after a feedback pass");
    CHECK(*(uint32_t*)previous.contents==0x3e800000,"image writes must not modify the read-only feedback snapshot");
    destroy_texture(&image);st.tpool=NULL;st.ubuf[5][1]=(Range){0};
}

static void live_shader_pipeline(void) {
    NvnTexture color=test_texture(1,4,4,1,1,0x25,1);
    bind_targets(&color,NULL,NULL);prepare_draw();fullscreen_draw(1);check_gpu();
    NvnProgram *program=st.program;Prog *target=nil;
    for(id value in cache.allValues) if([value isKindOfClass:[Prog class]]) {
        Prog *candidate=value;
        if(candidate->vs_addr==program->stages[0].code_addr && candidate->fs_addr==program->stages[1].code_addr) target=candidate;
    }
    CHECK(target!=nil,"live pipeline fixture must find its compiled program");
    char *original=strdup(target->fi->msl);CHECK(original!=NULL,"saved original shader");
    unsigned bad=0;
    for(unsigned i=0;i<32;i++) @autoreleasepool {
        unsigned red=17+7*i;
        FILE *f=fopen("live-pipeline.metal","w");CHECK(f!=NULL,"override fixture source");
        fprintf(f,"#include <metal_stdlib>\nusing namespace metal; fragment float4 main0() { return float4(%u.0f / 255.0f,0,0,1); }\n",red);fclose(f);
        CHECK(live_override_fs(target,"live-pipeline.metal"),"replacement fragment compiles");
        const float black[4]={0,0,0,1};clear(0,0,black,15,false,0,false,0,0);
        fullscreen_draw(1);id<MTLBuffer> result=read_texture(renderer_texture(&color,nil,true),0,0,4);
        const uint8_t *pixel=result.contents;
        fprintf(stderr,"live override%u fn=%p got=%u,%u,%u want=%u,0,0\n",i,(__bridge void*)target->fs,pixel[0],pixel[1],pixel[2],red);
        for(unsigned y=0;y<4;y++) for(unsigned x=0;x<4;x++) {
            const uint8_t *p=(const uint8_t*)result.contents+y*256+x*4;
            if(abs((int)p[0]-(int)red)>1 || p[1] || p[2] || p[3]!=255)bad++;
        }
    }
    FILE *restore=fopen("live-pipeline.metal","w");CHECK(restore!=NULL,"restore original shader source");
    fputs(original,restore);fclose(restore);free(original);
    CHECK(live_override_fs(target,"live-pipeline.metal"),"restore fixture shader for subsequent cases");
    fullscreen_draw(1);expect_rgba(&color,0,255,0);
    destroy_texture(&color);
    CHECK(!bad,"every live shader replacement must render its new color even when native function addresses are reused");
}

static void pipeline_archive_reload(void) {  // a pipeline built once is found in cache/pipelines.bin on the next run
    if (!pipeline_archive()) { fprintf(stderr, "pipeline archive off (LARECOMP_NO_PIPELINE_ARCHIVE)\n"); return; }
    NvnTexture color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    bind_targets(&color, NULL, NULL); prepare_draw(); fullscreen_draw(1); check_gpu();
    renderer_save_pipeline_archive();  // waits for the background add, then writes the file
    CHECK(g_archive_dirty == 0 && access("cache/pipelines.bin", R_OK) == 0, "pipeline archive saved to disk");
    MTLBinaryArchiveDescriptor *ad = [MTLBinaryArchiveDescriptor new];
    ad.url = [NSURL fileURLWithPath:@"cache/pipelines.bin"].absoluteURL;
    NSError *err = nil;
    id<MTLBinaryArchive> loaded = [dev newBinaryArchiveWithDescriptor:ad error:&err];
    CHECK(loaded != nil, "saved pipeline archive loads back");
    destroy_texture(&color);
    g_archive_read = loaded;  // as on the next run
    renderer_reset();    // forget the built pipelines and programs
    int hits = g_archive_hits;
    color = test_texture(1, 4, 4, 1, 1, 0x25, 1);
    bind_targets(&color, NULL, NULL); prepare_draw(); fullscreen_draw(1); expect_rgba(&color, 0, 255, 0);
    fprintf(stderr, "pipeline archive hits %d -> %d\n", hits, g_archive_hits);
    CHECK(g_archive_hits > hits, "the rebuilt pipeline must come from the loaded archive and draw correctly");
    destroy_texture(&color);
}

typedef void (*TestFn)(void);
static const struct { const char *name, *group; TestFn run; bool needs_sampler26; } tests[] = {
    {"uniform-snapshots", "uniforms", uniform_snapshots},
    {"largest-textures", "diagnostics", metal_test_texture_dump},
    {"gpu-interval-union", "gpu-time", gpu_interval_union},
    {"gpu-timing-state", "gpu-time", gpu_timing_state_machine},
    {"gpu-profile-boundaries", "profiling", gpu_profile_boundaries},
    {"gpu-capture-boundaries", "profiling", gpu_capture_boundaries},
    {"smoke", "smoke", smoke},
    {"live-shader-pipeline", "live", live_shader_pipeline},
    {"break-reconvergence", "flow", break_reconvergence},
    {"structured-brx", "flow", structured_brx},
    {"compute-image-store", "images", compute_image_store},
    {"compute-image-feedback", "images", compute_image_feedback},
    {"compute-image-ownership", "images", compute_image_ownership},
    {"compute-image-missing", "images", compute_image_missing},
    {"compute-image-array", "images", compute_image_array},
    {"compute-image-view", "images", compute_image_view},
    {"compute-image-atomic", "images", compute_image_atomic},
    {"compute-image-atomic-array", "images", compute_image_atomic_array},
    {"audit-f2f", "audit", audit_f2f},
    {"audit-shuffle", "audit", audit_shuffle},
    {"audit-shadow-array", "audit", audit_shadow_array},
    {"audit-sured-bytes", "audit", audit_sured_bytes},
    {"integer-opcode-semantics", "integers", integer_opcode_semantics},
    {"surface-handle-provenance", "integers", surface_handle_provenance},
    {"ldc64-overlap", "sibling", ldc64_overlap},
    {"program-readiness", "sibling", program_readiness},
    {"pipeline-archive", "sibling", pipeline_archive_reload},
    {"shadow-fallback", "sibling", shadow_fallback},
    {"safe-math-graphics", "sibling", safe_math_graphics},
    {"safe-math-compute", "sibling", safe_math_compute},
    {"screenshot-2d", "screenshots", screenshot_2d},
    {"screenshot-volume", "screenshots", screenshot_volume},
    {"screenshot-volume-r16", "screenshots", screenshot_volume_r16},
    {"clear-float-uint", "clears", clear_float_uint},
    {"view-array-count", "views", view_array_count},
    {"view-bounds", "views", view_bounds},
    {"view-cube-faces", "views", view_cube_faces},
    {"view-zero-swizzle", "views", view_zero_swizzle},
    {"view-sampled-cube-face", "views", view_sampled_cube_face},
    {"view-partial-cube-range", "views", view_partial_cube_range},
    {"view-chain-cleanup", "views", view_chain_cleanup},
    {"clear-bias", "clears", clear_bias},
    {"clear-wireframe", "clears", clear_wireframe},
    {"clear-bias-restore", "clears", clear_bias_restore},
    {"clear-layouts", "clears", clear_layouts},
    {"clear-multisample-depth", "clears", clear_multisample_depth},
    {"draw-multisample-depth", "draws", draw_multisample_depth},
    {"layer-single", "layers", layer_single},
    {"layer-color-array", "layers", layer_color_array},
    {"layer-mixed-depth", "layers", layer_mixed_depth},
    {"layer-depth-only", "layers", layer_depth_only},
    {"clear-layered", "clears", clear_layered},
    {"clear-mip-extent", "clears", clear_mip_extent},
    {"clear-minimum-color-extent", "clears", clear_minimum_color_extent},
    {"clear-minimum-depth-extent", "clears", clear_minimum_depth_extent},
    {"stencil-without-attachment", "aspects", stencil_without_attachment},
    {"depth-attachment-cache", "aspects", depth_attachment_cache},
    {"stencil-attachment-cache", "aspects", stencil_attachment_cache},
    {"stencil-only-depth-ignored", "aspects", stencil_only_depth_ignored},
    {"zero-array-instances", "draws", zero_array_instances},
    {"zero-indexed-instances", "draws", zero_indexed_instances},
    {"zero-xfb-instances", "draws", zero_xfb_instances},
    {"xfb-stream-four", "streams", xfb_stream_four},
    {"xfb-vertex-reuse", "xfb-barrier", xfb_vertex_reuse},
    {"vertex-stream-fifteen", "streams", vertex_stream_fifteen},
    {"vertex-stream-layout-cache", "streams", vertex_stream_layout_cache},
    {"gpu-indirect-arrays", "draws", gpu_indirect_arrays},
    {"gpu-indirect-indexed", "draws", gpu_indirect_indexed},
    {"raster-discard-restore", "draws", raster_discard_restore},
    {"sampler-reduction", "samplers", sampler_reduction, true},
    {"sampler-border", "samplers", sampler_border},
    {"sampler-bias", "samplers", sampler_bias, true},
    {"typed-fragment-fetch", "types", typed_fragment_fetch},
    {"typed-fragment-sample", "types", typed_fragment_sample},
    {"typed-compute-fetch", "types", typed_compute_fetch},
    {"typed-compute-sample", "types", typed_compute_sample},
    {"typed-fragment-gather", "types", typed_fragment_gather},
    {"typed-compute-gather", "types", typed_compute_gather},
    {"typed-fragment-fallback", "types", typed_fragment_fallback},
    {"typed-compute-fallback", "types", typed_compute_fallback},
    {"typed-fragment-feedback", "types", typed_fragment_feedback},
    {"typed-feedback-cleanup", "types", typed_feedback_cleanup},
    {"scaled-fragment-fetch", "scaling", scaled_fragment_fetch},
    {"feedback-mip-color", "feedback", feedback_mip_color},
    {"feedback-mip-depth", "feedback", feedback_mip_depth},
    {"feedback-base-alias", "feedback", feedback_base_alias},
};

int metal_renderer_test_main(int argc, char **argv) { @autoreleasepool {
    setenv("LARECOMP_SYNC_SHADERS", "1", 1);
    setenv("LARECOMP_NO_SHADER_WARM", "1", 1);
    char temporary[] = "/tmp/pokeza-metal-tests-XXXXXX";
    CHECK(mkdtemp(temporary) && chdir(temporary) == 0, "test working directory");
    metal_test_bootstrap();
    if (!dev) { fprintf(stderr, "SKIP: no Metal device\n"); return 77; }
    const char *selection = argc > 1 ? argv[1] : "all";
    unsigned ran = 0, skipped = 0;
    for (unsigned i = 0; i < sizeof tests / sizeof *tests; i++) {
        if (strcmp(selection, "all") && strcmp(selection, tests[i].name) && strcmp(selection, tests[i].group)) continue;
        if (tests[i].needs_sampler26 && !native_sampler_available()) {
            fprintf(stderr, "SKIP %s: requires macOS 26 and SDK 26\n", tests[i].name); skipped++; continue;
        }
        fprintf(stderr, "RUN %s\n", tests[i].name);
        tests[i].run(); check_gpu(); renderer_reset(); ran++;
        fprintf(stderr, "PASS %s\n", tests[i].name);
    }
    CHECK(ran + skipped != 0, "unknown test selection");
    renderer_save_pipeline_archive();  // now, while the directory still exists (exit would save again otherwise)
    // every case's pipelines (depth-only ones without fragment outputs among them) went in: the save must succeed, leaving
    // out ("left out" in the log) only pipelines that break it
    CHECK(g_archive_dirty == 0, "the pipeline archive must save with every pipeline the cases built");
    [[NSFileManager defaultManager] removeItemAtPath:@(temporary) error:nil];
    if (ran) fprintf(stderr, "PASS: %u Metal renderer tests on %s\n", ran, dev.name.UTF8String);
    if (skipped) fprintf(stderr, "SKIP: %u tests requiring newer sampler APIs\n", skipped);
    return ran ? 0 : 77;
}}
