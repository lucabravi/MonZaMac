// Developer log (devlog.h).
#include "devlog.h"
#include "settings.h"
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>

static const char *subjects() {
    static const char *s;
    static int read;
    if (!read) { read = 1; s = getenv("LARECOMP_DEVLOG"); if (s && !*s) s = NULL; }
    return s;
}

bool devlog_on(const char *subject) {
    if (g_settings.dev_log) return true;  // (the Developer tab: every subject)
    const char *s = subjects();
    if (!s) return false;
    if (!strcmp(s, "all")) return true;
    size_t n = strlen(subject);
    for (const char *p = s; *p;) {
        const char *e = strchr(p, ',');
        size_t len = e ? (size_t)(e - p) : strlen(p);
        if (len == n && !strncmp(p, subject, n)) return true;
        if (!e) break;
        p = e + 1;
    }
    return false;
}

void devlog(const char *subject, const char *fmt, ...) {
    if (!devlog_on(subject)) return;
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static FILE *f;
    pthread_mutex_lock(&lock);
    if (!f) {
        const char *path = getenv("LARECOMP_DEVLOG_FILE");
        if (!path || !*path) { mkdir("logs", 0755); path = "logs/devlog.txt"; }
        f = fopen(path, "a");
    }
    if (f) {
        struct timeval tv;
        struct tm tm;
        gettimeofday(&tv, NULL);
        localtime_r(&tv.tv_sec, &tm);
        fprintf(f, "%04d-%02d-%02d %02d:%02d:%02d.%03d [%s] ", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min,
                tm.tm_sec, (int)(tv.tv_usec / 1000), subject);
        va_list ap;
        va_start(ap, fmt);
        vfprintf(f, fmt, ap);
        va_end(ap);
        fputc('\n', f);
        fflush(f);
    }
    pthread_mutex_unlock(&lock);
}
