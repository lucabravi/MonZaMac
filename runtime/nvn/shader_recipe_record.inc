// Metadata only. The renderer hands immutable snapshots to one bounded writer;
// JSON, existing-file deduplication and atomic writes never run on the draw path.
#include <sys/file.h>
static NSString *const recipe_default_path = @"cache/shader-recipes/recipes.jsonl";
static dispatch_queue_t recipe_q;
static NSMutableDictionary *recipe_files;
static NSMutableSet *recipe_known;
static unsigned recipe_pending, recipe_count, recipe_dropped;
static pthread_mutex_t recipe_export_lock = PTHREAD_MUTEX_INITIALIZER;
static PlatProc recipe_export_child;
static bool recipe_stopping;

@interface RecipeJournal : NSObject {
@public
    NSString *path;
    NSMutableOrderedSet<NSString *> *rows;
    NSUInteger bytes;
    bool dirty, scheduled, failed;
    int lock_fd;
}
@end
@implementation RecipeJournal
- (void)dealloc { if (lock_fd >= 0) close(lock_fd); }
@end

static id recipe_numbers(id value) {
    if ([value isKindOfClass:NSNumber.class]) {
        double n = [value doubleValue];
        if (n < 0 || n > UINT32_MAX || n != [value unsignedLongLongValue]) return nil;
        return @([value unsignedLongLongValue]);
    }
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *out = [NSMutableArray new];
        for (id v in value) { id n = recipe_numbers(v); if (!n) return nil; [out addObject:n]; }
        return out;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *out = [NSMutableDictionary new];
        for (id k in value) { id n = recipe_numbers(value[k]); if (!n) return nil; out[k] = n; }
        return out;
    }
    return nil;
}
static bool recipe_valid(id r) {
    if ([r isKindOfClass:NSDictionary.class] && r[@"compute"]) {  // compute: code, texture-type masks, workgroup size
        id c = r[@"compute"]; uint32_t k[5], l[3];
        return [r count] == 2 && [r[@"version"] isEqual:@1] && [c isKindOfClass:NSDictionary.class] && [c count] == 3 &&
               prep_hash_valid(c[@"cs"]) && prep_array(c[@"key"], 5, UINT32_MAX, k) && k[3] <= 255 && k[4] <= 255 &&
               prep_array(c[@"local"], 3, 1024, l) && l[0] && l[1] && l[2];
    }
    if (![r isKindOfClass:NSDictionary.class] || [r count] != 3 || ![r[@"version"] isEqual:@1]) return false;
    id p = r[@"program"], d = r[@"pipeline"]; ShaderKey vk, fk;
    if (![p isKindOfClass:NSDictionary.class] || [p count] != 4 || !prep_hash_valid(p[@"vs"]) ||
        ![p[@"fs"] isKindOfClass:NSString.class] || ([p[@"fs"] length] && !prep_hash_valid(p[@"fs"])) ||
        ![p[@"vkey"] isKindOfClass:NSDictionary.class] || [p[@"vkey"] count] != 5 ||
        ![p[@"fkey"] isKindOfClass:NSDictionary.class] || [p[@"fkey"] count] != 5 ||
        !prep_key_parse(p[@"vkey"], &vk) || !prep_key_parse(p[@"fkey"], &fk) ||
        ![d isKindOfClass:NSDictionary.class] || [d count] != 4) return false;
    uint32_t scratch[9];
    if (!prep_array(d[@"state"], 6, 1024, scratch)) return false;
    NSString *names[] = {@"colors", @"attrs", @"layouts"}; unsigned counts[] = {8,31,31}, widths[] = {9,3,3};
    for (int i = 0; i < 3; i++) {
        id rows = d[names[i]];
        if (![rows isKindOfClass:NSArray.class] || [rows count] != counts[i]) return false;
        for (id row in rows) if (!prep_array(row, widths[i], 1u << 24, scratch)) return false;
    }
    return true;
}
static NSString *recipe_line(id record) {
    if (!recipe_valid(record)) return nil;
    id normalized = recipe_numbers(record);
    NSData *data = normalized ? prep_json(normalized) : nil;
    return data.length && data.length <= (64u << 10) ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}
