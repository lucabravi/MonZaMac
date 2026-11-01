#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <sys/stat.h>
#include "precompile_stamp.h"

#define STAMP_DIR "cache/shader-precompile"
#define STAMP_FILE STAMP_DIR "/stamp.txt"

// What this machine and these game files are, as "key=value" lines (the shaders count is not part of the comparison).
static NSString *stamp_now(const char *root) {
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSMutableString *s = [NSMutableString stringWithFormat:@"version=%d\nos=%ld.%ld\ngpu=%@\n", SHADER_PRECOMPILE_VERSION,
                          (long)v.majorVersion, (long)v.minorVersion, dev.name ?: @"unknown"];
    const char *files[] = {"exefs/main", "romfs/arc/data.trpfs"};
    for (int i = 0; i < 2; i++) {
        char path[1100]; struct stat st;
        snprintf(path, sizeof path, "%s/%s", root, files[i]);
        if (stat(path, &st) == 0) [s appendFormat:@"file%d=%lld-%ld\n", i, (long long)st.st_size, (long)st.st_mtime];
        else [s appendFormat:@"file%d=missing\n", i];
    }
    return s;
}

static NSString *value_of(const char *text, const char *key) {
    NSString *body = @(text), *prefix = [NSString stringWithFormat:@"%s=", key];
    for (NSString *line in [body componentsSeparatedByString:@"\n"])
        if ([line hasPrefix:prefix]) return [line substringFromIndex:prefix.length];
    return nil;
}

PrecompileState precompile_compare(const char *saved, const char *now, char *reason, unsigned reason_size) {
    NSString *why = nil;
    NSString *sv = value_of(saved, "version"), *nv = value_of(now, "version");
    if (!sv) { if (reason) snprintf(reason, reason_size, "Not done yet."); return PRECOMPILE_NOT_DONE; }
    if (![sv isEqual:nv]) why = @"This version of MonZaMac precompiles more than the last one did.";
    else if (![value_of(saved, "os") isEqual:value_of(now, "os")]) why = @"macOS was updated since the last precompile.";
    else if (![value_of(saved, "gpu") isEqual:value_of(now, "gpu")]) why = @"This Mac's graphics chip is not the one it was done on.";
    else if (![value_of(saved, "file0") isEqual:value_of(now, "file0")] || ![value_of(saved, "file1") isEqual:value_of(now, "file1")])
        why = @"The game files changed.";
    if (why) { if (reason) snprintf(reason, reason_size, "%s", why.UTF8String); return PRECOMPILE_OUTDATED; }
    if (reason) snprintf(reason, reason_size, "Up to date.");
    return PRECOMPILE_CURRENT;
}

PrecompileState precompile_state(const char *root, char *reason, unsigned reason_size) {
    @autoreleasepool {
        NSData *data = [NSData dataWithContentsOfFile:@STAMP_FILE];
        NSString *saved = data.length && data.length < 4096 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (!saved) { if (reason) snprintf(reason, reason_size, "Not done yet."); return PRECOMPILE_NOT_DONE; }
        return precompile_compare(saved.UTF8String, stamp_now(root).UTF8String, reason, reason_size);
    }
}

bool precompile_write_stamp(const char *root, unsigned shaders) {
    @autoreleasepool {
        mkdir("cache", 0755); mkdir(STAMP_DIR, 0755);
        NSString *text = [stamp_now(root) stringByAppendingFormat:@"shaders=%u\n", shaders];
        return [text writeToFile:@STAMP_FILE atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}
