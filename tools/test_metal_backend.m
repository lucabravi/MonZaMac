// Test-only offscreen bootstrap. Production code is included so no test API is added to the app.
#include "../runtime/nvn/metal.m"

void metal_test_bootstrap(void) {
    // runtime/main.o's constructor has already reserved the guest window, even with our alternate entry point.
    uint64_t address = 0x7200000000ull;
    dev = MTLCreateSystemDefaultDevice();
    if (!dev) return;
    queue = [dev newCommandQueue];
    gwin_done = true;
    // Indirect commands use the same guest-address checks as the game, so keep this tiny mapping in that range.
    g_guest_buffer = [dev newBufferWithBytesNoCopy:(void *)(uintptr_t)address length:16384
                                         options:MTLResourceStorageModeShared deallocator:nil];
    if (!g_guest_buffer) { fprintf(stderr, "test guest Metal buffer failed\n"); abort(); }
    g_guest_buffer_base = g_gwin_base = address;
    g_gwin_max = g_guest_buffer.length;
    renderer_init(dev);
}
