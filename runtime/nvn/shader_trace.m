// Local evidence collection, not a memory-taint engine: address matches are candidates, not proven file origins.
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdatomic.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "nvn.h"
#include "shader_trace.h"

enum { TRACE_READS = 512, TRACE_STAGES = 256, TRACE_EVENTS = 4096, TRACE_STACK = 12 };
static pthread_mutex_t trace_lock = PTHREAD_MUTEX_INITIALIZER;
static NSDictionary *trace_reads[TRACE_READS];
static unsigned trace_read_count, trace_stage_count, trace_event_count, trace_epoch;
static uint64_t trace_seq, trace_first, trace_last = UINT64_MAX;
static size_t trace_written, trace_dumped;
static _Atomic uint64_t trace_current_frame;
static FILE *trace_file;
static NSString *trace_dir;
static NSSet *trace_targets;
static NSMutableSet *trace_seen;
static bool trace_on, trace_dump, trace_timing_only;

static uint64_t trace_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static NSString *trace_hex(uint64_t n) { return [NSString stringWithFormat:@"%016llx", (unsigned long long)n]; }
static NSString *trace_hash(NSData *data) {
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, h);
    char text[65];
    for (int i = 0; i < 32; i++) snprintf(text + 2*i, 3, "%02x", h[i]);
    return @(text);
}
static bool trace_hash_valid(id h) {
    return [h isKindOfClass:NSString.class] && [h length] == 64 &&
        [h rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}

static void trace_emit(NSDictionary *fields) { // trace_lock held
    if (!trace_file || trace_event_count >= (trace_timing_only ? 32768 : TRACE_EVENTS)) return;
    NSMutableDictionary *record = [fields mutableCopy];
    uint64_t thread = 0; pthread_threadid_np(NULL, &thread);
    if (!record[@"ns"]) record[@"ns"] = @(trace_ns());
    if (!record[@"frame"]) record[@"frame"] = @(atomic_load(&trace_current_frame));
    record[@"host_thread"] = trace_hex(thread); record[@"epoch"] = @(trace_epoch);
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    if (!data || data.length + 1 > (16u << 20) - trace_written) return;
    if (fwrite(data.bytes, 1, data.length, trace_file) != data.length || fputc('\n', trace_file) == EOF) {
        fclose(trace_file); trace_file = NULL; return;
    }
    fflush(trace_file);
    trace_written += data.length + 1; trace_event_count++;
}

bool shader_trace_enabled(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *path = getenv("LARECOMP_SHADER_TRACE");
        if (!path || !*path) return;
        trace_dir = [NSString stringWithUTF8String:path];
        if (!trace_dir) return;
        const char *targets = getenv("LARECOMP_SHADER_TRACE_TARGETS");
        if (targets) {
            NSString *p = [NSString stringWithUTF8String:targets];
            NSDictionary *attrs = p ? [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil] : nil;
            NSData *data = attrs && [attrs fileSize] <= (1u << 20) ? [NSData dataWithContentsOfFile:p] : nil;
            id array = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (![array isKindOfClass:NSArray.class] || [array count] > 1024) { LOG("[shader-trace] invalid target list; disabled\n"); return; }
            for (id h in array) if (!trace_hash_valid(h)) { LOG("[shader-trace] invalid target hash; disabled\n"); return; }
            trace_targets = [NSSet setWithArray:array];
        }
        const char *range = getenv("LARECOMP_SHADER_TRACE_FRAMES");
        unsigned long long first, last;
        if (range) {
            char extra;
            if (sscanf(range, "%llu:%llu%c", &first, &last, &extra) != 2 || first >= last) {
                LOG("[shader-trace] invalid frame range; disabled\n"); return;
            }
            trace_first = first; trace_last = last;
        }
        trace_timing_only = getenv("LARECOMP_SHADER_TRACE_TIMING_ONLY") && atoi(getenv("LARECOMP_SHADER_TRACE_TIMING_ONLY")) != 0;
        trace_dump = !trace_timing_only && getenv("LARECOMP_SHADER_TRACE_DUMP") && atoi(getenv("LARECOMP_SHADER_TRACE_DUMP")) != 0;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:trace_dir withIntermediateDirectories:YES
                attributes:@{NSFilePosixPermissions: @0700} error:nil]) return;
        NSString *events = [trace_dir stringByAppendingPathComponent:@"events.jsonl"];
        int fd = open(events.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY, 0600);
        if (fd < 0) { LOG("[shader-trace] use a new output directory (events.jsonl already exists or cannot be created)\n"); return; }
        trace_file = fdopen(fd, "w");
        if (!trace_file) { close(fd); return; }
        trace_seen = [NSMutableSet new]; trace_on = true;
        trace_emit(@{@"kind": @"session", @"version": @1, @"input_dumps": @(trace_dump), @"timing_only": @(trace_timing_only)});
        LOG("[shader-trace] enabled (metadata%s), output %s\n", trace_dump ? " + private input dumps" : " only", path);
        atexit(shader_trace_flush);
    });
    return trace_on;
}

