// Runs a Lumiose helper script (tools/lumiose/prepare.py, activate.py) in the background and follows what it reports, for
// the start screen: `PROGRESS {json}` and `STATUS {json}` lines on its output (state, fraction 0..1, step, message, dir,
// version). Nothing else on the output matters. One job at a time; the screen polls online_prep_get() from its own thread.
#pragma once
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char state[16];       // "" (nothing yet), running, ready, error, none, invalid; "error" also when the job fails
    float fraction;       // 0..1
    char step[160];       // what it is doing
    char message[256];    // why it failed
    char dir[1024];       // where the result is (ready)
    char version[48];     // the module version (STATUS)
    char endpoint[64];    // the server set for it, "" if none (STATUS)
    bool running;         // the job is still alive
} OnlinePrepStatus;

// Starts argv (argv[0] is run through the PATH; NULL-terminated) as the job. false: one is already running, or it could
// not be started (the status then says why).
bool online_prep_start(const char *const *argv);
void online_prep_get(OnlinePrepStatus *out);
// Stops the job (SIGTERM, then SIGKILL) and waits for it. A job that did not report ready or error ends as an error.
void online_prep_cancel(void);
// One output line into a status (exposed for tests): true if it was a PROGRESS or STATUS line.
bool online_prep_parse_line(const char *line, OnlinePrepStatus *st);

#ifdef __cplusplus
}
#endif
