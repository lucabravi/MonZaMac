// Developer log: lines about one subject at a time for settling a doubt while developing, in a file of their own
// (LARECOMP_DEVLOG_FILE, default logs/devlog.txt), never in the normal log. Off unless LARECOMP_DEVLOG names the
// subjects (comma separated, or "all"). Subjects so far: compute (keys of the compute programs the game builds).
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

bool devlog_on(const char *subject);
void devlog(const char *subject, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

#ifdef __cplusplus
}
#endif