void shader_trace_frame(uint64_t frame) {
    if (shader_trace_enabled()) atomic_store(&trace_current_frame, frame);
}
void shader_trace_read(const char *path, uint64_t offset, uint64_t destination, size_t size) {
    if (!shader_trace_enabled() || trace_timing_only || !size) return;
    @autoreleasepool {
        NSDictionary *r = @{@"path": [NSString stringWithUTF8String:path ?: "?"] ?: @"?", @"offset": @(offset),
                            @"destination": @(destination), @"size": @(size), @"ns": @(trace_ns())};
        pthread_mutex_lock(&trace_lock);
        trace_reads[trace_seq++ % TRACE_READS] = r;
        if (trace_read_count < TRACE_READS) trace_read_count++;
        pthread_mutex_unlock(&trace_lock);
    }
}

static NSArray *trace_stack(Cpu *cpu) {
    NSMutableArray *pcs = [NSMutableArray new];
    uint64_t pc = cpu->x[30], fp = cpu->x[29];
    for (unsigned i = 0; i < TRACE_STACK && pc; i++) {
        uint64_t offset = 0;
        const char *name = loader_symbol_at(pc, &offset);
        [pcs addObject:@{@"pc": trace_hex(pc), @"symbol": name ? @(name) : @"?", @"symbol_offset": @(offset)}];
        if (fp < GUEST_LO || fp > GUEST_HI - 16 || (fp & 15)) break;
        uint64_t pair[2]; mach_vm_size_t got = 0;
        if (mach_vm_read_overwrite(mach_task_self(), fp, sizeof pair, (mach_vm_address_t)pair, &got) != KERN_SUCCESS || got != sizeof pair) break;
        if (pair[0] <= fp || pair[0] - fp > (16u << 20)) break;
        fp = pair[0]; pc = pair[1];
    }
    return pcs;
}

