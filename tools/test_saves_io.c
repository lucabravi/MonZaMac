// Save import / export (runtime/saves.c): staging from a folder or a .zip, commit as a new slot, export round trip,
// and the unsafe inputs (paths out of the archive, a linked `main`, no save at all). Runs in a scratch folder; the save
// reader is stubbed (a `main` starting with "ZA" reads as a save).
//   gmake B=build/za202 GEN=generated-202 test-saves-io
#include <assert.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include "platform.h"
#include "save_info.h"
#include "saves.h"

const char *g_save_dir;
extern char **environ;

PlatProc plat_spawn(const char *const argv[], const char *log_path, bool append_log) {
    (void)log_path, (void)append_log;
    pid_t pid;
    return posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, environ) ? 0 : (PlatProc)pid;
}
int plat_proc_wait(PlatProc p, bool block) {
    int st = 0;
    waitpid((pid_t)p, &st, block ? 0 : WNOHANG);
    return WIFEXITED(st) ? WEXITSTATUS(st) : 255;
}
const SaveInfo *save_info(const char *slot) {
    static SaveInfo si;
    char f[512], head[2] = {0};
    snprintf(f, sizeof f, "%s/save_0/main", slot);
    FILE *in = fopen(f, "rb");
    if (!in) return NULL;
    size_t n = fread(head, 1, 2, in);
    fclose(in);
    return n == 2 && head[0] == 'Z' && head[1] == 'A' ? &si : NULL;
}

static void put(const char *path, const char *text) {
    FILE *f = fopen(path, "wb");
    assert(f);
    fputs(text, f);
    fclose(f);
}
static bool same(const char *path, const char *text) {
    char buf[256] = {0};
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    return n == strlen(text) && !memcmp(buf, text, n);
}
static bool there(const char *p) { struct stat st; return lstat(p, &st) == 0; }

int main(void) {
    char tmp[] = "/tmp/saves_io_XXXXXX", err[160], id[SAVE_NAME_MAX + 1];
    assert(mkdtemp(tmp));
    assert(chdir(tmp) == 0);

    // a folder holding the save a few levels down (a JKSV backup: <game>/<date>/main)
    mkdir("in", 0755), mkdir("in/jksv", 0755), mkdir("in/jksv/2026", 0755);
    put("in/jksv/2026/main", "ZA save one");
    put("in/jksv/2026/backup", "extra");
    assert(saves_import_stage("in", err, sizeof err));
    assert(saves_import_commit("Trainer", id) && !strcmp(id, "Trainer"));
    assert(same("saves/Trainer/save_0/main", "ZA save one") && same("saves/Trainer/save_0/backup", "extra"));
    assert(!there("saves/.import"));

    // export, then import the .zip back as another slot: the same bytes
    assert(saves_export("Trainer", "out.zip") && there("out.zip"));
    assert(saves_import_stage("out.zip", err, sizeof err));
    assert(!saves_import_commit("Trainer", id));  // a taken name: false, the staged save stays for another try
    assert(there("saves/.import/save_0/main"));
    assert(saves_import_commit("Trainer 2", id));
    assert(same("saves/Trainer 2/save_0/main", "ZA save one"));

    // the name an import suggests: our export's file name gives the slot's name back; another file, the trainer's
    // name, play time and the file's name (the stub save: no trainer, 0:00)
    char nm[64];
    rename("out.zip", "Lega Kalos - 12h34 - 2026-10-31.zip");
    assert(saves_import_stage("Lega Kalos - 12h34 - 2026-10-31.zip", err, sizeof err));
    saves_import_name("/x/Lega Kalos - 12h34 - 2026-10-31.zip", nm, sizeof nm);
    assert(!strcmp(nm, "Lega Kalos"));
    saves_import_name("/x/Trainer - 1h05 - 2026-01-02.zip", nm, sizeof nm);
    assert(!strcmp(nm, "Trainer 3"));  // ("Trainer" and "Trainer 2" are slots already)
    saves_import_name("/x/Il mio backup.zip", nm, sizeof nm);
    assert(!strcmp(nm, "Imported - 0h00 - Il mio backup"));
    saves_import_name("/x/2026-10-31_12.00.00", nm, sizeof nm);
    assert(!strcmp(nm, "Imported - 0h00 - 2026-10-31_120000"));
    rename("Lega Kalos - 12h34 - 2026-10-31.zip", "out.zip");

    // cancel drops the staged save
    assert(saves_import_stage("out.zip", err, sizeof err));
    saves_import_cancel();
    assert(!there("saves/.import"));

    // no save in it / not a Z-A save
    mkdir("empty", 0755);
    assert(!saves_import_stage("empty", err, sizeof err) && strstr(err, "No save"));
    mkdir("other", 0755);
    put("other/main", "XX not ours");
    assert(!saves_import_stage("other", err, sizeof err) && strstr(err, "not a Pok"));
    assert(!there("saves/.import"));

    // a linked `main` is not followed
    mkdir("linked", 0755);
    put("target", "ZA outside");
    assert(symlink("../target", "linked/main") == 0);
    assert(!saves_import_stage("linked", err, sizeof err));

    // a .zip whose entries climb out (../, an absolute path): refused, nothing written outside
    assert(system("/usr/bin/python3 -c \"import zipfile; z=zipfile.ZipFile('evil.zip','w'); "
                  "z.writestr('../escaped', 'x'); z.writestr('/tmp/saves_io_abs_escape', 'x'); "
                  "z.writestr('s/save_0/main', 'ZA evil'); z.close()\"") == 0);
    unlink("/tmp/saves_io_abs_escape");
    assert(!saves_import_stage("evil.zip", err, sizeof err));  // (tar refuses the whole archive)
    assert(!there("saves/escaped") && !there("escaped") && !there("../escaped") && !there("/tmp/saves_io_abs_escape"));

    // not an archive at all
    put("junk.zip", "not a zip");
    assert(!saves_import_stage("junk.zip", err, sizeof err) && strstr(err, "couldn't be opened"));

    char rm[600];
    snprintf(rm, sizeof rm, "rm -rf '%s'", tmp);
    system(rm);
    printf("PASS: save import / export\n");
    return 0;
}
