// Experimental: learned variants only. Guest inputs are copied at registration;
// renderer-owned translation and publication never run on the compiler worker.
static pthread_mutex_t early_lock = PTHREAD_MUTEX_INITIALIZER;
static NSArray *early_recipes;
static NSSet *early_targets;
static NSMutableDictionary *early_inputs;
static NSMutableSet *early_attempted, *early_hits, *early_submitted;
static NSMutableArray *early_completed;
static dispatch_queue_t early_queue;
static dispatch_group_t early_group;
static size_t early_bytes;
static uint64_t early_input_revision, early_checked_revision = UINT64_MAX;
static unsigned early_inflight, early_active, early_peak, early_limit = 1;

static bool early_enabled(void) {
    const char *force = getenv("LARECOMP_SHADER_EARLY");
    return force ? atoi(force) != 0 : (g_settings.early_shaders || getenv("LARECOMP_SHADER_EARLY_RECIPES"));
}

static void early_add_record(id row, NSMutableArray *recipes, NSMutableSet *targets, NSMutableSet *seen) {
    if (![row isKindOfClass:NSDictionary.class] || ![row[@"version"] isEqual:@1]) return;
    id p = row[@"program"]; ShaderKey vk, fk;
    if (![p isKindOfClass:NSDictionary.class] || !prep_hash_valid(p[@"vs"]) || !prep_hash_valid(p[@"fs"]) ||
        !prep_key_parse(p[@"vkey"], &vk) || !prep_key_parse(p[@"fkey"], &fk)) return;
    MTLRenderPipelineDescriptor *pd = prep_descriptor(row[@"pipeline"], nil);
    if (!pd) return;
    NSDictionary *program = @{@"vs": p[@"vs"], @"fs": p[@"fs"], @"vkey": prep_key_dict(&vk), @"fkey": prep_key_dict(&fk)};
    NSDictionary *record = @{@"version": @1, @"program": program, @"pipeline": prep_descriptor_dict(pd)};
    NSString *identity = prep_digest(prep_json(record));
    if ([seen containsObject:identity]) return;
    NSMutableDictionary *indexed = [record mutableCopy]; indexed[@"program_id"] = prep_digest(prep_json(program));
    [seen addObject:identity]; [recipes addObject:indexed];
    [targets addObject:program[@"vs"]]; [targets addObject:program[@"fs"]];
}

static void early_read(NSString *name, bool catalog, NSMutableArray *recipes, NSMutableSet *targets, NSMutableSet *seen) {
    NSDictionary *attrs = name ? [[NSFileManager defaultManager] attributesOfItemAtPath:name error:nil] : nil;
    if (!attrs || ![attrs[NSFileType] isEqual:NSFileTypeRegular] || [attrs fileSize] > (16u << 20)) return;
    NSData *data = [NSData dataWithContentsOfFile:name];
    if (!data || data.length > (16u << 20)) return;
    if (!catalog) {
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            NSData *bytes = [line dataUsingEncoding:NSUTF8StringEncoding];
            early_add_record(bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil, recipes, targets, seen);
        }
        return;
    }
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:NSDictionary.class]) return;
    id rows = root[@"recipes"], profiles = root[@"profiles"];
    if (![root[@"version"] isEqual:@2] || ![rows isKindOfClass:NSArray.class] ||
        ![profiles isKindOfClass:NSDictionary.class]) return;
    NSArray *v = profiles[@"vertex_keys"], *f = profiles[@"fragment_keys"], *d = profiles[@"descriptors"];
    if (![v isKindOfClass:NSArray.class] || ![f isKindOfClass:NSArray.class] || ![d isKindOfClass:NSArray.class]) return;
    for (id r in rows) {
        uint32_t vi, fi, di;
        if (![r isKindOfClass:NSDictionary.class] || !prep_uint(r[@"vertex_key"], 0xFFFFFF, &vi) ||
            !prep_uint(r[@"fragment_key"], 0xFFFFFF, &fi) || !prep_uint(r[@"descriptor"], 0xFFFFFF, &di) ||
            vi >= v.count || fi >= f.count || di >= d.count || !r[@"vs"] || !r[@"fs"]) continue;
        early_add_record(@{@"version": @1, @"program": @{@"vs": r[@"vs"], @"fs": r[@"fs"], @"vkey": v[vi], @"fkey": f[fi]}, @"pipeline": d[di]}, recipes, targets, seen);
    }
}

