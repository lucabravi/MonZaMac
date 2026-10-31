#include "saves.h"
#include "platform.h"
#include "save_info.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

extern const char *g_save_dir;  // runtime/services/fs.c

#define ROOT "saves"
#define DEFAULT_DIR "save"
#define ORIGINAL_NAME "Main save"  // what the original save/ is called until it is renamed

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

// Newest modification time of the regular files under p (links are not followed).
static void scan(const char *p, long long *newest) {
    DIR *d = opendir(p);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;  // (.DS_Store and the like are not progress: Finder adds them just by looking)
        char q[1024];
        snprintf(q, sizeof q, "%s/%s", p, e->d_name);
        struct stat st;
        if (lstat(q, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) scan(q, newest);
        else if (S_ISREG(st.st_mode)) {
            if ((long long)st.st_mtime > *newest) *newest = (long long)st.st_mtime;
        }
    }
    closedir(d);
}

static void fill(SaveSlot *s, const char *id) {
    memset(s, 0, sizeof *s);
    snprintf(s->id, sizeof s->id, "%s", id);
    snprintf(s->name, sizeof s->name, "%s", *id ? id : ORIGINAL_NAME);
    slot_path(id, s->path, sizeof s->path);
    scan(s->path, &s->played);
    struct stat st;
    if (stat(s->path, &st) == 0)
#ifdef __APPLE__
        s->born = (long long)st.st_birthtimespec.tv_sec;
#else
        s->born = (long long)st.st_ctime;
#endif
}

static int by_born(const void *a, const void *b) {
    long long x = ((const SaveSlot *)a)->born, y = ((const SaveSlot *)b)->born;
    return x > y ? 1 : x < y ? -1 : strcmp(((const SaveSlot *)a)->id, ((const SaveSlot *)b)->id);
}

