// Data root and shipped resources (runtime/paths.h).
#include <SDL3/SDL.h>
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/file.h>

#include "gamelib.h"
#include "paths.h"
#include "platform.h"

static char g_root[1024], g_start[1024], g_exe_dir[1024];
static int g_setup_lock = -1;
static char g_setup_stage[1100], g_setup_target[1100];
static bool g_setup_rebuild;

// Children retain the lock after an app crash until they stop writing to staging.
static int setup_lock(void) {
    char path[1100];
    snprintf(path, sizeof path, "%s/.game-setup.lock", g_root);
    int fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    if (fd >= 0 && flock(fd, LOCK_EX | LOCK_NB)) { close(fd); return -1; }
    return fd;
}

#define SEP "/"
static bool is_link(const char *p) {
    struct stat st;
    return lstat(p, &st) == 0 && S_ISLNK(st.st_mode);
}
static bool resolve(const char *p, char *out, size_t n) {
    char buf[PATH_MAX];
    if (!realpath(p, buf)) return false;
    snprintf(out, n, "%s", buf);
    return true;
}
#define path_eq(a, b) (strcmp(a, b) == 0)

static bool is_dir(const char *p) {
    struct stat st;
    return stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

static bool exists(const char *p) {
    struct stat st;
    return stat(p, &st) == 0;
}

static void mkdirs(const char *path) {
    char p[1024];
    snprintf(p, sizeof p, "%s", path);
    for (char *c = p + 1; *c; c++)
        if (*c == '/' || *c == '\\') { char s = *c; *c = 0; mkdir(p, 0755); *c = s; }
    mkdir(p, 0755);
}

static bool writable(const char *dir) {
    char t[1100];
    snprintf(t, sizeof t, "%s" SEP ".write_test", dir);
    FILE *f = fopen(t, "wb");
    if (!f) return false;
    fclose(f);
    remove(t);
    return true;
}

static void fail(const char *msg) {
    fprintf(stderr, "%s\n", msg);
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "MonZaMac", msg, NULL);
    exit(1);
}

static bool g_dev;  // the data root is the starting folder because it has extracted/ (a source checkout)
bool rt_dev_mode(void) { return g_dev; }

void rt_paths_init(void) {
    if (!getcwd(g_start, sizeof g_start)) g_start[0] = 0;
    if (plat_exe_path(g_exe_dir, sizeof g_exe_dir)) {
        char *s = strrchr(g_exe_dir, '/'), *b = strrchr(g_exe_dir, '\\');
        if (b > s) s = b;
        if (s) *s = 0;
    }
    char root[1024];
    const char *env = getenv("LARECOMP_DATA_ROOT");
    if (env && *env) snprintf(root, sizeof root, "%s", env);
    else if (is_dir("extracted")) snprintf(root, sizeof root, "%s", g_start), g_dev = true;  // dev / portable: as before
    else {
        const char *home = getenv("HOME");
        snprintf(root, sizeof root, "%s/Library/Application Support/" RT_BUNDLE_ID, home && *home ? home : "/tmp");
    }
    mkdirs(root);
    char msg[1400];
    if (!is_dir(root) || !writable(root) || chdir(root) != 0) {
        snprintf(msg, sizeof msg, "MonZaMac can't write to its data folder:\n%s", root);
        fail(msg);
    }
    if (!getcwd(g_root, sizeof g_root)) snprintf(g_root, sizeof g_root, "%s", root);
    fprintf(stderr, "[paths] data: %s\n", g_root);
}

const char *rt_data_root(void) { return g_root; }

bool rt_resource(const char *name, const char *dev_rel, char *out, size_t n) {
    char c[4][1100] = {{0}};
    if (name) {
        snprintf(c[0], sizeof c[0], "%s" SEP "%s", g_exe_dir, name);
        snprintf(c[1], sizeof c[1], "%s" SEP ".." SEP "Resources" SEP "%s", g_exe_dir, name);  // .app/Contents/Resources
    }
    if (dev_rel) {
        snprintf(c[2], sizeof c[2], "%s" SEP "%s", g_start, dev_rel);
        snprintf(c[3], sizeof c[3], "%s" SEP ".." SEP "%s", g_exe_dir, dev_rel);  // build/monzamac -> repo root
    }
    for (int i = 0; i < 4; i++)
        if (c[i][0] && exists(c[i])) return (size_t)snprintf(out, n, "%s", c[i]) < n;  // (as is: a venv python must stay a link)
    return false;
}

