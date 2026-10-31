// A fatal error, explained to the player: the crash alert (plat_fatal_notice) says what went wrong in plain words and
// what to do about it; the technical lines (FATAL / signal, backtrace, registers) stay in the log for bug reports.
// Known causes are recognised from what the runtime knows when it stops: the fatal line, and where the crash was
// (the game code, MonZaMac itself, Apple's graphics driver).
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "platform.h"
#include "rt.h"

static char g_line[512];  // the first fatal line (FATAL message / "signal 11 accessing 0x10")
static uint64_t g_pc;     // a crash's host pc (0: a FATAL)

void rt_fatal_msg(const char *fmt, ...) {
    char b[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(b, sizeof b, fmt, ap);
    va_end(ap);
    fprintf(stderr, "FATAL: %s", b);
    if (!g_line[0]) snprintf(g_line, sizeof g_line, "%s", b);
}

void rt_crash_fault(const char *what, uint64_t fa, uint64_t pc) {
    if (!g_line[0]) snprintf(g_line, sizeof g_line, "%s accessing %#llx", what, (unsigned long long)fa);
    if (!g_pc) g_pc = pc;
}

static bool has(const char *s) { return strstr(g_line, s) != NULL; }

const char *rt_host_fn_name(uint64_t pc, uint64_t *offset);  // runtime/dispatch.c: inside the game code?

static bool contains_nocase(const char *hay, const char *needle) {
    for (; *hay; hay++) {
        size_t i = 0;
        while (needle[i] && tolower((unsigned char)hay[i]) == tolower((unsigned char)needle[i])) i++;
        if (!needle[i]) return true;
    }
    return false;
}

// The crash was inside Apple's graphics driver or shader compiler, not in MonZaMac
static bool in_gpu_driver(uint64_t pc) {
    char m[512];
    if (!pc || !plat_module_name(pc, m, sizeof m)) return false;
    static const char *const drivers[] = {"AGXMetal", "AGXCompiler", "MTLCompiler", "AppleParavirtGPU", "libLLVM",
                                          "GPUCompiler", "IOGPU"};
    for (size_t i = 0; i < sizeof drivers / sizeof *drivers; i++)
        if (contains_nocase(m, drivers[i])) return true;
    return false;
}

void rt_crash_explain(char *out, size_t n, const char *log_path) {
    static const char *const report = "Please report it as a GitHub issue and attach the log file below. "
                                      "Your progress up to your last save or autosave is safe.";
    char head[160], what[400];
    if (has("get_terminate") || has("uncaught C++ exception")) {  // (the game threw: recompiled code can't unwind)
        snprintf(head, sizeof head, "The game ran into an error it couldn't recover from");
        snprintf(what, sizeof what, "This is a bug in MonZaMac, not a problem with your game files or Mac. %s", report);
    } else if (has("svcBreak")) {  // (the game's own check failed: Pokémon Z-A, rarely, while it starts - a timing race)
        snprintf(head, sizeof head, "The game stopped at one of its own checks");
        snprintf(what, sizeof what, "Start it again: this happens now and then while the game starts, and the next "
                 "start is normally fine. If it keeps happening at the same place, it's a bug in MonZaMac. %s", report);
    } else if (has("no usable system font")) {
        snprintf(head, sizeof head, "No font for the game's text");
        snprintf(what, sizeof what, "MonZaMac couldn't find a font on this Mac for the game's text. Reinstall "
                 "MonZaMac, or update macOS, and try again.");
    } else if (in_gpu_driver(g_pc)) {
        snprintf(head, sizeof head, "The graphics driver crashed");
        snprintf(what, sizeof what, "Update macOS and try again. If it keeps happening, lower the graphics "
                 "settings (resolution, shadows) and please report it with the log file below.");
    } else if (has("out of memory") || has("cannot allocate") || has("alloc failed")) {
        snprintf(head, sizeof head, "Out of memory");
        snprintf(what, sizeof what, "Close other apps and try again.");
    } else if (g_pc && rt_host_fn_name(g_pc, NULL)) {
        snprintf(head, sizeof head, "The game crashed");
        snprintf(what, sizeof what, "This is a bug in MonZaMac, not a problem with your game files or Mac. %s", report);
    } else {
        snprintf(head, sizeof head, "MonZaMac stopped because of an error");
        snprintf(what, sizeof what, "%s", report);
    }
    fprintf(stderr, "[crash] %s\n", head);
    if (log_path && *log_path) snprintf(out, n, "%s\n\n%s\n\nLog file:\n%s", head, what, log_path);
    else snprintf(out, n, "%s\n\n%s", head, what);
}