int saves_list(SaveSlot *out, int max) {
    int n = 0;
    if (max < 1) return 0;
    fill(&out[0], "");
    if (out[0].played) n = 1;  // (an empty save/ is not a save)
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
    int first = out[0].played ? 1 : 0;
    if (n - first > 1) qsort(out + first, (size_t)(n - first), sizeof *out, by_born);
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
    if (!strcasecmp(id, ORIGINAL_NAME)) {  // (that name is the original save/'s, while it holds a save)
        long long t = 0;
        scan(DEFAULT_DIR, &t);
        if (t) return false;
    }
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

bool saves_rename(const char *id, const char *name, char *id_out) {
    char nid[SAVE_NAME_MAX + 1], to[128], from[128];
    if (!new_slot_path(name, nid, to, sizeof to)) return false;
    slot_path(id, from, sizeof from);  // (the original save/ moves into saves/ under its new name)
    if (rename(from, to) != 0) return false;
    if (id_out) snprintf(id_out, SAVE_NAME_MAX + 1, "%s", nid);
    return true;
}

bool saves_delete(const char *id) {
    char p[128];
    slot_path(id, p, sizeof p);
    remove_tree(p);
    return !exists(p);
}

// The slot the game reads and writes (g_save_dir): its path as in SaveSlot.path
const char *saves_current_path(void) { return g_save_dir ? g_save_dir : DEFAULT_DIR; }

void saves_select(const char *id) {
    static char dir[128];
    slot_path(id, dir, sizeof dir);
    if (*id && !exists(dir)) slot_path("", dir, sizeof dir);
    g_save_dir = dir;
}

void saves_select_latest(void) {
    SaveSlot slots[SAVE_SLOTS_MAX];
    int n = saves_list(slots, SAVE_SLOTS_MAX), best = -1;
    for (int i = 0; i < n; i++)
        if (slots[i].played && (best < 0 || slots[i].played > slots[best].played)) best = i;
    saves_select(best < 0 ? "" : slots[best].id);
}

// ------------------------------------------------------------------ import / export
// An import is first copied into STAGE (hidden from the list: its name starts with a dot) and read there, so the
// player sees whose save it is before naming it; saves_import_commit moves it into a new slot in one rename. An import
// never replaces a slot.
#define STAGE ROOT "/.import"
#define IMPORT_MAX_BYTES (64ll << 20)  // a Z-A save is a few MB: anything far bigger is not one

static bool run_tar(const char *const argv[]) {
    PlatProc p = plat_spawn(argv, NULL, false);
    return p && plat_proc_wait(p, true) == 0;
}

// The folder under p (p itself first, then up to 4 levels down) holding a regular file `main`: the save, whether p is
// our export, a JKSV backup or a folder copied off a console. Links are not followed.
static bool find_main(const char *p, int depth, char *out, size_t n) {
    char f[1024];
    struct stat st;
    snprintf(f, sizeof f, "%s/main", p);
    if (lstat(f, &st) == 0 && S_ISREG(st.st_mode)) return snprintf(out, n, "%s", p), true;
    if (depth >= 4) return false;
    DIR *d = opendir(p);
    if (!d) return false;
    struct dirent *e;
    bool found = false;
    while (!found && (e = readdir(d))) {
        if (e->d_name[0] == '.' || !strcmp(e->d_name, "__MACOSX")) continue;
        snprintf(f, sizeof f, "%s/%s", p, e->d_name);
        if (lstat(f, &st) == 0 && S_ISDIR(st.st_mode)) found = find_main(f, depth + 1, out, n);
    }
    closedir(d);
    return found;
}

static long long tree_bytes(const char *p) {
    long long sum = 0;
    DIR *d = opendir(p);
    if (!d) return 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char q[1024];
        struct stat st;
        snprintf(q, sizeof q, "%s/%s", p, e->d_name);
        if (lstat(q, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) sum += tree_bytes(q);
        else if (S_ISREG(st.st_mode)) sum += st.st_size;
        if (sum > IMPORT_MAX_BYTES) break;
    }
    closedir(d);
    return sum;
}

static bool is_dir(const char *p) {
    struct stat st;
    return stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

bool saves_import_stage(const char *src, char *err, size_t n) {
    remove_tree(STAGE);
    mkdir(ROOT, 0755);
    if (mkdir(STAGE, 0755) != 0) return snprintf(err, n, "Couldn't prepare the import."), false;
    char from[1024];
    if (is_dir(src)) {
        if (!find_main(src, 0, from, sizeof from)) return snprintf(err, n, "No save in that folder (a folder with the file \"main\")."), false;
    } else {
        // a .zip (our export, JKSV's): opened by the system's tar, which keeps entries inside STAGE/zip (no absolute
        // paths, no ..); links in it are skipped below
        mkdir(STAGE "/zip", 0755);
        const char *argv[] = {"/usr/bin/tar", "-x", "-f", src, "-C", STAGE "/zip", NULL};
        if (!run_tar(argv)) return remove_tree(STAGE), snprintf(err, n, "That file couldn't be opened: choose a .zip or a folder."), false;
        if (!find_main(STAGE "/zip", 0, from, sizeof from))
            return remove_tree(STAGE), snprintf(err, n, "No save in that file (a folder with the file \"main\")."), false;
    }
    if (tree_bytes(from) > IMPORT_MAX_BYTES) return remove_tree(STAGE), snprintf(err, n, "That's too big to be a Z-A save."), false;
    bool ok = copy_tree(from, STAGE "/save_0");
    remove_tree(STAGE "/zip");
    if (!ok) return remove_tree(STAGE), snprintf(err, n, "The save couldn't be copied."), false;
    if (!save_info(STAGE)) return remove_tree(STAGE), snprintf(err, n, "That's not a Pokémon Legends: Z-A save."), false;
    return true;
}

const char *saves_import_staged(void) { return STAGE; }

bool saves_import_commit(const char *name, char *id_out) {
    char id[SAVE_NAME_MAX + 1], path[128], to[160];
    if (!new_slot_path(name, id, path, sizeof path) || mkdir(path, 0755) != 0) return false;
    snprintf(to, sizeof to, "%s/save_0", path);
    if (rename(STAGE "/save_0", to) != 0) { rmdir(path); return false; }
    remove_tree(STAGE);
    if (id_out) snprintf(id_out, SAVE_NAME_MAX + 1, "%s", id);
    return true;
}

void saves_import_cancel(void) { remove_tree(STAGE); }

bool saves_export(const char *id, const char *zip) {
    char slot[128], s0[160];
    slot_path(id, slot, sizeof slot);
    snprintf(s0, sizeof s0, "%s/save_0", slot);
    if (!is_dir(s0)) return false;
    unlink(zip);  // (the save panel asked before replacing it)
    const char *argv[] = {"/usr/bin/tar", "-a", "-c", "-f", zip, "-C", slot, "save_0", NULL};  // -a: a .zip, from the name
    return run_tar(argv);
}

// A name for the staged save. Our own export's file name ("<name> - <h>h<mm> - <yyyy-mm-dd>.zip") gives back the slot's
// name it had; any other file or folder: "<trainer> - <h>h<mm> - <its name>". Only the characters a slot name holds,
// cut to fit, and made free with " 2", " 3"... like a typed one.
void saves_import_name(const char *src, char *out, size_t n) {
    const char *slash = strrchr(src, '/');
    char file[256], want[320];
    snprintf(file, sizeof file, "%s", slash ? slash + 1 : src);
    size_t fl = strlen(file);
    if (fl > 4 && !strcasecmp(file + fl - 4, ".zip")) file[fl -= 4] = 0;
    unsigned h, m, y, mo, d;
    int at = -1;
    for (size_t k = 0; k + 3 < fl; k++)  // (the " - " that starts "<h>h<mm> - <date>")
        if (!strncmp(file + k, " - ", 3) && sscanf(file + k, " - %uh%2u - %4u-%2u-%2u", &h, &m, &y, &mo, &d) == 5) at = (int)k;
    const SaveInfo *si = save_info(STAGE);
    unsigned t = si && si->played > 0 ? (unsigned)si->played : 0;
    if (at > 0) snprintf(want, sizeof want, "%.*s", at, file);
    else snprintf(want, sizeof want, "%s - %uh%02u - %s", si && si->trainer[0] ? si->trainer : "Imported", t / 3600, t / 60 % 60, file);
    char base[SAVE_NAME_MAX + 1] = {0};
    size_t k = 0;
    for (const char *c = want; *c && k < SAVE_NAME_MAX - 3; c++)  // (3 left for a " 2")
        if ((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') || *c == ' ' || *c == '-' || *c == '_')
            if (!(*c == ' ' && (!k || base[k - 1] == ' '))) base[k++] = *c;  // (no double space where a character was dropped)
    while (k && (base[k - 1] == ' ' || base[k - 1] == '-')) base[--k] = 0;
    if (!k) snprintf(base, sizeof base, "Imported save");
    char id[SAVE_NAME_MAX + 1], path[128];
    snprintf(out, n, "%s", base);
    for (int i = 2; i < 100; i++) {
        bool taken = !clean_name(out, id) || !strcasecmp(id, ORIGINAL_NAME) || (snprintf(path, sizeof path, ROOT "/%s", id), exists(path));
        if (!taken) break;
        snprintf(out, n, "%s %d", base, i);
    }
}