// ---- game files
// What the setup (runtime/ui/launcher.mm) creates in extracted/, plus what older versions' extraction and manual
// extractions left there (never read at run time).
static const char *const GAME_FILES[] = {"exefs", "romfs", "romfs.bin", GAMELIB_NAME, GAMELIB_NAME ".id", ".gamebuild",
                                         ".extract", "extract.log", "xci_secure", "nso_raw", "update_pfs", ".DS_Store"};

// game_dir must be <data root>/extracted, a real folder (a dev worktree's symlinked extracted/ is refused)
static bool game_dir_ok(const char *game_dir) {
    char want[1100], got[1100];
    snprintf(want, sizeof want, "%s" SEP "extracted", g_root);
    if (!g_root[0] || is_link(game_dir) || !resolve(game_dir, got, sizeof got)) return false;
    return path_eq(want, got);
}

bool rt_remove_game_file(const char *game_dir, const char *name) {
    bool known = false;
    for (size_t i = 0; i < sizeof GAME_FILES / sizeof *GAME_FILES; i++) known |= !strcmp(name, GAME_FILES[i]);
    char stage[1100];
    bool setup = g_setup_lock >= 0 && !is_link(game_dir) && resolve(game_dir, stage, sizeof stage) &&
                 path_eq(stage, g_setup_stage);
    if (!known || (!game_dir_ok(game_dir) && !setup)) {
        fprintf(stderr, "[paths] refusing to delete %s/%s (not app-created game files in the data root)\n", game_dir, name);
        return false;
    }
    char p[1100];
    snprintf(p, sizeof p, "%s" SEP "%s", game_dir, name);
    if (!exists(p) && !is_link(p)) return true;
    if (is_link(p)) {
        fprintf(stderr, "[paths] refusing to delete %s (a link)\n", p);
        return false;
    }
    return is_dir(p) ? plat_remove_tree(p) : remove(p) == 0;  // (plat_remove_tree doesn't follow links inside)
}

bool rt_remove_game_files(const char *game_dir) {
    if (!game_dir_ok(game_dir)) {
        fprintf(stderr, "[paths] refusing to delete game files in %s (not <data root>/extracted)\n", game_dir);
        return false;
    }
    if (g_setup_lock >= 0) return false;
    int fd = setup_lock();
    if (fd < 0) return false;
    bool ok = true;
    for (size_t i = 0; i < sizeof GAME_FILES / sizeof *GAME_FILES; i++) ok &= rt_remove_game_file(game_dir, GAME_FILES[i]);
    rmdir(game_dir);  // only if empty: anything else in there stays
    close(fd);
    return ok;
}

static unsigned long long tree_size(const char *p) {
    struct stat st;
    if (is_link(p) || stat(p, &st) != 0) return 0;
    if (!S_ISDIR(st.st_mode)) return (unsigned long long)st.st_size;
    unsigned long long n = 0;
    DIR *d = opendir(p);
    if (d) {
        struct dirent *e;
        while ((e = readdir(d))) {
            if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
            char c[2048];
            snprintf(c, sizeof c, "%s" SEP "%s", p, e->d_name);
            n += tree_size(c);
        }
        closedir(d);
    }
    return n;
}

unsigned long long rt_game_files_size(const char *game_dir) {
    unsigned long long n = 0;
    char p[1100];
    for (size_t i = 0; i < sizeof GAME_FILES / sizeof *GAME_FILES; i++) {
        snprintf(p, sizeof p, "%s" SEP "%s", game_dir, GAME_FILES[i]);
        n += tree_size(p);
    }
    return n;
}

static bool empty_dir(const char *path) {
    DIR *d = opendir(path);
    if (!d) return errno == ENOENT;
    bool empty = true;
    struct dirent *e;
    while ((e = readdir(d)))
        if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) { empty = false; break; }
    closedir(d);
    return empty;
}

