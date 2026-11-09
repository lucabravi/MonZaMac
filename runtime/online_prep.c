#include "online_prep.h"

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static OnlinePrepStatus g_status;
static pid_t g_pid;
static pthread_t g_thread;
static bool g_joinable;

static bool json_hex4(const char *p, unsigned *out) {
    unsigned v = 0;
    for (int i = 0; i < 4; i++) {
        char h = p[i];
        if (!((h >= '0' && h <= '9') || (h >= 'a' && h <= 'f') || (h >= 'A' && h <= 'F'))) return false;
        v = v * 16 + (unsigned)(h <= '9' ? h - '0' : (h | 0x20) - 'a' + 10);
    }
    *out = v;
    return true;
}

// The value of "key" in the flat JSON object `json` as a string (numbers as written). Escapes \" \\ \/ \n \t and \uXXXX
// (the scripts print ASCII-escaped JSON). false: no such key.
static bool json_value(const char *json, const char *key, char *out, size_t cap) {
    char pattern[48];
    snprintf(pattern, sizeof pattern, "\"%s\":", key);
    const char *p = strstr(json, pattern);
    if (!p) return false;
    p += strlen(pattern);
    while (*p == ' ') p++;
    size_t n = 0;
    if (*p == '"') {
        for (p++; *p && *p != '"'; p++) {
            unsigned c = (unsigned char)*p;
            if (c == '\\' && p[1]) {
                p++;
                switch (*p) {
                case 'n': c = '\n'; break;
                case 't': c = '\t'; break;
                case 'u': {
                    unsigned v;
                    if (!json_hex4(p + 1, &v)) return false;
                    p += 4;
                    if (v >= 0xD800 && v <= 0xDBFF) {
                        unsigned low;
                        if (p[1] != '\\' || p[2] != 'u' || !json_hex4(p + 3, &low) || low < 0xDC00 || low > 0xDFFF) return false;
                        v = 0x10000 + ((v - 0xD800) << 10) + low - 0xDC00;
                        p += 6;
                    } else if (v >= 0xDC00 && v <= 0xDFFF) return false;
                    char utf8[4];
                    int len = v < 0x80 ? (utf8[0] = (char)v, 1) : v < 0x800 ? (utf8[0] = (char)(0xC0 | v >> 6), utf8[1] = (char)(0x80 | (v & 63)), 2)
                              : v < 0x10000 ? (utf8[0] = (char)(0xE0 | v >> 12), utf8[1] = (char)(0x80 | ((v >> 6) & 63)), utf8[2] = (char)(0x80 | (v & 63)), 3)
                              : (utf8[0] = (char)(0xF0 | v >> 18), utf8[1] = (char)(0x80 | ((v >> 12) & 63)), utf8[2] = (char)(0x80 | ((v >> 6) & 63)), utf8[3] = (char)(0x80 | (v & 63)), 4);
                    if (n + (size_t)len >= cap) return false;  // never publish a partial UTF-8 character
                    for (int i = 0; i < len; i++) out[n++] = utf8[i];
                    continue;
                }
                default: c = (unsigned char)*p;  // \" \\ \/ and anything else as itself
                }
            }
            if (n + 1 < cap) out[n++] = (char)c;
        }
        if (*p != '"') return false;
    } else {
        while (*p && *p != ',' && *p != '}' && *p != ' ' && n + 1 < cap) out[n++] = *p++;
    }
    out[n] = 0;
    return true;
}

bool online_prep_parse_line(const char *line, OnlinePrepStatus *st) {
    const char *json;
    if (!strncmp(line, "PROGRESS ", 9)) json = line + 9;
    else if (!strncmp(line, "STATUS ", 7)) json = line + 7;
    else return false;
    char v[1024];
    if (json_value(json, "state", v, sizeof v)) snprintf(st->state, sizeof st->state, "%s", v);
    if (json_value(json, "fraction", v, sizeof v)) {
        float f = (float)atof(v);
        st->fraction = f < 0 ? 0 : f > 1 ? 1 : f;
    }
    if (json_value(json, "step", v, sizeof v)) snprintf(st->step, sizeof st->step, "%s", v);
    if (json_value(json, "message", v, sizeof v)) snprintf(st->message, sizeof st->message, "%s", v);
    if (json_value(json, "dir", v, sizeof v)) snprintf(st->dir, sizeof st->dir, "%s", v);
    if (json_value(json, "version", v, sizeof v)) snprintf(st->version, sizeof st->version, "%s", v);
    if (json_value(json, "endpoint", v, sizeof v)) snprintf(st->endpoint, sizeof st->endpoint, "%s", v);
    return true;
}

