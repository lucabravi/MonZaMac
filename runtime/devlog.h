// Developer log: a file of warnings for the developers (LARECOMP_DEVLOG_FILE, default logs/devlog.txt), apart from the
// normal log, every line with its date and time. A line says that something is not as expected, so the file stays empty
// while all is well. Off unless the Developer tab's "Developer log" is on or LARECOMP_DEVLOG names the subjects (comma
// separated, or "all"). Subjects so far: compute (a compute program the precompilation does not cover).
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
