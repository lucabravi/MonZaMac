// Test-only offscreen bootstrap. Production code is included so no test API is added to the app.
#include "../runtime/nvn/metal.m"
#include <assert.h>

static void check_texture_dump(void) {
    FILE *out = tmpfile();
    assert(out);
    fflush(stderr);
    int saved = dup(STDERR_FILENO);
    assert(saved >= 0 && dup2(fileno(out), STDERR_FILENO) >= 0);
    dump_largest_textures("test");
    fflush(stderr);
    assert(dup2(saved, STDERR_FILENO) >= 0);
    close(saved);
    rewind(out);
    char line[512];
    unsigned n = 0;
    bool seen[17] = {0};
    uint64_t previous = UINT64_MAX;
    while (fgets(line, sizeof line, out)) {
        double mib;
        if (sscanf(line, "[texdump] %lf MB", &mib) != 1) continue;
        char *label = strstr(line, "test-dump-");
        unsigned i;
        assert(label && sscanf(label, "test-dump-%u", &i) == 1 && i < (unsigned)g_reg_n && !seen[i]);
        seen[i] = true;
        TexBackend *b = (TexBackend *)g_reg[i]->backend;
        uint64_t size = b->tex.allocatedSize;
        assert(size <= previous && fabs(mib - size / 1048576.0) <= 0.051);
        previous = size;
        n++;
    }
    fclose(out);
    assert(n == (unsigned)MIN(g_reg_n, 16));
    if (g_reg_n == 17) assert(seen[16] && !seen[15]);
}

void metal_test_texture_dump(void) {
    assert(g_reg_n == 0);
    NvnTexture textures[17] = {0};
    TexBackend backends[17] = {0};
    id<MTLTexture> metal_textures[17] = {nil};
    check_texture_dump();
    for (unsigned i = 0; i < 17; i++) {
        unsigned width = i < 15 ? 128 + i * 64 : i == 15 ? 64 : 2048;
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                 width:width height:width mipmapped:NO];
        metal_textures[i] = [dev newTextureWithDescriptor:d];
        backends[i].tex = metal_textures[i];
        assert(backends[i].tex);
        textures[i].width = textures[i].height = width;
        textures[i].backend = &backends[i];
        snprintf(textures[i].label, sizeof textures[i].label, "test-dump-%u", i);
        reg_add(&textures[i], &backends[i]);
        if (i >= 14) check_texture_dump();
    }
    for (unsigned i = 0; i < 17; i++) reg_remove(&backends[i]);
    assert(g_reg_n == 0);
}

void metal_test_bootstrap(void) {
    // runtime/main.o's constructor has already reserved the guest window, even with our alternate entry point.
    uint64_t address = 0x7200000000ull;
    dev = MTLCreateSystemDefaultDevice();
    if (!dev) return;
    queue = [dev newCommandQueue];
    MTLSamplerDescriptor *sampler = [MTLSamplerDescriptor new];
    sampler.minFilter = sampler.magFilter = MTLSamplerMinMagFilterLinear;
    present_sampler = [dev newSamplerStateWithDescriptor:sampler];
    gwin_done = true;
    // Indirect commands use the same guest-address checks as the game, so keep this tiny mapping in that range.
    g_guest_buffer = [dev newBufferWithBytesNoCopy:(void *)(uintptr_t)address length:16384
                                         options:MTLResourceStorageModeShared deallocator:nil];
    if (!g_guest_buffer) { fprintf(stderr, "test guest Metal buffer failed\n"); abort(); }
    g_guest_buffer_base = g_gwin_base = address;
    g_gwin_max = g_guest_buffer.length;
    renderer_init(dev);
}

// Advance only the upload-cache frame for ownership regressions; no window or fake renderer is needed.
void metal_test_next_texture_frame(void) { g_frame_counter++; }
