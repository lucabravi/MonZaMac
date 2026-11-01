// "Prepare all shaders": every shader in the player's game files is translated with its default specialization and its
// Metal library compiled before the game starts, so Metal's own cache already holds what the game will ask for (measured
// against what a session really asked for: 99.5% of vertex, 73% of fragment programs). The translator embeds the guest
// memory window, so this runs inside the game process, not in the start screen. Included by renderer.m after the
// preparation code; the start screen only sets g_settings.precompile_request.
#include "precompile_stamp.h"

static bool precompile_requested(void) {
    return g_settings.precompile_request || (getenv("LARECOMP_PRECOMPILE") && atoi(getenv("LARECOMP_PRECOMPILE")));
}

// The helper writes every shader of the game's files to `dir` (inputs plus index.json): about 115 MB, deleted afterwards.
static bool precompile_index(NSString *game, NSString *dir) {
    char helper[1100], script[1100] = {0}, decoder[1100] = {0};
    if (!prep_find_helper(helper, script)) { LOG("[precompile] helper unavailable\n"); return false; }
    rt_resource("lasgen/monzamac-shader-decode", "build/shader-decode/release/monzamac-shader-decode", decoder, sizeof decoder);
    if (!*decoder) { LOG("[precompile] native decoder unavailable\n"); return false; }
    const char *argv[12]; int n = 0;
    argv[n++] = helper; if (*script) argv[n++] = script;
    argv[n++] = "shader-catalog"; argv[n++] = "index"; argv[n++] = game.UTF8String; argv[n++] = dir.UTF8String;
    argv[n++] = "--decoder"; argv[n++] = decoder; argv[n] = NULL;
    PlatProc child = plat_spawn(argv, "cache/shader-precompile/index.log", false);
    if (!child) return false;
    double started = now_ms(); int result;
    while ((result = plat_proc_wait(child, false)) < 0) {
        if (g_rt_unwind || backend_shader_prepare_cancelled() || now_ms() - started > 20 * 60 * 1000) {
            plat_proc_kill(child); return false;
        }
        usleep(50000);
    }
    return result == 0;
}

static void precompile_run(void) {
    g_settings.precompile_request = false;
    unsetenv("LARECOMP_PRECOMPILE");
    extern const char *g_romfs_dir;
    if (!g_romfs_dir || g_prep_active) return;
    NSString *root = [@(g_romfs_dir) stringByDeletingLastPathComponent];
    NSString *dir = @"cache/shader-precompile/inputs";
    NSFileManager *fm = NSFileManager.defaultManager;
    mkdir("cache", 0755); mkdir("cache/shader-precompile", 0755);
    [fm removeItemAtPath:dir error:nil];
    double t0 = now_ms();
    backend_shader_precompile_progress(0, 0, 0);
    if (!precompile_index(root, dir)) {
        LOG("[precompile] could not read the game's shaders%s\n", backend_shader_prepare_cancelled() ? " (stopped)" : "");
        [fm removeItemAtPath:dir error:nil];
        backend_shader_prepare_progress(0, 0);
        return;
    }
    NSData *idata = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"index.json"]];
    NSDictionary *index = idata ? [NSJSONSerialization JSONObjectWithData:idata options:0 error:nil][@"shaders"] : nil;
    NSArray<NSString *> *hashes = [index.allKeys sortedArrayUsingSelector:@selector(compare:)];
    unsigned total = (unsigned)hashes.count;
    if (!total) { backend_shader_prepare_progress(0, 0); return; }
    LOG("[precompile] %u shaders in the game files (read in %.0f ms)\n", total, now_ms() - t0);
    backend_shader_precompile_progress(1, 0, total);

    unsigned workers = prep_worker_count(NSProcessInfo.processInfo.activeProcessorCount, total, getenv("LARECOMP_SHADER_PREP_WORKERS"));
    dispatch_semaphore_t slots = dispatch_semaphore_create(workers);
    dispatch_group_t group = dispatch_group_create();
    __block unsigned done = 0, built = 0;
    unsigned translated = 0;
    t0 = now_ms();
    backend_gwin_pick(); maxwell_gmem_base = g_gwin_base; maxwell_gmem_size = g_gwin_max;
    bool stopped = false;
    for (NSString *hash in hashes) {
        if (backend_shader_prepare_cancelled() || g_rt_unwind) { stopped = true; break; }
        NSDictionary *m = index[hash]; int stage = [m[@"stage"] intValue];
        NSData *bin = (stage == 0 || stage == 1 || stage == 5)
            ? [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:[hash stringByAppendingString:@".bin"]]] : nil;
        if (!bin) { @synchronized(group) { backend_shader_precompile_progress(1, ++done, total); } continue; }
        size_t co = [m[@"const_offset"] unsignedIntValue], cs = [m[@"const_size"] unsignedIntValue];
        ShaderKey k = {0}; if (stage == 1) k.vs_out_mask = 0xFFFFFFFFu;  // (every vertex output may be there)
        ShaderInfo *si = maxwell_translate_with_constants(bin.bytes, co ? co : 0x10000,
            stage == 0 ? STAGE_VERTEX : stage == 1 ? STAGE_FRAGMENT : STAGE_COMPUTE, &k, (const uint8_t *)bin.bytes + co, co ? cs : 0);
        if (!si->msl) { @synchronized(group) { backend_shader_precompile_progress(1, ++done, total); } continue; }
        translated++;
        NSString *source = @(si->msl);
        dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
            id<MTLLibrary> lib = [dev newLibraryWithSource:source options:game_shader_opts(stage == 0) error:nil];
            @synchronized(group) { if (lib) built++; backend_shader_precompile_progress(1, ++done, total); }
            dispatch_semaphore_signal(slots);
        }});
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    [fm removeItemAtPath:dir error:nil];
    backend_shader_prepare_progress(0, 0);
    if (stopped) { LOG("[precompile] stopped after %u of %u shaders (kept)\n", done, total); return; }
    precompile_write_stamp(root.UTF8String, built);
    LOG("[precompile] %u shaders: %u translated, %u libraries compiled on %u workers in %.1f s\n", total, translated, built, workers,
        (now_ms() - t0) / 1000);
}