static NSData *recipe_read(NSString *path, bool *bad) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) { *bad = errno != ENOENT; return nil; }
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size < 0 || st.st_size > (100u << 20)) { close(fd); *bad = true; return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    size_t done = 0;
    while (done < data.length) {
        ssize_t n = read(fd, (char *)data.mutableBytes + done, data.length - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { *bad = true; break; }
        done += n;
    }
    close(fd);
    return *bad ? nil : data;
}
static void recipe_load_known(void) {  // writer queue; reload after catalog changes
    recipe_known = [NSMutableSet new];
    char resource[1100];
    const char *override = getenv("LARECOMP_SHADER_CATALOG");
    NSString *path = override && *override ? @(override) :
        !access("cache/shader-preparation/catalog.json", R_OK) ? @"cache/shader-preparation/catalog.json" :
        rt_resource("shader-catalog.json", NULL, resource, sizeof resource) ? @(resource) : @"cache/shader-preparation/catalog.json";
    bool bad = false; NSData *data = recipe_read(path, &bad);
    id c = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![c isKindOfClass:NSDictionary.class] || ![c[@"recipes"] isKindOfClass:NSArray.class]) return;
    for (id row in c[@"recipes"]) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        id record = row;
        if ([c[@"version"] isEqual:@2]) {
            id p = c[@"profiles"];
            if (![p isKindOfClass:NSDictionary.class] || !prep_hash_valid(row[@"vs"]) ||
                ![row[@"fs"] isKindOfClass:NSString.class]) continue;
            NSString *fields[] = {@"vertex_key", @"fragment_key", @"descriptor"};
            NSString *tables[] = {@"vertex_keys", @"fragment_keys", @"descriptors"};
            id values[3]; bool valid = true;
            for (int i = 0; i < 3; i++) {
                uint32_t index; id table = p[tables[i]];
                if (![table isKindOfClass:NSArray.class] || !prep_uint(row[fields[i]], 0xFFFFFF, &index) || index >= [table count]) { valid = false; break; }
                values[i] = table[index];
            }
            if (!valid) continue;
            record = @{@"version": @1, @"program": @{@"vs": row[@"vs"], @"fs": row[@"fs"], @"vkey": values[0], @"fkey": values[1]}, @"pipeline": values[2]};
        } else if (![c[@"version"] isEqual:@1]) continue;
        NSString *line = recipe_line(record);
        if (line) [recipe_known addObject:line];
    }
    if ([c[@"compute"] isKindOfClass:NSArray.class])
        for (id row in c[@"compute"]) { NSString *line = recipe_line(row); if (line) [recipe_known addObject:line]; }
}
static void recipe_save(RecipeJournal *j) {
    if (!j->dirty || j->failed) return;
    NSData *data = [[[j->rows.array componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSString *pattern = [j->path stringByAppendingString:@".tmp.XXXXXX"];
    char *temp = strdup(pattern.fileSystemRepresentation);
    int fd = mkstemp(temp); bool ok = fd >= 0;
    size_t done = 0;
    while (ok && done < data.length) {
        ssize_t n = write(fd, (const char *)data.bytes + done, data.length - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) ok = false; else done += n;
    }
    if (fd >= 0 && close(fd)) ok = false;
    if (ok) ok = rename(temp, j->path.fileSystemRepresentation) == 0;
    if (!ok) { unlink(temp); j->failed = true; LOG("[shader-recipes] couldn't save local recipes\n"); }
    else j->dirty = false;
    free(temp);
}
static RecipeJournal *recipe_file(NSString *path) {
    RecipeJournal *j = recipe_files[path];
    if (j) return j;
    j = [RecipeJournal new]; j->lock_fd = -1; j->path = path; j->rows = [NSMutableOrderedSet new]; recipe_files[path] = j;
    if ([path isEqual:recipe_default_path]) { mkdir("cache", 0755); mkdir("cache/shader-recipes", 0700); }
    NSString *lock = [path stringByAppendingString:@".lock"];
    j->lock_fd = open(lock.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
    struct stat st;
    if (j->lock_fd < 0 || fstat(j->lock_fd, &st) || !S_ISREG(st.st_mode) || flock(j->lock_fd, LOCK_EX | LOCK_NB)) j->failed = true;
    bool bad = false; NSData *data = j->failed ? nil : recipe_read(path, &bad);
    NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
    if (!text || bad) j->failed = true;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        id record = line.length <= (64u << 10) ? [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        NSString *canonical = [record isKindOfClass:NSDictionary.class] ? recipe_line(record) : nil;
        if (!canonical) { j->failed = true; break; }
        if (![path isEqual:recipe_default_path] || ![recipe_known containsObject:canonical]) [j->rows addObject:canonical];
    }
    j->bytes = [[j->rows.array componentsJoinedByString:@"\n"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + j->rows.count;
    if ([path isEqual:recipe_default_path]) __atomic_store_n(&recipe_count, (unsigned)j->rows.count, __ATOMIC_RELAXED);
    if (j->failed) LOG("[shader-recipes] local file unavailable, invalid, or in use by another instance\n");
    return j;
}
static void recipe_shutdown(void) {
    pthread_mutex_lock(&recipe_export_lock); recipe_stopping = true;
    if (recipe_export_child) { plat_proc_kill(recipe_export_child); recipe_export_child = 0; }
    pthread_mutex_unlock(&recipe_export_lock);
    renderer_recipe_flush();
}
static void recipe_queue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        recipe_q = dispatch_queue_create("monzamac.shader-recipes", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        recipe_files = [NSMutableDictionary new];
        dispatch_async(recipe_q, ^{ @autoreleasepool { recipe_load_known(); (void)recipe_file(recipe_default_path); } });
        atexit(recipe_shutdown);
    });
}
unsigned renderer_recipe_count(void) { recipe_queue(); return __atomic_load_n(&recipe_count, __ATOMIC_RELAXED); }
void renderer_recipe_flush(void) {
    if (!recipe_q) return;
    dispatch_sync(recipe_q, ^{ for (RecipeJournal *j in recipe_files.allValues) recipe_save(j); });
    unsigned dropped = __atomic_exchange_n(&recipe_dropped, 0, __ATOMIC_RELAXED);
    if (dropped) LOG("[shader-recipes] %u records skipped (queue/file limit or write error)\n", dropped);
}
static void recipe_refresh_known(void) {
    recipe_queue();
    dispatch_sync(recipe_q, ^{
        recipe_load_known();
        RecipeJournal *j = recipe_file(recipe_default_path);
        if (j->failed) return;
        for (NSString *row in j->rows.array) if ([recipe_known containsObject:row]) {
            [j->rows removeObject:row]; j->dirty = true;
        }
        j->bytes = [[j->rows.array componentsJoinedByString:@"\n"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + j->rows.count;
        __atomic_store_n(&recipe_count, (unsigned)j->rows.count, __ATOMIC_RELAXED);
        recipe_save(j);
    });
}

static void recipe_enqueue(NSDictionary *record, NSString *path) {
    recipe_queue();
    if (__atomic_fetch_add(&recipe_pending, 1, __ATOMIC_RELAXED) >= 128) {
        __atomic_fetch_sub(&recipe_pending, 1, __ATOMIC_RELAXED); __atomic_fetch_add(&recipe_dropped, 1, __ATOMIC_RELAXED); return;
    }
    dispatch_async(recipe_q, ^{ @autoreleasepool {
        RecipeJournal *j = recipe_file(path); NSString *line = recipe_line(record);
        if (!line || j->failed) __atomic_fetch_add(&recipe_dropped, 1, __ATOMIC_RELAXED);
        if (line && !j->failed && ![j->rows containsObject:line] &&
            (![path isEqual:recipe_default_path] || ![recipe_known containsObject:line])) {
            NSUInteger size = [line lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;
            if (j->bytes + size <= (100u << 20)) {
                [j->rows addObject:line]; j->bytes += size; j->dirty = true;
                if ([path isEqual:recipe_default_path]) __atomic_store_n(&recipe_count, (unsigned)j->rows.count, __ATOMIC_RELAXED);
                if (!j->scheduled) {
                    j->scheduled = true;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), recipe_q, ^{ j->scheduled = false; recipe_save(j); });
                }
            } else __atomic_fetch_add(&recipe_dropped, 1, __ATOMIC_RELAXED);
        }
        __atomic_fetch_sub(&recipe_pending, 1, __ATOMIC_RELAXED);
    }});
}
static void prep_record_pipeline(Prog *pr, MTLRenderPipelineDescriptor *pd, bool prepared) {
    const char *override = getenv("LARECOMP_SHADER_RECORD");
    if (!pr->prep_record || pr->ov_active || g_prep_active || !prep_enabled() ||
        (!(override && *override) && (!g_settings.collect_shader_recipes || prepared))) return;
    NSString *path = override && *override ? @(override) : recipe_default_path;
    NSString *key = [NSString stringWithFormat:@"%@/%@", path, prep_pipeline_id(pr, prep_descriptor_dict(pd))];
    if (!g_prep_recorded) g_prep_recorded = [NSMutableSet new];
    if ([g_prep_recorded containsObject:key]) return;
    [g_prep_recorded addObject:key];
    recipe_enqueue(@{@"version": @1, @"program": pr->prep_record, @"pipeline": prep_descriptor_dict(pd)}, path);
}

static void prep_record_compute(NSString *hash, const ShaderKey *k, const uint32_t local[3]) {
    const char *override = getenv("LARECOMP_SHADER_RECORD");
    if (g_prep_active || (!(override && *override) && !g_settings.collect_shader_recipes)) return;
    NSString *path = override && *override ? @(override) : recipe_default_path;
    NSDictionary *record = prep_compute_record(hash, k, local);
    NSString *key = [NSString stringWithFormat:@"%@/cs/%@", path, prep_compute_id(record)];
    if (!g_prep_recorded) g_prep_recorded = [NSMutableSet new];
    if ([g_prep_recorded containsObject:key]) return;
    [g_prep_recorded addObject:key];
    recipe_enqueue(@{@"version": @1, @"compute": record}, path);
}

static int recipe_helper_run(const char **args, NSString *log, double timeout_ms) {
    pthread_mutex_lock(&recipe_export_lock);
    if (!recipe_stopping && !recipe_export_child) recipe_export_child = plat_spawn(args, log.fileSystemRepresentation, false);
    else { pthread_mutex_unlock(&recipe_export_lock); return 1; }
    bool ok = recipe_export_child != 0;
    pthread_mutex_unlock(&recipe_export_lock);
    double started = now_ms(); int result = -1;
    while (ok && result < 0) {
        pthread_mutex_lock(&recipe_export_lock);
        if (g_rt_unwind || now_ms() - started > timeout_ms) {
            if (recipe_export_child) plat_proc_kill(recipe_export_child);
            recipe_export_child = 0; result = 1;
        } else if (recipe_export_child) {
            result = plat_proc_wait(recipe_export_child, false);
            if (result >= 0) recipe_export_child = 0;
        } else result = 1;
        pthread_mutex_unlock(&recipe_export_lock);
        if (result < 0) usleep(10000);
    }
    return ok ? result : 1;
}

bool renderer_export_recipes(const char *destination, char *error, size_t cap) {  // background caller only
    recipe_refresh_known();
    __block NSData *snapshot = nil;
    dispatch_sync(recipe_q, ^{
        RecipeJournal *j = recipe_file(recipe_default_path); recipe_save(j);
        if (!j->failed && j->rows.count) snapshot = [[[j->rows.array componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    });
    if (!snapshot) { snprintf(error, cap, "No readable new recipes to export. See the runtime log."); return false; }
    char helper[1100], script[1100] = {0};
    if (!prep_find_helper(helper, script)) { snprintf(error, cap, "Recipe export helper is missing."); return false; }
    char temp[] = "cache/shader-recipes/export-XXXXXX";
    if (!mkdtemp(temp)) { snprintf(error, cap, "Couldn't create the private export snapshot."); return false; }
    NSString *source = [@(temp) stringByAppendingPathComponent:@"recipes.jsonl"];
    bool ok = [snapshot writeToFile:source options:0 error:nil];
    const char *args[9]; int n = 0;
    args[n++] = helper; if (*script) args[n++] = script;
    args[n++] = "shader-catalog"; args[n++] = "contribute"; args[n++] = source.fileSystemRepresentation; args[n++] = destination; args[n] = NULL;
    NSString *log = [@(temp) stringByAppendingPathComponent:@"helper.log"];
    int result = ok ? recipe_helper_run(args, log, 30000) : 1;
    ok = ok && result == 0;
    if (ok) { unlink(source.fileSystemRepresentation); unlink(log.fileSystemRepresentation); rmdir(temp); }
    else snprintf(error, cap, "Export failed or was cancelled. Details: %s/helper.log", temp);
    return ok;
}

// Explicit user action; the helper downloads metadata only from official releases.
bool renderer_update_catalog(char *error, size_t cap) {
    recipe_queue();
    char helper[1100], script[1100] = {0}, decoder[1100] = {0};
    if (!prep_find_helper(helper, script)) { snprintf(error, cap, "Catalog helper is missing."); return false; }
    mkdir("cache/shader-preparation", 0755);
    char temp[] = "cache/shader-preparation/update-XXXXXX";
    if (!mkdtemp(temp)) { snprintf(error, cap, "Couldn't create catalog update storage."); return false; }
    extern const char *g_romfs_dir;
    NSString *game = g_romfs_dir ? [@(g_romfs_dir) stringByDeletingLastPathComponent] : [@(rt_data_root()) stringByAppendingPathComponent:@"extracted"];
    renderer_recipe_flush();
    const char *args[12]; int n = 0;
    args[n++] = helper; if (*script) args[n++] = script;
    args[n++] = "shader-catalog"; args[n++] = "update"; args[n++] = game.fileSystemRepresentation;
    args[n++] = "cache/shader-preparation/catalog.json";
    if (rt_resource("lasgen/monzamac-shader-decode", "build/shader-decode/release/monzamac-shader-decode", decoder, sizeof decoder)) {
        args[n++] = "--decoder"; args[n++] = decoder;
    }
    if (!access(recipe_default_path.fileSystemRepresentation, R_OK)) {
        args[n++] = "--recipes"; args[n++] = recipe_default_path.fileSystemRepresentation;
    }
    args[n] = NULL;
    NSString *log = [@(temp) stringByAppendingPathComponent:@"helper.log"];
    int result = recipe_helper_run(args, log, 120000);
    if (!result) { recipe_refresh_known(); unlink(log.fileSystemRepresentation); rmdir(temp); return true; }
    if (result == 2) snprintf(error, cap, "No published shader catalog is available yet.");
    else snprintf(error, cap, "Catalog update failed or was cancelled; previous catalog kept. Details: %s/helper.log", temp);
    return false;
}

// Metadata-only release lookup; no assets, game inputs or native shaders are downloaded.
int renderer_check_catalog(void) {
    recipe_queue();
    char helper[1100], script[1100] = {0}, catalog[1100] = "cache/shader-preparation/catalog.json", bundled[1100];
    if (!prep_find_helper(helper, script)) return -1;
    const char *override = getenv("LARECOMP_SHADER_CATALOG");
    if (override && *override) snprintf(catalog, sizeof catalog, "%s", override);
    else if (access(catalog, R_OK) && rt_resource("shader-catalog.json", NULL, bundled, sizeof bundled)) snprintf(catalog, sizeof catalog, "%s", bundled);
    mkdir("cache/shader-preparation", 0755);
    char temp[] = "cache/shader-preparation/check-XXXXXX";
    if (!mkdtemp(temp)) return -1;
    NSString *log = [@(temp) stringByAppendingPathComponent:@"helper.log"];
    const char *args[8]; int n = 0;
    args[n++] = helper; if (*script) args[n++] = script;
    args[n++] = "shader-catalog"; args[n++] = "status"; args[n++] = catalog; args[n] = NULL;
    int result = recipe_helper_run(args, log, 35000), state = -1;
    if (result == 2) state = 2;
    else if (!result) {
        bool bad = false; NSData *data = recipe_read(log, &bad);
        id row = data && data.length <= 4096 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([row isKindOfClass:NSDictionary.class]) {
            if ([row[@"state"] isEqual:@"current"]) state = 0;
            else if ([row[@"state"] isEqual:@"available"]) state = 1;
        }
    }
    unlink(log.fileSystemRepresentation); rmdir(temp); return state;
}
