// Developer prototype: private hash/state recipes, rebuilt from the user's indexed shader inputs.
// Included by renderer.m so preparation uses the live translator and compiler, serialized with drawing.
static Prog *get_program(NvnProgram *, ShaderKey *, ShaderKey *);
static NSMutableDictionary<NSString *, Prog *> *g_prep_programs;
static NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *g_prep_pipelines;
static NSMutableSet<NSString *> *g_prep_recorded;
static bool g_prep_started;
static unsigned g_prep_program_hits, g_prep_pipeline_hits;

static NSString *prep_digest(NSData *data) {
    if (!data || data.length > UINT32_MAX) return nil;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    char text[65];
    for (int i = 0; i < 32; i++) snprintf(text + 2 * i, 3, "%02x", hash[i]);
    return @(text);
}

static NSString *prep_stage_hash(NvnShaderStage *s) {
    if (!s->code_addr || s->const_offset < 16 || s->const_offset > (16u << 20) ||
        s->const_size > (16u << 20) - s->const_offset) return nil;
    return prep_digest([NSData dataWithBytesNoCopy:(void *)(uintptr_t)s->code_addr
                                          length:(size_t)s->const_offset + s->const_size freeWhenDone:NO]);
}

static NSData *prep_json(id value) {
    return [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
}

static bool prep_uint(id value, uint32_t max, uint32_t *out) {
    if (![value isKindOfClass:NSNumber.class]) return false;
    double d = [value doubleValue];
    if (!isfinite(d) || d < 0 || d > max || floor(d) != d) return false;
    *out = (uint32_t)d;
    return true;
}

static bool prep_array(id value, unsigned n, uint32_t max, uint32_t *out) {
    if (![value isKindOfClass:NSArray.class] || [value count] != n) return false;
    for (unsigned i = 0; i < n; i++) if (!prep_uint(value[i], max, &out[i])) return false;
    return true;
}

static NSDictionary *prep_key_dict(const ShaderKey *k) {
    NSMutableArray *attr = [NSMutableArray new], *rt = [NSMutableArray new], *count = [NSMutableArray new], *stride = [NSMutableArray new];
    for (int i = 0; i < 32; i++) [attr addObject:@(k->attr_kind[i])];
    for (int i = 0; i < 8; i++) [rt addObject:@(k->rt_kind[i])];
    for (int i = 0; i < 4; i++) { [count addObject:@(k->xfb_count[i])]; [stride addObject:@(k->xfb_stride[i])]; }
    return @{@"attr": attr, @"rt": rt, @"xfb_count": count, @"xfb_stride": stride,
             @"params": @[@(k->depth_minus_one), @(k->flip_y), @(k->flip_x), @(k->vs_out_mask), @(k->glsl),
                          @(k->stencil_slots), @(k->sint_slots), @(k->uint_slots), @(k->xfb_void), @(k->img_sint), @(k->img_uint)]};
}

static bool prep_key_parse(id d, ShaderKey *k) {
    if (![d isKindOfClass:NSDictionary.class]) return false;
    uint32_t a[32], r[8], c[4], s[4], p[11];
    if (!prep_array(d[@"attr"], 32, 2, a) || !prep_array(d[@"rt"], 8, 2, r) ||
        !prep_array(d[@"xfb_count"], 4, 255, c) || !prep_array(d[@"xfb_stride"], 4, 65535, s) ||
        !prep_array(d[@"params"], 11, UINT32_MAX, p)) return false;
    if (p[0] > 1 || p[1] > 1 || p[2] > 1 || p[4] != 0 || p[8] > 1 || p[9] > 255 || p[10] > 255) return false;
    memset(k, 0, sizeof *k);
    for (int i = 0; i < 32; i++) k->attr_kind[i] = a[i];
    for (int i = 0; i < 8; i++) k->rt_kind[i] = r[i];
    for (int i = 0; i < 4; i++) { k->xfb_count[i] = c[i]; k->xfb_stride[i] = s[i]; }
    k->depth_minus_one = p[0]; k->flip_y = p[1]; k->flip_x = p[2]; k->vs_out_mask = p[3]; k->glsl = p[4];
    k->stencil_slots = p[5]; k->sint_slots = p[6]; k->uint_slots = p[7]; k->xfb_void = p[8]; k->img_sint = p[9]; k->img_uint = p[10];
    return true;
}

// Enumerate precisely the descriptor fields the live draw sets. No function objects, addresses or shader bytes.
static NSArray<NSString *> *prep_pd_fields(void) {
    return @[@"depthAttachmentPixelFormat", @"stencilAttachmentPixelFormat", @"rasterSampleCount",
             @"alphaToCoverageEnabled", @"rasterizationEnabled", @"inputPrimitiveTopology"];
}
static NSArray<NSString *> *prep_color_fields(void) {
    return @[@"pixelFormat", @"writeMask", @"blendingEnabled", @"sourceRGBBlendFactor", @"destinationRGBBlendFactor",
             @"sourceAlphaBlendFactor", @"destinationAlphaBlendFactor", @"rgbBlendOperation", @"alphaBlendOperation"];
}
static NSArray *prep_values(id object, NSArray<NSString *> *fields) {
    NSMutableArray *a = [NSMutableArray new];
    for (NSString *field in fields) [a addObject:[object valueForKey:field]];
    return a;
}
static bool prep_apply(id object, id array, NSArray<NSString *> *fields) {
    uint32_t values[16];
    if (fields.count > 16 || !prep_array(array, (unsigned)fields.count, 1u << 24, values)) return false;
    for (unsigned i = 0; i < fields.count; i++) [object setValue:@(values[i]) forKey:fields[i]];
    return true;
}
static NSDictionary *prep_descriptor_dict(MTLRenderPipelineDescriptor *pd) {
    NSMutableArray *colors = [NSMutableArray new], *attrs = [NSMutableArray new], *layouts = [NSMutableArray new];
    for (int i = 0; i < 8; i++) {
        NSMutableArray *values = [prep_values(pd.colorAttachments[i], prep_color_fields()) mutableCopy];
        // Unattached targets and disabled blending cannot use these fields.
        if (!pd.colorAttachments[i].pixelFormat) { values[1] = @0; values[2] = @0; }
        if (![values[2] boolValue]) for (int j = 3; j < 9; j++) values[j] = @0;
        [colors addObject:values];
    }
    for (int i = 0; i < 31; i++) {
        MTLVertexAttributeDescriptor *a = pd.vertexDescriptor.attributes[i];
        MTLVertexBufferLayoutDescriptor *l = pd.vertexDescriptor.layouts[i];
        [attrs addObject:a ? @[@(a.format), @(a.offset), @(a.bufferIndex)] : @[@0, @0, @0]];
        [layouts addObject:l ? @[@(l.stride), @(l.stepFunction), @(l.stepRate)] : @[@0, @0, @0]];
    }
    return @{@"state": prep_values(pd, prep_pd_fields()), @"colors": colors, @"attrs": attrs, @"layouts": layouts};
}
static MTLRenderPipelineDescriptor *prep_descriptor(id d, Prog *pr) {
    if (![d isKindOfClass:NSDictionary.class]) return nil;
    NSArray *colors = d[@"colors"], *attrs = d[@"attrs"], *layouts = d[@"layouts"];
    if (![colors isKindOfClass:NSArray.class] || colors.count != 8 || ![attrs isKindOfClass:NSArray.class] || attrs.count != 31 ||
        ![layouts isKindOfClass:NSArray.class] || layouts.count != 31) return nil;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    if (!prep_apply(pd, d[@"state"], prep_pd_fields())) return nil;
    uint32_t state[6];
    if (!prep_array(d[@"state"], 6, 1024, state) || state[3] > 1 || state[4] > 1 || state[5] > 3) return nil;
    if (pd.rasterSampleCount != 1 && pd.rasterSampleCount != 2 && pd.rasterSampleCount != 4 && pd.rasterSampleCount != 8) return nil;
    pd.vertexFunction = pr ? pr->vs : nil; pd.fragmentFunction = pr ? pr->fs : nil;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    for (int i = 0; i < 8; i++) {
        uint32_t c[9];
        if (!prep_array(colors[i], 9, 1024, c) || c[1] > 15 || c[2] > 1 || c[3] > 20 || c[4] > 20 ||
            c[5] > 20 || c[6] > 20 || c[7] > 4 || c[8] > 4 || !prep_apply(pd.colorAttachments[i], colors[i], prep_color_fields())) return nil;
    }
    for (int i = 0; i < 31; i++) {
        uint32_t a[3], l[3];
        if (!prep_array(attrs[i], 3, 1u << 24, a) || !prep_array(layouts[i], 3, 1u << 24, l) || a[2] >= 31 || a[0] > 64 || l[1] > 4) return nil;
        vd.attributes[i].format = a[0]; vd.attributes[i].offset = a[1]; vd.attributes[i].bufferIndex = a[2];
        vd.layouts[i].stride = l[0]; vd.layouts[i].stepFunction = l[1]; vd.layouts[i].stepRate = l[2];
    }
    pd.vertexDescriptor = vd;
    return pd;
}

static NSDictionary *prep_program_record(NvnProgram *p, const ShaderKey *vk, const ShaderKey *fk) {
    NSString *vs = prep_stage_hash(&p->stages[0]);
    NSString *fs = p->stage_mask & 2 ? prep_stage_hash(&p->stages[1]) : @"";
    if (!vs || !fs) return nil;
    return @{@"vs": vs, @"fs": fs, @"vkey": prep_key_dict(vk), @"fkey": prep_key_dict(fk)};
}
static NSString *prep_program_id(NSDictionary *record) {
    // The translator embeds the selected guest memory window; never reuse a different window's translation.
    return prep_digest(prep_json(@[record, @(g_gwin_base), @(g_gwin_max)]));
}
static NSString *prep_pipeline_id(Prog *pr, NSDictionary *descriptor) {
    return pr->prep_id ? prep_digest(prep_json(@[pr->prep_id, descriptor])) : nil;
}
static bool prep_enabled(void) {
    if (getenv("LARECOMP_FS_OVERRIDE") || getenv("LARECOMP_FS_OVERRIDE_HASH") ||
        getenv("LARECOMP_DBG_FS") || getenv("LARECOMP_DBG_VS")) return false;
    return g_prep_active || g_prep_programs.count || getenv("LARECOMP_SHADER_RECORD") || getenv("LARECOMP_SHADER_PREP") || g_settings.prepare_shaders || g_settings.collect_shader_recipes;
}

static id<MTLRenderPipelineState> prep_pipeline(Prog *pr, MTLRenderPipelineDescriptor *pd) {
    if (!pr->prep_record || pr->ov_active || g_prep_active || !prep_enabled()) return nil;
    NSDictionary *descriptor = prep_descriptor_dict(pd);
    NSString *key = prep_pipeline_id(pr, descriptor);
    id<MTLRenderPipelineState> pipeline = g_prep_pipelines[key];
    if (pipeline) g_prep_pipeline_hits++;
    return pipeline;
}

static bool prep_hash_valid(NSString *hash) {
    if (![hash isKindOfClass:NSString.class] || hash.length != 64) return false;
    return [hash rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}
static NSData *prep_load_stage(NSString *hash, NSDictionary *index, NSString *dir, unsigned stage, NvnShaderStage *out) {
    if (!prep_hash_valid(hash)) return nil;
    id m = index[hash];
    if (![m isKindOfClass:NSDictionary.class]) return nil;
    uint32_t sz, co, cs, stg;
    if (!prep_uint(m[@"size"], 16u << 20, &sz) || !prep_uint(m[@"const_offset"], sz, &co) || co < 16 ||
        !prep_uint(m[@"const_size"], sz - co, &cs) || co + cs != sz || !prep_uint(m[@"stage"], 5, &stg) || stg != stage) return nil;
    NSString *path = [dir stringByAppendingPathComponent:[hash stringByAppendingString:@".bin"]];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if ([attrs fileSize] != sz) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length != sz || ![prep_digest(data) isEqualToString:hash]) return nil;
    *out = (NvnShaderStage){.stage = stage, .code_addr = (uint64_t)(uintptr_t)data.bytes, .const_offset = co, .const_size = cs};
    return data;
}

static bool prep_find_helper(char *helper, char *script) {
    return rt_resource("lasgen/lasgen", NULL, helper, 1100) ||
        (rt_resource(NULL, "tools/" PLAT_VENV_PYTHON, helper, 1100) &&
         rt_resource(NULL, "tools/lasgen_main.py", script, 1100));
}
#include "shader_recipe_record.inc"

static void prep_report(void) {
    if (g_prep_program_hits || g_prep_pipeline_hits)
        LOG("[shader-prep] live reuse: %u program variants, %u pipeline lookups\n", g_prep_program_hits, g_prep_pipeline_hits);
}

static unsigned prep_worker_count(NSUInteger cpus, NSUInteger jobs, const char *override) {
    NSUInteger capacity = MIN(MAX(cpus, 1), MAX(jobs, 1));
    if (override && override[0] >= '1' && override[0] <= '9') {
        char *end = NULL;
        errno = 0;
        unsigned long value = strtoul(override, &end, 10);
        if (!errno && end && !*end && value) capacity = MIN(capacity, value);
    }
    return (unsigned)capacity;
}

// Translation and address-keyed caches stay on the render thread. Each worker
// owns one translated program and all its PSOs; nothing escapes until the join.
static unsigned prep_compile(NSDictionary *jobs, unsigned total, unsigned missed) {
    unsigned workers = prep_worker_count(NSProcessInfo.processInfo.activeProcessorCount, jobs.count,
                                         getenv("LARECOMP_SHADER_PREP_WORKERS"));
    dispatch_semaphore_t slots = dispatch_semaphore_create(workers);
    dispatch_group_t group = dispatch_group_create();
    __block unsigned completed = missed, failures = missed, active = 0, peak = 0;
    backend_shader_prepare_progress(completed, total);
    pipeline_archive();
    for (NSDictionary *job in jobs.allValues) {
        dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
            @synchronized(g_prep_pipelines) { if (++active > peak) peak = active; }
            Prog *pr = job[@"program"];
            compile_program(pr);
            NSMutableDictionary *pipes = [NSMutableDictionary new];
            for (NSDictionary *recipe in job[@"recipes"]) {
                NSString *key = recipe[@"key"];
                id<MTLRenderPipelineState> pipe = pipes[key];
                if (!pipe && pr->ready && !pr->failed) {
                    MTLRenderPipelineDescriptor *pd = prep_descriptor(recipe[@"descriptor"], pr);
                    if (pd) {
                        pipe = [dev newRenderPipelineStateWithDescriptor:pd error:nil];
                        if (pipe) { pipes[key] = pipe; pipeline_archive_add([pd copy], pr); }
                    }
                }
                @synchronized(g_prep_pipelines) {
                    if (pipe) g_prep_pipelines[key] = pipe;
                    else failures++;
                    backend_shader_prepare_progress(++completed, total);
                    if (completed % 32 == 0) LOG("[shader-prep] %u/%u recipes checked\n", completed, total);
                }
            }
            @synchronized(g_prep_pipelines) { active--; }
            dispatch_semaphore_signal(slots);
        }});
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    for (NSString *key in g_prep_programs.allKeys) {
        Prog *pr = g_prep_programs[key];
        if (!pr->ready || pr->failed) [g_prep_programs removeObjectForKey:key];
    }
    LOG("[shader-prep] native compilation: %u workers, %u peak active\n", workers, peak);
    return failures;
}

