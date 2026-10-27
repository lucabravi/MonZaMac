#include "gameimport.h"
#include "paths.h"
#include "platform.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

typedef struct { char helper[1100], script[1100], nstool[1100]; } ImportTools;
static bool find_tools(ImportTools *t) {
    memset(t, 0, sizeof *t);
    return (rt_resource("lasgen/lasgen" PLAT_EXE_SUFFIX, NULL, t->helper, sizeof t->helper) ||
            (rt_resource(NULL, "tools/" PLAT_VENV_PYTHON, t->helper, sizeof t->helper) &&
             rt_resource(NULL, "tools/game_extract.py", t->script, sizeof t->script))) &&
           rt_resource("nstool/nstool" PLAT_EXE_SUFFIX, "tools/nstool/bin/nstool" PLAT_EXE_SUFFIX,
                       t->nstool, sizeof t->nstool);
}
bool gameimport_available(void) { ImportTools t; return find_tools(&t); }

static uint32_t le32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint64_t le64(const unsigned char *p) {
    return (uint64_t)le32(p) | (uint64_t)le32(p + 4) << 32;
}

static bool read_at(FILE *f, uint64_t offset, void *data, size_t size) {
    return offset <= INT64_MAX && fseeko(f, (off_t)offset, SEEK_SET) == 0 && fread(data, 1, size, f) == size;
}

static void import_error_text(const char *error, unsigned long long required, char *why, size_t why_size) {
    if (!strcmp(error, "space")) snprintf(why, why_size, "Setup needs about %.0f GB of free space.", required / 1e9);
    else if (!strcmp(error, "archive-7z-nsp")) snprintf(why, why_size, "This file is a 7z archive despite its .nsp name. Choose an uncompressed NSP or XCI game package.");
    else if (!strcmp(error, "archive-7z")) snprintf(why, why_size, "This is a 7z archive, not an NSP or XCI. Choose an uncompressed game package.");
    else if (!strcmp(error, "archive")) snprintf(why, why_size, "This is a compressed archive, not an NSP or XCI. Choose an uncompressed game package.");
    else if (!strcmp(error, "package")) snprintf(why, why_size, "This file isn't a valid NSP or XCI game package.");
    else if (!strcmp(error, "keys")) snprintf(why, why_size, "Choose a readable prod.keys file.");
    else if (!strcmp(error, "input")) snprintf(why, why_size, "Choose different files for the base game and update.");
    else if (!strcmp(error, "game")) snprintf(why, why_size, "Choose the base game and matching update for Pokémon Legends: Z-A.");
    else if (!strcmp(error, "version")) snprintf(why, why_size, "This update is not version 2.0.2 of Pokémon Legends: Z-A.");
    else if (!strcmp(error, "files")) snprintf(why, why_size, "The extracted game is incomplete. Check the base game and update dumps.");
    else if (!strcmp(error, "decrypt")) snprintf(why, why_size, "Couldn't read the encrypted game files. Check your prod.keys and game dumps.");
    else if (!strcmp(error, "io")) snprintf(why, why_size, "Couldn't read this file. Check that it still exists and is accessible.");
    else snprintf(why, why_size, "Couldn't prepare these files. Use complete NSP or XCI dumps and an update NSP; compressed dumps aren't supported.");
}