static void early_init(void) {
    if (!early_enabled()) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (getenv("LARECOMP_FS_OVERRIDE") || getenv("LARECOMP_FS_OVERRIDE_HASH") ||
            getenv("LARECOMP_DBG_FS") || getenv("LARECOMP_DBG_VS")) return;
        NSMutableArray *recipes = [NSMutableArray new]; NSMutableSet *targets = [NSMutableSet new], *seen = [NSMutableSet new];
        const char *path = getenv("LARECOMP_SHADER_EARLY_RECIPES");
        if (path && *path) early_read(@(path), false, recipes, targets, seen);
        else {
            char catalog[1100]; const char *override = getenv("LARECOMP_SHADER_CATALOG");
            if (override && *override) early_read(@(override), true, recipes, targets, seen);
            else if (!access("cache/shader-preparation/catalog.json", R_OK))
                early_read(@"cache/shader-preparation/catalog.json", true, recipes, targets, seen);
            else if (rt_resource("shader-catalog.json", NULL, catalog, sizeof catalog))
                early_read(@(catalog), true, recipes, targets, seen);
            early_read(@"cache/shader-recipes/recipes.jsonl", false, recipes, targets, seen);
        }
        if (!recipes.count) return;
        early_recipes = recipes; early_targets = targets;
        early_inputs = [NSMutableDictionary new]; early_attempted = [NSMutableSet new];
        early_submitted = [NSMutableSet new]; early_hits = [NSMutableSet new]; early_completed = [NSMutableArray new];
        early_queue = dispatch_queue_create("monzamac.shader-early", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_UTILITY, 0));
        early_group = dispatch_group_create();
        NSMutableSet *programs = [NSMutableSet new];
        for (NSDictionary *recipe in recipes) [programs addObject:prep_digest(prep_json(recipe[@"program"]))];
        early_limit = prep_worker_count(NSProcessInfo.processInfo.activeProcessorCount, programs.count, getenv("LARECOMP_SHADER_EARLY_WORKERS"));
        LOG("[shader-early] native concurrency limit: %u\n", early_limit);
        LOG("[shader-early] enabled: %u learned recipes, %u input hashes\n", (unsigned)recipes.count, (unsigned)targets.count);
    });
}

void renderer_shader_registered(const NvnShaderStage *s) {
    if (!early_enabled()) return;
    early_init();
    if (!early_targets || !s || s->stage > 1 || s->const_offset < 16 || s->const_offset > (16u << 20) ||
        s->const_size > (16u << 20) - s->const_offset || s->code_addr < GUEST_LO || s->code_addr >= GUEST_HI) return;
    size_t size = (size_t)s->const_offset + s->const_size;
    if (size > GUEST_HI - s->code_addr) return;
    @autoreleasepool {
        NSMutableData *bytes = [NSMutableData dataWithLength:size]; mach_vm_size_t got = 0;
        if (mach_vm_read_overwrite(mach_task_self(), s->code_addr, size, (mach_vm_address_t)bytes.mutableBytes, &got) != KERN_SUCCESS || got != size) return;
        NSString *hash = prep_digest(bytes);
        if (![early_targets containsObject:hash]) return;
        pthread_mutex_lock(&early_lock);
        if (!early_inputs[hash] && early_inputs.count < early_targets.count && size <= (32u << 20) - early_bytes) {
            early_inputs[hash] = @{@"bytes": bytes, @"offset": @(s->const_offset), @"size": @(s->const_size), @"stage": @(s->stage), @"registered": @(now_ms())};
            early_bytes += size; early_input_revision++;
            LOG("[shader-early] captured stage %u (%zu bytes)\n", s->stage, size);
        }
        pthread_mutex_unlock(&early_lock);
    }
}

// Called only by the renderer, including from a synchronous live draw wait.
static void early_publish(void) {
    if (!early_group) return;
    pthread_mutex_lock(&early_lock);
    NSArray *completed = [early_completed copy]; [early_completed removeAllObjects];
    for (NSDictionary *job in completed) {
        Prog *pr = job[@"program"];
        if (pr->ready && !pr->failed) {
            if (!g_prep_pipelines) g_prep_pipelines = [NSMutableDictionary new];
            [g_prep_pipelines addEntriesFromDictionary:job[@"pipelines"]];
        } else {
            // A failed speculative compile must not poison normal first-use fallback.
            [g_prep_programs removeObjectForKey:pr->prep_id];
            for (id key in cache.allKeys) if (cache[key] == pr) [cache removeObjectForKey:key];
            for (unsigned i = 0; i < PROG_TAB; i++) if (prog_tab[i].value == (__bridge void *)pr) memset(&prog_tab[i], 0, sizeof prog_tab[i]);
        }
        pr->early_pending = false;
    }
    pthread_mutex_unlock(&early_lock);
}

