// The job runner of the start screen's online entry (runtime/online_prep.c), with /bin/sh as the "script".
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "../runtime/online_prep.h"

static void wait_done(OnlinePrepStatus *st) {
    for (int i = 0; i < 200; i++) {  // up to 10 s
        online_prep_get(st);
        if (!st->running) return;
        usleep(50000);
    }
    assert(!"the job did not end");
}

static void job(const char *script, OnlinePrepStatus *st) {
    const char *argv[] = {"/bin/sh", "-c", script, NULL};
    assert(online_prep_start(argv));
    wait_done(st);
}

int main(void) {
    OnlinePrepStatus st;
    memset(&st, 0, sizeof st);
    assert(!online_prep_parse_line("Preparing module bootstrap...", &st));
    assert(!online_prep_parse_line("PROGRESSX {}", &st));
    assert(online_prep_parse_line("PROGRESS {\"state\": \"running\", \"fraction\": 0.4231, \"step\": \"Compiled 3 of 61 \\\"files\\\" \\u00e8\\u20ac\"}", &st));
    assert(!strcmp(st.state, "running") && st.fraction > 0.42f && st.fraction < 0.43f);
    assert(!strcmp(st.step, "Compiled 3 of 61 \"files\" \xc3\xa8\xe2\x82\xac"));
    assert(online_prep_parse_line("PROGRESS {\"fraction\": 7}", &st) && st.fraction == 1.0f);
    assert(online_prep_parse_line("STATUS {\"state\": \"ready\", \"active\": \"x\", \"version\": \"1.4.3-build2\", \"server\": false}", &st));
    assert(!strcmp(st.state, "ready") && !strcmp(st.version, "1.4.3-build2"));
    assert(online_prep_parse_line("STATUS {\"state\": \"ready\", \"endpoint\": \"203.0.113.5:27777\"}", &st));
    assert(!strcmp(st.endpoint, "203.0.113.5:27777"));
    assert(online_prep_parse_line("PROGRESS {\"step\": \"unterminated", &st));  // (a cut line changes nothing it cannot read)

    // a job that reports progress and ends ready
    job("echo noise; echo 'PROGRESS {\"state\": \"running\", \"fraction\": 0.5, \"step\": \"half\"}'; "
        "echo 'PROGRESS {\"state\": \"ready\", \"fraction\": 1.0, \"step\": \"Prepared\", \"dir\": \"/tmp/x y\"}'", &st);
    assert(!strcmp(st.state, "ready") && st.fraction == 1.0f && !strcmp(st.dir, "/tmp/x y"));

    // it reports an error itself
    job("echo 'PROGRESS {\"state\": \"error\", \"message\": \"no module\"}'; exit 1", &st);
    assert(!strcmp(st.state, "error") && !strcmp(st.message, "no module"));

    // it ends without a word, or is killed by itself: an error with a reason
    job("exit 0", &st);
    assert(!strcmp(st.state, "error") && st.message[0]);
    job("kill -9 $$", &st);
    assert(!strcmp(st.state, "error") && strstr(st.message, "stopped"));

    // not startable
    const char *missing[] = {"/nonexistent/prepare", NULL};
    assert(!online_prep_start(missing));
    online_prep_get(&st);
    assert(!strcmp(st.state, "error") && strstr(st.message, "Could not start"));

    // one at a time, and a cancel reaches the whole group promptly
    const char *slow[] = {"/bin/sh", "-c", "echo 'PROGRESS {\"state\": \"running\", \"fraction\": 0.1, \"step\": \"x\"}'; sleep 30 & wait", NULL};
    assert(online_prep_start(slow));
    assert(!online_prep_start(slow));
    time_t t0 = time(NULL);
    online_prep_cancel();
    online_prep_get(&st);
    assert(!st.running && !strcmp(st.state, "error") && time(NULL) - t0 < 4);
    job("echo 'PROGRESS {\"state\": \"ready\", \"fraction\": 1}'", &st);  // (usable again after a cancel)
    assert(!strcmp(st.state, "ready"));
    online_prep_cancel();
    puts("PASS: online job runner");
    return 0;
}