static const char *package_error(const char *path) {
    struct stat st;
    if (!path || stat(path, &st) || !S_ISREG(st.st_mode) || st.st_size < 16) return "package";
    FILE *f = fopen(path, "rb");
    if (!f) return "io";
    unsigned char h[0x38];
    const char *error = "package";
    if (fread(h, 1, 4, f) != 4) goto done;
    if (!memcmp(h, "7z\xbc\xaf", 4)) {
        const char *ext = strrchr(path, '.');
        error = ext && !strcasecmp(ext, ".nsp") ? "archive-7z-nsp" : "archive-7z";
        goto done;
    }
    if (!memcmp(h, "PK\003\004", 4) || (h[0] == 0x1f && h[1] == 0x8b)) { error = "archive"; goto done; }
    if (!memcmp(h, "PFS0", 4)) {
        unsigned char rest[12];
        if (fread(rest, 1, sizeof rest, f) != sizeof rest) goto done;
        uint64_t count = le32(rest), names = le32(rest + 4);
        uint64_t header = 16 + count * 24 + names;
        if (count && count <= 65536 && names <= (16u << 20) && header <= (uint64_t)st.st_size) error = NULL;
        goto done;
    }
    if (!read_at(f, 0x100, h, sizeof h) || memcmp(h, "HEAD", 4)) goto done;
    {
        uint64_t root = le64(h + 0x30);
        unsigned char root_header[16];
        if (root > (uint64_t)st.st_size || !read_at(f, root, root_header, sizeof root_header) ||
            memcmp(root_header, "HFS0", 4)) goto done;
        uint64_t count = le32(root_header + 4), names = le32(root_header + 8);
        uint64_t end = root + 16 + count * 64 + names;
        if (count && count <= 65536 && names <= (16u << 20) && end <= (uint64_t)st.st_size) error = NULL;
    }
done:
    fclose(f);
    return error;
}

bool gameimport_preflight(const char *base, const char *update, const char *keys,
                          char *bad_field, size_t bad_field_size, char *why, size_t why_size) {
    if (bad_field && bad_field_size) bad_field[0] = 0;
    if (!why || !why_size) return false;
    why[0] = 0;
    struct stat b, u, k;
    if (!base || stat(base, &b) || !S_ISREG(b.st_mode)) {
        if (bad_field && bad_field_size) snprintf(bad_field, bad_field_size, "base");
        import_error_text("io", 0, why, why_size); return false;
    }
    const char *error = package_error(base);
    if (error) {
        if (bad_field && bad_field_size) snprintf(bad_field, bad_field_size, "base");
        import_error_text(error, 0, why, why_size); return false;
    }
    if (!update || stat(update, &u) || !S_ISREG(u.st_mode)) {
        if (bad_field && bad_field_size) snprintf(bad_field, bad_field_size, "update");
        import_error_text("io", 0, why, why_size); return false;
    }
    if (b.st_dev == u.st_dev && b.st_ino == u.st_ino) {
        if (bad_field && bad_field_size) snprintf(bad_field, bad_field_size, "update");
        import_error_text("input", 0, why, why_size); return false;
    }
    error = package_error(update);
    if (error) {
        if (bad_field && bad_field_size) snprintf(bad_field, bad_field_size, "update");
        import_error_text(error, 0, why, why_size); return false;
    }
    if (!keys || stat(keys, &k) || !S_ISREG(k.st_mode) || k.st_size <= 0 || k.st_size > (8 << 20)) {
        if (bad_field && bad_field_size) snprintf(bad_field, bad_field_size, "keys");
        import_error_text("keys", 0, why, why_size); return false;
    }
    return true;
}

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static PlatProc active;
static bool quitting;
static void stop_import(void) {
    pthread_mutex_lock(&lock);
    quitting = true;
    if (active) { plat_proc_kill(active); active = 0; }
    pthread_mutex_unlock(&lock);
}

static void register_cleanup(void) { atexit(stop_import); }