static void early_frame(void) {
    early_init();
    if (!early_targets || !dev || !cache || g_prep_active) return;
    early_publish();
    for (;;) {
        pthread_mutex_lock(&early_lock);
        if (!early_enabled() || early_checked_revision == early_input_revision || early_inflight >= early_limit) { pthread_mutex_unlock(&early_lock); return; }
        NSDictionary *selected = nil, *vs = nil, *fs = nil;
        for (NSDictionary *recipe in early_recipes) {
            NSDictionary *p = recipe[@"program"];
            NSString *id_ = recipe[@"program_id"] ?: prep_digest(prep_json(p));
            if ([early_attempted containsObject:id_]) continue;
            vs = early_inputs[p[@"vs"]]; fs = early_inputs[p[@"fs"]];
            if (!vs || !fs || [vs[@"stage"] unsignedIntValue] != 0 || [fs[@"stage"] unsignedIntValue] != 1) continue;
            selected = recipe; [early_attempted addObject:id_]; early_inflight++; break;
        }
        if (!selected) early_checked_revision = early_input_revision;
        pthread_mutex_unlock(&early_lock);
        if (!selected) return;
        NvnProgram np = {.stage_mask = 3};
        NSDictionary *inputs[] = {vs, fs};
        for (int i = 0; i < 2; i++) {
            NSData *data = inputs[i][@"bytes"];
            np.stages[i] = (NvnShaderStage){.stage = i, .code_addr = (uint64_t)(uintptr_t)data.bytes,
                .const_offset = [inputs[i][@"offset"] unsignedIntValue], .const_size = [inputs[i][@"size"] unsignedIntValue]};
        }
        ShaderKey vk, fk; prep_key_parse(selected[@"program"][@"vkey"], &vk); prep_key_parse(selected[@"program"][@"fkey"], &fk);
        // Prepared and already-live programs need no second native build.
        backend_gwin_pick();
        NSString *identity = prep_program_id(prep_program_record(&np, &vk, &fk));
        Prog *existing = g_prep_programs[identity];
        if (!existing) for (id candidate in cache.allValues) {
            if ([candidate isKindOfClass:Prog.class] && [((Prog *)candidate)->prep_id isEqual:identity]) { existing = candidate; break; }
        }
        if (existing) {
            pthread_mutex_lock(&early_lock); early_inflight--; pthread_mutex_unlock(&early_lock); continue;
        }
        // get_program owns translation/cache access; only native Metal work escapes.
        bool old_active = g_prep_active, old_translate = g_prep_translate_only;
        g_prep_active = g_prep_translate_only = true;
        double start = now_ms(); Prog *pr = get_program(&np, &vk, &fk);
        g_prep_active = old_active; g_prep_translate_only = old_translate;
        if (!pr || pr->failed) {
            pthread_mutex_lock(&early_lock); early_inflight--; pthread_mutex_unlock(&early_lock); continue;
        }
        // Different learned metadata can collapse to the same live cache entry.
        // Never let two native workers mutate the same Prog, even after one finishes.
        if (pr->ready || [early_submitted containsObject:pr]) {
            pthread_mutex_lock(&early_lock); early_inflight--; pthread_mutex_unlock(&early_lock); continue;
        }
        [early_submitted addObject:pr];
        pr->early_pending = true;
        if (!g_prep_programs) g_prep_programs = [NSMutableDictionary new];
        g_prep_programs[pr->prep_id] = pr;
        [early_hits addObject:pr->prep_id];
        double registered = MAX([vs[@"registered"] doubleValue], [fs[@"registered"] doubleValue]);
        LOG("[shader-early] queued after %.2f ms, translation %.2f ms\n", start - registered, now_ms() - start);
        dispatch_group_async(early_group, early_queue, ^{ @autoreleasepool {
            pthread_mutex_lock(&early_lock);
            if (++early_active > early_peak) early_peak = early_active;
            LOG("[shader-early] native active: %u, peak: %u\n", early_active, early_peak);
            pthread_mutex_unlock(&early_lock);
            double began = now_ms(); compile_program(pr);
            NSMutableDictionary *pipes = [NSMutableDictionary new];
            if (pr->ready && !pr->failed) for (NSDictionary *recipe in early_recipes) {
                if (![recipe[@"program"] isEqual:selected[@"program"]]) continue;
                MTLRenderPipelineDescriptor *pd = prep_descriptor(recipe[@"pipeline"], pr);
                id<MTLRenderPipelineState> pipe = pd ? [dev newRenderPipelineStateWithDescriptor:pd error:nil] : nil;
                if (pipe) { pipes[prep_pipeline_id(pr, prep_descriptor_dict(pd))] = pipe; pipeline_archive_add([pd copy], pr); }
            }
            pthread_mutex_lock(&early_lock);
            [early_completed addObject:@{@"program": pr, @"pipelines": pipes}];
            early_active--; early_inflight--;
            LOG("[shader-early] completed %s, %.2f ms, %u pipelines, %.2f ms since registration\n", pr->ready ? "ready" : "failed", now_ms() - began, (unsigned)pipes.count, now_ms() - registered);
            pthread_mutex_unlock(&early_lock);
        }});
    }
}

static void early_live_hit(NSString *identity) {
    if ([early_hits containsObject:identity]) {
        LOG("[shader-early] live program hit\n"); [early_hits removeObject:identity];
    }
}

static void early_reset(void) {
    if (!early_group) return;
    dispatch_group_wait(early_group, DISPATCH_TIME_FOREVER);
    pthread_mutex_lock(&early_lock);
    [early_inputs removeAllObjects]; [early_attempted removeAllObjects];
    [early_submitted removeAllObjects]; [early_hits removeAllObjects]; [early_completed removeAllObjects]; early_bytes = 0; early_input_revision = 0; early_checked_revision = UINT64_MAX; early_inflight = early_active = early_peak = 0;
    pthread_mutex_unlock(&early_lock);
}