static void *reader(void *arg) {
    int fd = (int)(intptr_t)arg;
    FILE *f = fdopen(fd, "r");
    char line[4096];
    while (f && fgets(line, sizeof line, f)) {
        size_t len = strlen(line);
        while (len && (line[len - 1] == '\n' || line[len - 1] == '\r')) line[--len] = 0;
        pthread_mutex_lock(&g_lock);
        online_prep_parse_line(line, &g_status);
        pthread_mutex_unlock(&g_lock);
    }
    if (f) fclose(f);
    int wstatus = 0;
    pthread_mutex_lock(&g_lock);
    pid_t pid = g_pid;
    pthread_mutex_unlock(&g_lock);
    pid_t waited = -1;
    if (pid > 0) {
        do waited = waitpid(pid, &wstatus, 0); while (waited < 0 && errno == EINTR);
    }
    pthread_mutex_lock(&g_lock);
    g_pid = 0;
    g_status.running = false;
    bool failed = waited != pid || !WIFEXITED(wstatus) || WEXITSTATUS(wstatus) != 0;
    bool reported_error = !strcmp(g_status.state, "error");
    bool finished = !strcmp(g_status.state, "ready") || !strcmp(g_status.state, "error") ||
                    !strcmp(g_status.state, "none") || !strcmp(g_status.state, "invalid");
    if (failed || !finished) {  // a result line cannot turn a failed process into a successful job
        snprintf(g_status.state, sizeof g_status.state, "error");
        if (!reported_error || !g_status.message[0]) {
            if (waited != pid) snprintf(g_status.message, sizeof g_status.message, "Could not read the job exit status.");
            else if (WIFSIGNALED(wstatus)) snprintf(g_status.message, sizeof g_status.message, "The job was stopped.");
            else if (failed) snprintf(g_status.message, sizeof g_status.message, "The job failed (exit %d).", WEXITSTATUS(wstatus));
            else snprintf(g_status.message, sizeof g_status.message, "The job ended without a result.");
        }
    }
    pthread_mutex_unlock(&g_lock);
    return NULL;
}

bool online_prep_start(const char *const *argv) {
    pthread_mutex_lock(&g_lock);
    if (g_status.running) { pthread_mutex_unlock(&g_lock); return false; }
    if (g_joinable) { pthread_mutex_unlock(&g_lock); pthread_join(g_thread, NULL); pthread_mutex_lock(&g_lock); g_joinable = false; }
    memset(&g_status, 0, sizeof g_status);
    int fds[2];
    posix_spawn_file_actions_t actions;
    pid_t pid = 0;
    int rc = pipe(fds);
    if (rc == 0) {
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1);
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2);
        posix_spawn_file_actions_addclose(&actions, fds[0]);
        posix_spawn_file_actions_addclose(&actions, fds[1]);
        posix_spawnattr_t attr;  // its own process group, so a cancel reaches what the script started too
        posix_spawnattr_init(&attr);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
        posix_spawnattr_setpgroup(&attr, 0);
        rc = posix_spawnp(&pid, argv[0], &actions, &attr, (char *const *)argv, environ);
        posix_spawnattr_destroy(&attr);
        posix_spawn_file_actions_destroy(&actions);
        close(fds[1]);
        if (rc != 0) close(fds[0]);
    } else rc = errno;
    if (rc != 0) {
        snprintf(g_status.state, sizeof g_status.state, "error");
        snprintf(g_status.message, sizeof g_status.message, "Could not start %s (%s).", argv[0], strerror(rc));
        pthread_mutex_unlock(&g_lock);
        return false;
    }
    g_pid = pid;
    g_status.running = true;
    snprintf(g_status.state, sizeof g_status.state, "running");
    if (pthread_create(&g_thread, NULL, reader, (void *)(intptr_t)fds[0]) != 0) {
        kill(-pid, SIGKILL); waitpid(pid, NULL, 0); close(fds[0]);
        g_pid = 0; g_status.running = false;
        snprintf(g_status.state, sizeof g_status.state, "error");
        snprintf(g_status.message, sizeof g_status.message, "Could not start a thread for the job.");
        pthread_mutex_unlock(&g_lock);
        return false;
    }
    g_joinable = true;
    pthread_mutex_unlock(&g_lock);
    return true;
}

void online_prep_get(OnlinePrepStatus *out) {
    pthread_mutex_lock(&g_lock);
    *out = g_status;
    pthread_mutex_unlock(&g_lock);
}

void online_prep_cancel(void) {
    pthread_mutex_lock(&g_lock);
    pid_t pid = g_pid;
    pthread_mutex_unlock(&g_lock);
    if (pid > 0) {
        kill(-pid, SIGTERM);
        for (int i = 0; i < 50; i++) {  // up to 5 s
            pthread_mutex_lock(&g_lock);
            bool alive = g_status.running;
            pthread_mutex_unlock(&g_lock);
            if (!alive) break;
            usleep(100000);
        }
        pthread_mutex_lock(&g_lock);
        pid = g_pid;
        pthread_mutex_unlock(&g_lock);
        if (pid > 0) kill(-pid, SIGKILL);
    }
    pthread_mutex_lock(&g_lock);
    bool joinable = g_joinable;
    g_joinable = false;
    pthread_mutex_unlock(&g_lock);
    if (joinable) pthread_join(g_thread, NULL);
}
