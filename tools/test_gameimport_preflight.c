// Quick package preflight, before the launcher shows its setup progress overlay.
#include "gameimport.h"
#include "platform.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

bool rt_resource(const char *name, const char *dev_rel, char *out, size_t n) { (void)name; (void)dev_rel; (void)out; (void)n; return false; }
PlatProc plat_spawn(const char *const argv[], const char *log_path, bool append_log) { (void)argv; (void)log_path; (void)append_log; return 0; }
int plat_proc_wait(PlatProc p, bool block) { (void)p; (void)block; return -1; }
void plat_proc_kill(PlatProc p) { (void)p; }
uint64_t plat_now_ns(void) { return 0; }
void plat_sleep_until_ns(uint64_t t) { (void)t; }

static void pfs0(const char *path) {
    unsigned char h[42] = {0};
    memcpy(h, "PFS0", 4); h[4] = 1; h[8] = 2;  // one entry, two-byte name table
    h[40] = 'a'; h[41] = 0;
    FILE *f = fopen(path, "wb"); assert(f); assert(fwrite(h, 1, sizeof h, f) == sizeof h); fclose(f);
}

static void bytes(const char *path, const void *data, size_t n) {
    FILE *f = fopen(path, "wb"); assert(f); assert(fwrite(data, 1, n, f) == n); fclose(f);
}

int main(void) {
    char dir[] = "/tmp/monzamac-preflight.XXXXXX"; assert(mkdtemp(dir));
    char base[256], update[256], keys[256], bad[16], why[256];
    snprintf(base, sizeof base, "%s/base.nsp", dir);
    snprintf(update, sizeof update, "%s/update.nsp", dir);
    snprintf(keys, sizeof keys, "%s/prod.keys", dir);
    pfs0(base); pfs0(update); bytes(keys, "k", 1);

    unsigned char sevenzip[64] = {'7','z',0xbc,0xaf,0x27,0x1c};
    bytes(update, sevenzip, sizeof sevenzip);
    assert(!gameimport_preflight(base, update, keys, bad, sizeof bad, why, sizeof why));
    assert(!strcmp(bad, "update"));
    assert(strstr(why, "7z") && strstr(why, ".nsp"));

    pfs0(update);
    assert(gameimport_preflight(base, update, keys, bad, sizeof bad, why, sizeof why));
    assert(!bad[0] && !why[0]);
    assert(!gameimport_preflight(base, base, keys, bad, sizeof bad, why, sizeof why));
    assert(!strcmp(bad, "update"));
    assert(!gameimport_preflight(base, update, "/missing/prod.keys", bad, sizeof bad, why, sizeof why));
    assert(!strcmp(bad, "keys"));

    unlink(base); unlink(update); unlink(keys); rmdir(dir);
    puts("PASS preflight detects mislabeled 7z before setup and identifies the bad field");
    return 0;
}