void shader_trace_stage(Cpu *cpu, const NvnShaderStage *s, uint64_t program) {
    if (!shader_trace_enabled() || !cpu || !s) return;
    uint64_t size = (uint64_t)s->const_offset + s->const_size, observed = trace_ns();
    uint64_t frame = atomic_load(&trace_current_frame);
    if (size < 16 || size > (16u << 20) || s->code_addr < GUEST_LO ||
        s->code_addr >= GUEST_HI || size > GUEST_HI - s->code_addr) return;
    @autoreleasepool {
        NSMutableData *bytes = [NSMutableData dataWithLength:(NSUInteger)size]; mach_vm_size_t got = 0;
        if (mach_vm_read_overwrite(mach_task_self(), s->code_addr, size, (mach_vm_address_t)bytes.mutableBytes, &got) != KERN_SUCCESS || got != size) return;
        NSString *hash = trace_hash(bytes);
        if (trace_targets && ![trace_targets containsObject:hash]) return;
        NSString *seen_key = trace_timing_only ? [hash stringByAppendingString:trace_hex(s->code_addr)] : hash;
        NSArray *stack = trace_timing_only ? @[] : trace_stack(cpu);
        pthread_mutex_lock(&trace_lock);
        if ([trace_seen containsObject:seen_key] || trace_stage_count >= (trace_timing_only ? 16384 : TRACE_STAGES)) { pthread_mutex_unlock(&trace_lock); return; }
        [trace_seen addObject:seen_key]; trace_stage_count++;
        NSMutableArray *candidates = [NSMutableArray new], *recent = [NSMutableArray new];
        for (unsigned i = 0; i < trace_read_count; i++) {
            NSDictionary *r = trace_reads[(trace_seq - 1 - i) % TRACE_READS];
            if ([r[@"ns"] unsignedLongLongValue] > observed) continue;
            if (recent.count < 32) [recent addObject:r];
            uint64_t at = [r[@"destination"] unsignedLongLongValue], n = [r[@"size"] unsignedLongLongValue];
            if (s->code_addr >= at && size <= n && s->code_addr - at <= n - size) [candidates addObject:r];
        }
        NSMutableDictionary *record = [@{@"kind": @"shader", @"hash": hash, @"stage": @(s->stage), @"ns": @(observed), @"frame": @(frame),
            @"program": trace_hex(program), @"code_address": trace_hex(s->code_addr),
            @"control_address": trace_hex((uint64_t)(uintptr_t)s->control), @"size": @(size),
            @"const_offset": @(s->const_offset), @"const_size": @(s->const_size), @"callers": stack,
            @"read_sequence": @(trace_seq), @"read_candidates": candidates, @"recent_reads": recent} mutableCopy];
        if (trace_dump && size <= (32u << 20) - trace_dumped) {
            NSString *name = [hash stringByAppendingString:@".bin"];
            int fd = open([trace_dir stringByAppendingPathComponent:name].fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY, 0600);
            if (fd >= 0) {
                const uint8_t *p = bytes.bytes; size_t written = 0;
                while (written < size) { ssize_t n = write(fd, p + written, (size_t)size - written); if (n <= 0) break; written += (size_t)n; }
                close(fd); trace_dumped += written;
                if (written == size) record[@"input_dump"] = name;
                else unlink([trace_dir stringByAppendingPathComponent:name].fileSystemRepresentation);
            }
        }
        trace_emit(record);
        pthread_mutex_unlock(&trace_lock);
    }
}

void shader_trace_compile(const char *kind, double ms, uint64_t vs, uint64_t fs, uint64_t vh, uint64_t fh, int archivable) {
    if (!shader_trace_enabled()) return;
    uint64_t frame = atomic_load(&trace_current_frame);
    if (frame < trace_first || frame >= trace_last) return;
    pthread_mutex_lock(&trace_lock);
    char vp[96], fp[96];
    snprintf(vp, sizeof vp, "cache/shaders/v_%016llx.metal", (unsigned long long)vh);
    snprintf(fp, sizeof fp, "cache/shaders/f_%016llx.metal", (unsigned long long)fh);
    trace_emit(@{@"kind": @"compile", @"frame": @(frame), @"operation": @(kind), @"ms": @(ms), @"vs": trace_hex(vs), @"fs": trace_hex(fs),
        @"vertex_msl_hash": trace_hex(vh), @"fragment_msl_hash": trace_hex(fh), @"archivable": @(archivable),
        @"vertex_source_saved": vh ? @(access(vp, R_OK) == 0) : (id)[NSNull null],
        @"fragment_source_saved": fh ? @(access(fp, R_OK) == 0) : (id)[NSNull null]});
    pthread_mutex_unlock(&trace_lock);
}
void shader_trace_flush(void) {
    pthread_mutex_lock(&trace_lock);
    if (trace_file) fflush(trace_file);
    pthread_mutex_unlock(&trace_lock);
}
void shader_trace_reset(void) {
    if (!shader_trace_enabled()) return;
    pthread_mutex_lock(&trace_lock);
    for (unsigned i = 0; i < TRACE_READS; i++) trace_reads[i] = nil;
    trace_read_count = 0; trace_seq = 0; trace_epoch++;
    [trace_seen removeAllObjects]; trace_emit(@{@"kind": @"reset"});
    pthread_mutex_unlock(&trace_lock);
}