static bool prep_run(NSString *path, NSString *dir) {
    if (g_prep_active) return false;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!attrs || [attrs fileSize] > (16u << 20)) return false;
    NSData *manifest = [NSData dataWithContentsOfFile:path];
    if (!manifest) return false;
    NSString *text = [[NSString alloc] initWithData:manifest encoding:NSUTF8StringEncoding];
    NSString *index_path = [dir stringByAppendingPathComponent:@"index.json"];
    attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:index_path error:nil];
    if (!text || !attrs || [attrs fileSize] > (16u << 20)) return false;
    NSData *index_data = [NSData dataWithContentsOfFile:index_path];
    if (!index_data) return false;
    id root = [NSJSONSerialization JSONObjectWithData:index_data options:0 error:nil];
    if (![root isKindOfClass:NSDictionary.class] || ![root[@"version"] isEqual:@1] || ![root[@"shaders"] isKindOfClass:NSDictionary.class]) return false;
    NSDictionary *index = root[@"shaders"];
    g_prep_programs = [NSMutableDictionary new]; g_prep_pipelines = [NSMutableDictionary new];
    NSMutableDictionary *inputs = [NSMutableDictionary new], *jobs = [NSMutableDictionary new];
    unsigned missed = 0, seen = 0;
    size_t total_bytes = 0;
    double t0 = now_ms(), previous_ms = stat_compile_ms;
    int previous_compiles = stat_compiles;
    static bool report_registered;
    if (!report_registered) { atexit(prep_report); report_registered = true; }
    NSSet *old_keys = [NSSet setWithArray:cache.allKeys];
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    unsigned total = 0;
    for (NSString *line in lines) if (line.length) total++;
    backend_shader_prepare_progress(0, total);
    g_prep_active = g_prep_translate_only = true;
    for (NSString *line in lines) { @autoreleasepool {
        if (!line.length) continue;
        if (seen == total) break;
        seen++;
        id r = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![r isKindOfClass:NSDictionary.class] || ![r[@"version"] isEqual:@1]) { missed++; continue; }
        NSDictionary *p = r[@"program"];
        ShaderKey vk, fk;
        if (![p isKindOfClass:NSDictionary.class] || !prep_key_parse(p[@"vkey"], &vk) || !prep_key_parse(p[@"fkey"], &fk) ||
            !prep_hash_valid(p[@"vs"]) || ![p[@"fs"] isKindOfClass:NSString.class]) { missed++; continue; }
        if (!prep_descriptor(r[@"pipeline"], nil)) { missed++; continue; }
        NvnProgram np = {.stage_mask = [p[@"fs"] length] ? 3 : 1};
        bool ok = true;
        for (int i = 0; i < 2 && ok; i++) {
            if (i == 1 && !(np.stage_mask & 2)) continue;
            NSString *hash = p[i ? @"fs" : @"vs"];
            NSData *bytes = inputs[hash];
            if (!bytes) {
                bytes = prep_load_stage(hash, index, dir, i, &np.stages[i]);
                if (bytes && total_bytes + bytes.length <= (128u << 20)) { inputs[hash] = bytes; total_bytes += bytes.length; }
                else ok = false;
            } else {
                id meta = index[hash];
                if ([meta[@"stage"] unsignedIntValue] != (unsigned)i) { ok = false; break; }
                np.stages[i] = (NvnShaderStage){.stage = i, .code_addr = (uint64_t)(uintptr_t)bytes.bytes,
                    .const_offset = [meta[@"const_offset"] unsignedIntValue], .const_size = [meta[@"const_size"] unsignedIntValue]};
            }
            if (!bytes) ok = false;
        }
        if (!ok) { missed++; continue; }
        Prog *pr = g_prep_programs[prep_program_id(p)];
        if (!pr) pr = get_program(&np, &vk, &fk);
        if (!pr || pr->failed || !pr->prep_id) { missed++; continue; }
        g_prep_programs[pr->prep_id] = pr;
        NSMutableDictionary *job = jobs[pr->prep_id];
        if (!job) {
            job = [@{@"program": pr, @"recipes": [NSMutableArray new]} mutableCopy];
            jobs[pr->prep_id] = job;
        }
        NSDictionary *descriptor = prep_descriptor_dict(prep_descriptor(r[@"pipeline"], nil));
        [job[@"recipes"] addObject:@{@"key": prep_pipeline_id(pr, descriptor), @"descriptor": descriptor}];
    }}
    g_prep_translate_only = false;
    missed = prep_compile(jobs, total, missed);
    // Fake source addresses must not escape into the live address-keyed cache after inputs are released.
    memset(prog_tab, 0, sizeof prog_tab);
    for (id key in cache.allKeys) if (![old_keys containsObject:key]) [cache removeObjectForKey:key];
    g_prep_active = false;
    backend_shader_prepare_progress(0, 0);
    stat_compile_ms = previous_ms; stat_compiles = previous_compiles;
    LOG("[shader-prep] prepared %lu programs, %lu pipelines, %u missing/invalid in %.0f ms\n",
        (unsigned long)g_prep_programs.count, (unsigned long)g_prep_pipelines.count, missed, now_ms() - t0);
    return g_prep_pipelines.count != 0;
}

