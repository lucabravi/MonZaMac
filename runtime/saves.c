#include "saves.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern const char *g_save_dir;  // runtime/services/fs.c

#define ROOT "saves"
#define DEFAULT_DIR "save"

static void slot_path(const char *id, char *out, size_t n) {
    if (*id) snprintf(out, n, ROOT "/%s", id);
    else snprintf(out, n, DEFAULT_DIR);
}

// A name that is safe as a folder name: trimmed, only letters, digits, space, - and _. false: nothing left of it.
static bool clean_name(const char *in, char *out) {
    while (*in == ' ') in++;
    size_t n = 0;
    for (; *in && n < SAVE_NAME_MAX; in++) {
        char c = *in;
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == ' ' || c == '-' || c == '_')
            out[n++] = c;
    }
    while (n && out[n - 1] == ' ') n--;
    out[n] = 0;
    return n > 0;
}

static bool exists(const char *p) {
    struct stat st;
    return lstat(p, &st) == 0;
}

// Newest modification time and total size of the regular files under p (links are not followed).
static void scan(const char *p, long long *newest, unsigned long long *bytes) {
    DIR *d = opendir(p);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char q[1024];
        snprintf(q, sizeof q, "%s/%s", p, e->d_name);
        struct stat st;
        if (lstat(q, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) scan(q, newest, bytes);
        else if (S_ISREG(st.st_mode)) {
            *bytes += (unsigned long long)st.st_size;
            if ((long long)st.st_mtime > *newest) *newest = (long long)st.st_mtime;
        }
    }
    closedir(d);
}

static void fill(SaveSlot *s, const char *id) {
    memset(s, 0, sizeof *s);
    snprintf(s->id, sizeof s->id, "%s", id);
    snprintf(s->name, sizeof s->name, "%s", *id ? id : "Main save");
    slot_path(id, s->path, sizeof s->path);
    scan(s->path, &s->played, &s->bytes);
}

static int by_played(const void *a, const void *b) {
    long long x = ((const SaveSlot *)a)->played, y = ((const SaveSlot *)b)->played;
    return x < y ? 1 : x > y;
}

int saves_list(SaveSlot *out, int max) {
    int n = 0;
    if (max < 1) return 0;
    fill(&out[n++], "");
    DIR *d = opendir(ROOT);
    if (d) {
        struct dirent *e;
        while (n < max && (e = readdir(d))) {
            char path[300];
            struct stat st;
            if (e->d_name[0] == '.' || strlen(e->d_name) > SAVE_NAME_MAX) continue;
            snprintf(path, sizeof path, ROOT "/%s", e->d_name);
            if (lstat(path, &st) == 0 && S_ISDIR(st.st_mode)) fill(&out[n++], e->d_name);
        }
        closedir(d);
    }
    if (n > 2) qsort(out + 1, (size_t)n - 1, sizeof *out, by_played);
    return n;
}

static bool copy_file(const char *from, const char *to) {
    int a = open(from, O_RDONLY), b = open(to, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    bool ok = a >= 0 && b >= 0;
    char buf[65536];
    ssize_t r;
    while (ok && (r = read(a, buf, sizeof buf)) > 0)
        if (write(b, buf, (size_t)r) != r) ok = false;
    if (r < 0) ok = false;
    if (a >= 0) close(a);
    if (b >= 0) close(b);
    return ok;
}

static bool copy_tree(const char *from, const char *to) {
    if (mkdir(to, 0755) != 0 && errno != EEXIST) return false;
    DIR *d = opendir(from);
    if (!d) return false;
    bool ok = true;
    struct dirent *e;
    while (ok && (e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char a[1024], b[1024];
        struct stat st;
        snprintf(a, sizeof a, "%s/%s", from, e->d_name);
        snprintf(b, sizeof b, "%s/%s", to, e->d_name);
        if (lstat(a, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) ok = copy_tree(a, b);
        else if (S_ISREG(st.st_mode)) ok = copy_file(a, b);
    }
    closedir(d);
    return ok;
}

// (links are removed, never followed)
static void remove_tree(const char *p) {
    struct stat st;
    if (lstat(p, &st) != 0) return;
    if (S_ISDIR(st.st_mode)) {
        DIR *d = opendir(p);
        struct dirent *e;
        while (d && (e = readdir(d))) {
            char q[1024];
            if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
            snprintf(q, sizeof q, "%s/%s", p, e->d_name);
            remove_tree(q);
        }
        if (d) closedir(d);
        rmdir(p);
    } else
        unlink(p);
}

// the folder for a new slot called `name`: ROOT/name, which must not exist
static bool new_slot_path(const char *name, char *id, char *path, size_t n) {
    if (!clean_name(name, id)) return false;
    snprintf(path, n, ROOT "/%s", id);
    if (exists(path)) return false;
    mkdir(ROOT, 0755);
    return true;
}

bool saves_create(const char *name, char *id_out) {
    char id[SAVE_NAME_MAX + 1], path[128];
    if (!new_slot_path(name, id, path, sizeof path) || mkdir(path, 0755) != 0) return false;
    if (id_out) snprintf(id_out, SAVE_NAME_MAX + 1, "%s", id);
    return true;
}

bool saves_copy(const char *id, const char *name) {
    char nid[SAVE_NAME_MAX + 1], to[128], from[128];
    if (!new_slot_path(name, nid, to, sizeof to)) return false;
    slot_path(id, from, sizeof from);
    if (copy_tree(from, to)) return true;
    remove_tree(to);  // (half a copy is not a save)
    return false;
}

bool saves_rename(const char *id, const char *name) {
    char nid[SAVE_NAME_MAX + 1], to[128], from[128];
    if (!*id || !new_slot_path(name, nid, to, sizeof to)) return false;
    slot_path(id, from, sizeof from);
    return rename(from, to) == 0;
}

bool saves_delete(const char *id) {
    char p[128];
    slot_path(id, p, sizeof p);
    remove_tree(p);
    return !exists(p);
}

void saves_select(const char *id) {
    static char dir[128];
    slot_path(id, dir, sizeof dir);
    if (*id && !exists(dir)) slot_path("", dir, sizeof dir);
    g_save_dir = dir;
}
