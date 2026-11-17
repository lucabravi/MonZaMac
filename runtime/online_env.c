#include "online_env.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;

// What stays: the variables docs/environment.md supports, and what the start screen and the restart pass on to the
// game (the library and the save chosen there, the loading cover).
static const char *const kept[] = {
    "LARECOMP_DATA_ROOT", "LARECOMP_SETTINGS", "LARECOMP_NO_UPDATE_CHECK", "LARECOMP_NULL_GETTER", "LARECOMP_NPC_CAPACITY_FIX",
    "LARECOMP_GPU_OVERLAP", "LARECOMP_XFB_END_BARRIER", "LARECOMP_DEVLOG", "LARECOMP_PERF_LOG", "LARECOMP_UNCAPPED_FPS",
    "LARECOMP_GAME_LIB", "LARECOMP_PLAY_SAVE", "LARECOMP_LOADING_COVER",
};

#define MAX_REMOVED 512
static char *g_removed[MAX_REMOVED];  // "NAME=value" as it was
static int g_nremoved;

static int is_kept(const char *name, size_t n) {
    for (size_t i = 0; i < sizeof kept / sizeof *kept; i++)
        if (strlen(kept[i]) == n && !strncmp(kept[i], name, n)) return 1;
    return 0;
}

void rt_online_env_sanitize(void) {
    if (!getenv("LUMIOSE_TEST_MODULE")) return;
    char *names[MAX_REMOVED];  // (collected first: removing while walking environ shifts it)
    int n = 0;
    for (char **e = environ; e && *e && n < MAX_REMOVED; e++) {
        if (strncmp(*e, "LARECOMP_", 9)) continue;
        const char *eq = strchr(*e, '=');
        size_t len = eq ? (size_t)(eq - *e) : strlen(*e);
        if (is_kept(*e, len)) continue;
        names[n++] = strndup(*e, len);
    }
    for (int i = 0; i < n; i++) {
        const char *value = getenv(names[i]);
        if (g_nremoved < MAX_REMOVED) {
            size_t need = strlen(names[i]) + 1 + (value ? strlen(value) : 0) + 1;
            char *kept_copy = malloc(need);
            if (kept_copy) {
                snprintf(kept_copy, need, "%s=%s", names[i], value ? value : "");
                g_removed[g_nremoved++] = kept_copy;
            }
        }
        fprintf(stderr, "[online] %s is ignored online (debug hooks are off)\n", names[i]);
        unsetenv(names[i]);
        free(names[i]);
    }
}

void rt_online_env_restore(void) {
    for (int i = 0; i < g_nremoved; i++) {
        char *eq = strchr(g_removed[i], '=');
        if (eq) {
            *eq = 0;
            setenv(g_removed[i], eq + 1, 0);  // (not over one that was set again since)
        }
        free(g_removed[i]);
    }
    g_nremoved = 0;
}
