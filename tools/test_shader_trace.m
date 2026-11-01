// All shader bytes here are synthetic; no game files or GPU are needed.
#include "../runtime/nvn/shader_trace.m"
#include <assert.h>

uint32_t kernel_current_thread_handle(void) { return 7; }
const char *loader_symbol_at(uint64_t a, uint64_t *off) { (void)a; *off = 0; return NULL; }

int main(int argc, char **argv) { @autoreleasepool {
    assert(argc == 3);
    NSString *dir = @(argv[1]);
    if (!strcmp(argv[2], "disabled")) {
        unsetenv("LARECOMP_SHADER_TRACE");
        assert(!shader_trace_enabled());
        shader_trace_read("synthetic", 0, 1, 1);
        assert(![[NSFileManager defaultManager] fileExistsAtPath:dir]);
        return 0;
    }
    bool timing = !strcmp(argv[2], "timing");
    if (timing) setenv("LARECOMP_SHADER_TRACE_TIMING_ONLY", "1", 1);
    setenv("LARECOMP_SHADER_TRACE", argv[1], 1);
    setenv("LARECOMP_SHADER_TRACE_FRAMES", "750:1110", 1);
    if (!strcmp(argv[2], "dump")) setenv("LARECOMP_SHADER_TRACE_DUMP", "1", 1);
    mach_vm_address_t address = GUEST_LO + 0x100000;
    assert(mach_vm_allocate(mach_task_self(), &address, 16384, VM_FLAGS_FIXED) == KERN_SUCCESS);
    unsigned char *bytes = (void *)(uintptr_t)address;
    for (int i = 0; i < 128; i++) bytes[i] = i;
    if (!strcmp(argv[2], "invalid-target")) {
        setenv("LARECOMP_SHADER_TRACE_TARGETS", dir.stringByDeletingLastPathComponent.fileSystemRepresentation, 1);
        assert(!shader_trace_enabled());
        assert(![[NSFileManager defaultManager] fileExistsAtPath:dir]);
        mach_vm_deallocate(mach_task_self(), address, 16384);
        return 0;
    }
    if (!strcmp(argv[2], "filtered")) {
        NSString *target = [dir.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"targets.json"];
        NSData *json = [NSJSONSerialization dataWithJSONObject:@[trace_hash([NSData dataWithBytes:bytes length:128])]
                                                     options:0 error:nil];
        assert([json writeToFile:target atomically:YES]);
        setenv("LARECOMP_SHADER_TRACE_TARGETS", target.fileSystemRepresentation, 1);
    }
    assert(shader_trace_enabled());
    shader_trace_frame(700);
    shader_trace_read("arc/synthetic.bin", 17, (uint64_t)bytes, 128);
    NvnShaderStage stage = {.stage = 0, .code_addr = (uint64_t)bytes, .const_offset = 128};
    Cpu c = {.sp = 0}; c.x[29] = 1; c.x[30] = MAIN_BASE + 0x100;
    shader_trace_stage(&c, &stage, 123);
    shader_trace_stage(&c, &stage, 123);
    memset(bytes + 256, 99, 128);
    NvnShaderStage other = stage; other.code_addr = address + 256;
    if (!strcmp(argv[2], "filtered")) shader_trace_stage(&c, &other, 999);
    unsigned char host_memory[128] = {99};
    NvnShaderStage outside = stage; outside.code_addr = (uint64_t)host_memory;
    shader_trace_stage(&c, &outside, 999); // must never capture unrelated host memory
    shader_trace_compile("program", 1.0, 123, 0, 1, 0, -1); // outside frame filter
    shader_trace_frame(800);
    shader_trace_compile("pipeline", 2.0, 123, 0, 1, 0, 1);
    shader_trace_frame(900);
    pthread_mutex_lock(&trace_lock);
    trace_emit(@{@"kind": @"stamp", @"frame": @800}); // presenter advanced after operation was stamped
    pthread_mutex_unlock(&trace_lock);
    for (int i = 0; i < 600; i++) shader_trace_read("other", i, 1000+i, 1);
    assert(trace_read_count == (timing ? 0 : TRACE_READS));
    shader_trace_flush();
    NSString *text = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"events.jsonl"] encoding:NSUTF8StringEncoding error:nil];
    unsigned stages = 0, compiles = 0;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        id row = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        assert(row);
        if ([row[@"kind"] isEqual:@"shader"]) {
            stages++;
            assert([row[@"read_candidates"] count] == (timing ? 0 : 1));
            assert([row[@"recent_reads"] count] == (timing ? 0 : 1));
            if (timing) assert([row[@"callers"] count] == 0);
        }
        if ([row[@"kind"] isEqual:@"stamp"]) assert([row[@"frame"] unsignedLongLongValue] == 800);
        if ([row[@"kind"] isEqual:@"compile"]) { compiles++; assert([row[@"frame"] unsignedLongLongValue] == 800); }
    }
    assert(stages == 1 && compiles == 1);
    NSUInteger dumps = 0;
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]) dumps += [name hasSuffix:@".bin"];
    assert(dumps == (!strcmp(argv[2], "dump") ? 1 : 0));
    if (timing) {
        memcpy(bytes + 512, bytes, 128);
        NvnShaderStage alias = stage; alias.code_addr = address + 512;
        shader_trace_stage(&c, &alias, 456);
        assert(trace_stage_count == 2); // same content at a new upload address
        // Bulk registration must pass the normal origin-investigation budget.
        for (uint32_t i = 0; i < 300; i++) {
            memcpy(bytes, &i, sizeof i);
            shader_trace_stage(&c, &stage, 123);
        }
        assert(trace_stage_count == 302);
        assert(trace_read_count == 0 && trace_dumped == 0);
    }
    shader_trace_reset(); assert(trace_read_count == 0);
    mach_vm_deallocate(mach_task_self(), address, 16384);
    return 0;
}}
