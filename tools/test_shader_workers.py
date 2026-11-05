#!/usr/bin/env python3
"""Exercise the production preparation worker policy without compiling shaders."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "runtime/nvn/shader_prepare.inc").read_text()
policy = source[source.index("static unsigned prep_worker_count("):source.index("// Translation and address-keyed")]
assert "prep_compilation_workers(" in policy, "dedicated preparation does not query Metal's compilation capacity"
HARNESS = r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <errno.h>
static id<MTLDevice> dev;
@interface CompilerCapacity : NSObject
@property NSUInteger maximumConcurrentCompilationTaskCount;
@end
@implementation CompilerCapacity
@end
'''
CHECKS = r'''
int main(void) { @autoreleasepool {
    NSUInteger cpus = NSProcessInfo.processInfo.activeProcessorCount;
    CompilerCapacity *device = [CompilerCapacity new];
    dev = (id<MTLDevice>)device;
    device.maximumConcurrentCompilationTaskCount = 1;
    assert(prep_compilation_workers(100, NULL) == 1);
    device.maximumConcurrentCompilationTaskCount = 4;
    assert(prep_compilation_workers(100, NULL) == MIN(cpus, 4));
    assert(prep_compilation_workers(2, NULL) == MIN(cpus, 2));
    assert(prep_compilation_workers(100, "1") == 1);
    assert(prep_compilation_workers(100, "999") == MIN(cpus, 4));
    assert(prep_compilation_workers(100, "garbage") == MIN(cpus, 4));
    assert(prep_compilation_workers(0, NULL) == 1);
    device.maximumConcurrentCompilationTaskCount = 0;
    assert(prep_compilation_workers(100, NULL) == MIN(cpus, 100));
    dev = (id<MTLDevice>)[NSObject new];
    assert(prep_compilation_workers(100, NULL) == MIN(cpus, 100));
    assert(prep_worker_count(12, 100, NULL) == 12); // gameplay background policy stays CPU based
    assert(prep_worker_count(12, 100, "3") == 3);
    dev = MTLCreateSystemDefaultDevice();
    if (dev) {
        NSUInteger capacity = dev.maximumConcurrentCompilationTaskCount;
        assert(prep_compilation_workers(1000, NULL) == MIN(MIN(cpus, capacity ?: cpus), 1000));
        printf("Metal capacity %lu, active CPUs %lu, preparation workers %u\n", capacity, cpus, prep_compilation_workers(1000, NULL));
    }
    puts("PASS: Metal capacity, fallback, job/override bounds and unchanged background policy");
} }
'''
with tempfile.TemporaryDirectory(prefix="shader-workers-") as tmp:
    tmp = Path(tmp)
    (tmp / "workers.m").write_text(HARNESS + policy + CHECKS)
    subprocess.run(["clang", "-fobjc-arc", "-Wall", "-Werror", "-framework", "Foundation", "-framework", "Metal",
                    str(tmp / "workers.m"), "-o", str(tmp / "workers")], check=True)
    subprocess.run([str(tmp / "workers")], check=True)