bool rt_game_setup_begin(const char *game_dir, bool rebuild_code, char *stage, size_t size, char *why, size_t why_size) {
    char marker[1200];
    if (g_setup_lock >= 0) { snprintf(why, why_size, "A setup is already running."); return false; }
    snprintf(g_setup_target, sizeof g_setup_target, "%s/extracted", g_root);
    if (!g_root[0] || is_link(game_dir) ||
        (strcmp(game_dir, "extracted") && strcmp(game_dir, g_setup_target) && !game_dir_ok(game_dir))) {
        snprintf(why, why_size, "Setup can only write to MonZaMac's game-data folder."); return false;
    }
    if (rebuild_code ? !game_dir_ok(game_dir) : !empty_dir(g_setup_target)) {
        snprintf(why, why_size, "Remove the existing game files below before importing a new copy."); return false;
    }
    int fd = setup_lock();
    if (fd < 0) {
        if (fd >= 0) close(fd);
        snprintf(why, why_size, "Another setup is running, or the data folder is not writable."); return false;
    }
    snprintf(g_setup_stage, sizeof g_setup_stage, "%s/.game-setup", g_root);
    snprintf(marker, sizeof marker, "%s/.monzamac-setup", g_setup_stage);
    if (is_link(g_setup_stage)) goto fail;
    if (exists(g_setup_stage)) {
        char tag[32] = "";
        FILE *old = is_link(marker) ? NULL : fopen(marker, "r");
        if (old) { fgets(tag, sizeof tag, old); fclose(old); }
        if (strcmp(tag, "MonZaMac setup 1\n") || !plat_remove_tree(g_setup_stage)) goto fail;
    }
    if (mkdir(g_setup_stage, 0700)) goto fail;
    FILE *f = fopen(marker, "wx");
    if (!f) { rmdir(g_setup_stage); goto fail; }
    bool marked = fputs("MonZaMac setup 1\n", f) >= 0;
    if (fclose(f)) marked = false;
    if (!marked) { remove(marker); rmdir(g_setup_stage); goto fail; }
    g_setup_rebuild = rebuild_code;
    g_setup_lock = fd;
    snprintf(stage, size, "%s", g_setup_stage);
    return true;
fail:
    close(fd);
    snprintf(why, why_size, "Couldn't prepare setup storage; existing files were kept.");
    return false;
}

bool rt_game_setup_end(bool publish, char *why, size_t why_size) {
    if (g_setup_lock < 0) return false;
    bool ok = true;
    if (publish && g_setup_rebuild) {
        const char *names[] = {GAMELIB_NAME, GAMELIB_NAME ".id"};
        ok = game_dir_ok(g_setup_target);
        for (int i = 0; i < 2 && ok; i++) {
            char source[1200], target[1200];
            struct stat st;
            snprintf(source, sizeof source, "%s/%s", g_setup_stage, names[i]);
            snprintf(target, sizeof target, "%s/%s", g_setup_target, names[i]);
            ok = !is_link(source) && !is_link(target) && stat(source, &st) == 0 && S_ISREG(st.st_mode) &&
                 (!exists(target) || (stat(target, &st) == 0 && S_ISREG(st.st_mode)));
        }
        // Publish the id last. A crash between the renames leaves a mismatched
        // library that the loader rejects, and setup can rebuild it on retry.
        for (int i = 0; i < 2 && ok; i++) {
            char source[1200], target[1200];
            snprintf(source, sizeof source, "%s/%s", g_setup_stage, names[i]);
            snprintf(target, sizeof target, "%s/%s", g_setup_target, names[i]);
            ok = rename(source, target) == 0;
        }
        if (!ok) snprintf(why, why_size, "Couldn't install the updated game code; retry setup.");
        plat_remove_tree(g_setup_stage);
    } else if (publish) {
        char marker[1200];
        snprintf(marker, sizeof marker, "%s/.monzamac-setup", g_setup_stage);
        // rename cannot replace a non-empty directory. Check links separately:
        // the user may have changed the target while setup was running.
        ok = !is_link(g_setup_target) && empty_dir(g_setup_target) && remove(marker) == 0 &&
             rename(g_setup_stage, g_setup_target) == 0;
        if (!ok) snprintf(why, why_size, "Couldn't install the prepared game files; existing files were kept.");
    }
    if (!publish || !ok) plat_remove_tree(g_setup_stage);
    close(g_setup_lock); g_setup_lock = -1;
    return ok;
}

// Window / Dock icon: icon.png shipped next to the exe or in the .app (none for a plain source build).
void rt_window_icon(SDL_Window *w) {
    char p[1100];
    if (!rt_resource("icon.png", NULL, p, sizeof p)) return;
    SDL_Surface *s = SDL_LoadPNG(p);
    if (s) SDL_SetWindowIcon(w, s), SDL_DestroySurface(s);
}