// The catalog contains references/state only. The trusted bundled helper reads
// the player's own files and publishes an immutable generation after verification.
static bool prep_install(NSString **manifest, NSString **inputs) {
    char catalog[1100], helper[1100], script[1100] = {0}, decoder[1100] = {0};
    const char *override = getenv("LARECOMP_SHADER_CATALOG");
    if (override && *override) snprintf(catalog, sizeof catalog, "%s", override);
    else if (!access("cache/shader-preparation/catalog.json", R_OK))
        snprintf(catalog, sizeof catalog, "cache/shader-preparation/catalog.json");
    else if (!rt_resource("shader-catalog.json", NULL, catalog, sizeof catalog)) {
        snprintf(catalog, sizeof catalog, "cache/shader-preparation/catalog.json");
        if (access(catalog, R_OK)) { LOG("[shader-prep] no installed catalog; compiling normally\n"); return false; }
    }
    if (!prep_find_helper(helper, script)) {
        LOG("[shader-prep] preparation helper unavailable; compiling normally\n"); return false;
    }
    rt_resource("lasgen/monzamac-shader-decode", "build/shader-decode/release/monzamac-shader-decode", decoder, sizeof decoder);
    extern const char *g_romfs_dir;
    if (!g_romfs_dir) return false;
    NSString *game = [@(g_romfs_dir) stringByDeletingLastPathComponent];
    mkdir("cache", 0755); mkdir("cache/shader-preparation", 0755);
    const char *argv[16]; int n = 0;
    argv[n++] = helper; if (*script) argv[n++] = script;
    argv[n++] = "shader-catalog"; argv[n++] = "prepare";
    argv[n++] = game.UTF8String; argv[n++] = catalog; argv[n++] = "cache/shader-preparation";
    if (*decoder) { argv[n++] = "--decoder"; argv[n++] = decoder; }
    if (!access("cache/shader-recipes/recipes.jsonl", R_OK)) { argv[n++] = "--recipes"; argv[n++] = "cache/shader-recipes/recipes.jsonl"; }
    argv[n] = NULL;
    backend_shader_prepare_inputs(0, 1);
    PlatProc child = plat_spawn(argv, "cache/shader-preparation/prepare.log", false);
    if (!child) { backend_shader_prepare_progress(0, 0); return false; }
    double started = now_ms(); int result;
    while ((result = plat_proc_wait(child, false)) < 0) {
        if (g_rt_unwind || now_ms() - started > 120000) {
            plat_proc_kill(child); backend_shader_prepare_progress(0, 0);
            LOG("[shader-prep] input preparation interrupted or timed out; compiling normally\n"); return false;
        }
        FILE *f = fopen("cache/shader-preparation/prepare.log", "r");
        if (f) {
            char line[512]; unsigned done, total;
            while (fgets(line, sizeof line, f))
                if (sscanf(line, "[shader-inputs] %u/%u verified", &done, &total) == 2 && total && total <= 2048)
                    backend_shader_prepare_inputs(done, total);
            fclose(f);
        }
        usleep(20000);
    }
    backend_shader_prepare_progress(0, 0);
    if (result) { LOG("[shader-prep] input preparation failed (%d); compiling normally (see cache/shader-preparation/prepare.log)\n", result); return false; }
    NSData *data = [NSData dataWithContentsOfFile:@"cache/shader-preparation/current.json"];
    if (!data || data.length > 1024) return false;
    id current = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![current isKindOfClass:NSDictionary.class] || ![current[@"version"] isEqual:@1] || !prep_hash_valid(current[@"catalog"])) return false;
    NSString *base = [@"cache/shader-preparation" stringByAppendingPathComponent:current[@"catalog"]];
    *manifest = [base stringByAppendingPathComponent:@"recipes.jsonl"];
    *inputs = [base stringByAppendingPathComponent:@"inputs"];
    return true;
}

static void prep_once(void) {
    if (g_prep_started || g_prep_active) return;
    g_prep_started = true;
    const char *path = getenv("LARECOMP_SHADER_PREP"), *dir = getenv("LARECOMP_SHADER_INPUTS");
    if (!prep_enabled()) return;
    NSString *manifest = path && *path ? @(path) : nil, *inputs = dir && *dir ? @(dir) : nil;
    if (!path && !dir && g_settings.prepare_shaders) prep_install(&manifest, &inputs);
    if (manifest && inputs && !prep_run(manifest, inputs)) LOG("[shader-prep] no usable preparation; compiling normally\n");
}
static void prep_reset(void) {
    renderer_recipe_flush();
    g_prep_recorded = nil;
    g_prep_programs = nil; g_prep_pipelines = nil; g_prep_started = false;
}