bool gameimport_run(const char *base, const char *update, const char *keys, const char *stage,
                    const unsigned char build_id[8], void (*progress)(double, const char *),
                    char *bad_field, size_t bad_field_size, char *why, size_t why_size) {
    if (bad_field && bad_field_size) bad_field[0] = 0;
    ImportTools t;
    if (!find_tools(&t)) { snprintf(why, why_size, "The import tools are missing. Reinstall the complete app."); return false; }
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, register_cleanup);
    char id[17], log[1200];
    for (int i = 0; i < 8; i++) snprintf(id + i * 2, 3, "%02x", build_id[i]);
    snprintf(log, sizeof log, "%s/import.log", stage);
    const char *argv[22]; int n = 0;
    argv[n++] = t.helper;
    if (t.script[0]) argv[n++] = t.script;
    else argv[n++] = "extract";
    argv[n++] = "--base"; argv[n++] = base;
    argv[n++] = "--update"; argv[n++] = update;
    argv[n++] = "--keys"; argv[n++] = keys;
    argv[n++] = "--output"; argv[n++] = stage;
    argv[n++] = "--nstool"; argv[n++] = t.nstool;
    argv[n++] = "--build-id"; argv[n++] = id; argv[n] = NULL;
    pthread_mutex_lock(&lock);
    active = quitting ? 0 : plat_spawn(argv, log, false);
    pthread_mutex_unlock(&lock);
    if (!active) { snprintf(why, why_size, "Couldn't start game-file preparation."); return false; }
    int result = -1, last_phase = -1;
    char error[32] = "extract", field[16] = "none";
    unsigned long long required = 0;
    while (result < 0) {
        pthread_mutex_lock(&lock);
        result = active ? plat_proc_wait(active, false) : 255;
        if (result >= 0) active = 0;
        pthread_mutex_unlock(&lock);
        FILE *f = fopen(log, "r");
        char line[256];
        if (f) {
            while (fgets(line, sizeof line, f)) {
                static const char *phases[] = {"checking", "base", "update", "extracting", "ready"};
                static const char *labels[] = {"Checking game packages...", "Preparing the base game...",
                    "Preparing the update...", "Extracting the updated game...", "Game packages prepared."};
                for (int i = 0; i < 5; i++) {
                    char want[64]; snprintf(want, sizeof want, "import: %s\n", phases[i]);
                    if (!strcmp(line, want) && i > last_phase) {
                        last_phase = i;
                        if (progress) progress(i / 4.0, labels[i]);
                    }
                }
                char parsed_field[16], parsed_error[32];
                if (sscanf(line, "import: error %15s %31s", parsed_field, parsed_error) == 2) {
                    snprintf(field, sizeof field, "%s", parsed_field);
                    snprintf(error, sizeof error, "%s", parsed_error);
                }
                sscanf(line, "import: space %llu", &required);
            }
            fclose(f);
        }
        if (result < 0) plat_sleep_until_ns(plat_now_ns() + 100000000ull);
    }
    remove(log);
    if (!result) return true;
    if (bad_field && bad_field_size && strcmp(field, "none"))
        snprintf(bad_field, bad_field_size, "%s", field);
    fprintf(stderr, "[gameimport] preparation failed (code %s, exit %d)\n", error, result);
    if (!strcmp(error, "space")) snprintf(why, why_size, "Setup needs about %.0f GB of free space.", required / 1e9);
    else if (!strcmp(error, "archive-7z-nsp")) snprintf(why, why_size, "This file has a 7z archive header despite its .nsp name. Extract it, then choose the NSP inside.");
    else if (!strcmp(error, "archive-7z")) snprintf(why, why_size, "This is a 7z archive, not a game package. Extract it and choose the NSP or XCI inside.");
    else if (!strcmp(error, "archive")) snprintf(why, why_size, "This is a compressed archive, not a game package. Extract it and choose the NSP or XCI inside.");
    else if (!strcmp(error, "game")) snprintf(why, why_size, "Choose the base game and matching update for Pokémon Legends: Z-A.");
    else if (!strcmp(error, "version")) snprintf(why, why_size, "This update is not version 2.0.2 of Pokémon Legends: Z-A.");
    else if (!strcmp(error, "files")) snprintf(why, why_size, "The extracted game is incomplete. Check the base game and update dumps.");
    else if (!strcmp(error, "decrypt") || !strcmp(error, "keys")) snprintf(why, why_size, "Couldn't read the encrypted game files. Check your prod.keys and game dumps.");
    else snprintf(why, why_size, "Couldn't prepare these files. Use complete NSP or XCI dumps and an update NSP; compressed dumps aren't supported.");
    return false;
}
